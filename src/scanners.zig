//! Hand-rolled scanners for the escape sequences the original matches with
//! regular expressions (Zig 0.17 has no regex engine).
//!
//! These are intentionally conservative approximations: they catch the common
//! cases (screen clears, cursor moves, alternate-screen toggles) that drive
//! history management, without reproducing every permutation the original's
//! `CLEAR_REGEX`/`NOT_SIMPLE_LOG_ESCAPE` generate.
const std = @import("std");

/// The alternate-screen enable/disable sequences.
pub const ENABLE_ALTERNATE_SCREEN = "\x1B[?1049h";
pub const DISABLE_ALTERNATE_SCREEN = "\x1B[?1049l";

/// A piece of output after splitting on the alternate-screen sequences.
pub const Part = union(enum) {
    /// A regular chunk of output (no alt-screen toggle).
    text: []const u8,
    /// The alternate screen was enabled.
    enable: void,
    /// The alternate screen was disabled.
    disable: void,
};

/// True when `s` contains a sequence that clears the screen (and therefore
/// should reset the captured history). Matches the common clear patterns:
/// clear-screen (`2J`), clear-scrollback (`3J`), clear-down (`0J`), and
/// cursor-to-top-left (`0f`/`1f`/`0H`/`1H` and their `;0`/`;1` variants).
pub fn matchesClear(s: []const u8) bool {
    const patterns = [_][]const u8{
        "\x1B[2J", // clear screen
        "\x1B[3J", // clear scrollback
        "\x1B[0J", // clear down
        "\x1B[0f", "\x1B[1f", "\x1B[0;0f", "\x1B[1;0f",
        "\x1B[0H", "\x1B[1H", "\x1B[0;0H", "\x1B[1;0H",
    };
    for (patterns) |p| {
        if (contains(s, p)) return true;
    }
    return false;
}

/// True when `s` contains an escape that makes the log "not simple" (i.e. the
/// output uses cursor moves / clears that can't be replayed as a plain log).
/// Matches the common cases from the original's `NOT_SIMPLE_LOG_ESCAPE`:
/// clear-down (`0?J`), cursor moves (`F`/`L`/`M`/`S`/`T`/`u`/`s`), and cursor
/// up (`<n>A`) that isn't a simple `\n`+`1A` pair.
pub fn isNotSimpleLog(s: []const u8) bool {
    // Clear-down: \x1B[0J or \x1B[J.
    if (contains(s, "\x1B[0J") or contains(s, "\x1B[J")) return true;
    // Cursor moves that rewrite previous lines.
    const moves = [_][]const u8{
        "\x1B[F", "\x1B[L", "\x1B[M", "\x1B[S", "\x1B[T", "\x1B[u", "\x1B[s",
    };
    for (moves) |m| {
        if (contains(s, m)) return true;
    }
    // Cursor up: \x1B[<n>A where <n> is a positive number.
    var i: usize = 0;
    while (i + 3 < s.len) : (i += 1) {
        if (s[i] == '\x1B' and s[i + 1] == '[') {
            var j = i + 2;
            var has_digit = false;
            while (j < s.len and s[j] >= '0' and s[j] <= '9') : (j += 1) {
                has_digit = true;
            }
            if (has_digit and j < s.len and s[j] == 'A') return true;
        }
    }
    return false;
}

/// Split `s` on the alternate-screen enable/disable sequences. Returns a list
/// of `Part` values; `text` parts borrow from `s`.
pub fn splitAlternateScreen(s: []const u8, allocator: std.mem.Allocator) ![]Part {
    var parts = std.array_list.Managed(Part).init(allocator);
    errdefer parts.deinit();

    var start: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (startsWith(s[i..], ENABLE_ALTERNATE_SCREEN)) {
            if (i > start) parts.append(.{ .text = s[start..i] }) catch @panic("oom");
            parts.append(.{ .enable = {} }) catch @panic("oom");
            i += ENABLE_ALTERNATE_SCREEN.len - 1;
            start = i + 1;
        } else if (startsWith(s[i..], DISABLE_ALTERNATE_SCREEN)) {
            if (i > start) parts.append(.{ .text = s[start..i] }) catch @panic("oom");
            parts.append(.{ .disable = {} }) catch @panic("oom");
            i += DISABLE_ALTERNATE_SCREEN.len - 1;
            start = i + 1;
        }
    }
    if (start < s.len) parts.append(.{ .text = s[start..] }) catch @panic("oom");
    return parts.toOwnedSlice() catch @panic("oom");
}

/// Check if `s` is a terminal query that needs a fake response.
/// Only matches specific escape sequences, not arbitrary text ending in "t".
pub fn isTerminalQuery(s: []const u8) bool {
    // Cursor position request: \x1B[6n
    if (endsWith(s, "\x1B[6n")) return true;
    // Window size / state queries: \x1B[<digits>t (e.g. \x1B[0t, \x1B[13t, \x1B[21t)
    if (startsWith(s, "\x1B[") and endsWith(s, "t") and s.len > 3) return true;
    // OSC queries: \x1B]10;?, \x1B]11;?, \x1B]4;N;?
    if (startsWith(s, "\x1B]10;") or startsWith(s, "\x1B]11;") or startsWith(s, "\x1B]4;")) return true;
    return false;
}

