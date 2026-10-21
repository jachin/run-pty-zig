const std = @import("std");
const Allocator = std.mem.Allocator;
const command_mod = @import("command.zig");
const indicators = @import("indicators.zig");
const ansi = @import("ansi.zig");
const labels = @import("labels.zig");
const types = @import("types.zig");

const Command = command_mod.Command;
const Status = command_mod.Status;
const CommandText = command_mod.CommandText;
const Selection = command_mod.Selection;
const AutoExit = types.AutoExit;
const Env = indicators.Env;
const StatusValue = indicators.StatusValue;
const pick = indicators.pick;
const waiting = indicators.waiting;
const running = indicators.running;
const killing = indicators.killing;
const restarting = indicators.restarting;
const aborted = indicators.aborted;
const exitIndicator = indicators.exitIndicator;
const folder = indicators.folder;
const RESET_COLOR = ansi.RESET_COLOR;
const CLEAR_DOWN = ansi.CLEAR_DOWN;
const CLEAR_RIGHT = ansi.CLEAR_RIGHT;

/// Keyboard shortcut labels shown in the footers.
pub const KEYS = struct {
    pub const kill = "ctrl+c";
    pub const restart = "enter";
    pub const dashboard = "ctrl+z";
    pub const navigate = "↑↓←→";
    pub const navigate_vertically_only = "↑↓";
    pub const enter = "enter";
    pub const unselect = "escape";
};

// ---------------------------------------------------------------------------
// Text styling helpers.
// ---------------------------------------------------------------------------

fn appendDim(out: *std.array_list.Managed(u8), s: []const u8, no_color: bool) !void {
    if (no_color) {
        try out.appendSlice(s);
    } else {
        try out.appendSlice("\x1B[2m");
        try out.appendSlice(s);
        try out.appendSlice(RESET_COLOR);
    }
}

fn appendBold(out: *std.array_list.Managed(u8), s: []const u8, no_color: bool) !void {
    if (no_color) {
        try out.appendSlice(s);
    } else {
        try out.appendSlice("\x1B[1m");
        try out.appendSlice(s);
        try out.appendSlice(RESET_COLOR);
    }
}

fn appendInvert(out: *std.array_list.Managed(u8), s: []const u8, no_color: bool) !void {
    if (no_color) {
        try out.appendSlice(s);
    } else {
        try out.appendSlice("\x1B[7m");
        try out.appendSlice(s);
        try out.appendSlice(RESET_COLOR);
    }
}

fn appendShortcut(out: *std.array_list.Managed(u8), s: []const u8, pad: bool, no_color: bool) !void {
    try appendDim(out, "[", no_color);
    try appendBold(out, s, no_color);
    try appendDim(out, "]", no_color);
    if (pad) {
        const target: usize = KEYS.kill.len;
        if (target > s.len) {
            try out.appendNTimes(' ', target - s.len);
        }
    }
}

/// Wrap `s` in dim (faint) ANSI codes, unless NO_COLOR. Returns an owned slice.
pub fn dim(allocator: Allocator, s: []const u8, no_color: bool) ![]u8 {
    if (no_color) return allocator.dupe(u8, s);
    var out: std.array_list.Managed(u8) = .init(allocator);
    errdefer out.deinit();
    try appendDim(&out, s, no_color);
    return out.toOwnedSlice();
}

/// Wrap `s` in bold ANSI codes, unless NO_COLOR. Returns an owned slice.
pub fn bold(allocator: Allocator, s: []const u8, no_color: bool) ![]u8 {
    if (no_color) return allocator.dupe(u8, s);
    var out: std.array_list.Managed(u8) = .init(allocator);
    errdefer out.deinit();
    try appendBold(&out, s, no_color);
    return out.toOwnedSlice();
}

/// Wrap `s` in reverse-video (invert) ANSI codes, unless NO_COLOR. This is a
/// simplified version of the original (which splits on embedded reset codes);
/// it wraps the whole string, which is sufficient for the dashboard highlight.
pub fn invert(allocator: Allocator, s: []const u8, no_color: bool) ![]u8 {
    if (no_color) return allocator.dupe(u8, s);
    var out: std.array_list.Managed(u8) = .init(allocator);
    errdefer out.deinit();
    try appendInvert(&out, s, no_color);
    return out.toOwnedSlice();
}

/// Render a keyboard shortcut like `[ctrl+c]`, padding to the width of the
/// longest key ("ctrl+c") when `pad` is true. Returns an owned slice.
pub fn shortcut(allocator: Allocator, s: []const u8, pad: bool, no_color: bool) ![]u8 {
    var out: std.array_list.Managed(u8) = .init(allocator);
    errdefer out.deinit();
    try appendShortcut(&out, s, pad, no_color);
    return out.toOwnedSlice();
}

/// The display width of a status icon, and the cursor nudge that compensates
/// for emoji being 2 columns wide.
pub fn iconWidth(env: Env) usize {
    return if (env.no_color or !env.supports_emoji) 1 else 2;
}

pub fn emojiWidthFix(env: Env) []const u8 {
    return if (env.no_color or !env.supports_emoji) "" else "\x1B[3G";
}

pub fn cursorHorizontalAbsolute(buf: []u8, n: usize) []const u8 {
    // `\x1B[{n}G`
    return std.fmt.bufPrint(buf, "\x1B[{d}G", .{ n }) catch unreachable;
}

