//! Core logic for run-pty-zig, kept separate from the CLI entry point in main.zig.
const std = @import("std");
const Io = std.Io;

const types = @import("types.zig");
const labels = @import("labels.zig");
const args_mod = @import("args.zig");
const ansi = @import("ansi.zig");
const indicators = @import("indicators.zig");
const command = @import("command.zig");
const render = @import("render.zig");
const pty = @import("pty.zig");
const noninteractive = @import("noninteractive.zig");
const interactive = @import("interactive.zig");

// Re-export the public API (Zig 0.17 has no `usingnamespace`).
pub const StatusTuple = types.StatusTuple;
pub const StatusRule = types.StatusRule;
pub const CommandDescription = types.CommandDescription;
pub const AutoExit = types.AutoExit;
pub const ParseResult = types.ParseResult;

pub const LABEL_GROUPS = labels.LABEL_GROUPS;
pub const ALL_LABELS = labels.ALL_LABELS;
pub const summarizeLabels = labels.summarizeLabels;

pub const ParseError = args_mod.ParseError;
pub const commandToPresentationName = args_mod.commandToPresentationName;
pub const parseInputFile = args_mod.parseInputFile;
pub const parseArgs = args_mod.parseArgs;

pub const removeGraphicRenditions = ansi.removeGraphicRenditions;
pub const truncate = ansi.truncate;
pub const splitUnfinishedEscape = ansi.splitUnfinishedEscape;

pub const Env = indicators.Env;
pub const Indicator = indicators.Indicator;
pub const pick = indicators.pick;
pub const extractStatus = indicators.extractStatus;

pub const Status = command.Status;
pub const Command = command.Command;
pub const CommandText = command.CommandText;
pub const Current = command.Current;
pub const Selection = command.Selection;
pub const isDone = command.isDone;

pub const statusText = render.statusText;
pub const drawSummary = render.drawSummary;
pub const exitTextAndHistory = render.exitTextAndHistory;

pub const Pty = pty.Pty;
pub const runNonInteractively = noninteractive.run;
pub const runInteractively = interactive.run;

/// Detect the rendering environment from environment variables.
fn detectEnv() Env {
    const nc = std.c.getenv("NO_COLOR");
    if (nc) |ptr| {
        if (ptr[0] != 0) return Env{ .no_color = true, .supports_emoji = false };
    }
    return Env{ .no_color = false, .supports_emoji = true };
}

pub const version = "0.0.1";

/// Entry point for the tool. `args` is the full argv; `args[0]` is the program
/// name. `stdin_is_tty` decides between interactive (Phase 6) and
/// non-interactive (CI) modes.
pub fn run(writer: *Io.Writer, args: []const [:0]const u8, stdin_is_tty: bool) !void {
    const allocator = std.heap.page_allocator;
    const rest = if (args.len > 0) args[1..] else args;

    // Handle --version / -V before parsing.
    for (rest) |arg| {
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            try writer.print("run-pty-zig {s}\n", .{ version });
            writer.flush() catch {};
            return;
        }
    }

    const parse_result = try parseArgs(allocator, rest);
    defer switch (parse_result) {
        .parsed => |p| allocator.free(p.commands),
        .error_message => |msg| allocator.free(msg),
        else => {},
    };

    switch (parse_result) {
        .help => {
            try writer.print("run-pty-zig {s}\n\nUsage: run-pty-zig [--auto-exit=N] <delimiter> <cmd1> <delimiter> <cmd2> ...\n       run-pty-zig [--auto-exit=N] <config.json>\n\nFlags:\n  --auto-exit=N    Exit when all commands finish; at most N run in parallel.\n  --auto-exit=auto Same, but N = CPU count.\n  -h, --help       Show this help.\n  -V, --version    Show version.\n", .{ version });
        },
        .no_commands => {},
        .error_message => |msg| {
            try writer.print("run-pty-zig: {s}\n", .{ msg });
        },
        .parsed => |p| {
            const env = detectEnv();
            const has_auto_exit = p.auto_exit == .auto_exit;
            if (!stdin_is_tty) {
                if (has_auto_exit) {
                    const exit_code = try runNonInteractively(allocator, p.commands, p.auto_exit, env, writer);
                    writer.flush() catch {};
                    std.process.exit(@as(u8, @intCast(exit_code)));
                } else {
                    try writer.writeAll("run-pty-zig: interactive mode requires a TTY. Use --auto-exit=N for non-interactive mode.\n");
                    writer.flush() catch {};
                    std.process.exit(1);
                }
            } else {
                const exit_code = try runInteractively(allocator, p.commands, p.auto_exit, env, writer);
                writer.flush() catch {};
                std.process.exit(@as(u8, @intCast(exit_code)));
            }
        },
    }
}
