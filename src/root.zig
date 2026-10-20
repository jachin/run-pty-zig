//! Core logic for run-pty-zig, kept separate from the CLI entry point in main.zig.
const std = @import("std");
const Io = std.Io;

/// Runs the tool. `args` is the full argv; `args[0]` is the program name.
pub fn run(writer: *Io.Writer, args: []const [:0]const u8) !void {
    _ = args;
    try writer.print("run-pty-zig: not implemented yet\n", .{});
}

test "run" {
    // Placeholder until the PTY/dashboard logic lands.
}
