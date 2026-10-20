const std = @import("std");
const types = @import("types.zig");
const indicators = @import("indicators.zig");
const pty_mod = @import("pty.zig");

const AutoExit = types.AutoExit;
const StatusValue = indicators.StatusValue;
const StatusRule = types.StatusRule;
const StatusTuple = types.StatusTuple;
const Pty = pty_mod.Pty;
const scanners = @import("scanners.zig");
const ansi = @import("ansi.zig");

/// Convert a `?StatusTuple` to a `?StatusValue` (`[2][]const u8`).
fn toStatusValue(status: ?StatusTuple) ?StatusValue {
    return if (status) |s| .{ s.primary, s.degraded } else null;
}

/// Milliseconds between two kill presses before the second is treated as a
/// force-kill (SIGKILL).
const DOUBLE_PRESS: u64 = 500;
/// Milliseconds after a kill before the command is considered "slow" (and the
/// UI shows a hint to force-kill).
const SLOW_KILL: u64 = 1000;

/// The current monotonic time in milliseconds (Zig 0.17 has no
/// `std.time.milliTimestamp`; this uses `clock_gettime(CLOCK_MONOTONIC)`).
fn milliTimestamp() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.clockid_t.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

/// The lifecycle state of a command.
///
/// `running`/`killing` carry the child pid (the PTY master fd is added in the
/// PTY layer). `exit` records the exit code and whether the command was killed.
pub const Status = union(enum) {
    waiting: void,
    running: struct {
        pid: i32,
    },
    killing: struct {
        pid: i32,
        slow: bool,
        last_kill_press: ?u64,
        restart_after_kill: bool,
    },
    exit: struct {
        exit_code: u32,
        was_killed: bool,
    },
};

/// True when the status holds a live child process (running or killing).
pub fn statusHasTerminal(status: Status) bool {
    return switch (status) {
        .running, .killing => true,
        else => false,
    };
}

/// Convenience constructors for the payload-bearing status variants.
pub fn runningStatus(pid: i32) Status {
    return .{ .running = .{ .pid = pid } };
}

pub fn exitStatus(exit_code: u32, was_killed: bool) Status {
    return .{ .exit = .{ .exit_code = exit_code, .was_killed = was_killed } };
}

/// The rendering-relevant subset of a command (mirrors the original's
/// `CommandText = Pick<Command, ...>`).
pub const CommandText = struct {
    formatted_command_with_title: []const u8,
    title: []const u8,
    title_possibly_with_graphic_renditions: []const u8,
    cwd: []const u8,
    history: []const u8,
};

