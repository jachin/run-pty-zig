//! PTY allocation and process control.
//!
//! `openpty`/`forkpty` live in `<util.h>`, which Zig 0.17 does not expose
//! through `std.c`, so they are declared here as `extern "c"`. Everything else
//! (fork, waitpid, ioctl, dup2, setsid, chdir, kill, read, write, close) comes
//! from `std.c`/`std.posix`.
const std = @import("std");
const c = std.c;

extern "c" fn openpty(amaster: *c_int, aslave: *c_int, name: [*:0]u8, termp: ?*c.termios, winp: ?*c.winsize) c_int;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

// Darwin ioctl request encodings (computed from _IOW/_IOR/_IO in <sys/ioccom.h>).
const TIOCSWINSZ: c_int = @bitCast(@as(u32, 0x80087467));
const TIOCGWINSZ: c_int = @bitCast(@as(u32, 0x40087468));
const TIOCSCTTY: c_int = @bitCast(@as(u32, 0x0000746d));
const WNOHANG: c_int = 1;

/// A spawned process attached to a PTY. `master` is the parent's end of the
/// PTY; `pid` is the child's process id.
pub const Pty = struct {
    master: c_int,
    pid: c.pid_t,

    pub const Error = error{
        OpenptyFailed,
        ForkFailed,
    };

    /// Allocate a PTY and spawn `file` (with `args`) as a child whose stdio is
    /// the slave end. `cwd` is optional. Returns the master fd and child pid.
    ///
    /// The argv/cwd strings are allocated in the child after `fork` (using the
    /// page allocator) and are discarded when the child `exec`s, so no freeing
    /// is required in the parent.
    pub fn spawn(file: []const u8, args: []const []const u8, cwd: ?[]const u8, cols: u16, rows: u16) Error!Pty {
        var master: c_int = undefined;
        var slave: c_int = undefined;
        var name: [128]u8 = undefined;
        name[0] = 0;
        var ws: c.winsize = .{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
        if (openpty(&master, &slave, @ptrCast(&name), null, &ws) != 0) {
            return error.OpenptyFailed;
        }

        const pid = c.fork();
        if (pid < 0) {
            _ = c.close(master);
            _ = c.close(slave);
            return error.ForkFailed;
        }
        if (pid == 0) {
            // Child: become a session leader, adopt the slave as controlling
            // tty, point stdio at it, then exec.
            const alloc = std.heap.page_allocator;
            _ = c.setsid();
            _ = c.ioctl(slave, TIOCSCTTY);
            _ = c.dup2(slave, 0);
            _ = c.dup2(slave, 1);
            _ = c.dup2(slave, 2);
            if (slave > 2) _ = c.close(slave);
            _ = c.close(master);
            if (cwd) |dir| {
                const zdir = zdup(alloc, dir) catch unreachable;
                _ = c.chdir(zdir);
            }
            const argv = buildArgv(alloc, file, args) catch unreachable;
            _ = execvp(argv[0].?, argv);
            // execvp only returns on failure.
            const msg = "run-pty: failed to exec\n";
            _ = c.write(2, msg.ptr, msg.len);
            c._exit(127);
        }
        // Parent: the slave end is not needed.
        _ = c.close(slave);
        return .{ .master = master, .pid = pid };
    }

    /// Read up to `buf.len` bytes from the master end.
    pub fn read(self: *const Pty, buf: []u8) std.posix.ReadError!usize {
        return std.posix.read(self.master, buf);
    }

    /// Write `data` to the master end (goes to the child's stdin).
    pub fn write(self: *const Pty, data: []const u8) void {
        _ = c.write(self.master, data.ptr, data.len);
    }

    /// Resize the child's terminal window.
    pub fn resize(self: *const Pty, cols: u16, rows: u16) void {
        var ws: c.winsize = .{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
        _ = c.ioctl(self.master, TIOCSWINSZ, &ws);
    }

    /// Send a signal to the child.
    pub fn kill(self: *const Pty, sig: std.posix.SIG) void {
        _ = std.posix.kill(self.pid, sig) catch {};
    }

    /// Block until the child exits; returns its exit code (128+signal if killed
    /// by a signal).
    pub fn wait(self: *const Pty) c_int {
        var status: c_int = undefined;
        while (c.waitpid(self.pid, &status, 0) < 0) {
            // EINTR: retry.
        }
        return decodeStatus(status);
    }

    /// Non-blocking wait. Returns the exit code if the child has exited, or
    /// null if it is still running.
    pub fn tryWait(self: *const Pty) ?c_int {
        var status: c_int = undefined;
        const rc = c.waitpid(self.pid, &status, WNOHANG);
        if (rc == 0) return null; // still running
        if (rc < 0) return null; // error (e.g. EINTR); treat as still running
        return decodeStatus(status);
    }

    /// Read all remaining output from the PTY master (drain the kernel buffer).
    /// Returns the collected data as an owned slice.
    pub fn drain(self: *const Pty) []u8 {
        var out: std.array_list.Managed(u8) = .init(std.heap.page_allocator);
        defer out.deinit();
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = self.read(&buf) catch break;
            if (n == 0) break;
            out.appendSlice(buf[0..n]) catch break;
        }
        return out.toOwnedSlice() catch &.{};
    }

    /// Close the master fd.
    pub fn deinit(self: *const Pty) void {
        _ = c.close(self.master);
    }

    pub fn decodeStatus(status: c_int) c_int {
        const u = @as(u32, @bitCast(status));
        const sig = u & 0x7f;
        if (sig == 0) {
            return @as(c_int, @intCast(u >> 8));
        }
        return 128 + @as(c_int, @intCast(sig));
    }

    fn buildArgv(allocator: std.mem.Allocator, file: []const u8, args: []const []const u8) ![*:null]const ?[*:0]const u8 {
        const total = args.len + 2;
        const argv = try allocator.alloc(?[*:0]const u8, total);
        argv[0] = try zdup(allocator, file);
        for (args, 1..) |arg, i| {
            argv[i] = try zdup(allocator, arg);
        }
        argv[total - 1] = null;
        return @ptrCast(@constCast(argv.ptr));
    }

    fn zdup(allocator: std.mem.Allocator, s: []const u8) ![*:0]const u8 {
        const z = try allocator.alloc(u8, s.len + 1);
        @memcpy(z[0..s.len], s);
        z[s.len] = 0;
        return @ptrCast(@constCast(z.ptr));
    }
};

test "spawn echo and read its output" {
    const pty = try Pty.spawn("echo", &.{"hello", "world"}, null, 80, 24);
    defer pty.deinit();

    var buf: [512]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        const n = pty.read(buf[len..]) catch break;
        if (n == 0) break;
        len += n;
    }
    const exit_code = pty.wait();
    try std.testing.expectEqual(@as(c_int, 0), exit_code);
    var text_end = len;
    for (buf[0..len], 0..) |ch, i| {
        if (ch == '\n') {
            text_end = i;
            break;
        }
    }
    // PTYs in canonical mode emit \r\n (ONLCR); strip the trailing \r.
    if (text_end > 0 and buf[text_end - 1] == '\r') text_end -= 1;
    try std.testing.expectEqualStrings("hello world", buf[0..text_end]);
}

test "spawn a failing command reports its exit code" {
    const pty = try Pty.spawn("sh", &.{"-c", "exit 3"}, null, 80, 24);
    defer pty.deinit();
    var buf: [256]u8 = undefined;
    var r: usize = 1;
    while (r != 0) {
        r = pty.read(&buf) catch 0;
    }
    const exit_code = pty.wait();
    try std.testing.expectEqual(@as(c_int, 3), exit_code);
}

test "killing a sleeping process yields 128+signal" {
    const pty = try Pty.spawn("sleep", &.{"30"}, null, 80, 24);
    defer pty.deinit();
    pty.kill(.KILL);
    const exit_code = pty.wait();
    try std.testing.expectEqual(@as(c_int, 128 + @intFromEnum(std.posix.SIG.KILL)), exit_code);
}
