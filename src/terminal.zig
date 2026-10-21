//! Terminal detection and capability negotiation.
//!
//! Detects the terminal type from environment variables and provides
//! capability flags that the renderer can use to adapt its output.
const std = @import("std");

/// Color capability level.
pub const ColorLevel = enum {
    none,
    /// 8 basic colors (ANSI 30-37, 40-47).
    basic,
    /// 256 colors (ANSI 38;5;n, 48;5;n).
    twenty_five_six,
    /// 24-bit truecolor (ANSI 38;2;r;g;b, 48;2;r;g;b).
    truecolor,
};

/// Terminal capabilities, determined at startup.
pub const Capabilities = struct {
    /// The terminal type string (from $TERM), or "unknown".
    term: []const u8,
    /// The terminal program name (from $TERM_PROGRAM), or null.
    term_program: ?[]const u8,
    /// Color support level.
    color: ColorLevel,
    /// Whether the terminal supports Unicode (wide chars, emoji).
    unicode: bool,
    /// Whether the terminal supports synchronized output (mode 2026).
    sync_update: bool,
    /// Whether the terminal supports the alternate screen buffer.
    alt_screen: bool,
    /// Whether the terminal supports SGR mouse mode (1006).
    sgr_mouse: bool,
    /// Whether the terminal supports bracketed paste (2004).
    bracketed_paste: bool,
    /// Whether the terminal supports truecolor (redundant with color == .truecolor,
    /// but kept for clarity in rendering code).
    truecolor: bool,
    /// Whether the terminal supports 24-bit color in the background erase.
    bce: bool,
    /// Whether NO_COLOR is set (user explicitly requested no color).
    no_color: bool,

    /// Detect capabilities from the current environment.
    pub fn detect() Capabilities {
        const term = std.c.getenv("TERM") orelse "unknown";
        const term_slice = std.mem.sliceTo(term, 0);
        const term_program = std.c.getenv("TERM_PROGRAM");
        const term_program_slice = if (term_program) |tp| std.mem.sliceTo(tp, 0) else null;
        const colorterm = std.c.getenv("COLORTERM");
        const colorterm_slice = if (colorterm) |ct| std.mem.sliceTo(ct, 0) else null;
        const no_color = std.c.getenv("NO_COLOR");
        const no_color_set = if (no_color) |nc| nc[0] != 0 else false;

        const color = detectColor(term_slice, colorterm_slice, no_color_set);
        const unicode = detectUnicode(term_slice);
        const modern = isModernTerminal(term_slice, term_program_slice);

        return .{
            .term = term_slice,
            .term_program = term_program_slice,
            .color = color,
            .unicode = unicode,
            .sync_update = modern,
            .alt_screen = true,
            .sgr_mouse = modern,
            .bracketed_paste = modern,
            .truecolor = color == .truecolor,
            .bce = color != .none,
            .no_color = no_color_set,
        };
    }

    /// Detect color level from environment.
    pub fn detectColor(term: []const u8, colorterm: ?[]const u8, no_color: bool) ColorLevel {
        if (no_color) return .none;
        if (colorterm) |ct| {
            if (std.mem.eql(u8, ct, "truecolor") or std.mem.eql(u8, ct, "24bit")) {
                return .truecolor;
            }
        }
        if (std.mem.indexOf(u8, term, "256color") != null) return .twenty_five_six;
        if (std.mem.eql(u8, term, "dumb")) return .none;
        if (std.mem.indexOf(u8, term, "color") != null) return .basic;
        // Most modern terminals support at least 256 colors by default.
        return .twenty_five_six;
    }

    /// Detect Unicode support.
    pub fn detectUnicode(term: []const u8) bool {
        if (std.mem.eql(u8, term, "dumb")) return false;
        if (std.mem.indexOf(u8, term, "vt100") != null) return false;
        return true;
    }

    /// Whether this is a "modern" terminal that supports advanced features
    /// (sync update, SGR mouse, bracketed paste).
    pub fn isModernTerminal(term: []const u8, term_program: ?[]const u8) bool {
        if (term_program) |tp| {
            const modern_programs = [_][]const u8{
                "WezTerm", "ghostty", "kitty", "alacritty",
                "iTerm.app", "Hyper", "WarpTerminal", "rio",
            };
            for (modern_programs) |p| {
                if (std.mem.indexOf(u8, tp, p) != null) return true;
            }
        }
        const modern_terms = [_][]const u8{
            "alacritty", "kitty", "wezterm", "ghostty",
            "st-256color", "xterm-256color", "iterm2",
            "contour", "rio", "foot",
        };
        for (modern_terms) |t| {
            if (std.mem.indexOf(u8, term, t) != null) return true;
        }
        return false;
    }
};

