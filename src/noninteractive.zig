//! Non-interactive (CI) mode: run commands with a concurrency limit, stream
//! their output to stdout, and exit with the appropriate code. Used when stdin
//! is not a TTY and `--auto-exit` is set.
const std = @import("std");
const Allocator = std.mem.Allocator;
const command_mod = @import("command.zig");
const render = @import("render.zig");
const indicators = @import("indicators.zig");
const scanners = @import("scanners.zig");
const types = @import("types.zig");
const labels = @import("labels.zig");

const Command = command_mod.Command;
const AutoExit = types.AutoExit;
const Env = indicators.Env;

// Darwin poll event bits (not exposed by std.posix).
const POLLIN: i16 = 0x0001;
const POLLHUP: i16 = 0x0020;
const POLLERR: i16 = 0x0008;

/// Run the given commands non-interactively. Streams each command's output to
/// `writer` as it is produced, prints an exit block when each command finishes,
/// and returns the process exit code (0 when every command exited 0, else 1).
pub fn run(allocator: Allocator, descriptions: []const types.CommandDescription, auto_exit: AutoExit, env: Env, writer: *std.Io.Writer) !u32 {
    const max_parallel = switch (auto_exit) {
        .auto_exit => |n| @max(1, n),
        else => 1,
    };

    var commands = std.array_list.Managed(Command).init(allocator);
    defer {
        for (commands.items) |*cmd| cmd.deinit();
        commands.deinit();
    }

    for (descriptions, 0..) |desc, i| {
        const cmd = Command{
            .allocator = allocator,
            .label = if (i < labels.ALL_LABELS.len) labels.ALL_LABELS[i .. i + 1] else null,
            .file = desc.command[0],
            .args = desc.command[1..],
            .cwd = desc.cwd,
            .kill_all_sequence = desc.kill_all_sequence,
            .title = desc.title,
            .title_possibly_with_graphic_renditions = desc.title,
            .formatted_command_with_title = desc.title,
            .is_simple_log = true,
            .is_on_alternate_screen = false,
            .status = .waiting,
            .status_from_rules = null,
            .status_rules = desc.status,
            .default_status = desc.default_status,
            .history = "",
            .history_alternate_screen = "",
            .pty = null,
        };
        try commands.append(cmd);
    }

    // Start the first batch (up to the concurrency limit); the rest wait.
    const first_batch = @min(max_parallel, commands.items.len);
    for (0..commands.items.len) |i| {
        const start_now = i < first_batch;
        if (start_now) {
            try commands.items[i].start(80, 24);
        }
        const indicator = pick(if (start_now) indicators.running else indicators.waiting, env);
        const title = try render.commandTitleOnlyWithIndicator(allocator, indicator, &commands.items[i].text(), env);
        defer allocator.free(title);
        try writer.writeAll(title);
        try writer.writeAll("\n\n");
    }

    const attempted_kill_all = false;

    while (true) {
        // Build the poll set from the live (running/killing) commands, tracking
        // which command each pollfd belongs to.
        var pollfds = std.array_list.Managed(std.posix.pollfd).init(allocator);
        defer pollfds.deinit();
        var cmd_of_pollfd = std.array_list.Managed(usize).init(allocator);
        defer cmd_of_pollfd.deinit();
        for (commands.items, 0..) |*cmd, i| {
            if (cmd.pty) |*p| {
                try pollfds.append(.{ .fd = p.master, .events = POLLIN, .revents = 0 });
                try cmd_of_pollfd.append(i);
            }
        }

        // Block until at least one PTY has data (or one exits).
        if (pollfds.items.len > 0) {
            _ = std.posix.poll(pollfds.items, -1) catch {};
        }

        var any_exited = false;
        for (pollfds.items, 0..) |*pfd, i| {
            const cmd = &commands.items[cmd_of_pollfd.items[i]];
            const readable = (pfd.revents & (POLLIN | POLLHUP | POLLERR)) != 0;
            if (readable) {
                var buf: [4096]u8 = undefined;
                const n = cmd.pty.?.read(&buf) catch 0;
                if (n > 0) {
                    const data = buf[0..n];
                    // Respond to terminal queries with fake responses.
                    if (scanners.isTerminalQuery(data)) {
                        const response = try scanners.respondToRequestFake(allocator, data);
                        defer allocator.free(response);
                        if (response.len > 0) {
                            cmd.pty.?.write(response);
                        }
                        continue;
                    }
                    _ = cmd.pushHistory(data);
                    try writer.writeAll(data);
                }
            }
            if (cmd.pty.?.tryWait()) |exit_code| {
                any_exited = true;
                try handleExit(allocator, &commands, cmd, @intCast(exit_code), env, writer);
            }
        }

        // Start the next waiting command when a slot frees up.
        if (any_exited and !attempted_kill_all) {
            var running_count = countRunning(&commands);
            if (running_count < max_parallel) {
                for (commands.items) |*cmd| {
                    if (running_count >= max_parallel) break;
                    if (switch (cmd.status) {
                        .waiting => true,
                        else => false,
                    }) {
                        try cmd.start(80, 24);
                        const title = try render.commandTitleOnlyWithIndicator(allocator, pick(indicators.running, env), &cmd.text(), env);
                        defer allocator.free(title);
                        try writer.writeAll(title);
                        try writer.writeAll("\n\n");
                        running_count += 1;
                    }
                }
            }
        }

        // Exit when all commands have finished.
        if (allExited(&commands)) {
            const summary = try render.drawSummary(allocator, commands.items, env);
            defer allocator.free(summary);
            try writer.writeAll(summary);
            const num_exit = commands.items.len;
            const num_exit0 = countExit0(&commands);
            return if (attempted_kill_all or num_exit0 != num_exit) 1 else 0;
        }
    }
}