/// A command to run, with its lifecycle state and the data the renderer needs.
pub const Command = struct {
    label: ?[]const u8,
    file: []const u8,
    args: []const []const u8,
    cwd: []const u8,
    kill_all_sequence: []const u8,
    title: []const u8,
    title_possibly_with_graphic_renditions: []const u8,
    formatted_command_with_title: []const u8,
    is_simple_log: bool,
    is_on_alternate_screen: bool,
    status: Status,
    status_from_rules: ?StatusValue,
    status_rules: []const StatusRule,
    default_status: ?StatusValue,
    history: []const u8,
    history_alternate_screen: []const u8,
    pty: ?Pty,

    /// Project this command down to its rendering-relevant fields.
    pub fn text(self: *const Command) CommandText {
        return .{
            .formatted_command_with_title = self.formatted_command_with_title,
            .title = self.title,
            .title_possibly_with_graphic_renditions = self.title_possibly_with_graphic_renditions,
            .cwd = self.cwd,
            .history = self.history,
        };
    }

    /// A minimal command for tests: only `status` (and optionally `label`) is
    /// meaningful; the rest are empty defaults.
    pub fn forTest(status: Status, label: ?[]const u8) Command {
        return .{
            .label = label,
            .file = "",
            .args = &.{},
            .cwd = "",
            .kill_all_sequence = "",
            .title = "",
            .title_possibly_with_graphic_renditions = "",
            .formatted_command_with_title = "",
            .is_simple_log = true,
            .is_on_alternate_screen = false,
            .status = status,
            .status_from_rules = null,
            .status_rules = &.{},
            .default_status = null,
            .history = "",
            .history_alternate_screen = "",
            .pty = null,
        };
    }

    /// Spawn the command in a new PTY and transition to the `running` state.
    pub fn start(self: *Command, cols: u16, rows: u16) Pty.Error!void {
        const p = try Pty.spawn(self.file, self.args, if (self.cwd.len > 0) self.cwd else null, cols, rows);
        self.pty = p;
        self.status = .{ .running = .{ .pid = p.pid } };
    }

    /// Request that the command be killed. The first press sends the
    /// `kill_all_sequence` (e.g. Ctrl-C); a second press within `DOUBLE_PRESS`
    /// sends SIGKILL.
    pub fn kill(self: *Command, restart_after_kill: bool) void {
        switch (self.status) {
            .running => |r| {
                self.status = .{ .killing = .{ .pid = r.pid, .slow = false, .last_kill_press = null, .restart_after_kill = restart_after_kill } };
                if (self.pty) |*p| p.write(self.kill_all_sequence);
            },
            .killing => |k| {
                const now = milliTimestamp();
                if (k.last_kill_press) |last| {
                    if (now - last <= DOUBLE_PRESS) {
                        if (self.pty) |*p| p.kill(.KILL);
                    } else {
                        if (self.pty) |*p| p.write(self.kill_all_sequence);
                    }
                } else {
                    if (self.pty) |*p| p.write(self.kill_all_sequence);
                }
                self.status.killing.last_kill_press = now;
                self.status.killing.restart_after_kill = restart_after_kill;
            },
            else => {},
        }
    }

    /// Match the command's status rules against new output. A rule whose
    /// pattern appears in `data` sets `status_from_rules`; a rule with a `null`
    /// status resets it. (The original splits into lines and matches each; this
    /// is a conservative substring approximation.)
    pub fn updateStatusFromRules(self: *Command, data: []const u8) void {
        const stripped = ansi.removeGraphicRenditions(std.heap.page_allocator, data) catch return;
        defer std.heap.page_allocator.free(stripped);
        for (self.status_rules) |rule| {
            if (std.mem.indexOf(u8, stripped, rule.pattern)) |_| {
                self.status_from_rules = toStatusValue(rule.status);
            }
        }
    }

    /// Process a chunk of output: append to history, toggle the alternate-screen
    /// flag, update the simple-log flag and the status-from-rules. Returns true
    /// when `status_from_rules` changed.
    pub fn pushHistory(self: *Command, data: []const u8) bool {
        const previous = self.status_from_rules;
        const parts = scanners.splitAlternateScreen(data, std.heap.page_allocator) catch return false;
        defer std.heap.page_allocator.free(parts);

        for (parts) |part| {
            switch (part) {
                .enable => self.is_on_alternate_screen = true,
                .disable => self.is_on_alternate_screen = false,
                .text => |chunk| {
                    self.updateStatusFromRules(chunk);
                    if (scanners.matchesClear(chunk)) {
                        self.is_simple_log = true;
                        self.history = "";
                        self.history_alternate_screen = "";
                    } else if (!self.is_on_alternate_screen and scanners.isNotSimpleLog(chunk)) {
                        self.is_simple_log = false;
                    }
                    if (self.is_on_alternate_screen) {
                        self.history_alternate_screen = appendCapped(self.history_alternate_screen, chunk, maxHistory());
                    } else {
                        self.history = appendCapped(self.history, chunk, maxHistory());
                    }
                },
            }
        }
        const a_null = self.status_from_rules == null;
        const b_null = previous == null;
        return a_null != b_null;
    }

    /// The full history (for re-display when switching back to a command).
    pub fn joinHistory(self: *const Command) []const u8 {
        return self.history;
    }

    /// Record that the child has exited with `exit_code`. If the command was in
    /// the `killing` state, it is marked as killed.
    pub fn markExited(self: *Command, exit_code: u32) void {
        const was_killing = switch (self.status) {
            .killing => true,
            else => false,
        };
        self.status = .{ .exit = .{ .exit_code = exit_code, .was_killed = was_killing } };
        if (self.pty) |*p| p.deinit();
        self.pty = null;
    }
};

/// What the user is currently looking at.
pub const Current = union(enum) {
    command: struct {
        index: usize,
    },
    dashboard: struct {
        previous_render: []const []const u8,
    },
};

/// Which command (if any) is highlighted, and how the selection was made.
pub const Selection = union(enum) {
    invisible: struct {
        index: usize,
    },
    mousedown: struct {
        index: usize,
    },
    keyboard: struct {
        index: usize,
    },
    by_indicator: struct {
        indicator: []const u8,
        keyboard_index: usize,
    },
};