/// Build a fake response to a terminal query so programs don't get stuck when
/// stdin is not a TTY (non-interactive mode). Mirrors the original's
/// `respondToRequestFake`.
pub fn respondToRequestFake(allocator: std.mem.Allocator, request: []const u8) ![]const u8 {
    if (endsWith(request, "\x1B[6n")) return "\x1B[1;1R";
    if (startsWith(request, "\x1B[") and endsWith(request, "t") and request.len > 3) {
        return "\x1B[3;0;0t";
    }
    if (startsWith(request, "\x1B]10;") or startsWith(request, "\x1B]4;")) {
        return try replaceFirst(allocator, request, "?", "rgb:ffff/ffff/ffff");
    }
    if (startsWith(request, "\x1B]11;")) {
        return try replaceFirst(allocator, request, "?", "rgb:0000/0000/0000");
    }
    return "";
}

fn replaceFirst(allocator: std.mem.Allocator, s: []const u8, from: []const u8, to: []const u8) ![]const u8 {
    const idx = containsIndex(s, from) orelse return allocator.dupe(u8, s);
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    try out.appendSlice(s[0..idx]);
    try out.appendSlice(to);
    try out.appendSlice(s[idx + from.len..]);
    return out.toOwnedSlice();
}

fn containsIndex(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.mem.eql(u8, haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn endsWith(s: []const u8, suffix: []const u8) bool {
    if (s.len < suffix.len) return false;
    return std.mem.eql(u8, s[s.len - suffix.len ..], suffix);
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.mem.eql(u8, haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn startsWith(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    return std.mem.eql(u8, s[0..prefix.len], prefix);
}

test "matchesClear" {
    try std.testing.expect(matchesClear("\x1B[2J"));
    try std.testing.expect(matchesClear("\x1B[3J"));
    try std.testing.expect(matchesClear("\x1B[0J"));
    try std.testing.expect(matchesClear("foo\x1B[0fbar"));
    try std.testing.expect(!matchesClear("hello world"));
    try std.testing.expect(!matchesClear("\x1B[0m"));
}

test "isNotSimpleLog" {
    try std.testing.expect(isNotSimpleLog("\x1B[0J"));
    try std.testing.expect(isNotSimpleLog("\x1B[2A"));
    try std.testing.expect(isNotSimpleLog("\x1B[F"));
    try std.testing.expect(!isNotSimpleLog("plain text\nmore text"));
    try std.testing.expect(!isNotSimpleLog("\x1B[0m"));
}

test "respondToRequestFake" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqualStrings("\x1B[1;1R", respondToRequestFake(allocator, "\x1B[6n") catch unreachable);
    try std.testing.expectEqualStrings("\x1B[3;0;0t", respondToRequestFake(allocator, "\x1B[21t") catch unreachable);
    const fg = respondToRequestFake(allocator, "\x1B]10;?\x07") catch unreachable;
    defer allocator.free(fg);
    try std.testing.expectEqualStrings("\x1B]10;rgb:ffff/ffff/ffff\x07", fg);
    const bg = respondToRequestFake(allocator, "\x1B]11;?\x07") catch unreachable;
    defer allocator.free(bg);
    try std.testing.expectEqualStrings("\x1B]11;rgb:0000/0000/0000\x07", bg);
    const pal = respondToRequestFake(allocator, "\x1B]4;0;?\x07") catch unreachable;
    defer allocator.free(pal);
    try std.testing.expectEqualStrings("\x1B]4;0;rgb:ffff/ffff/ffff\x07", pal);
    const unknown = respondToRequestFake(allocator, "\x1B]99;?\x07") catch unreachable;
    defer allocator.free(unknown);
    try std.testing.expectEqualStrings("", unknown);
}

test "isTerminalQuery: matches real queries" {
    try std.testing.expect(isTerminalQuery("\x1B[6n"));
    try std.testing.expect(isTerminalQuery("\x1B[0t"));
    try std.testing.expect(isTerminalQuery("\x1B[13t"));
    try std.testing.expect(isTerminalQuery("\x1B[21t"));
    try std.testing.expect(isTerminalQuery("\x1B]10;?\x07"));
    try std.testing.expect(isTerminalQuery("\x1B]11;?\x07"));
    try std.testing.expect(isTerminalQuery("\x1B]4;0;?\x07"));
}

test "isTerminalQuery: does not match plain text" {
    try std.testing.expect(!isTerminalQuery("result"));
    try std.testing.expect(!isTerminalQuery("output"));
    try std.testing.expect(!isTerminalQuery("input"));
    try std.testing.expect(!isTerminalQuery("hello world"));
    try std.testing.expect(!isTerminalQuery("t"));
    try std.testing.expect(!isTerminalQuery(""));
}

test "splitAlternateScreen" {
    const allocator = std.testing.allocator;
    const parts = try splitAlternateScreen("a\x1B[?1049hb\x1B[?1049lc", allocator);
    defer allocator.free(parts);
    try std.testing.expectEqual(@as(usize, 5), parts.len);
    try std.testing.expectEqualStrings("a", parts[0].text);
    try std.testing.expect(switch (parts[1]) {
        .enable => true,
        else => false,
    });
    try std.testing.expectEqualStrings("b", parts[2].text);
    try std.testing.expect(switch (parts[3]) {
        .disable => true,
        else => false,
    });
    try std.testing.expectEqualStrings("c", parts[4].text);
}