pub fn cursorAbsolute(buf: []u8, row: usize, col: usize) []const u8 {
    // `\x1B[{row};{col}H`
    return std.fmt.bufPrint(buf, "\x1B[{d};{d}H", .{ row, col }) catch unreachable;
}

pub fn cursorUp(buf: []u8, n: usize) []const u8 {
    // `\x1B[{n}A`
    return std.fmt.bufPrint(buf, "\x1B[{d}A", .{ n }) catch unreachable;
}

// ---------------------------------------------------------------------------
// Status text.
// ---------------------------------------------------------------------------

/// The indicator (already selected for the environment) and, for an exited
/// command, its exit code (the caller renders the bolded "exit N" text).
pub const StatusText = struct {
    indicator: []const u8,
    exit_code: ?u32,
};

pub fn statusText(status: Status, status_from_rules: ?StatusValue, use_separate_killed_indicator: bool, env: Env) StatusText {
    return switch (status) {
        .waiting => .{ .indicator = pick(waiting, env), .exit_code = null },
        .running => .{ .indicator = statusValueIndicator(status_from_rules, env), .exit_code = null },
        .killing => |k| .{ .indicator = pick(if (k.restart_after_kill) restarting else killing, env), .exit_code = null },
        .exit => |e| .{
            .indicator = pick(if (e.was_killed and use_separate_killed_indicator) aborted else exitIndicator(e.exit_code), env),
            .exit_code = e.exit_code,
        },
    };
}

/// Pick the display string for a config status value, falling back to the
/// running indicator when there is none.
fn statusValueIndicator(value: ?StatusValue, env: Env) []const u8 {
    if (value) |v| {
        if (env.no_color or !env.supports_emoji) return v.degraded;
        return v.primary;
    }
    return pick(running, env);
}

// ---------------------------------------------------------------------------
// Title / cwd / history-start.
// ---------------------------------------------------------------------------

fn appendCwdText(out: *std.array_list.Managed(u8), command: *const CommandText, is_process_cwd: bool, env: Env) !void {
    if (is_process_cwd) return;
    try out.appendSlice(pick(folder, env));
    try out.appendSlice(emojiWidthFix(env));
    try out.append(' ');
    try appendDim(out, command.cwd, env.no_color);
    try out.append('\n');
}

fn appendCommandTitleWithIndicator(out: *std.array_list.Managed(u8), indicator: []const u8, command: *const CommandText, env: Env) !void {
    try out.appendSlice(indicator);
    try out.appendSlice(emojiWidthFix(env));
    try out.append(' ');
    try out.appendSlice(command.formatted_command_with_title);
    try out.appendSlice(RESET_COLOR);
}

fn appendCommandTitleOnlyWithIndicator(out: *std.array_list.Managed(u8), indicator: []const u8, command: *const CommandText, env: Env) !void {
    try out.appendSlice(indicator);
    try out.appendSlice(emojiWidthFix(env));
    try out.append(' ');
    try out.appendSlice(command.title_possibly_with_graphic_renditions);
    try out.appendSlice(RESET_COLOR);
}

/// The cwd line: empty when it's the process cwd, else a folder icon + path.
pub fn cwdText(allocator: Allocator, command: *const CommandText, is_process_cwd: bool, env: Env) ![]u8 {
    if (is_process_cwd) return allocator.dupe(u8, "");
    var out: std.array_list.Managed(u8) = .init(allocator);
    errdefer out.deinit();
    try appendCwdText(&out, command, is_process_cwd, env);
    return out.toOwnedSlice();
}

/// `indicator + width-fix + " " + formattedCommandWithTitle + reset`.
pub fn commandTitleWithIndicator(allocator: Allocator, indicator: []const u8, command: *const CommandText, env: Env) ![]u8 {
    var out: std.array_list.Managed(u8) = .init(allocator);
    errdefer out.deinit();
    try appendCommandTitleWithIndicator(&out, indicator, command, env);
    return out.toOwnedSlice();
}

/// Like `commandTitleWithIndicator` but shows only the title (not the full
/// command). Used in non-interactive mode and the dashboard.
pub fn commandTitleOnlyWithIndicator(allocator: Allocator, indicator: []const u8, command: *const CommandText, env: Env) ![]u8 {
    var out: std.array_list.Managed(u8) = .init(allocator);
    errdefer out.deinit();
    try appendCommandTitleOnlyWithIndicator(&out, indicator, command, env);
    return out.toOwnedSlice();
}