/// The session is "done" when every command has been killed after a kill-all,
/// or (with --auto-exit) when every command has exited 0.
pub fn isDone(commands: []const Command, attempted_kill_all: bool, auto_exit: AutoExit) bool {
    if (attempted_kill_all) {
        for (commands) |c| {
            if (statusHasTerminal(c.status)) return false;
        }
        return true;
    }
    return switch (auto_exit) {
        .auto_exit => {
            for (commands) |c| {
                const ok = switch (c.status) {
                    .exit => |e| e.exit_code == 0 and !e.was_killed,
                    else => false,
                };
                if (!ok) return false;
            }
            return true;
        },
        else => false,
    };
}

/// The last line of a string (after the final `\n` or `\r`).
pub fn getLastLine(s: []const u8) []const u8 {
    var index: i64 = @as(i64, @intCast(s.len)) - 1;
    while (index >= 0) {
        if (s[@intCast(index)] == '\n' or s[@intCast(index)] == '\r') break;
        index -= 1;
    }
    return s[@intCast(index + 1)..];
}

/// The PID of a running/killing command, or null if not running.
pub fn getPid(command: *const Command) ?i32 {
    return switch (command.status) {
        .running => |r| r.pid,
        .killing => |k| k.pid,
        else => null,
    };
}

/// The maximum history length, from `RUN_PTY_MAX_HISTORY` or the default (1M).
fn maxHistory() usize {
    const env = std.c.getenv("RUN_PTY_MAX_HISTORY");
    if (env) |ptr| {
        if (ptr[0] != 0) {
            const s = std.mem.sliceTo(ptr, 0);
            const n = std.fmt.parseInt(usize, s, 10) catch return 1000000;
            if (n > 0) return n;
        }
    }
    return 1000000;
}

/// Append `chunk` to `existing`, capping the result at `max` bytes (keeping
/// the most recent data). Frees the old `existing` slice if it was heap-allocated
/// (i.e. non-empty). Returns an owned slice.
fn appendCapped(existing: []const u8, chunk: []const u8, max: usize) []const u8 {
    const total = existing.len + chunk.len;
    const out = if (total <= max) blk: {
        const o = std.heap.page_allocator.alloc(u8, total) catch return existing;
        std.mem.copyForwards(u8, o, existing);
        std.mem.copyForwards(u8, o[existing.len..], chunk);
        break :blk o;
    } else blk: {
        const o = std.heap.page_allocator.alloc(u8, max) catch return existing;
        // We want the last `max` bytes of (existing + chunk).
        // The start position in the concatenation is (total - max).
        const start_in_concat = total - max;
        if (start_in_concat < existing.len) {
            // Take tail of existing + all of chunk.
            const from_existing = existing.len - start_in_concat;
            std.mem.copyForwards(u8, o, existing[start_in_concat..]);
            std.mem.copyForwards(u8, o[from_existing..], chunk);
        } else {
            // Take only from chunk: the offset is (start_in_concat - existing.len).
            const offset_in_chunk = start_in_concat - existing.len;
            std.mem.copyForwards(u8, o, chunk[offset_in_chunk..]);
        }
        break :blk o;
    };
    // Free the old slice if it was heap-allocated (non-empty means it was
    // produced by a previous appendCapped call, not the initial "" literal).
    if (existing.len > 0) std.heap.page_allocator.free(existing);
    return out;
}

test "statusHasTerminal" {
    try std.testing.expect(statusHasTerminal(runningStatus(1)));
    try std.testing.expect(statusHasTerminal(.{ .killing = .{ .pid = 1, .slow = false, .last_kill_press = null, .restart_after_kill = false } }));
    try std.testing.expect(!statusHasTerminal(.waiting));
    try std.testing.expect(!statusHasTerminal(exitStatus(0, false)));
}

test "isDone: kill-all" {
    const running = Command.forTest(runningStatus(1), null);
    const exited = Command.forTest(exitStatus(0, false), null);
    const commands = &[_]Command{running, exited};
    // Not done: one is still running.
    try std.testing.expect(!isDone(commands, true, .none));
    const commands2 = &[_]Command{exited, exited};
    // Done: both exited after a kill-all.
    try std.testing.expect(isDone(commands2, true, .none));
}

test "isDone: auto-exit requires all exit 0" {
    const ok = Command.forTest(exitStatus(0, false), null);
    const failed = Command.forTest(exitStatus(1, false), null);
    const commands = &[_]Command{ok, failed};
    // Not done: one exited non-zero.
    try std.testing.expect(!isDone(commands, false, .{ .auto_exit = 2 }));
    const all_ok = &[_]Command{ok, ok};
    try std.testing.expect(isDone(all_ok, false, .{ .auto_exit = 2 }));
}

