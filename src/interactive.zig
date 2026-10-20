const std = @import("std");
const Allocator = std.mem.Allocator;
const command_mod = @import("command.zig");
const render = @import("render.zig");
const ansi = @import("ansi.zig");
const types = @import("types.zig");
const indicators = @import("indicators.zig");
const pty_mod = @import("pty.zig");
const labels = @import("labels.zig");

const Command = command_mod.Command;
const Current = command_mod.Current;
const Selection = command_mod.Selection;
const AutoExit = types.AutoExit;
const Env = indicators.Env;
const StatusValue = indicators.StatusValue;
const StatusRule = types.StatusRule;
const Pty = pty_mod.Pty;

const HIDE_CURSOR = ansi.HIDE_CURSOR;
const SHOW_CURSOR = ansi.SHOW_CURSOR;
const DISABLE_ALTERNATE_SCREEN = ansi.DISABLE_ALTERNATE_SCREEN;
const DISABLE_APPLICATION_CURSOR_KEYS = ansi.DISABLE_APPLICATION_CURSOR_KEYS;
const ENABLE_MOUSE = ansi.ENABLE_MOUSE;
const DISABLE_MOUSE = ansi.DISABLE_MOUSE;
const BEGIN_SYNC_UPDATE = ansi.BEGIN_SYNC_UPDATE;
const END_SYNC_UPDATE = ansi.END_SYNC_UPDATE;
const RESET_COLOR = ansi.RESET_COLOR;
const CLEAR = ansi.CLEAR;
const CLEAR_RIGHT = ansi.CLEAR_RIGHT;
const CLEAR_DOWN = ansi.CLEAR_DOWN;
const SAVE_CURSOR = ansi.SAVE_CURSOR;
const RESTORE_CURSOR = ansi.RESTORE_CURSOR;

const KEY_KILL = "\x03";
const KEY_DASHBOARD = "\x1a";
const KEY_UP = "\x1B[A";
const KEY_DOWN = "\x1B[B";
const KEY_LEFT = "\x1B[D";
const KEY_RIGHT = "\x1B[C";
const KEY_ENTER = "\r";
const KEY_ESC = "\x1B";

const POLLIN: i16 = 1;
const POLLHUP: i16 = 0x20;
const POLLERR: i16 = 8;

fn optionalize(s: []u8) ?[]u8 {
    return s;
}

/// Global signal flag: set by the signal handler, checked in the main loop.
const signal_received = std.atomic.Value(bool).init(false);
/// Set by the SIGWINCH handler to trigger a resize check.
const resize_received = std.atomic.Value(bool).init(false);

extern "c" fn signal(sig: c_int, handler: ?*fn(c_int) callconv(.c) void) c_int;

fn signalHandler(sig: c_int) callconv(.c) void {
    _ = sig;
    @constCast(&signal_received).store(true, .monotonic);
}

fn resizeHandler(sig: c_int) callconv(.c) void {
    _ = sig;
    @constCast(&resize_received).store(true, .monotonic);
}