/// The block printed when a command exits in non-interactive mode: the title
/// with the exit indicator, the cwd, the full history, a clear-down, and the
/// bolded "exit N (X/Y exited)" line.
pub fn exitTextAndHistory(allocator: Allocator, command: *const CommandText, exit_code: u32, num_exited: usize, num_total: usize, env: Env) ![]u8 {
    const last_line = command_mod.getLastLine(command.history);
    const last_line_plain = try ansi.removeGraphicRenditions(allocator, last_line);
    defer allocator.free(last_line_plain);
    const newline: []const u8 = if (std.mem.trim(u8, last_line_plain, " \t\r\n").len == 0) "" else "\n";

    var out: std.array_list.Managed(u8) = .init(allocator);
    errdefer out.deinit();

    try appendCommandTitleOnlyWithIndicator(&out, pick(exitIndicator(exit_code), env), command, env);
    try out.append('\n');

    try appendCwdText(&out, command, false, env);
    try out.appendSlice(command.history);
    try out.appendSlice(CLEAR_DOWN);
    try out.appendSlice(newline);

    var num_buf: [64]u8 = undefined;
    const exit_plain = std.fmt.bufPrint(&num_buf, "exit {d}", .{ exit_code }) catch unreachable;
    try appendBold(&out, exit_plain, env.no_color);
    try out.append(' ');

    const count_plain = std.fmt.bufPrint(&num_buf, "({d}/{d} exited)", .{ num_exited, num_total }) catch unreachable;
    try appendDim(&out, count_plain, env.no_color);
    try out.appendSlice("\n\n");

    return out.toOwnedSlice();
}

/// The header printed before a command's history: title + cwd.
pub fn historyStart(allocator: Allocator, indicator: []const u8, command: *const CommandText, is_process_cwd: bool, env: Env) ![]u8 {
    var out: std.array_list.Managed(u8) = .init(allocator);
    errdefer out.deinit();
    try appendCommandTitleWithIndicator(&out, indicator, command, env);
    try out.append('\n');
    try appendCwdText(&out, command, is_process_cwd, env);
    return out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Footer texts (focused command).
// ---------------------------------------------------------------------------

fn appendKillAllLabel(out: *std.array_list.Managed(u8), commands: []const Command, no_color: bool) !void {
    var any_killing = false;
    var any_terminal = false;
    for (commands) |c| {
        if (command_mod.statusHasTerminal(c.status)) any_terminal = true;
        if (c.status == .killing) any_killing = true;
    }
    if (any_killing) {
        try out.appendSlice("kill all ");
        try appendDim(out, "(double-press to force) ", no_color);
        return;
    }
    if (!any_terminal) {
        try out.appendSlice("exit");
    } else {
        try out.appendSlice("kill all");
    }
}

pub fn waitingText(allocator: Allocator, commands: []const Command, env: Env) ![]u8 {
    var out: std.array_list.Managed(u8) = .init(allocator);
    errdefer out.deinit();
    try out.appendSlice("\nWaiting for other commands to finish before starting.\n\n");
    try appendShortcut(&out, KEYS.kill, true, env.no_color);
    try out.append(' ');
    try appendKillAllLabel(&out, commands, env.no_color);
    try out.append('\n');
    try appendShortcut(&out, KEYS.dashboard, true, env.no_color);
    try out.appendSlice(" dashboard\n");
    return out.toOwnedSlice();
}

pub fn runningText(allocator: Allocator, pid: i32, env: Env) ![]u8 {
    var out: std.array_list.Managed(u8) = .init(allocator);
    errdefer out.deinit();
    try out.append('\n');
    try appendShortcut(&out, KEYS.kill, true, env.no_color);
    try out.appendSlice(" kill ");
    var pid_buf: [32]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&pid_buf, "(pid {d})", .{ pid }) catch unreachable;
    try appendDim(&out, pid_str, env.no_color);
    try out.append('\n');
    try appendShortcut(&out, KEYS.dashboard, true, env.no_color);
    try out.appendSlice(" dashboard\n");
    return out.toOwnedSlice();
}

pub fn killingText(allocator: Allocator, pid: i32, env: Env) ![]u8 {
    var out: std.array_list.Managed(u8) = .init(allocator);
    errdefer out.deinit();
    try out.append('\n');
    try appendShortcut(&out, KEYS.kill, true, env.no_color);
    try out.appendSlice(" kill ");
    var pid_buf: [64]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&pid_buf, "(double-press to force) (pid {d})", .{ pid }) catch unreachable;
    try appendDim(&out, pid_str, env.no_color);
    try out.append('\n');
    try appendShortcut(&out, KEYS.dashboard, true, env.no_color);
    try out.appendSlice(" dashboard\n");
    return out.toOwnedSlice();
}

/// The label for the kill-all shortcut.
pub fn killAllLabel(allocator: Allocator, commands: []const Command, no_color: bool) ![]u8 {
    var out: std.array_list.Managed(u8) = .init(allocator);
    errdefer out.deinit();
    try appendKillAllLabel(&out, commands, no_color);
    return out.toOwnedSlice();
}