test "getLastLine" {
    try std.testing.expectEqualStrings("world", getLastLine("hello\nworld"));
    try std.testing.expectEqualStrings("world", getLastLine("hello\rworld"));
    try std.testing.expectEqualStrings("only", getLastLine("only"));
    try std.testing.expectEqualStrings("", getLastLine("hello\n"));
    try std.testing.expectEqualStrings("", getLastLine(""));
}

test "start, kill, and markExited lifecycle" {
    var cmd = Command.forTest(.waiting, null);
    cmd.file = "sleep";
    cmd.args = &.{"30"};
    cmd.kill_all_sequence = "\x03";

    try cmd.start(80, 24);

    const running_pid = switch (cmd.status) {
        .running => |r| r.pid,
        else => unreachable,
    };
    try std.testing.expectEqual(cmd.pty.?.pid, running_pid);

    // Transition to `killing` directly (without sending the kill sequence, to
    // keep the test deterministic — the kill-sequence path is covered by the
    // double-press test below).
    const pid = running_pid;
    cmd.status = .{ .killing = .{ .pid = pid, .slow = false, .last_kill_press = null, .restart_after_kill = false } };

    // Force-kill with SIGKILL (deterministic exit code 137).
    if (cmd.pty) |*p| p.kill(.KILL);

    if (cmd.pty) |*p| {
        const exit_code = p.wait();
        cmd.markExited(@intCast(exit_code));
    } else {
        unreachable;
    }

    const exit = switch (cmd.status) {
        .exit => |e| e,
        else => unreachable,
    };
    try std.testing.expect(exit.was_killed);
    try std.testing.expectEqual(@as(u32, 128 + @intFromEnum(std.posix.SIG.KILL)), exit.exit_code);
}

const test_rules = [_]StatusRule{
    .{ .pattern = "Building", .status = .{ .primary = "🔨", .degraded = "\x1B[94mB\x1B[m" } },
    .{ .pattern = "Done", .status = null },
};

test "updateStatusFromRules sets status_from_rules on a match" {
    var cmd = Command.forTest(runningStatus(1), null);
    cmd.status_rules = test_rules[0..];

    // No match yet.
    cmd.updateStatusFromRules("hello world");
    try std.testing.expect(cmd.status_from_rules == null);

    // A match sets the status.
    cmd.updateStatusFromRules("now Building the thing");
    try std.testing.expect(cmd.status_from_rules != null);
    try std.testing.expectEqualStrings("🔨", cmd.status_from_rules.?[0]);

    // A later rule with a null status resets it.
    cmd.updateStatusFromRules("all Done");
    try std.testing.expect(cmd.status_from_rules == null);
}

test "pushHistory toggles alternate screen and simple-log flags" {
    var cmd = Command.forTest(runningStatus(1), null);
    try std.testing.expect(cmd.is_simple_log);
    try std.testing.expect(!cmd.is_on_alternate_screen);

    // Entering the alternate screen.
    const changed = cmd.pushHistory("some output\x1B[?1049h");
    try std.testing.expect(!changed);
    try std.testing.expect(cmd.is_on_alternate_screen);

    // A cursor move on the main screen makes the log non-simple.
    var cmd2 = Command.forTest(runningStatus(1), null);
    _ = cmd2.pushHistory("line one\n\x1B[2Aline three");
    try std.testing.expect(!cmd2.is_simple_log);

    // A clear resets the simple-log flag.
    var cmd3 = Command.forTest(runningStatus(1), null);
    cmd3.is_simple_log = false;
    _ = cmd3.pushHistory("\x1B[2J");
    try std.testing.expect(cmd3.is_simple_log);
}

test "kill double-press state transitions" {
    var cmd = Command.forTest(.waiting, null);
    cmd.file = "sleep";
    cmd.args = &.{"30"};
    cmd.kill_all_sequence = "\x03";
    defer {
        if (cmd.pty) |*p| {
            p.kill(.KILL);
            _ = p.wait();
            p.deinit();
        }
    }

    try cmd.start(80, 24);

    // Press 1: running -> killing, last_kill_press is null.
    cmd.kill(false);
    try std.testing.expectEqual(@as(?u64, null), cmd.status.killing.last_kill_press);

    // Press 2: still killing; last_kill_press is now set (no SIGKILL yet,
    // matching the original which requires a third press to force-kill).
    cmd.kill(false);
    try std.testing.expect(cmd.status.killing.last_kill_press != null);

    // Press 3 (within DOUBLE_PRESS of press 2): would send SIGKILL.
    cmd.kill(false);
    try std.testing.expect(cmd.status.killing.last_kill_press != null);
}