fn handleExit(allocator: Allocator, commands: *std.array_list.Managed(Command), cmd: *Command, exit_code: u32, env: Env, writer: *std.Io.Writer) !void {
    // Drain remaining PTY output before closing.
    if (cmd.pty) |*pty| {
        const remaining = try pty.drain(allocator);
        defer allocator.free(remaining);
        if (remaining.len > 0) {
            _ = cmd.pushHistory(remaining);
            try writer.writeAll(remaining);
        }
    }
    cmd.markExited(exit_code);
    const num_exited = countExited(commands);
    const block = try render.exitTextAndHistory(allocator, &cmd.text(), exit_code, num_exited, commands.items.len, env);
    defer allocator.free(block);
    try writer.writeAll(block);
}

fn countRunning(commands: *std.array_list.Managed(Command)) usize {
    var count: usize = 0;
    for (commands.items) |*cmd| {
        if (command_mod.statusHasTerminal(cmd.status)) count += 1;
    }
    return count;
}

fn countExited(commands: *std.array_list.Managed(Command)) usize {
    var count: usize = 0;
    for (commands.items) |*cmd| {
        if (switch (cmd.status) {
            .exit => true,
            else => false,
        }) count += 1;
    }
    return count;
}

fn countExit0(commands: *std.array_list.Managed(Command)) usize {
    var count: usize = 0;
    for (commands.items) |*cmd| {
        if (switch (cmd.status) {
            .exit => |e| e.exit_code == 0 and !e.was_killed,
            else => false,
        }) count += 1;
    }
    return count;
}

fn allExited(commands: *std.array_list.Managed(Command)) bool {
    for (commands.items) |*cmd| {
        if (!switch (cmd.status) {
            .exit => true,
            else => false,
        }) return false;
    }
    return true;
}

fn pick(ind: indicators.Indicator, env: Env) []const u8 {
    return indicators.pick(ind, env);
}

test "exit-code helpers" {
    const allocator = std.testing.allocator;
    var commands = std.array_list.Managed(Command).init(allocator);
    defer commands.deinit();

    const ok = Command.forTest(command_mod.exitStatus(0, false), null);
    const failed = Command.forTest(command_mod.exitStatus(1, false), null);
    const running = Command.forTest(command_mod.runningStatus(1), null);
    try commands.append(ok);
    try commands.append(failed);
    try commands.append(running);

    try std.testing.expectEqual(@as(usize, 1), countRunning(&commands));
    try std.testing.expectEqual(@as(usize, 2), countExited(&commands));
    try std.testing.expectEqual(@as(usize, 1), countExit0(&commands));
    try std.testing.expect(!allExited(&commands));

    // Mark the running one as exited 0; now all are exited and all exit 0.
    commands.items[2].markExited(0);
    try std.testing.expect(allExited(&commands));
    try std.testing.expectEqual(@as(usize, 2), countExit0(&commands));
}