pub fn exitText(allocator: Allocator, commands: []const Command, command: *const CommandText, status: Status, auto_exit: AutoExit, env: Env) ![]u8 {
    const was_killed = switch (status) {
        .exit => |e| e.was_killed,
        else => false,
    };
    const exit_code = switch (status) {
        .exit => |e| e.exit_code,
        else => 0,
    };
    const is_auto_exit = auto_exit == .auto_exit;
    const indicator = pick(if (was_killed and is_auto_exit) aborted else exitIndicator(exit_code), env);
    var out: std.array_list.Managed(u8) = .init(allocator);
    errdefer out.deinit();
    try out.append('\n');
    try appendCommandTitleWithIndicator(&out, indicator, command, env);
    try out.append('\n');
    try appendCwdText(&out, command, false, env);
    var exit_buf: [32]u8 = undefined;
    const exit_str = std.fmt.bufPrint(&exit_buf, "exit {d}\n\n", .{ exit_code }) catch unreachable;
    try out.appendSlice(exit_str);
    // Restart line: omitted when auto-exit and a clean, non-killed exit.
    const show_restart = !(is_auto_exit and exit_code == 0 and !was_killed);
    if (show_restart) {
        try appendShortcut(&out, KEYS.enter, true, env.no_color);
        try out.appendSlice(" restart\n");
    }
    try appendShortcut(&out, KEYS.kill, true, env.no_color);
    try out.append(' ');
    try appendKillAllLabel(&out, commands, env.no_color);
    try out.append('\n');
    try appendShortcut(&out, KEYS.dashboard, true, env.no_color);
    try out.appendSlice(" dashboard\n");
    return out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Summary (non-interactive mode).
// ---------------------------------------------------------------------------

/// The overall outcome: success (all exit 0), failure (any non-zero exit),
/// or aborted (killed).
pub fn summaryOutcome(commands: []const Command) []const u8 {
    var all_ok = true;
    var any_failed = false;
    for (commands) |c| {
        switch (c.status) {
            .exit => |e| {
                if (e.exit_code != 0 or e.was_killed) all_ok = false;
                if (e.exit_code != 0 and !e.was_killed) any_failed = true;
            },
            else => all_ok = false,
        }
    }
    if (all_ok) return "success";
    if (any_failed) return "failure";
    return "aborted";
}

pub fn drawSummary(allocator: Allocator, commands: []const Command, env: Env) ![]u8 {
    var out: std.array_list.Managed(u8) = .init(allocator);
    errdefer out.deinit();
    const outcome = summaryOutcome(commands);
    var header_buf: [64]u8 = undefined;
    const header_str = std.fmt.bufPrint(&header_buf, "Summary – {s}:", .{ outcome }) catch unreachable;
    try appendBold(&out, header_str, env.no_color);
    try out.append('\n');
    for (commands, 0..) |c, i| {
        if (i > 0) try out.append('\n');
        const st = statusText(c.status, c.status_from_rules, true, env);
        try out.appendSlice(st.indicator);
        try out.appendSlice(emojiWidthFix(env));
        try out.append(' ');
        if (st.exit_code) |code| {
            var exit_buf: [32]u8 = undefined;
            const exit_plain = std.fmt.bufPrint(&exit_buf, "exit {d}", .{ code }) catch unreachable;
            try appendBold(&out, exit_plain, env.no_color);
            try out.append(' ');
        }
        try out.appendSlice(c.title_possibly_with_graphic_renditions);
        try out.appendSlice(RESET_COLOR);
    }
    try out.append('\n');
    return out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Dashboard (interactive mode).
// ---------------------------------------------------------------------------

/// One rendered dashboard line: the ANSI-escaped line and its display length.
pub const DashboardLine = struct {
    line: []u8,
    length: usize,
};

/// The indicator for a command (used for "ByIndicator" selection).
pub fn getIndicatorChoice(command: *const Command, env: Env) []const u8 {
    return statusText(command.status, command.status_from_rules, false, env).indicator;
}

/// The unique set of indicators across all commands, in first-seen order.
/// The caller must free the returned slice (not the individual strings, which
/// point into the indicator tables).
pub fn getIndicatorChoices(allocator: Allocator, commands: []const Command, env: Env) ![][]const u8 {
    var out: std.array_list.Managed([]const u8) = .init(allocator);
    defer out.deinit();
    for (commands) |*c| {
        const ind = getIndicatorChoice(c, env);
        const exists = for (out.items) |existing| {
            if (std.mem.eql(u8, existing, ind)) break true;
        } else false;
        if (!exists) try out.append(ind);
    }
    return out.toOwnedSlice();
}

/// Render the per-command lines of the dashboard. Each line has the form:
/// `[label] icon  status  title` with the selected line highlighted.
/// The caller must free each `line.line` and the returned slice.
pub fn drawDashboardCommandLines(
    allocator: Allocator,
    commands: []const Command,
    selection: Selection,
    width: usize,
    use_separate_killed_indicator: bool,
    env: Env,
) ![]DashboardLine {
    const separator = "  ";
    const icon_width = iconWidth(env);

    // Pre-compute status texts.
    var statuses: std.array_list.Managed(StatusText) = .init(allocator);
    defer statuses.deinit();
    for (commands) |c| {
        try statuses.append(statusText(c.status, c.status_from_rules, use_separate_killed_indicator, env));
    }

    // Widest "exit N" string.
    var widest_status: usize = 0;
    for (statuses.items) |st| {
        if (st.exit_code) |code| {
            var buf: [16]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "exit {d}", .{ code }) catch "exit 99999";
            if (s.len > widest_status) widest_status = s.len;
        }
    }

    const selected_indicator: ?[]const u8 = switch (selection) {
        .by_indicator => |bi| bi.indicator,
        else => null,
    };

    var lines: std.array_list.Managed(DashboardLine) = .init(allocator);
    errdefer {
        for (lines.items) |l| allocator.free(l.line);
        lines.deinit();
    }

    var scratch_buf: std.array_list.Managed(u8) = .init(allocator);
    defer scratch_buf.deinit();

    const sel_index: ?usize = switch (selection) {
        .keyboard => |k| k.index,
        .mousedown => |m| m.index,
        else => null,
    };

    for (commands, 0..) |c, i| {
        const st = statuses.items[i];
        const label = if (c.label) |l| l else " ";

        scratch_buf.clearRetainingCapacity();
        try appendShortcut(&scratch_buf, label, false, env.no_color);
        const start_length = ansi.visibleLen(scratch_buf.items) + separator.len + icon_width;

        const start = try ansi.truncate(allocator, scratch_buf.items, width);
        defer allocator.free(start);

        var line_buf: std.array_list.Managed(u8) = .init(allocator);
        errdefer line_buf.deinit();
        try line_buf.appendSlice(start);

        // Append the icon portion directly into line_buf.
        const is_selected_indicator = if (selected_indicator) |si| std.mem.eql(u8, st.indicator, si) else false;
        if (is_selected_indicator) {
            if (env.no_color) {
                try line_buf.appendSlice(separator[0..1]);
                try line_buf.appendSlice("→");
                try line_buf.appendSlice(st.indicator);
            } else {
                try line_buf.appendSlice(separator[0..1]);
                try line_buf.appendSlice("\x1B[7m ");
                try line_buf.appendSlice(st.indicator);
                try line_buf.appendNTimes(' ', icon_width);
                try line_buf.appendSlice(RESET_COLOR);
            }
        } else {
            try line_buf.appendSlice(separator);
            try line_buf.appendSlice(st.indicator);
        }

        // Build the end portion in scratch_buf.
        scratch_buf.clearRetainingCapacity();
        if (st.exit_code) |code| {
            var status_buf: [16]u8 = undefined;
            const status_str = std.fmt.bufPrint(&status_buf, "exit {d}", .{ code }) catch "exit 99999";
            try scratch_buf.appendSlice(status_str);
            try scratch_buf.appendNTimes(' ', widest_status - status_str.len);
            try scratch_buf.appendSlice(separator);
        }
        try scratch_buf.appendSlice(c.title_possibly_with_graphic_renditions);

        const end_width: usize = if (width > start_length + separator.len) width - start_length - separator.len else 0;
        const truncated_end = try ansi.truncate(allocator, scratch_buf.items, end_width);
        defer allocator.free(truncated_end);

        const length = start_length + separator.len + ansi.visibleLen(truncated_end);

        var cha_buf: [16]u8 = undefined;
        try line_buf.appendSlice(RESET_COLOR);
        try line_buf.appendSlice(cursorHorizontalAbsolute(&cha_buf, start_length + 1));
        try line_buf.appendSlice(CLEAR_RIGHT);

        // Append separator + highlighted end directly into line_buf.
        const is_selected = sel_index != null and sel_index.? == i;
        if (is_selected and env.no_color) {
            try line_buf.appendSlice(separator[0..1]);
            try line_buf.appendSlice("→");
            try line_buf.appendSlice(truncated_end);
        } else {
            if (is_selected_indicator and !env.no_color) {
                try appendInvert(&line_buf, " ", false);
                try line_buf.appendSlice(separator[1..]);
            } else {
                try line_buf.appendSlice(separator);
            }
            if (is_selected) {
                try appendInvert(&line_buf, truncated_end, env.no_color);
            } else {
                try line_buf.appendSlice(truncated_end);
            }
        }
        try line_buf.appendSlice(RESET_COLOR);

        try lines.append(.{ .line = try line_buf.toOwnedSlice(), .length = length });
    }

    return lines.toOwnedSlice();
}

/// The full dashboard: command lines + footer with keyboard shortcuts.
/// Returns an owned string.
pub fn drawDashboard(
    allocator: Allocator,
    commands: []const Command,
    width: usize,
    attempted_kill_all: bool,
    auto_exit: AutoExit,
    selection: Selection,
    env: Env,
) ![]u8 {
    const done = command_mod.isDone(commands, attempted_kill_all, auto_exit);
    const sel = if (done) Selection{ .invisible = .{ .index = 0 } } else selection;
    const lines = try drawDashboardCommandLines(allocator, commands, sel, width, auto_exit == .auto_exit, env);
    defer {
        for (lines) |l| allocator.free(l.line);
        allocator.free(lines);
    }

    var out: std.array_list.Managed(u8) = .init(allocator);
    errdefer out.deinit();
    if (!done) {
        try out.append('\n');
    }
    for (lines, 0..) |l, i| {
        if (i > 0) try out.append('\n');
        try out.appendSlice(l.line);
    }

    if (done) {
        try out.append('\n');
        return out.toOwnedSlice();
    }

    try out.appendSlice("\n\n");

    const label = try labels.summarizeLabels(allocator, commands.len);
    defer allocator.free(label);

    try appendShortcut(&out, label, false, env.no_color);
    try out.appendSlice(" focus command ");
    try appendDim(&out, "(or click)", env.no_color);
    try out.append('\n');

    try appendShortcut(&out, KEYS.kill, false, env.no_color);
    try out.append(' ');
    try appendKillAllLabel(&out, commands, env.no_color);
    try out.append('\n');

    const nav_keys = if (auto_exit == .auto_exit) KEYS.navigate_vertically_only else KEYS.navigate;
    try appendShortcut(&out, nav_keys, false, env.no_color);
    try out.appendSlice(" move selection\n");

    // Enter line.
    switch (selection) {
        .keyboard => |kb| {
            try appendShortcut(&out, KEYS.enter, false, env.no_color);
            try out.appendSlice(" focus selected");
            if (command_mod.getPid(&commands[kb.index])) |p| {
                var pid_buf: [32]u8 = undefined;
                const pid_str = std.fmt.bufPrint(&pid_buf, " (pid {d})", .{ p }) catch unreachable;
                try out.appendSlice(pid_str);
            }
            try out.append('\n');
            try appendShortcut(&out, KEYS.unselect, false, env.no_color);
            try out.appendSlice(" unselect\n");
        },
        .by_indicator => |bi| {
            try appendShortcut(&out, KEYS.enter, false, env.no_color);
            var any_killing = false;
            for (commands) |*c| {
                if (std.mem.eql(u8, getIndicatorChoice(c, env), bi.indicator) and c.status == .killing) any_killing = true;
            }
            if (any_killing) try out.appendSlice(" force ");
            try out.appendSlice("restart selected\n");
            try appendShortcut(&out, KEYS.unselect, false, env.no_color);
            try out.appendSlice(" unselect\n");
        },
        else => {
            const has_failed = for (commands) |c| {
                switch (c.status) {
                    .exit => |e| {
                        if (e.exit_code != 0 or e.was_killed) break true;
                    },
                    else => {},
                }
            } else false;
            const has_exited = for (commands) |c| {
                if (c.status == .exit) break true;
            } else false;
            if (auto_exit == .auto_exit) {
                if (has_failed) {
                    try appendShortcut(&out, KEYS.enter, false, env.no_color);
                    try out.appendSlice(" restart failed\n");
                }
            } else if (has_exited) {
                try appendShortcut(&out, KEYS.enter, false, env.no_color);
                try out.appendSlice(" restart exited\n");
            }
        },
    }

    switch (auto_exit) {
        .auto_exit => |max_parallel| {
            try out.appendSlice("The session ends automatically once all commands are ");
            try out.appendSlice(pick(exitIndicator(0), env));
            try out.appendSlice(emojiWidthFix(env));
            try out.appendSlice(" ");
            try appendBold(&out, "exit 0", env.no_color);
            try out.appendSlice(".\n");
            var max_buf: [64]u8 = undefined;
            const max_str = std.fmt.bufPrint(&max_buf, "At most {d} {s} at a time.\n", .{ max_parallel, if (max_parallel == 1) "command runs" else "commands run" }) catch unreachable;
            try out.appendSlice(max_str);
        },
        else => {},
    }

    return out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

const testEnv = Env{ .no_color = false, .supports_emoji = true };
const plainEnv = Env{ .no_color = true, .supports_emoji = true };

test "dim and bold" {
    const allocator = std.testing.allocator;
    const d = try dim(allocator, "x", false);
    defer allocator.free(d);
    try std.testing.expectEqualStrings("\x1B[2mx\x1B[m", d);
    const d2 = try dim(allocator, "x", true);
    defer allocator.free(d2);
    try std.testing.expectEqualStrings("x", d2);
    const b = try bold(allocator, "x", false);
    defer allocator.free(b);
    try std.testing.expectEqualStrings("\x1B[1mx\x1B[m", b);
}

test "shortcut pads to the longest key" {
    const allocator = std.testing.allocator;
    const s = try shortcut(allocator, "enter", true, true); // no_color for readability
    defer allocator.free(s);
    // "enter" (5) padded to "ctrl+c" (6) -> one trailing space.
    try std.testing.expectEqualStrings("[enter] ", s);
    const s2 = try shortcut(allocator, "ctrl+c", true, true);
    defer allocator.free(s2);
    try std.testing.expectEqualStrings("[ctrl+c]", s2);
}

test "statusText: waiting, running, exit" {
    const st = statusText(.waiting, null, false, testEnv);
    try std.testing.expectEqualStrings("🥱", st.indicator);
    try std.testing.expect(st.exit_code == null);

    const run = statusText(command_mod.runningStatus(1), null, false, testEnv);
    try std.testing.expectEqualStrings("🟢", run.indicator);

    const ex = statusText(command_mod.exitStatus(1, false), null, false, testEnv);
    try std.testing.expectEqualStrings("🔴", ex.indicator);
    try std.testing.expectEqual(@as(u32, 1), ex.exit_code.?);

    // NO_COLOR picks the plain variant.
    const ex_plain = statusText(command_mod.exitStatus(0, false), null, false, plainEnv);
    try std.testing.expectEqualStrings("●", ex_plain.indicator);
}

test "commandTitleWithIndicator" {
    const allocator = std.testing.allocator;
    const ct = CommandText{
        .formatted_command_with_title = "node --run frontend",
        .title = "Frontend",
        .title_possibly_with_graphic_renditions = "Frontend",
        .cwd = ".",
        .history = "",
    };
    const title = try commandTitleWithIndicator(allocator, "🟢", &ct, testEnv);
    defer allocator.free(title);
    // emoji width fix is a cursor nudge for 2-col emoji.
    try std.testing.expect(std.mem.indexOf(u8, title, "🟢") != null);
    try std.testing.expect(std.mem.indexOf(u8, title, "node --run frontend") != null);
}

test "cwdText: process cwd is empty, otherwise folder + path" {
    const allocator = std.testing.allocator;
    const ct = CommandText{
        .formatted_command_with_title = "",
        .title = "",
        .title_possibly_with_graphic_renditions = "",
        .cwd = "/tmp/proj",
        .history = "",
    };
    const empty = try cwdText(allocator, &ct, true, testEnv);
    defer allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);
    const with_cwd = try cwdText(allocator, &ct, false, testEnv);
    defer allocator.free(with_cwd);
    try std.testing.expect(std.mem.indexOf(u8, with_cwd, "/tmp/proj") != null);
}

test "waitingText" {
    const allocator = std.testing.allocator;
    const commands = &[_]Command{Command.forTest(.waiting, null)};
    const text = try waitingText(allocator, commands, plainEnv);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Waiting for other commands") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "exit") != null);
}

test "runningText and killingText" {
    const allocator = std.testing.allocator;
    const r = try runningText(allocator, 1234, plainEnv);
    defer allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "kill") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "(pid 1234)") != null);
    const k = try killingText(allocator, 1234, plainEnv);
    defer allocator.free(k);
    try std.testing.expect(std.mem.indexOf(u8, k, "double-press to force") != null);
}