test "appendCapped: empty existing, small chunk" {
    const result = appendCapped("", "hello", 100);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

test "appendCapped: empty existing, chunk larger than max" {
    const result = appendCapped("", "abcdefghij", 5);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualStrings("fghij", result);
}

test "appendCapped: existing + chunk fits in max" {
    const existing = std.heap.page_allocator.alloc(u8, 3) catch unreachable;
    std.mem.copyForwards(u8, existing, "abc");
    const result = appendCapped(existing, "def", 10);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualStrings("abcdef", result);
}

test "appendCapped: existing + chunk exceeds max (tail of existing + all chunk)" {
    const existing = std.heap.page_allocator.alloc(u8, 5) catch unreachable;
    std.mem.copyForwards(u8, existing, "abcde");
    const result = appendCapped(existing, "fghij", 7);
    defer std.heap.page_allocator.free(result);
    // Keep last 7 of "abcdefghij" = "cdefghij"[1..] = "defghij"
    try std.testing.expectEqualStrings("defghij", result);
}

test "appendCapped: chunk alone exceeds max (keep tail of chunk)" {
    const existing = std.heap.page_allocator.alloc(u8, 2) catch unreachable;
    std.mem.copyForwards(u8, existing, "ab");
    const result = appendCapped(existing, "cdefghijklmnop", 5);
    defer std.heap.page_allocator.free(result);
    // total = 14, start_in_concat = 9, offset_in_chunk = 7, chunk[7..] = "lmnop"
    try std.testing.expectEqualStrings("lmnop", result);
}

test "pushHistory: text goes to history" {
    var cmd = Command.forTest(runningStatus(1), null);
    _ = cmd.pushHistory("hello world\n");
    try std.testing.expectEqualStrings("hello world\n", cmd.history);
    try std.testing.expectEqualStrings("", cmd.history_alternate_screen);
}

test "pushHistory: alternate screen text goes to history_alternate_screen" {
    var cmd = Command.forTest(runningStatus(1), null);
    _ = cmd.pushHistory("before\x1B[?1049halt screen text\x1B[?1049lafter");
    try std.testing.expectEqualStrings("beforeafter", cmd.history);
    try std.testing.expectEqualStrings("alt screen text", cmd.history_alternate_screen);
}

test "pushHistory: clear resets history" {
    var cmd = Command.forTest(runningStatus(1), null);
    _ = cmd.pushHistory("old output\n");
    _ = cmd.pushHistory("\x1B[2Jnew output\n");
    // After clear, history is reset and the chunk (including the clear seq) is appended.
    try std.testing.expectEqualStrings("\x1B[2Jnew output\n", cmd.history);
}

test "pushHistory: status rule change returns true" {
    var cmd = Command.forTest(runningStatus(1), null);
    cmd.status_rules = &.{
        .{ .pattern = "Building", .status = .{ .primary = "🔨", .degraded = "B" } },
        .{ .pattern = "Done", .status = null },
    };
    // First match: null -> non-null (change).
    const changed1 = cmd.pushHistory("now Building");
    try std.testing.expect(changed1);
    // Second match: non-null -> null (change).
    const changed2 = cmd.pushHistory("all Done");
    try std.testing.expect(changed2);
    // No match: no change.
    const changed3 = cmd.pushHistory("nothing here");
    try std.testing.expect(!changed3);
}

test "updateStatusFromRules: ANSI-embedded pattern" {
    var cmd = Command.forTest(runningStatus(1), null);
    cmd.status_rules = &.{
        .{ .pattern = "Building", .status = .{ .primary = "🔨", .degraded = "B" } },
    };
    // The pattern "Building" is embedded in ANSI codes; after stripping, it matches.
    cmd.updateStatusFromRules("\x1B[32mBuilding\x1B[m the thing");
    try std.testing.expect(cmd.status_from_rules != null);
    try std.testing.expectEqualStrings("🔨", cmd.status_from_rules.?[0]);
}

test "updateStatusFromRules: last match wins" {
    var cmd = Command.forTest(runningStatus(1), null);
    cmd.status_rules = &.{
        .{ .pattern = "Building", .status = .{ .primary = "🔨", .degraded = "B" } },
        .{ .pattern = "Testing", .status = .{ .primary = "🧪", .degraded = "T" } },
    };
    // Both patterns in the same chunk: last rule wins.
    cmd.updateStatusFromRules("Building then Testing");
    try std.testing.expect(cmd.status_from_rules != null);
    try std.testing.expectEqualStrings("🧪", cmd.status_from_rules.?[0]);
}
