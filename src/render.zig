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

/// Wrap `s` in dim (faint) ANSI codes, unless NO_COLOR. Returns an owned slice.
pub fn dim(allocator: Allocator, s: []const u8, no_color: bool) ![]u8 {
    if (no_color) return allocator.dupe(u8, s);
    var out: std.array_list.Managed(u8) = .init(allocator);
    defer out.deinit();
    try out.appendSlice("\x1B[2m");
    try out.appendSlice(s);
    try out.appendSlice(RESET_COLOR);
    return out.toOwnedSlice();
}

/// Wrap `s` in bold ANSI codes, unless NO_COLOR. Returns an owned slice.
pub fn bold(allocator: Allocator, s: []const u8, no_color: bool) ![]u8 {
    if (no_color) return allocator.dupe(u8, s);
    var out: std.array_list.Managed(u8) = .init(allocator);
    defer out.deinit();
    try out.appendSlice("\x1B[1m");
    try out.appendSlice(s);
    try out.appendSlice(RESET_COLOR);
    return out.toOwnedSlice();
}

/// Wrap `s` in reverse-video (invert) ANSI codes, unless NO_COLOR. This is a
/// simplified version of the original (which splits on embedded reset codes);
/// it wraps the whole string, which is sufficient for the dashboard highlight.
pub fn invert(allocator: Allocator, s: []const u8, no_color: bool) ![]u8 {
    if (no_color) return allocator.dupe(u8, s);
    var out: std.array_list.Managed(u8) = .init(allocator);
    defer out.deinit();
    try out.appendSlice("\x1B[7m");
    try out.appendSlice(s);
    try out.appendSlice(RESET_COLOR);
    return out.toOwnedSlice();
}

/// Render a keyboard shortcut like `[ctrl+c]`, padding to the width of the
/// longest key ("ctrl+c") when `pad` is true. Returns an owned slice.
pub fn shortcut(allocator: Allocator, s: []const u8, pad: bool, no_color: bool) ![]u8 {
    var out: std.array_list.Managed(u8) = .init(allocator);
    defer out.deinit();
    const open = try dim(allocator, "[", no_color);
    defer allocator.free(open);
    try out.appendSlice(open);
    const body = try bold(allocator, s, no_color);
    defer allocator.free(body);
    try out.appendSlice(body);
    const close = try dim(allocator, "]", no_color);
    defer allocator.free(close);
    try out.appendSlice(close);
    if (pad) {
        const target: usize = KEYS.kill.len;
        if (target > s.len) {
            for (0..(target - s.len)) |_| try out.append(' ');
        }
    }
    return out.toOwnedSlice();
}

/// The display width of a status icon, and the cursor nudge that compensates
/// for emoji being 2 columns wide.
pub fn iconWidth(env: Env) usize {
    return if (env.no_color or !env.supports_emoji) 1 else 2;
}

pub fn emojiWidthFix(env: Env) []const u8 {
    return if (env.no_color or !env.supports_emoji) "" else cursorHorizontalAbsolute(3);
}

pub fn cursorHorizontalAbsolute(n: usize) []const u8 {
    // `\x1B[{n}G`
    var buf: [16]u8 = undefined;
    return std.fmt.bufPrint(&buf, "\x1B[{d}G", .{ n }) catch unreachable;
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
        if (env.no_color or !env.supports_emoji) return v[1];
        return v[0];
    }
    return pick(running, env);
}

// ---------------------------------------------------------------------------
// Title / cwd / history-start.
// ---------------------------------------------------------------------------

/// The cwd line: empty when it's the process cwd, else a folder icon + path.
pub fn cwdText(allocator: Allocator, command: *const CommandText, is_process_cwd: bool, env: Env) ![]u8 {
    if (is_process_cwd) return allocator.dupe(u8, "");
    var out: std.array_list.Managed(u8) = .init(allocator);
    defer out.deinit();
    try out.appendSlice(pick(folder, env));
    try out.appendSlice(emojiWidthFix(env));
    try out.append(' ');
    const dimmed = try dim(allocator, command.cwd, env.no_color);
    defer allocator.free(dimmed);
    try out.appendSlice(dimmed);
    try out.append('\n');
    return out.toOwnedSlice();
}

