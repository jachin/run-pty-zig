const std = @import("std");
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Escape-sequence constants (subset used by run-pty).
// ---------------------------------------------------------------------------

pub const HIDE_CURSOR = "\x1B[?25l";
pub const SHOW_CURSOR = "\x1B[?25h";
pub const ENABLE_ALTERNATE_SCREEN = "\x1B[?1049h";
pub const DISABLE_ALTERNATE_SCREEN = "\x1B[?1049l";
pub const DISABLE_BRACKETED_PASTE_MODE = "\x1B[?2004l";
pub const DISABLE_APPLICATION_CURSOR_KEYS = "\x1B[?1l";
pub const ENABLE_MOUSE = "\x1B[?1000;1006h";
pub const DISABLE_MOUSE = "\x1B[?1000;1006l";
pub const BEGIN_SYNC_UPDATE = "\x1B[?2026h";
pub const END_SYNC_UPDATE = "\x1B[?2026l";
pub const RESET_COLOR = "\x1B[m";
pub const CLEAR = "\x1B[2J\x1B[3J\x1B[H";
pub const CLEAR_LEFT = "\x1B[1K";
pub const CLEAR_RIGHT = "\x1B[K";
pub const CLEAR_DOWN = "\x1B[J";
// Save/restore cursor position _and_ graphic renditions.
pub const SAVE_CURSOR = "\x1B[s";
pub const RESTORE_CURSOR = "\x1B[u";

// ---------------------------------------------------------------------------
// SGR (Select Graphic Rendition) handling.
// ---------------------------------------------------------------------------

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// If `s[i..]` begins an SGR sequence (`ESC [ params m`), return the index just
/// past it; otherwise return null. The parameter part is optional and matches
/// `\d+(?:;\d+)*`, mirroring the original `GRAPHIC_RENDITIONS` regex.
fn findSgrEnd(s: []const u8, i: usize) ?usize {
    if (i + 1 >= s.len or s[i] != 0x1B or s[i + 1] != '[') return null;
    var j = i + 2;
    if (j < s.len and isDigit(s[j])) {
        while (j < s.len and isDigit(s[j])) j += 1;
        while (j < s.len and s[j] == ';') {
            j += 1;
            if (j < s.len and isDigit(s[j])) {
                while (j < s.len and isDigit(s[j])) j += 1;
            } else break;
        }
    }
    if (j < s.len and s[j] == 'm') return j + 1;
    return null;
}

/// Remove all SGR (color/style) escape sequences from `s`, keeping the text.
/// The result is a newly-allocated slice owned by `allocator`.
pub fn removeGraphicRenditions(allocator: Allocator, s: []const u8) ![]u8 {
    var out: std.array_list.Managed(u8) = .init(allocator);
    defer out.deinit();
    var i: usize = 0;
    while (i < s.len) {
        if (findSgrEnd(s, i)) |end| {
            i = end;
            continue;
        }
        try out.append(s[i]);
        i += 1;
    }
    return out.toOwnedSlice();
}

/// Truncate `s` to at most `max_length` *visible* characters. SGR codes are
/// preserved (they don't count toward the length). If the visible content
/// exceeds `max_length`, it is cut to `max_length - 1` visible chars and a
/// `…` is appended (so the total visible width is `max_length`). The result is
/// a newly-allocated slice owned by `allocator`.
pub fn truncate(allocator: Allocator, s: []const u8, max_length: usize) ![]u8 {
    // Count visible characters (everything that is not part of an SGR code).
    var visible: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (findSgrEnd(s, i)) |end| {
            i = end;
        } else {
            visible += 1;
            i += 1;
        }
    }
    if (visible <= max_length) return allocator.dupe(u8, s);
    if (max_length == 0) return allocator.dupe(u8, "…");

    var out: std.array_list.Managed(u8) = .init(allocator);
    defer out.deinit();
    var length: usize = 0;
    i = 0;
    while (i < s.len) {
        if (findSgrEnd(s, i)) |end| {
            try out.appendSlice(s[i..end]);
            i = end;
            continue;
        }
        if (length >= max_length - 1) break;
        try out.append(s[i]);
        length += 1;
        i += 1;
    }
    try out.appendSlice("…");
    return out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Unfinished-escape detection.
// ---------------------------------------------------------------------------

/// The trailing part of a chunk of PTY output may be a partial escape sequence
/// (split across reads). We must not print anything in the middle of it, or the
/// escape breaks and parts of it leak out as text. This returns the split point:
/// `finished` is safe to print, `unfinished` is a trailing partial escape that
/// should be buffered for the next chunk.
///
/// Mirrors the original `UNFINISHED_ESCAPE` regex:
///   `\x1B(?:\[[0-?]*[ -/]*|\][^\x1B\x07]*)?$`
pub const Split = struct {
    finished: []const u8,
    unfinished: []const u8,
};