test "exitText" {
    const allocator = std.testing.allocator;
    const commands = &[_]Command{Command.forTest(command_mod.exitStatus(1, false), null)};
    const ct = CommandText{
        .formatted_command_with_title = "false",
        .title = "false",
        .title_possibly_with_graphic_renditions = "false",
        .cwd = ".",
        .history = "",
    };
    const text = try exitText(allocator, commands, &ct, command_mod.exitStatus(1, false), .none, plainEnv);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "exit 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "restart") != null);
}

test "summaryOutcome" {
    const all_ok = &[_]Command{Command.forTest(command_mod.exitStatus(0, false), null)};
    try std.testing.expectEqualStrings("success", summaryOutcome(all_ok));
    const one_failed = &[_]Command{
        Command.forTest(command_mod.exitStatus(0, false), null),
        Command.forTest(command_mod.exitStatus(1, false), null),
    };
    try std.testing.expectEqualStrings("failure", summaryOutcome(one_failed));
    const killed = &[_]Command{Command.forTest(command_mod.exitStatus(130, true), null)};
    try std.testing.expectEqualStrings("aborted", summaryOutcome(killed));
}

test "drawSummary" {
    const allocator = std.testing.allocator;
    const commands = &[_]Command{
        Command.forTest(command_mod.exitStatus(0, false), null),
        Command.forTest(command_mod.exitStatus(1, false), null),
    };
    const text = try drawSummary(allocator, commands, plainEnv);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Summary – failure:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "exit 1") != null);
}

