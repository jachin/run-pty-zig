const std = @import("std");
const Allocator = std.mem.Allocator;
const ansi = @import("ansi.zig");

/// Environment flags that decide how indicators are rendered.
pub const Env = struct {
    /// When set, indicators are plain single characters (no ANSI color).
    no_color: bool,
    /// When false, emoji are replaced by colored single characters.
    supports_emoji: bool,
};

/// A status indicator is a 3-way value: an emoji (2 columns), a colored
/// single character (ANSI), and a plain single character (for NO_COLOR).
pub const Indicator = struct {
    emoji: []const u8,
    colored: []const u8,
    plain: []const u8,
};

/// Pick the right variant of an indicator for the given environment.
pub fn pick(ind: Indicator, env: Env) []const u8 {
    if (env.no_color) return ind.plain;
    if (!env.supports_emoji) return ind.colored;
    return ind.emoji;
}

pub const waiting = Indicator{
    .emoji = "🥱",
    .colored = "\x1B[93m■\x1B[m",
    .plain = "■",
};

pub const running = Indicator{
    .emoji = "🟢",
    .colored = "\x1B[92m●\x1B[m",
    .plain = "›",
};

pub const killing = Indicator{
    .emoji = "⭕",
    .colored = "\x1B[91m○\x1B[m",
    .plain = "○",
};

pub const restarting = Indicator{
    .emoji = "🔄",
    .colored = "\x1B[96m◌\x1B[m",
    .plain = "◌",
};

pub const aborted = Indicator{
    .emoji = "⛔️",
    .colored = "\x1B[91m▲\x1B[m",
    .plain = "▲",
};

/// The indicator for a command that has exited. `130` (128 + SIGINT) is
/// treated like a clean exit (it usually means the user pressed Ctrl-C).
pub fn exitIndicator(exit_code: u32) Indicator {
    if (exit_code == 0 or exit_code == 130) {
        return Indicator{
            .emoji = "⚪",
            .colored = "\x1B[97m●\x1B[m",
            .plain = "●",
        };
    }
    return Indicator{
        .emoji = "🔴",
        .colored = "\x1B[91m●\x1B[m",
        .plain = "×",
    };
}

pub const folder = Indicator{
    .emoji = "📂",
    .colored = "\x1B[2m⌂\x1B[m",
    .plain = "⌂",
};

/// A status value from a config `status` rule: a two-string tuple
/// `[primary, degraded]` where `primary` is the emoji (2 cols) and `degraded`
/// is the single-character form.
pub const StatusValue = [2][]const u8;

/// Choose which string of a config status value to display, based on the
/// environment. Returns a newly-allocated slice (owned by `allocator`) when
/// NO_COLOR is set (the color codes are stripped); otherwise it returns one of
/// the input strings as-is (caller must not free it in that case).
pub fn extractStatus(allocator: Allocator, status: ?StatusValue, env: Env) !?[]const u8 {
    if (status == null) return null;
    const s = status.?;
    if (env.no_color) return try ansi.removeGraphicRenditions(allocator, s[1]);
    if (!env.supports_emoji) return s[1];
    return s[0];
}

test "pick selects by environment" {
    const emoji_env = Env{ .no_color = false, .supports_emoji = true };
    const color_env = Env{ .no_color = false, .supports_emoji = false };
    const plain_env = Env{ .no_color = true, .supports_emoji = true };
    try std.testing.expectEqualStrings("🟢", pick(running, emoji_env));
    try std.testing.expectEqualStrings("\x1B[92m●\x1B[m", pick(running, color_env));
    try std.testing.expectEqualStrings("›", pick(running, plain_env));
}

test "exitIndicator: 0 and 130 are clean, others are failures" {
    const emoji_env = Env{ .no_color = false, .supports_emoji = true };
    try std.testing.expectEqualStrings("⚪", pick(exitIndicator(0), emoji_env));
    try std.testing.expectEqualStrings("⚪", pick(exitIndicator(130), emoji_env));
    try std.testing.expectEqualStrings("🔴", pick(exitIndicator(1), emoji_env));
    const plain_env = Env{ .no_color = true, .supports_emoji = true };
    try std.testing.expectEqualStrings("●", pick(exitIndicator(0), plain_env));
    try std.testing.expectEqualStrings("×", pick(exitIndicator(1), plain_env));
}

test "extractStatus: null, emoji, color, no_color" {
    const allocator = std.testing.allocator;
    const value: StatusValue = .{ "🚀", "\x1B[94mR\x1B[m" };

    // null -> null
    const null_result = try extractStatus(allocator, null, .{ .no_color = false, .supports_emoji = true });
    try std.testing.expect(null_result == null);

    // emoji-capable -> first string (borrowed)
    const emoji = (try extractStatus(allocator, value, .{ .no_color = false, .supports_emoji = true })).?;
    try std.testing.expectEqualStrings("🚀", emoji);

    // no emoji -> second string (borrowed)
    const color = (try extractStatus(allocator, value, .{ .no_color = false, .supports_emoji = false })).?;
    try std.testing.expectEqualStrings("\x1B[94mR\x1B[m", color);

    // NO_COLOR -> second string with color stripped (owned)
    const plain = (try extractStatus(allocator, value, .{ .no_color = true, .supports_emoji = true })).?;
    defer allocator.free(plain);
    try std.testing.expectEqualStrings("R", plain);
}