/// `indicator + width-fix + " " + formattedCommandWithTitle + reset`.
pub fn commandTitleWithIndicator(allocator: Allocator, indicator: []const u8, command: *const CommandText, env: Env) ![]u8 {
    var out: std.array_list.Managed(u8) = .init(allocator);
    defer out.deinit();
    try out.appendSlice(indicator);
    try out.appendSlice(emojiWidthFix(env));
    try out.append(' ');
    try out.appendSlice(command.formatted_command_with_title);
    try out.appendSlice(RESET_COLOR);
    return out.toOwnedSlice();
}

/// Like `commandTitleWithIndicator` but shows only the title (not the full
/// command). Used in non-interactive mode and the dashboard.
pub fn commandTitleOnlyWithIndicator(allocator: Allocator, indicator: []const u8, command: *const CommandText, env: Env) ![]u8 {
    var out: std.array_list.Managed(u8) = .init(allocator);
    defer out.deinit();
    try out.appendSlice(indicator);
    try out.appendSlice(emojiWidthFix(env));
    try out.append(' ');
    try out.appendSlice(command.title_possibly_with_graphic_renditions);
    try out.appendSlice(RESET_COLOR);
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
    defer out.deinit();

    const title = try commandTitleOnlyWithIndicator(allocator, pick(exitIndicator(exit_code), env), command, env);
    defer allocator.free(title);
    try out.appendSlice(title);
    try out.append('\n');

    const cwd = try cwdText(allocator, command, false, env);
    defer allocator.free(cwd);
    try out.appendSlice(cwd);
    try out.appendSlice(command.history);
    try out.appendSlice(CLEAR_DOWN);
    try out.appendSlice(newline);

    const exit_plain = try std.fmt.allocPrint(allocator, "exit {d}", .{ exit_code });
    defer allocator.free(exit_plain);
    const exit_bold = try bold(allocator, exit_plain, env.no_color);
    defer allocator.free(exit_bold);
    try out.appendSlice(exit_bold);
    try out.append(' ');

    const count_plain = try std.fmt.allocPrint(allocator, "({d}/{d} exited)", .{ num_exited, num_total });
    defer allocator.free(count_plain);
    const count_dim = try dim(allocator, count_plain, env.no_color);
    defer allocator.free(count_dim);
    try out.appendSlice(count_dim);
    try out.appendSlice("\n\n");

    return out.toOwnedSlice();
}