test "exitTextAndHistory" {
    const allocator = std.testing.allocator;
    var cmd = Command.forTest(command_mod.exitStatus(1, false), null);
    cmd.title = "my command";
    cmd.title_possibly_with_graphic_renditions = "my command";
    cmd.history = "line one\nline two";
    const text = try exitTextAndHistory(allocator, &cmd.text(), 1, 2, 3, plainEnv);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "my command") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "line one") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "exit 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "(2/3 exited)") != null);
}

test "getIndicatorChoice and getIndicatorChoices" {
    const allocator = std.testing.allocator;
    const commands = &[_]Command{
        Command.forTest(command_mod.exitStatus(0, false), null),
        Command.forTest(command_mod.exitStatus(1, false), null),
        Command.forTest(.waiting, null),
    };
    // exit 0 and exit 1 have different indicators; waiting has its own.
    const choices = try getIndicatorChoices(allocator, commands, plainEnv);
    defer allocator.free(choices);
    try std.testing.expectEqual(@as(usize, 3), choices.len);
}

test "drawDashboardCommandLines" {
    const allocator = std.testing.allocator;
    var c1 = Command.forTest(command_mod.exitStatus(0, false), "a");
    c1.title = "cmd one";
    c1.title_possibly_with_graphic_renditions = "cmd one";
    var c2 = Command.forTest(command_mod.runningStatus(1), "b");
    c2.title = "cmd two";
    c2.title_possibly_with_graphic_renditions = "cmd two";
    const commands = &[_]Command{c1, c2};
    const sel = Selection{ .invisible = .{ .index = 0 } };
    const lines = try drawDashboardCommandLines(allocator, commands, sel, 80, false, plainEnv);
    defer {
        for (lines) |l| allocator.free(l.line);
        allocator.free(lines);
    }
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expect(std.mem.indexOf(u8, lines[0].line, "cmd one") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines[1].line, "cmd two") != null);
}