/// A terminal "profile" that the renderer uses to decide which sequences to emit.
pub const Profile = struct {
    caps: Capabilities,

    pub fn init(caps: Capabilities) Profile {
        return .{ .caps = caps };
    }

    /// Whether to use synchronized update sequences.
    pub fn useSyncUpdate(self: Profile) bool {
        return self.caps.sync_update;
    }

    /// Whether to use SGR mouse mode (vs X10 mode).
    pub fn useSgrMouse(self: Profile) bool {
        return self.caps.sgr_mouse;
    }

    /// Whether to use bracketed paste.
    pub fn useBracketedPaste(self: Profile) bool {
        return self.caps.bracketed_paste;
    }
};

/// Convert RGB to a 256-color palette index.
/// Uses the 6x6x6 cube (16-231) for most colors, and the grayscale ramp
/// (232-255) only for intermediate grays that don't map well to the cube.
pub fn rgbTo256(r: u8, g: u8, b: u8) u8 {
    // Grayscale ramp: only for intermediate grays (not pure black/white
    // which are better represented by the cube).
    if (r == g and g == b and r > 4 and r < 248) {
        return @intCast(232 + (r - 8 + 5) / 10);
    }
    // Map to the 6x6x6 cube (16-231).
    const cr = cubeComponent(r);
    const cg = cubeComponent(g);
    const cb = cubeComponent(b);
    return @intCast(16 + 36 * cr + 6 * cg + cb);
}

