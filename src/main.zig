const std = @import("std");
const Io = std.Io;

const run_pty_zig = @import("run_pty_zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    const io = init.io;
    var buf: [1024]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), io, &buf);
    defer stdout.interface.flush() catch {};

    try run_pty_zig.run(&stdout.interface, args);
}