test "drawDashboard" {
    const allocator = std.testing.allocator;
    var c1 = Command.forTest(command_mod.exitStatus(0, false), "a");
    c1.title = "cmd one";
    c1.title_possibly_with_graphic_renditions = "cmd one";
    var c2 = Command.forTest(command_mod.runningStatus(1), "b");
    c2.title = "cmd two";
    c2.title_possibly_with_graphic_renditions = "cmd two";
    const commands = &[_]Command{c1, c2};
    const sel = Selection{ .invisible = .{ .index = 0 } };
    const text = try drawDashboard(allocator, commands, 80, false, .none, sel, plainEnv);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "cmd one") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "cmd two") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "focus command") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "kill all") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "move selection") != null);
}

test "drawDashboard: done state" {
    const allocator = std.testing.allocator;
    var c1 = Command.forTest(command_mod.exitStatus(0, false), "a");
    c1.title = "cmd one";
    c1.title_possibly_with_graphic_renditions = "cmd one";
    const commands = &[_]Command{c1};
    const sel = Selection{ .invisible = .{ .index = 0 } };
    const text = try drawDashboard(allocator, commands, 80, true, .none, sel, plainEnv);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "cmd one") != null);
    // Done state: no footer.
    try std.testing.expect(std.mem.indexOf(u8, text, "focus command") == null);
}