pub fn splitUnfinishedEscape(s: []const u8) Split {
    // Find the last ESC byte.
    var i = s.len;
    while (i > 0) {
        i -= 1;
        if (s[i] == 0x1B) break;
    }
    if (i >= s.len) return .{ .finished = s, .unfinished = "" };
    const tail = s[i..];
    if (tail.len == 1) {
        // A lone ESC at the end.
        return .{ .finished = s[0..i], .unfinished = tail };
    }
    switch (tail[1]) {
        '[' => {
            // CSI: complete only if it has a final byte (0x40..0x7E).
            for (tail[2..]) |b| {
                if (b >= 0x40 and b <= 0x7E) return .{ .finished = s, .unfinished = "" };
            }
            return .{ .finished = s[0..i], .unfinished = tail };
        },
        ']' => {
            // OSC: complete only if it ends with BEL (0x07) or ST (ESC \).
            // Since this is the last ESC, only a trailing BEL can terminate it.
            if (tail[tail.len - 1] == 0x07) return .{ .finished = s, .unfinished = "" };
            return .{ .finished = s[0..i], .unfinished = tail };
        },
        else => {
            // A two-byte FES (ESC + final byte) is complete.
            return .{ .finished = s, .unfinished = "" };
        },
    }
}

test "removeGraphicRenditions strips SGR, keeps text" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "hello", .expected = "hello" },
        .{ .input = "\x1B[31mred\x1B[m", .expected = "red" },
        .{ .input = "\x1B[1;32mgreen\x1B[0m", .expected = "green" },
        .{ .input = "\x1B[m", .expected = "" },
        .{ .input = "a\x1B[4mb\x1B[0mc", .expected = "abc" },
        .{ .input = "\x1B[31m", .expected = "" },
    };
    for (cases) |c| {
        const result = try removeGraphicRenditions(allocator, c.input);
        defer allocator.free(result);
        try std.testing.expectEqualStrings(c.expected, result);
    }
}

test "removeGraphicRenditions keeps non-SGR escapes" {
    const allocator = std.testing.allocator;
    // A cursor-move escape (H) is not an SGR and must be kept.
    const result = try removeGraphicRenditions(allocator, "\x1B[2J\x1B[31mhi\x1B[m");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("\x1B[2Jhi", result);
}

test "truncate keeps everything when it fits" {
    const allocator = std.testing.allocator;
    const result = try truncate(allocator, "hello", 10);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

test "truncate cuts and appends ellipsis" {
    const allocator = std.testing.allocator;
    const result = try truncate(allocator, "hello", 3);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("he…", result);
}

test "truncate counts only visible chars, preserves SGR" {
    const allocator = std.testing.allocator;
    // 5 visible chars ("hello"), max 3 -> "he…", with the leading color kept.
    const result = try truncate(allocator, "\x1B[31mhello\x1B[m", 3);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("\x1B[31mhe…", result);
}

test "truncate zero width" {
    const allocator = std.testing.allocator;
    const result = try truncate(allocator, "abc", 0);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("…", result);
}

test "splitUnfinishedEscape: no escape" {
    const r = splitUnfinishedEscape("hello");
    try std.testing.expectEqualStrings("hello", r.finished);
    try std.testing.expectEqualStrings("", r.unfinished);
}

test "splitUnfinishedEscape: lone ESC" {
    const r = splitUnfinishedEscape("hello\x1B");
    try std.testing.expectEqualStrings("hello", r.finished);
    try std.testing.expectEqualStrings("\x1B", r.unfinished);
}

test "splitUnfinishedEscape: partial CSI" {
    const r = splitUnfinishedEscape("hi\x1B[1;3");
    try std.testing.expectEqualStrings("hi", r.finished);
    try std.testing.expectEqualStrings("\x1B[1;3", r.unfinished);
}

test "splitUnfinishedEscape: complete CSI is not split" {
    const r = splitUnfinishedEscape("hi\x1B[1;32m");
    try std.testing.expectEqualStrings("hi\x1B[1;32m", r.finished);
    try std.testing.expectEqualStrings("", r.unfinished);
}

test "splitUnfinishedEscape: partial OSC" {
    const r = splitUnfinishedEscape("hi\x1B]0;titl");
    try std.testing.expectEqualStrings("hi", r.finished);
    try std.testing.expectEqualStrings("\x1B]0;titl", r.unfinished);
}

test "splitUnfinishedEscape: complete OSC (BEL) is not split" {
    const r = splitUnfinishedEscape("hi\x1B]0;title\x07");
    try std.testing.expectEqualStrings("hi\x1B]0;title\x07", r.finished);
    try std.testing.expectEqualStrings("", r.unfinished);
}

test "splitUnfinishedEscape: complete FES is not split" {
    const r = splitUnfinishedEscape("hi\x1B7");
    try std.testing.expectEqualStrings("hi\x1B7", r.finished);
    try std.testing.expectEqualStrings("", r.unfinished);
}