fn cubeComponent(v: u8) u8 {
    if (v == 0) return 0;
    if (v < 48) return 0;
    if (v < 115) return 1;
    if (v < 170) return 2;
    if (v < 220) return 3;
    if (v < 242) return 4;
    return 5;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "detectColor: NO_COLOR disables" {
    try std.testing.expectEqual(@as(ColorLevel, .none), Capabilities.detectColor("xterm-256color", "truecolor", true));
}

test "detectColor: COLORTERM=truecolor" {
    try std.testing.expectEqual(@as(ColorLevel, .truecolor), Capabilities.detectColor("xterm-256color", "truecolor", false));
}

test "detectColor: COLORTERM=24bit" {
    try std.testing.expectEqual(@as(ColorLevel, .truecolor), Capabilities.detectColor("alacritty", "24bit", false));
}

test "detectColor: TERM has 256color" {
    try std.testing.expectEqual(@as(ColorLevel, .twenty_five_six), Capabilities.detectColor("xterm-256color", null, false));
}

test "detectColor: TERM=dumb" {
    try std.testing.expectEqual(@as(ColorLevel, .none), Capabilities.detectColor("dumb", null, false));
}

test "detectColor: TERM has color but not 256color" {
    try std.testing.expectEqual(@as(ColorLevel, .basic), Capabilities.detectColor("xterm-color", null, false));
}

test "detectColor: default is 256" {
    try std.testing.expectEqual(@as(ColorLevel, .twenty_five_six), Capabilities.detectColor("unknown-term", null, false));
}

test "detectUnicode: dumb terminal" {
    try std.testing.expect(!Capabilities.detectUnicode("dumb"));
}

test "detectUnicode: vt100" {
    try std.testing.expect(!Capabilities.detectUnicode("vt100"));
}

test "detectUnicode: modern terminal" {
    try std.testing.expect(Capabilities.detectUnicode("xterm-256color"));
    try std.testing.expect(Capabilities.detectUnicode("alacritty"));
}

test "isModernTerminal: by TERM_PROGRAM" {
    try std.testing.expect(Capabilities.isModernTerminal("xterm-256color", "WezTerm"));
    try std.testing.expect(Capabilities.isModernTerminal("xterm-256color", "ghostty"));
    try std.testing.expect(Capabilities.isModernTerminal("xterm-256color", "kitty"));
    try std.testing.expect(Capabilities.isModernTerminal("xterm-256color", "iTerm.app"));
}

test "isModernTerminal: by TERM" {
    try std.testing.expect(Capabilities.isModernTerminal("alacritty", null));
    try std.testing.expect(Capabilities.isModernTerminal("kitty", null));
    try std.testing.expect(Capabilities.isModernTerminal("ghostty", null));
    try std.testing.expect(Capabilities.isModernTerminal("wezterm", null));
    try std.testing.expect(Capabilities.isModernTerminal("st-256color", null));
    try std.testing.expect(Capabilities.isModernTerminal("xterm-256color", null));
}

test "isModernTerminal: old terminal" {
    try std.testing.expect(!Capabilities.isModernTerminal("vt100", null));
    try std.testing.expect(!Capabilities.isModernTerminal("dumb", null));
    try std.testing.expect(!Capabilities.isModernTerminal("linux", null));
}

test "rgbTo256: black" {
    try std.testing.expectEqual(@as(u8, 16), rgbTo256(0, 0, 0));
}

test "rgbTo256: red" {
    try std.testing.expectEqual(@as(u8, 196), rgbTo256(255, 0, 0));
}

test "rgbTo256: green" {
    try std.testing.expectEqual(@as(u8, 46), rgbTo256(0, 255, 0));
}

test "rgbTo256: blue" {
    try std.testing.expectEqual(@as(u8, 21), rgbTo256(0, 0, 255));
}

test "rgbTo256: white" {
    try std.testing.expectEqual(@as(u8, 231), rgbTo256(255, 255, 255));
}

test "rgbTo256: grayscale ramp for intermediate grays" {
    // Intermediate gray (128,128,128) should use the grayscale ramp.
    const idx = rgbTo256(128, 128, 128);
    try std.testing.expect(idx >= 232 and idx <= 255);
    // Pure black and white use the cube (16 and 231).
    try std.testing.expectEqual(@as(u8, 16), rgbTo256(0, 0, 0));
    try std.testing.expectEqual(@as(u8, 231), rgbTo256(255, 255, 255));
}

test "Profile: useSyncUpdate follows caps" {
    const modern = Capabilities{
        .term = "alacritty",
        .term_program = null,
        .color = .truecolor,
        .unicode = true,
        .sync_update = true,
        .alt_screen = true,
        .sgr_mouse = true,
        .bracketed_paste = true,
        .truecolor = true,
        .bce = true,
        .no_color = false,
    };
    const p = Profile.init(modern);
    try std.testing.expect(p.useSyncUpdate());
    try std.testing.expect(p.useSgrMouse());
    try std.testing.expect(p.useBracketedPaste());

    const old = Capabilities{
        .term = "vt100",
        .term_program = null,
        .color = .basic,
        .unicode = false,
        .sync_update = false,
        .alt_screen = true,
        .sgr_mouse = false,
        .bracketed_paste = false,
        .truecolor = false,
        .bce = true,
        .no_color = false,
    };
    const p2 = Profile.init(old);
    try std.testing.expect(!p2.useSyncUpdate());
    try std.testing.expect(!p2.useSgrMouse());
    try std.testing.expect(!p2.useBracketedPaste());
}