test "drawDashboard: color env uses ANSI codes" {
    const allocator = std.testing.allocator;
    var c1 = Command.forTest(command_mod.runningStatus(1), "a");
    c1.title = "cmd one";
    c1.title_possibly_with_graphic_renditions = "cmd one";
    const commands = &[_]Command{c1};
    const sel = Selection{ .keyboard = .{ .index = 0 } };
    const color_env = Env{ .no_color = false, .supports_emoji = true };
    const text = try drawDashboard(allocator, commands, 80, false, .none, sel, color_env);
    defer allocator.free(text);
    // Color env should produce ANSI escape sequences.
    try std.testing.expect(std.mem.indexOf(u8, text, "\x1B[") != null);
}

test "drawDashboard: narrow width does not underflow" {
    const allocator = std.testing.allocator;
    var c1 = Command.forTest(command_mod.runningStatus(1), "a");
    c1.title = "a very long command title that exceeds the width";
    c1.title_possibly_with_graphic_renditions = "a very long command title that exceeds the width";
    const commands = &[_]Command{c1};
    const sel = Selection{ .invisible = .{ .index = 0 } };
    // Width smaller than the start_length + separator would cause underflow before the fix.
    const text = try drawDashboard(allocator, commands, 5, false, .none, sel, plainEnv);
    defer allocator.free(text);
    // Should not crash and should produce some output.
    try std.testing.expect(text.len > 0);
}

test "exitText: exit 0 with was_killed under auto_exit shows restart" {
    const allocator = std.testing.allocator;
    const commands = &[_]Command{Command.forTest(command_mod.exitStatus(0, true), null)};
    const ct = CommandText{
        .formatted_command_with_title = "cmd",
        .title = "cmd",
        .title_possibly_with_graphic_renditions = "cmd",
        .cwd = ".",
        .history = "",
    };
    const text = try exitText(allocator, commands, &ct, command_mod.exitStatus(0, true), .{ .auto_exit = 1 }, plainEnv);
    defer allocator.free(text);
    // Killed under auto_exit: not a clean exit, so restart is shown.
    try std.testing.expect(std.mem.indexOf(u8, text, "restart") != null);
}

test "exitText: exit 0 without kill under auto_exit hides restart" {
    const allocator = std.testing.allocator;
    const commands = &[_]Command{Command.forTest(command_mod.exitStatus(0, false), null)};
    const ct = CommandText{
        .formatted_command_with_title = "cmd",
        .title = "cmd",
        .title_possibly_with_graphic_renditions = "cmd",
        .cwd = ".",
        .history = "",
    };
    const text = try exitText(allocator, commands, &ct, command_mod.exitStatus(0, false), .{ .auto_exit = 1 }, plainEnv);
    defer allocator.free(text);
    // Clean exit under auto_exit: restart is hidden.
    try std.testing.expect(std.mem.indexOf(u8, text, "restart") == null);
}

test "exitTextAndHistory: history ending with newline" {
    const allocator = std.testing.allocator;
    var cmd = Command.forTest(command_mod.exitStatus(1, false), null);
    cmd.title = "my command";
    cmd.title_possibly_with_graphic_renditions = "my command";
    cmd.history = "line one\nline two\n";
    const text = try exitTextAndHistory(allocator, &cmd.text(), 1, 1, 1, plainEnv);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "line two") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "exit 1") != null);
}

test "drawDashboard: auto_exit=1 shows '1 command runs'" {
    const allocator = std.testing.allocator;
    var c1 = Command.forTest(command_mod.runningStatus(1), "a");
    c1.title = "cmd one";
    c1.title_possibly_with_graphic_renditions = "cmd one";
    const commands = &[_]Command{c1};
    const sel = Selection{ .invisible = .{ .index = 0 } };
    const text = try drawDashboard(allocator, commands, 80, false, .{ .auto_exit = 1 }, sel, plainEnv);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "1 command") != null);
}

test "drawDashboard: auto_exit=2 shows '2 commands run'" {
    const allocator = std.testing.allocator;
    var c1 = Command.forTest(command_mod.runningStatus(1), "a");
    c1.title = "cmd one";
    c1.title_possibly_with_graphic_renditions = "cmd one";
    var c2 = Command.forTest(command_mod.runningStatus(2), "b");
    c2.title = "cmd two";
    c2.title_possibly_with_graphic_renditions = "cmd two";
    const commands = &[_]Command{c1, c2};
    const sel = Selection{ .invisible = .{ .index = 0 } };
    const text = try drawDashboard(allocator, commands, 80, false, .{ .auto_exit = 2 }, sel, plainEnv);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "2 commands") != null);
}