/// The header printed before a command's history: title + cwd.
pub fn historyStart(allocator: Allocator, indicator: []const u8, command: *const CommandText, is_process_cwd: bool, env: Env) ![]u8 {
    var out: std.array_list.Managed(u8) = .init(allocator);
    defer out.deinit();
    const title = try commandTitleWithIndicator(allocator, indicator, command, env);
    defer allocator.free(title);
    try out.appendSlice(title);
    try out.append('\n');
    const cwd = try cwdText(allocator, command, is_process_cwd, env);
    defer allocator.free(cwd);
    try out.appendSlice(cwd);
    return out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Footer texts (focused command).
// ---------------------------------------------------------------------------

pub fn waitingText(allocator: Allocator, commands: []const Command, env: Env) ![]u8 {
    var out: std.array_list.Managed(u8) = .init(allocator);
    defer out.deinit();
    try out.appendSlice("\nWaiting for other commands to finish before starting.\n\n");
    const kill = try shortcut(allocator, KEYS.kill, true, env.no_color);
    defer allocator.free(kill);
    try out.appendSlice(kill);
    try out.append(' ');
    const label = try killAllLabel(allocator, commands, env.no_color);
    defer allocator.free(label);
    try out.appendSlice(label);
    try out.append('\n');
    const dash = try shortcut(allocator, KEYS.dashboard, true, env.no_color);
    defer allocator.free(dash);
    try out.appendSlice(dash);
    try out.appendSlice(" dashboard\n");
    return out.toOwnedSlice();
}

pub fn runningText(allocator: Allocator, pid: i32, env: Env) ![]u8 {
    var out: std.array_list.Managed(u8) = .init(allocator);
    defer out.deinit();
    try out.append('\n');
    const kill = try shortcut(allocator, KEYS.kill, true, env.no_color);
    defer allocator.free(kill);
    try out.appendSlice(kill);
    try out.appendSlice(" kill ");
    const pid_str = try std.fmt.allocPrint(allocator, "(pid {d})", .{ pid });
    defer allocator.free(pid_str);
    const pid_text = try dim(allocator, pid_str, env.no_color);
    defer allocator.free(pid_text);
    try out.appendSlice(pid_text);
    try out.append('\n');
    const dash = try shortcut(allocator, KEYS.dashboard, true, env.no_color);
    defer allocator.free(dash);
    try out.appendSlice(dash);
    try out.appendSlice(" dashboard\n");
    return out.toOwnedSlice();
}

pub fn killingText(allocator: Allocator, pid: i32, env: Env) ![]u8 {
    var out: std.array_list.Managed(u8) = .init(allocator);
    defer out.deinit();
    try out.append('\n');
    const kill = try shortcut(allocator, KEYS.kill, true, env.no_color);
    defer allocator.free(kill);
    try out.appendSlice(kill);
    try out.appendSlice(" kill ");
    const pid_str = try std.fmt.allocPrint(allocator, "(double-press to force) (pid {d})", .{ pid });
    defer allocator.free(pid_str);
    const pid_text = try dim(allocator, pid_str, env.no_color);
    defer allocator.free(pid_text);
    try out.appendSlice(pid_text);
    try out.append('\n');
    const dash = try shortcut(allocator, KEYS.dashboard, true, env.no_color);
    defer allocator.free(dash);
    try out.appendSlice(dash);
    try out.appendSlice(" dashboard\n");
    return out.toOwnedSlice();
}

/// The label for the kill-all shortcut.
pub fn killAllLabel(allocator: Allocator, commands: []const Command, no_color: bool) ![]u8 {
    var any_killing = false;
    var any_terminal = false;
    for (commands) |c| {
        if (command_mod.statusHasTerminal(c.status)) any_terminal = true;
        if (c.status == .killing) any_killing = true;
    }
    if (any_killing) {
        var out: std.array_list.Managed(u8) = .init(allocator);
        defer out.deinit();
        try out.appendSlice("kill all ");
        const dimmed = try dim(allocator, "(double-press to force) ", no_color);
        defer allocator.free(dimmed);
        try out.appendSlice(dimmed);
        return out.toOwnedSlice();
    }
    if (!any_terminal) return allocator.dupe(u8, "exit");
    return allocator.dupe(u8, "kill all");
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
    defer out.deinit();
    try out.append('\n');
    const title = try commandTitleWithIndicator(allocator, indicator, command, env);
    defer allocator.free(title);
    try out.appendSlice(title);
    try out.append('\n');
    const cwd = try cwdText(allocator, command, false, env);
    defer allocator.free(cwd);
    try out.appendSlice(cwd);
    try out.appendSlice("exit ");
    const exit_str = try std.fmt.allocPrint(allocator, "{d}\n\n", .{ exit_code });
    defer allocator.free(exit_str);
    try out.appendSlice(exit_str);
    // Restart line: omitted when auto-exit and a clean, non-killed exit.
    const show_restart = !(is_auto_exit and exit_code == 0 and !was_killed);
    if (show_restart) {
        const enter = try shortcut(allocator, KEYS.enter, true, env.no_color);
        defer allocator.free(enter);
        try out.appendSlice(enter);
        try out.appendSlice(" restart\n");
    }
    const kill = try shortcut(allocator, KEYS.kill, true, env.no_color);
    defer allocator.free(kill);
    try out.appendSlice(kill);
    try out.append(' ');
    const label = try killAllLabel(allocator, commands, env.no_color);
    defer allocator.free(label);
    try out.appendSlice(label);
    try out.append('\n');
    const dash = try shortcut(allocator, KEYS.dashboard, true, env.no_color);
    defer allocator.free(dash);
    try out.appendSlice(dash);
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
    defer out.deinit();
    const outcome = summaryOutcome(commands);
    const header_str = try std.fmt.allocPrint(allocator, "Summary – {s}:", .{ outcome });
    defer allocator.free(header_str);
    const header = try bold(allocator, header_str, env.no_color);
    defer allocator.free(header);
    try out.appendSlice(header);
    try out.append('\n');
    for (commands, 0..) |c, i| {
        if (i > 0) try out.append('\n');
        const st = statusText(c.status, c.status_from_rules, true, env);
        try out.appendSlice(st.indicator);
        try out.appendSlice(emojiWidthFix(env));
        try out.append(' ');
        if (st.exit_code) |code| {
            const exit_plain = try std.fmt.allocPrint(allocator, "exit {d}", .{ code });
            defer allocator.free(exit_plain);
            const exit_str = try bold(allocator, exit_plain, env.no_color);
            defer allocator.free(exit_str);
            try out.appendSlice(exit_str);
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
    defer lines.deinit();

    for (commands, 0..) |c, i| {
        const st = statuses.items[i];
        const label = if (c.label) |l| l else " ";
        const label_sc = try shortcut(allocator, label, false, env.no_color);
        defer allocator.free(label_sc);

        // Build the icon portion.
        var icon_buf: std.array_list.Managed(u8) = .init(allocator);
        defer icon_buf.deinit();
        const is_selected_indicator = if (selected_indicator) |si| std.mem.eql(u8, st.indicator, si) else false;
        if (is_selected_indicator) {
            if (env.no_color) {
                try icon_buf.appendSlice(separator[0..1]);
                try icon_buf.appendSlice("→");
                try icon_buf.appendSlice(st.indicator);
            } else {
                try icon_buf.appendSlice(separator[0..1]);
                var padded: std.array_list.Managed(u8) = .init(allocator);
                defer padded.deinit();
                try padded.append(' ');
                try padded.appendSlice(st.indicator);
                for (0..icon_width) |_| try padded.append(' ');
                const padded_slice = try padded.toOwnedSlice();
                const inv = try invert(allocator, padded_slice, env.no_color);
                allocator.free(padded_slice);
                try icon_buf.appendSlice(inv);
                allocator.free(inv);
            }
        } else {
            try icon_buf.appendSlice(separator);
            try icon_buf.appendSlice(st.indicator);
        }
        const icon_str = try icon_buf.toOwnedSlice();
        defer allocator.free(icon_str);

        const start = try ansi.truncate(allocator, label_sc, width);
        defer allocator.free(start);
        const start_combined = try std.mem.concat(allocator, u8, &.{ start, icon_str });
        defer allocator.free(start_combined);

        const start_length = removeGraphicRenditionsLen(label_sc) + separator.len + icon_width;

        // Build the end portion.
        var end_buf: std.array_list.Managed(u8) = .init(allocator);
        defer end_buf.deinit();
        if (st.exit_code) |code| {
            var status_buf: [16]u8 = undefined;
            const status_str = std.fmt.bufPrint(&status_buf, "exit {d}", .{ code }) catch "exit 99999";
            try end_buf.appendSlice(status_str);
            for (0..(widest_status - status_str.len)) |_| try end_buf.append(' ');
            try end_buf.appendSlice(separator);
        }
        try end_buf.appendSlice(c.title_possibly_with_graphic_renditions);
        const end_str = try end_buf.toOwnedSlice();
        defer allocator.free(end_str);

        const truncated_end = try ansi.truncate(allocator, end_str, width - start_length - separator.len);
        defer allocator.free(truncated_end);

        const length = start_length + separator.len + removeGraphicRenditionsLen(truncated_end);

        // Highlighted separator.
        var sep_buf: std.array_list.Managed(u8) = .init(allocator);
        defer sep_buf.deinit();
        if (is_selected_indicator and !env.no_color) {
            const inv_space = try invert(allocator, " ", env.no_color);
            defer allocator.free(inv_space);
            try sep_buf.appendSlice(inv_space);
            try sep_buf.appendSlice(separator[1..]);
        } else {
            try sep_buf.appendSlice(separator);
        }
        const sep_str = try sep_buf.toOwnedSlice();
        defer allocator.free(sep_str);

        // Final end with highlight.
        var final_end_buf: std.array_list.Managed(u8) = .init(allocator);
        defer final_end_buf.deinit();
        const sel_index: ?usize = switch (selection) {
            .keyboard => |k| k.index,
            .mousedown => |m| m.index,
            else => null,
        };
        const is_selected = sel_index != null and sel_index.? == i;
        if (is_selected) {
            if (env.no_color) {
                try final_end_buf.appendSlice(sep_str[0..1]);
                try final_end_buf.appendSlice("→");
                try final_end_buf.appendSlice(truncated_end);
            } else {
                try final_end_buf.appendSlice(sep_str);
                const inv_end = try invert(allocator, truncated_end, env.no_color);
                defer allocator.free(inv_end);
                try final_end_buf.appendSlice(inv_end);
            }
        } else {
            try final_end_buf.appendSlice(sep_str);
            try final_end_buf.appendSlice(truncated_end);
        }
        const final_end = try final_end_buf.toOwnedSlice();
        defer allocator.free(final_end);

        // Assemble the line.
        var line_buf: std.array_list.Managed(u8) = .init(allocator);
        defer line_buf.deinit();
        try line_buf.appendSlice(start_combined);
        try line_buf.appendSlice(RESET_COLOR);
        try line_buf.appendSlice(cursorHorizontalAbsolute(start_length + 1));
        try line_buf.appendSlice(CLEAR_RIGHT);
        try line_buf.appendSlice(final_end);
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

    var final_lines: std.array_list.Managed(u8) = .init(allocator);
    defer final_lines.deinit();
    for (lines, 0..) |l, i| {
        if (i > 0) try final_lines.append('\n');
        try final_lines.appendSlice(l.line);
    }

    if (done) {
        try final_lines.append('\n');
        return final_lines.toOwnedSlice();
    }

    const label = labels.summarizeLabels(allocator, commands.len) catch return final_lines.toOwnedSlice();
    defer allocator.free(label);

    // Enter line.
    var enter_buf: std.array_list.Managed(u8) = .init(allocator);
    defer enter_buf.deinit();
    switch (selection) {
        .keyboard => |kb| {
            const enter_sc = try shortcut(allocator, KEYS.enter, false, env.no_color);
            defer allocator.free(enter_sc);
            try enter_buf.appendSlice(enter_sc);
            try enter_buf.appendSlice(" focus selected");
            const pid = command_mod.getPid(&commands[kb.index]);
            if (pid) |p| {
                const pid_str = try std.fmt.allocPrint(allocator, " (pid {d})", .{ p });
                defer allocator.free(pid_str);
                try enter_buf.appendSlice(pid_str);
            }
            try enter_buf.append('\n');
            const unsel_sc = try shortcut(allocator, KEYS.unselect, false, env.no_color);
            defer allocator.free(unsel_sc);
            try enter_buf.appendSlice(unsel_sc);
            try enter_buf.appendSlice(" unselect");
        },
        .by_indicator => |bi| {
            const enter_sc = try shortcut(allocator, KEYS.enter, false, env.no_color);
            defer allocator.free(enter_sc);
            try enter_buf.appendSlice(enter_sc);
            var any_killing = false;
            for (commands) |*c| {
                if (std.mem.eql(u8, getIndicatorChoice(c, env), bi.indicator) and c.status == .killing) any_killing = true;
            }
            if (any_killing) try enter_buf.appendSlice(" force ");
            try enter_buf.appendSlice("restart selected\n");
            const unsel_sc = try shortcut(allocator, KEYS.unselect, false, env.no_color);
            defer allocator.free(unsel_sc);
            try enter_buf.appendSlice(unsel_sc);
            try enter_buf.appendSlice(" unselect");
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
                    const enter_sc = try shortcut(allocator, KEYS.enter, false, env.no_color);
                    defer allocator.free(enter_sc);
                    try enter_buf.appendSlice(enter_sc);
                    try enter_buf.appendSlice(" restart failed");
                }
            } else if (has_exited) {
                const enter_sc = try shortcut(allocator, KEYS.enter, false, env.no_color);
                defer allocator.free(enter_sc);
                try enter_buf.appendSlice(enter_sc);
                try enter_buf.appendSlice(" restart exited");
            }
        },
    }
    const enter_str = try enter_buf.toOwnedSlice();
    defer allocator.free(enter_str);

    const nav_keys = if (auto_exit == .auto_exit) KEYS.navigate_vertically_only else KEYS.navigate;

    var out: std.array_list.Managed(u8) = .init(allocator);
    defer out.deinit();
    try out.append('\n');
    try out.appendSlice(final_lines.items);
    try out.appendSlice("\n\n");

    const label_sc = try shortcut(allocator, label, false, env.no_color);
    defer allocator.free(label_sc);
    try out.appendSlice(label_sc);
    try out.appendSlice(" focus command ");
    const or_click = try dim(allocator, "(or click)", env.no_color);
    defer allocator.free(or_click);
    try out.appendSlice(or_click);
    try out.append('\n');

    const kill_sc = try shortcut(allocator, KEYS.kill, false, env.no_color);
    defer allocator.free(kill_sc);
    try out.appendSlice(kill_sc);
    try out.append(' ');
    const kill_label = try killAllLabel(allocator, commands, env.no_color);
    defer allocator.free(kill_label);
    try out.appendSlice(kill_label);
    try out.append('\n');

    const nav_sc = try shortcut(allocator, nav_keys, false, env.no_color);
    defer allocator.free(nav_sc);
    try out.appendSlice(nav_sc);
    try out.appendSlice(" move selection\n");

    if (enter_str.len > 0) {
        try out.appendSlice(enter_str);
        try out.append('\n');
    }

    switch (auto_exit) {
        .auto_exit => |max_parallel| {
            const session_ends = "The session ends automatically once all commands are ";
            try out.appendSlice(session_ends);
            try out.appendSlice(pick(exitIndicator(0), env));
            try out.appendSlice(emojiWidthFix(env));
            try out.appendSlice(" ");
            const exit0 = try bold(allocator, "exit 0", env.no_color);
            defer allocator.free(exit0);
            try out.appendSlice(exit0);
            try out.appendSlice(".\n");
            const max_str = try std.fmt.allocPrint(allocator, "At most {d} {s} at a time.", .{ max_parallel, if (max_parallel == 1) "command runs" else "commands run" });
            defer allocator.free(max_str);
            try out.appendSlice(max_str);
            try out.append('\n');
        },
        else => {},
    }

    return out.toOwnedSlice();
}

/// Display length of a string after removing SGR (color/style) escape sequences.
fn removeGraphicRenditionsLen(s: []const u8) usize {
    var i: usize = 0;
    var len: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1B and i + 1 < s.len and s[i + 1] == '[') {
            var j = i + 2;
            while (j < s.len and ((s[j] >= '0' and s[j] <= '9') or s[j] == ';')) j += 1;
            if (j < s.len and s[j] == 'm') {
                i = j + 1;
                continue;
            }
        }
        len += 1;
        i += 1;
    }
    return len;
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