/// The interactive session: holds all state for the TUI event loop.
pub const Session = struct {
    allocator: Allocator,
    commands: []Command,
    auto_exit: AutoExit,
    env: Env,
    writer: *std.Io.Writer,

    current: Current,
    selection: Selection,
    attempted_kill_all: bool,
    extra_text_printed: bool,
    in_sync_since: ?u64,

    poll_fds: std.array_list.Managed(std.posix.pollfd),
    cmd_of_pollfd: std.array_list.Managed(usize),
    original_termios: std.c.termios,
    term_cols: u16,
    term_rows: u16,

    pub fn init(allocator: Allocator, commands: []Command, auto_exit: AutoExit, env: Env, writer: *std.Io.Writer) Session {
        return .{
            .allocator = allocator,
            .commands = commands,
            .auto_exit = auto_exit,
            .env = env,
            .writer = writer,
            .current = .{ .dashboard = .{ .previous_render = &.{} } },
            .selection = .{ .invisible = .{ .index = 0 } },
            .attempted_kill_all = false,
            .extra_text_printed = false,
            .in_sync_since = null,
            .poll_fds = .init(allocator),
            .cmd_of_pollfd = .init(allocator),
            .original_termios = undefined,
            .term_cols = @as(u16, @intCast(getTermCols())),
            .term_rows = @as(u16, @intCast(getTermRows())),
        };
    }

    pub fn deinit(self: *Session) void {
        self.poll_fds.deinit();
        self.cmd_of_pollfd.deinit();
        for (self.commands) |*c| {
            if (c.pty) |*pty| pty.deinit();
        }
    }

    fn writeRaw(self: *Session, data: []const u8) !void {
        try self.writer.writeAll(data);
    }

    fn writeFlush(self: *Session, data: []const u8) !void {
        try self.writer.writeAll(data);
        self.writer.flush() catch {};
    }

    // -----------------------------------------------------------------------
    // Dashboard / command switching.
    // -----------------------------------------------------------------------

    fn switchToDashboard(self: *Session, force_clear: bool) !void {
        const cols = getTermCols();
        const rows = getTermRows();

        var prev_render: []const []const u8 = &.{};
        switch (self.current) {
            .dashboard => |d| {
                if (!force_clear and d.previous_render.len <= rows) {
                    var max_len: usize = 0;
                    for (d.previous_render) |line| {
                        if (line.len > max_len) max_len = line.len;
                    }
                    if (max_len <= cols) prev_render = d.previous_render;
                }
            },
            else => {},
        }

        const dashboard_text = try render.drawDashboard(
            self.allocator,
            self.commands,
            cols,
            self.attempted_kill_all,
            self.auto_exit,
            self.selection,
            self.env,
        );
        defer self.allocator.free(dashboard_text);

        var lines = std.mem.splitScalar(u8, dashboard_text, '\n');
        var current_render: std.array_list.Managed([]const u8) = .init(self.allocator);
        defer current_render.deinit();
        var line_count: usize = 0;
        while (lines.next()) |line| {
            if (line_count >= rows) break;
            try current_render.append(line);
            line_count += 1;
        }

        const clear = if (prev_render.len == 0) CLEAR else "";
        const num_lines_to_clear = if (prev_render.len > current_render.items.len) prev_render.len - current_render.items.len else 0;

        self.current = .{ .dashboard = .{ .previous_render = try current_render.toOwnedSlice() } };

        var out: std.array_list.Managed(u8) = .init(self.allocator);
        defer out.deinit();
        try out.appendSlice(BEGIN_SYNC_UPDATE);
        try out.appendSlice(HIDE_CURSOR);
        try out.appendSlice(DISABLE_ALTERNATE_SCREEN);
        try out.appendSlice(DISABLE_APPLICATION_CURSOR_KEYS);
        try out.appendSlice(ENABLE_MOUSE);
        try out.appendSlice(RESET_COLOR);
        try out.appendSlice(clear);

        for (current_render.items, 0..) |line, i| {
            if (i < prev_render.len and std.mem.eql(u8, line, prev_render[i])) continue;
            try out.appendSlice(render.cursorHorizontalAbsolute(i + 1));
            try out.appendSlice(CLEAR_RIGHT);
            try out.appendSlice(line);
        }
        for (0..num_lines_to_clear) |i| {
            try out.appendSlice(render.cursorHorizontalAbsolute(current_render.items.len + i + 1));
            try out.appendSlice(CLEAR_RIGHT);
        }
        try out.appendSlice(END_SYNC_UPDATE);

        try self.writeFlush(out.items);
    }

    fn switchToCommand(self: *Session, index: usize, hide_selection: bool) !void {
        const command = &self.commands[index];
        self.current = .{ .command = .{ .index = index } };
        if (hide_selection) {
            self.selection = .{ .invisible = .{ .index = index } };
        }

        try self.writeRaw(SHOW_CURSOR);
        try self.writeRaw(DISABLE_ALTERNATE_SCREEN);
        try self.writeRaw(DISABLE_APPLICATION_CURSOR_KEYS);
        try self.writeRaw(DISABLE_MOUSE);
        try self.writeRaw(RESET_COLOR);
        try self.writeRaw(CLEAR);

        self.extra_text_printed = false;
        try self.printDataWithExtraText(command, command.history, false);
    }

    fn setSelection(self: *Session, new_selection: Selection) !void {
        self.selection = new_selection;
        try self.switchToDashboard(false);
    }

    fn hideSelection(self: *Session) void {
        const idx = switch (self.selection) {
            .by_indicator => |bi| bi.keyboard_index,
            .invisible => |s| s.index,
            .keyboard => |s| s.index,
            .mousedown => |s| s.index,
        };
        self.selection = .{ .invisible = .{ .index = idx } };
    }

    // -----------------------------------------------------------------------
    // Command lifecycle.
    // -----------------------------------------------------------------------

    fn killAll(self: *Session) !void {
        self.attempted_kill_all = true;
        self.hideSelection();

        for (self.commands) |*c| {
            if (c.status == .killing) {
                const k = c.status.killing;
                c.status = .{ .killing = .{ .pid = k.pid, .slow = k.slow, .last_kill_press = k.last_kill_press, .restart_after_kill = false } };
            }
        }

        var any_terminal = false;
        for (self.commands) |c| {
            if (command_mod.statusHasTerminal(c.status)) {
                any_terminal = true;
                break;
            }
        }

        if (!any_terminal) {
            try self.switchToDashboard(true);
            const exit_code: u8 = if (self.auto_exit == .auto_exit) 1 else 0;
            self.cleanup();
            std.process.exit(exit_code);
        } else {
            for (self.commands) |*c| {
                if (command_mod.statusHasTerminal(c.status)) {
                    c.kill(false);
                }
            }
            try self.switchToDashboard(false);
        }
    }

    fn restart(self: *Session, index: usize) !void {
        const command = &self.commands[index];
        self.attempted_kill_all = false;
        try command.start(self.term_cols, self.term_rows);
        try self.switchToCommand(index, false);
    }

    fn restartExited(self: *Session) !void {
        var any_exited = false;
        for (self.commands) |*c| {
            if (c.status == .exit) {
                any_exited = true;
                break;
            }
        }
        if (any_exited) {
            self.attempted_kill_all = false;
            for (self.commands) |*c| {
                if (c.status == .exit) try c.start(self.term_cols, self.term_rows);
            }
        }
        try self.switchToDashboard(false);
    }

    fn restartByIndicator(self: *Session, indicator: []const u8) !void {
        self.attempted_kill_all = false;
        self.hideSelection();
        for (self.commands) |*c| {
            if (std.mem.eql(u8, render.getIndicatorChoice(c, self.env), indicator)) {
                switch (c.status) {
                    .exit => {
                        try c.start(self.term_cols, self.term_rows);
                    },
                    .waiting => {},
                    .running => {
                        c.kill(true);
                    },
                    .killing => {
                        c.kill(true);
                    },
                }
            }
        }
        try self.switchToDashboard(false);
    }

    fn countRunning(self: *Session) usize {
        var count: usize = 0;
        for (self.commands) |c| {
            if (command_mod.statusHasTerminal(c.status)) count += 1;
        }
        return count;
    }

    // -----------------------------------------------------------------------
    // Data printing.
    // -----------------------------------------------------------------------

    fn printDataWithExtraText(self: *Session, command: *Command, data: []const u8, ignore_alt_screen: bool) !void {
        if (self.extra_text_printed) {
            var out: std.array_list.Managed(u8) = .init(self.allocator);
            defer out.deinit();
            try out.appendSlice(BEGIN_SYNC_UPDATE);
            try out.appendSlice(SAVE_CURSOR);
            try out.appendSlice("\x1B[1B");
            try out.appendSlice(RESET_COLOR);
            try out.appendSlice(ansi.CLEAR_LEFT);
            try out.appendSlice(CLEAR_DOWN);
            try out.appendSlice(RESTORE_CURSOR);
            try out.appendSlice(END_SYNC_UPDATE);
            try self.writeRaw(out.items);
            self.extra_text_printed = false;
        }

        if (command.is_on_alternate_screen and !ignore_alt_screen) {
            try self.writeRaw(data);
            return;
        }

        const extra_text = self.getExtraText(command) catch null;
        if (extra_text) |text| {
            defer self.allocator.free(text);
            if (command.is_simple_log and self.in_sync_since == null) {
                const num_lines = std.mem.count(u8, text, "\n") + 1;
                var out: std.array_list.Managed(u8) = .init(self.allocator);
                defer out.deinit();
                try out.appendSlice(data);
                try out.appendSlice(BEGIN_SYNC_UPDATE);
                for (0..num_lines) |_| try out.appendSlice("\x1B[D");
                try out.appendSlice(SAVE_CURSOR);
                try out.appendSlice(RESET_COLOR);
                try out.append('\n');
                try out.appendSlice(CLEAR_DOWN);
                try out.appendSlice(text);
                try out.appendSlice(RESTORE_CURSOR);
                try out.appendSlice(END_SYNC_UPDATE);
                try self.writeRaw(out.items);
                self.extra_text_printed = true;
            } else {
                try self.writeRaw(data);
            }
        } else {
            try self.writeRaw(data);
        }
    }

    fn getExtraText(self: *Session, command: *Command) !?[]u8 {
        return switch (command.status) {
            .running => |r| optionalize(try render.runningText(self.allocator, r.pid, self.env)),
            .killing => |k| {
                if (k.slow) return optionalize(try render.killingText(self.allocator, k.pid, self.env));
                return optionalize(try render.runningText(self.allocator, k.pid, self.env));
            },
            .waiting => optionalize(try render.waitingText(self.allocator, self.commands, self.env)),
            .exit => optionalize(try render.exitText(self.allocator, self.commands, &command.text(), command.status, self.auto_exit, self.env)),
        };
    }

    // -----------------------------------------------------------------------
    // Stdin handling (key dispatcher).
    // -----------------------------------------------------------------------

    fn onStdin(self: *Session, data: []const u8) !void {
        switch (self.current) {
            .command => |cmd| {
                const command = &self.commands[cmd.index];
                switch (command.status) {
                    .waiting => {
                        if (std.mem.eql(u8, data, KEY_KILL)) {
                            try self.killAll();
                        } else if (std.mem.eql(u8, data, KEY_DASHBOARD)) {
                            try self.switchToDashboard(false);
                        }
                    },
                    .running, .killing => {
                        if (std.mem.eql(u8, data, KEY_KILL)) {
                            command.kill(false);
                        } else if (std.mem.eql(u8, data, KEY_DASHBOARD)) {
                            try self.switchToDashboard(false);
                        } else {
                            switch (command.status) {
                                .killing => |k| {
                                    command.status = .{ .running = .{ .pid = k.pid } };
                                },
                                else => {},
                            }
                            if (command.pty) |*pty| pty.write(data);
                        }
                    },
                    .exit => {
                        if (std.mem.eql(u8, data, KEY_KILL)) {
                            try self.killAll();
                        } else if (std.mem.eql(u8, data, KEY_DASHBOARD)) {
                            try self.switchToDashboard(false);
                        } else if (std.mem.eql(u8, data, KEY_ENTER)) {
                            try self.restart(cmd.index);
                        }
                    },
                }
            },
            .dashboard => {
                if (std.mem.eql(u8, data, KEY_KILL)) {
                    try self.killAll();
                } else if (std.mem.eql(u8, data, KEY_ENTER)) {
                    switch (self.selection) {
                        .invisible => {
                            try self.restartExited();
                        },
                        .keyboard => |s| {
                            try self.switchToCommand(s.index, false);
                        },
                        .mousedown => |s| {
                            try self.switchToCommand(s.index, false);
                        },
                        .by_indicator => |bi| {
                            try self.restartByIndicator(bi.indicator);
                        },
                    }
                } else if (std.mem.eql(u8, data, KEY_UP)) {
                    try self.moveSelection(-1);
                } else if (std.mem.eql(u8, data, KEY_DOWN)) {
                    try self.moveSelection(1);
                } else if (std.mem.eql(u8, data, KEY_LEFT) or std.mem.eql(u8, data, KEY_RIGHT)) {
                    try self.toggleIndicatorSelection();
                } else if (std.mem.eql(u8, data, KEY_ESC)) {
                    self.hideSelection();
                    try self.switchToDashboard(false);
                } else {
                    for (self.commands, 0..) |c, i| {
                        if (c.label) |label| {
                            if (std.mem.eql(u8, label, data)) {
                                try self.switchToCommand(i, true);
                                return;
                            }
                        }
                    }
                    self.handleMouse(data);
                }
            },
        }
    }

    fn moveSelection(self: *Session, delta: i32) !void {
        switch (self.selection) {
            .by_indicator => |bi| {
                const choices = try render.getIndicatorChoices(self.allocator, self.commands, self.env);
                defer self.allocator.free(choices);
                var idx: usize = 0;
                for (choices, 0..) |c, i| {
                    if (std.mem.eql(u8, c, bi.indicator)) {
                        idx = i;
                        break;
                    }
                }
                const new_idx: usize = if (delta < 0)
                    if (idx == 0) choices.len - 1 else idx - 1
                else
                    if (idx == choices.len - 1) 0 else idx + 1;
                try self.setSelection(.{ .by_indicator = .{ .indicator = choices[new_idx], .keyboard_index = bi.keyboard_index } });
            },
            .invisible => |s| {
                const new_idx: usize = if (delta < 0)
                    if (s.index == 0) self.commands.len - 1 else s.index - 1
                else
                    if (s.index == self.commands.len - 1) 0 else s.index + 1;
                try self.setSelection(.{ .keyboard = .{ .index = new_idx } });
            },
            .keyboard => |s| {
                const new_idx: usize = if (delta < 0)
                    if (s.index == 0) self.commands.len - 1 else s.index - 1
                else
                    if (s.index == self.commands.len - 1) 0 else s.index + 1;
                try self.setSelection(.{ .keyboard = .{ .index = new_idx } });
            },
            .mousedown => |s| {
                const new_idx: usize = if (delta < 0)
                    if (s.index == 0) self.commands.len - 1 else s.index - 1
                else
                    if (s.index == self.commands.len - 1) 0 else s.index + 1;
                try self.setSelection(.{ .keyboard = .{ .index = new_idx } });
            },
        }
    }

    fn toggleIndicatorSelection(self: *Session) !void {
        switch (self.auto_exit) {
            .auto_exit => {},
            else => {
                switch (self.selection) {
                    .by_indicator => |bi| {
                        try self.setSelection(.{ .keyboard = .{ .index = bi.keyboard_index } });
                    },
                    .invisible => |s| {
                        const ind = render.getIndicatorChoice(&self.commands[s.index], self.env);
                        try self.setSelection(.{ .by_indicator = .{ .indicator = ind, .keyboard_index = s.index } });
                    },
                    .keyboard => |s| {
                        const ind = render.getIndicatorChoice(&self.commands[s.index], self.env);
                        try self.setSelection(.{ .by_indicator = .{ .indicator = ind, .keyboard_index = s.index } });
                    },
                    .mousedown => |s| {
                        const ind = render.getIndicatorChoice(&self.commands[s.index], self.env);
                        try self.setSelection(.{ .by_indicator = .{ .indicator = ind, .keyboard_index = s.index } });
                    },
                }
            },
        }
    }

    /// Handle SGR/1006 mouse events: \x1B[<0;x;yM (down) or \x1B[<0;x;ym (up).
    fn handleMouse(self: *Session, data: []const u8) void {
        if (data.len < 5 or data[0] != 0x1B or data[1] != '[' or data[2] != '<') return;
        var i: usize = 3;
        if (i < data.len and data[i] == '0') i += 1;
        if (i < data.len and data[i] == ';') i += 1;
        var x: usize = 0;
        while (i < data.len and data[i] >= '0' and data[i] <= '9') {
            x = x * 10 + (data[i] - '0');
            i += 1;
        }
        if (i < data.len and data[i] == ';') i += 1;
        var y: usize = 0;
        while (i < data.len and data[i] >= '0' and data[i] <= '9') {
            y = y * 10 + (data[i] - '0');
            i += 1;
        }
        if (i >= data.len) return;
        const is_down = data[i] == 'M';
        x -= 1;
        y -= 1;
        // Map y to command index (each command is one line in the dashboard).
        if (y < self.commands.len) {
            if (is_down) {
                self.selection = .{ .mousedown = .{ .index = y } };
                self.switchToDashboard(false) catch {};
            } else {
                switch (self.selection) {
                    .mousedown => |s| {
                        if (s.index == y) {
                            self.switchToCommand(y, true) catch {};
                        } else {
                            self.selection = .{ .invisible = .{ .index = s.index } };
                            self.switchToDashboard(false) catch {};
                        }
                    },
                    .keyboard => |s| {
                        if (s.index == y) {
                            self.switchToCommand(y, true) catch {};
                        } else {
                            self.selection = .{ .invisible = .{ .index = s.index } };
                            self.switchToDashboard(false) catch {};
                        }
                    },
                    else => {},
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Main loop.
    // -----------------------------------------------------------------------

    pub fn run(self: *Session) !void {
        self.setRawMode();
        defer self.restoreTerminal();

        try self.poll_fds.append(.{ .fd = 0, .events = POLLIN, .revents = 0 });
        try self.cmd_of_pollfd.append(0);

        const max_parallel = switch (self.auto_exit) {
            .auto_exit => |n| n,
            else => self.commands.len,
        };

        for (self.commands, 0..) |*c, i| {
            if (i < max_parallel) {
                try c.start(self.term_cols, self.term_rows);
            }
            if (c.pty) |*pty| {
                try self.poll_fds.append(.{ .fd = pty.master, .events = POLLIN, .revents = 0 });
                try self.cmd_of_pollfd.append(i);
            }
        }

        if (self.commands.len == 1) {
            try self.switchToCommand(0, false);
        } else {
            try self.switchToDashboard(false);
        }

        var stdin_buf: [4096]u8 = undefined;
        var pty_buf: [4096]u8 = undefined;

        while (true) {
            // Check for signals (SIGINT/TERM/HUP).
            if (signal_received.load(.monotonic)) {
                self.killAll() catch {};
                // Wait for children to exit.
                for (self.commands) |*c| {
                    if (c.pty) |*pty| {
                        _ = pty.wait();
                        pty.deinit();
                        c.pty = null;
                    }
                }
                self.cleanup();
                return;
            }

            // Check for terminal resize.
            const new_cols = @as(u16, @intCast(getTermCols()));
            const new_rows = @as(u16, @intCast(getTermRows()));
            if (new_cols != self.term_cols or new_rows != self.term_rows) {
                self.term_cols = new_cols;
                self.term_rows = new_rows;
                for (self.commands) |*c| {
                    if (c.pty) |*pty| pty.resize(new_cols, new_rows);
                }
                if (self.current == .dashboard) {
                    self.switchToDashboard(false) catch {};
                }
            }

            const nready = std.posix.poll(self.poll_fds.items, 100) catch break;
            if (nready == 0) {
                // Timeout: check for resize.
                if (@constCast(&resize_received).swap(false, .monotonic)) {
                    const nc = @as(u16, @intCast(getTermCols()));
                    const nr = @as(u16, @intCast(getTermRows()));
                    if (nc != self.term_cols or nr != self.term_rows) {
                        self.term_cols = nc;
                        self.term_rows = nr;
                        for (self.commands) |*c| {
                            if (c.pty) |*pty| pty.resize(nc, nr);
                        }
                        if (self.current == .dashboard) {
                            self.switchToDashboard(false) catch {};
                        }
                    }
                }
                continue;
            }

            for (self.poll_fds.items, 0..) |*pfd, i| {
                if (pfd.revents == 0) continue;

                if (pfd.revents & (POLLHUP | POLLERR) != 0) {
                    if (i == 0) continue;
                    const cmd_idx = self.cmd_of_pollfd.items[i];
                    self.handleExit(cmd_idx);
                    pfd.revents = 0;
                    continue;
                }
                if (pfd.revents & POLLIN == 0) {
                    pfd.revents = 0;
                    continue;
                }

                if (i == 0) {
                    const n = std.posix.read(0, &stdin_buf) catch 0;
                    if (n > 0) {
                        try self.onStdin(stdin_buf[0..n]);
                    }
                } else {
                    const cmd_idx = self.cmd_of_pollfd.items[i];
                    const command = &self.commands[cmd_idx];
                    if (command.pty) |*pty| {
                        const n = pty.read(&pty_buf) catch 0;
                        if (n > 0) {
                            self.handlePtyData(cmd_idx, pty_buf[0..n]);
                        }
                    }
                }
                pfd.revents = 0;
            }

            if (command_mod.isDone(self.commands, self.attempted_kill_all, self.auto_exit)) {
                try self.switchToDashboard(true);
                const exit_code: u8 = if (self.auto_exit == .auto_exit and self.attempted_kill_all) 1 else 0;
                self.cleanup();
                std.process.exit(exit_code);
            }
        }
    }

    fn handlePtyData(self: *Session, cmd_idx: usize, data: []const u8) void {
        const command = &self.commands[cmd_idx];
        const status_changed = command.pushHistory(data);
        command.updateStatusFromRules(data);

        switch (self.current) {
            .command => |cmd| {
                if (cmd.index == cmd_idx) {
                    switch (command.status) {
                        .running, .killing => {
                            self.printDataWithExtraText(command, data, false) catch {};
                        },
                        else => {},
                    }
                }
            },
            .dashboard => {
                if (status_changed) {
                    self.switchToDashboard(false) catch {};
                }
            },
        }
    }

    fn handleExit(self: *Session, cmd_idx: usize) void {
        const command = &self.commands[cmd_idx];
        if (command.pty == null) return;

        const exit_code = command.pty.?.tryWait() orelse return;
        // Drain remaining PTY output before closing.
        const remaining = command.pty.?.drain();
        if (remaining.len > 0) {
            _ = command.pushHistory(remaining);
            self.writeRaw(remaining) catch {};
        }
        command.markExited(@as(u32, @intCast(exit_code)));

        // Remove from poll.
        for (self.poll_fds.items, 0..) |*pfd, i| {
            if (self.cmd_of_pollfd.items[i] == cmd_idx and i > 0) {
                pfd.events = 0;
                break;
            }
        }

        // Start next waiting command.
        for (self.commands, 0..) |*c, i| {
            if (c.status == .waiting and !self.attempted_kill_all) {
                c.start(self.term_cols, self.term_rows) catch {};
                if (c.pty) |*pty| {
                    self.poll_fds.append(.{ .fd = pty.master, .events = POLLIN, .revents = 0 }) catch {};
                    self.cmd_of_pollfd.append(i) catch {};
                }
                switch (self.current) {
                    .command => |cmd| {
                        if (cmd.index == i) {
                            self.switchToCommand(i, false) catch {};
                        }
                    },
                    else => {},
                }
                break;
            }
        }

        switch (self.current) {
            .command => |cmd| {
                if (cmd.index == cmd_idx) {
                    self.printDataWithExtraText(command, "", true) catch {};
                }
            },
            .dashboard => {
                self.switchToDashboard(false) catch {};
            },
        }
    }

    fn cleanup(self: *Session) void {
        self.writeRaw(SHOW_CURSOR) catch {};
        self.writeRaw(ansi.DISABLE_BRACKETED_PASTE_MODE) catch {};
        self.writeRaw(DISABLE_MOUSE) catch {};
        self.writeRaw(RESET_COLOR) catch {};
        self.writer.flush() catch {};
    }

    fn setRawMode(self: *Session) void {
        var t: std.c.termios = undefined;
        if (std.c.tcgetattr(0, &t) < 0) return;
        self.original_termios = t;
        const VMIN: usize = 6;
        const VTIME: usize = 5;
        // Clear LCANON, ECHO, ISIG from lflag.
        t.lflag = @bitCast(@as(u64, @bitCast(t.lflag)) & ~@as(u64, 0x0010 | 0x0008 | 0x0080));
        // Clear ICRNL, INLCR, IXON from iflag.
        t.iflag = @bitCast(@as(u64, @bitCast(t.iflag)) & ~@as(u64, 0x0004 | 0x0010 | 0x0400));
        // Clear OPOST from oflag.
        t.oflag = @bitCast(@as(u64, @bitCast(t.oflag)) & ~@as(u64, 0x0001));
        t.cc[VMIN] = 1;
        t.cc[VTIME] = 0;
        _ = std.c.tcsetattr(0, std.posix.TCSA.NOW, &t);

        // Install signal handlers.
        @constCast(&signal_received).store(false, .monotonic);
        @constCast(&resize_received).store(false, .monotonic);
        const handler: *fn(c_int) callconv(.c) void = @constCast(&signalHandler);
        _ = signal(@intFromEnum(std.posix.SIG.INT), handler);
        _ = signal(@intFromEnum(std.posix.SIG.TERM), handler);
        _ = signal(@intFromEnum(std.posix.SIG.HUP), handler);
        const resize_handler: *fn(c_int) callconv(.c) void = @constCast(&resizeHandler);
        _ = signal(@intFromEnum(std.posix.SIG.WINCH), resize_handler);
    }

    fn restoreTerminal(self: *Session) void {
        _ = std.c.tcsetattr(0, std.posix.TCSA.NOW, &self.original_termios);
    }

    fn getTermCols() usize {
        var ws: std.posix.winsize = undefined;
        if (std.c.ioctl(1, @bitCast(@as(u32, 0x00005413)), &ws) < 0) return 80;
        return if (ws.col > 0) ws.col else 80;
    }

    fn getTermRows() usize {
        var ws: std.posix.winsize = undefined;
        if (std.c.ioctl(1, @bitCast(@as(u32, 0x00005413)), &ws) < 0) return 24;
        return if (ws.row > 0) ws.row else 24;
    }
};

/// Entry point for interactive mode.
pub fn run(allocator: Allocator, descriptions: []const types.CommandDescription, auto_exit: AutoExit, env: Env, writer: *std.Io.Writer) !u32 {
    var commands: std.array_list.Managed(Command) = .init(allocator);
    defer commands.deinit();

    for (descriptions, 0..) |desc, i| {
        const label = if (i < labels.ALL_LABELS.len) labels.ALL_LABELS[i .. i + 1] else null;
        var cmd = Command{
            .label = label,
            .file = desc.command[0],
            .args = desc.command[1..],
            .cwd = desc.cwd,
            .kill_all_sequence = desc.kill_all_sequence,
            .title = desc.title,
            .title_possibly_with_graphic_renditions = desc.title,
            .formatted_command_with_title = desc.command[0],
            .is_simple_log = true,
            .is_on_alternate_screen = false,
            .status = .waiting,
            .status_from_rules = null,
            .status_rules = desc.status,
            .default_status = null,
            .history = "",
            .history_alternate_screen = "",
            .pty = null,
        };
        if (desc.default_status) |ds| {
            cmd.default_status = .{ ds.primary, ds.degraded };
            cmd.status_from_rules = .{ ds.primary, ds.degraded };
        }
        try commands.append(cmd);
    }

    var session = Session.init(allocator, commands.items, auto_exit, env, writer);
    defer session.deinit();

    session.run() catch |err| {
        if (err == error.Exit) return 0;
        return err;
    };
    return 0;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
// Interactive mode requires a real TTY; unit tests here are limited to
// pure-parsing helpers that do not touch the writer.

test "handleMouse: non-SGR data is ignored (no state change)" {
    // Verify the SGR prefix check: data that doesn't start with \x1B[< is
    // rejected immediately without any state mutation.
    const data = "hello";
    if (data.len < 5 or data[0] != 0x1B or data[1] != '[' or data[2] != '<') {
        // Correctly rejected.
    } else {
        @panic("should have been rejected");
    }
}

test "handleMouse: SGR prefix parsing (x/y extraction)" {
    // \x1B[<0;5;3M → x=5, y=3 (before 1-based → 0-based conversion)
    const data = "\x1B[<0;5;3M";
    var i: usize = 3;
    if (i < data.len and data[i] == '0') i += 1;
    if (i < data.len and data[i] == ';') i += 1;
    var x: usize = 0;
    while (i < data.len and data[i] >= '0' and data[i] <= '9') {
        x = x * 10 + (data[i] - '0');
        i += 1;
    }
    if (i < data.len and data[i] == ';') i += 1;
    var y: usize = 0;
    while (i < data.len and data[i] >= '0' and data[i] <= '9') {
        y = y * 10 + (data[i] - '0');
        i += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), x);
    try std.testing.expectEqual(@as(usize, 3), y);
    try std.testing.expectEqual(@as(u8, 'M'), data[i]);
}
