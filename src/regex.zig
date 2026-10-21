const std = @import("std");
const Allocator = std.mem.Allocator;

/// A compiled regular expression supporting a practical subset of ECMAScript
/// regex: literals, `.`, `*`, `+`, `?`, `|`, `()`, `[]` (with ranges),
/// `\d`, `\w`, `\s`, `\D`, `\W`, `\S`, `^`, `$`, and `\\` escapes.
/// Matching is done via recursive backtracking.
pub const Regex = struct {
    allocator: Allocator,
    nodes: []Node,

    pub const Error = error{
        UnbalancedGroup,
        UnbalancedClass,
        InvalidEscape,
        OutOfMemory,
    };

    pub fn compile(allocator: Allocator, pattern: []const u8) Error!Regex {
        var parser = Parser{ .allocator = allocator, .src = pattern, .pos = 0 };
        var nodes = std.array_list.Managed(Node).init(allocator);
        errdefer {
            for (nodes.items) |*n| n.free(allocator);
            nodes.deinit();
        }
        try parser.parseAlternation(&nodes);
        return .{ .allocator = allocator, .nodes = try nodes.toOwnedSlice() };
    }

    pub fn deinit(self: *Regex) void {
        for (self.nodes) |*n| n.free(self.allocator);
        self.allocator.free(self.nodes);
    }

    /// Search mode: the pattern can match anywhere in the string (like JS
    /// `RegExp.test`).
    pub fn matches(self: *const Regex, haystack: []const u8) bool {
        for (0..haystack.len) |start| {
            if (matchNodes(self.nodes, haystack, start, 0)) return true;
        }
        return false;
    }

    /// Full match: the entire string must be consumed.
    pub fn matchesFull(self: *const Regex, haystack: []const u8) bool {
        const result = matchNodesLen(self.nodes, haystack, 0);
        return result != null and result.? == haystack.len;
    }
};

const Node = struct {
    kind: Kind,
    byte: u8 = 0,
    class_lo: u128 = 0,
    class_negated: bool = false,
    children: []Node = &.{},
    branches: [][]Node = &.{},
    min: u32 = 0,
    max: u32 = 10000,

    const Kind = enum {
        literal,
        any,
        char_class,
        group,
        alt,
        quantified,
        start_anchor,
        end_anchor,
    };

    fn containsClass(self: Node, b: u8) bool {
        const in_set = if (b < 128) ((self.class_lo >> @as(u7, @intCast(b))) & 1) != 0 else true;
        return if (self.class_negated) !in_set else in_set;
    }

    fn free(self: *Node, allocator: Allocator) void {
        if (self.children.len > 0) {
            for (self.children) |*c| c.free(allocator);
            allocator.free(self.children);
        }
        if (self.branches.len > 0) {
            for (self.branches) |branch| {
                for (branch) |*c| c.free(allocator);
                allocator.free(branch);
            }
            allocator.free(self.branches);
        }
    }
};

fn matchNodes(nodes: []Node, haystack: []const u8, haystack_pos: usize, node_pos: usize) bool {
    _ = node_pos;
    return matchFrom(nodes, haystack, haystack_pos, 0, haystack_pos) != null;
}

fn matchNodesLen(nodes: []Node, haystack: []const u8, start: usize) ?usize {
    return matchFrom(nodes, haystack, start, 0, start);
}

fn matchFrom(nodes: []Node, haystack: []const u8, pos_in: usize, np_in: usize, start: usize) ?usize {
    var np = np_in;
    var pos = pos_in;
    while (np < nodes.len) {
        const node = nodes[np];
        switch (node.kind) {
            .start_anchor => {
                if (pos != 0) return null;
                np += 1;
            },
            .end_anchor => {
                if (pos != haystack.len) return null;
                np += 1;
            },
            .literal => {
                if (pos >= haystack.len or haystack[pos] != node.byte) return null;
                pos += 1;
                np += 1;
            },
            .any => {
                if (pos >= haystack.len) return null;
                if (haystack[pos] == '\n') return null;
                pos += 1;
                np += 1;
            },
            .char_class => {
                if (pos >= haystack.len) return null;
                if (!node.containsClass(haystack[pos])) return null;
                pos += 1;
                np += 1;
            },
            .group => {
                const r = matchFrom(node.children, haystack, pos, 0, pos);
                if (r == null) return null;
                pos += r.?;
                np += 1;
            },
            .alt => {
                var found: ?usize = null;
                for (node.branches) |branch| {
                    const r = matchFrom(branch, haystack, pos, 0, pos);
                    if (r != null) {
                        found = r;
                        break;
                    }
                }
                if (found == null) return null;
                pos += found.?;
                np += 1;
            },
            .quantified => {
                var count: u32 = node.max;
                var matched: ?usize = null;
                while (true) : (count = if (count == 0) 0 else count - 1) {
                    var qpos = pos;
                    var ok = true;
                    var i: u32 = 0;
                    while (i < count) : (i += 1) {
                        const r = matchFrom(node.children, haystack, qpos, 0, qpos);
                        if (r == null) {
                            ok = false;
                            break;
                        }
                        if (r.? == 0) {
                            if (i > 0) break;
                        }
                        qpos += r.?;
                    }
                    if (ok and count >= node.min) {
                        const rest = matchFrom(nodes, haystack, qpos, np + 1, start);
                        if (rest != null) {
                            matched = (qpos - pos) + rest.?;
                            break;
                        }
                    }
                    if (count == 0) break;
                }
                if (matched == null) return null;
                return matched;
            },
        }
    }
    return pos - start;
}

const Parser = struct {
    allocator: Allocator,
    src: []const u8,
    pos: usize,

    fn parseAlternation(self: *Parser, out: *std.array_list.Managed(Node)) Regex.Error!void {
        var branches: std.array_list.Managed([]Node) = .init(self.allocator);
        errdefer {
            for (branches.items) |b| {
                for (b) |*n| n.free(self.allocator);
                self.allocator.free(b);
            }
            branches.deinit();
        }

        var branch: std.array_list.Managed(Node) = .init(self.allocator);
        errdefer {
            for (branch.items) |*n| n.free(self.allocator);
            branch.deinit();
        }
        try self.parseSequence(&branch);

        while (self.pos < self.src.len and self.src[self.pos] == '|') {
            self.pos += 1;
            try branches.append(try branch.toOwnedSlice());
            branch = std.array_list.Managed(Node).init(self.allocator);
            try self.parseSequence(&branch);
        }

        if (branches.items.len == 0) {
            branches.deinit();
            defer branch.deinit();
            try out.appendSlice(branch.items);
        } else {
            try branches.append(try branch.toOwnedSlice());
            const alt_node = Node{ .kind = .alt, .branches = try branches.toOwnedSlice() };
            try out.append(alt_node);
        }
    }

    fn parseSequence(self: *Parser, out: *std.array_list.Managed(Node)) Regex.Error!void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == '|' or c == ')') break;
            try self.parseQuantifiedTerm(out);
        }
    }

    fn parseQuantifiedTerm(self: *Parser, out: *std.array_list.Managed(Node)) Regex.Error!void {
        var atom: std.array_list.Managed(Node) = .init(self.allocator);
        errdefer {
            for (atom.items) |*n| n.free(self.allocator);
            atom.deinit();
        }
        try self.parseAtom(&atom);

        if (self.pos < self.src.len) {
            const q = self.src[self.pos];
            if (q == '*' or q == '+' or q == '?') {
                self.pos += 1;
                var min: u32 = 0;
                var max: u32 = 10000;
                if (q == '*') {
                    min = 0;
                } else if (q == '+') {
                    min = 1;
                } else {
                    min = 0;
                    max = 1;
                }
                const child_nodes = try atom.toOwnedSlice();
                const quant_node = Node{
                    .kind = .quantified,
                    .children = child_nodes,
                    .min = min,
                    .max = max,
                };
                try out.append(quant_node);
                return;
            }
        }

        defer atom.deinit();
        try out.appendSlice(atom.items);
    }

    fn parseAtom(self: *Parser, out: *std.array_list.Managed(Node)) Regex.Error!void {
        if (self.pos >= self.src.len) return;
        const c = self.src[self.pos];

        if (c == '(') {
            self.pos += 1;
            if (self.pos < self.src.len and self.src[self.pos] == '?') {
                if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == ':') {
                    self.pos += 2;
                }
            }
            var group: std.array_list.Managed(Node) = .init(self.allocator);
            errdefer {
                for (group.items) |*n| n.free(self.allocator);
                group.deinit();
            }
            try self.parseAlternation(&group);
            if (self.pos >= self.src.len or self.src[self.pos] != ')')
                return Regex.Error.UnbalancedGroup;
            self.pos += 1;
            const group_nodes = try group.toOwnedSlice();
            try out.append(Node{ .kind = .group, .children = group_nodes });
            return;
        }

        if (c == '[') {
            self.pos += 1;
            var class_lo: u128 = 0;
            var negated = false;
            if (self.pos < self.src.len and self.src[self.pos] == '^') {
                negated = true;
                self.pos += 1;
            }
            var first = true;
            while (self.pos < self.src.len) {
                if (self.src[self.pos] == ']' and !first) break;
                first = false;
                const lo_byte = self.parseClassChar();
                if (self.pos < self.src.len and self.src[self.pos] == '-' and
                    self.pos + 1 < self.src.len and self.src[self.pos + 1] != ']')
                {
                    self.pos += 1;
                    const hi_byte = self.parseClassChar();
                    var b: u8 = lo_byte;
                    while (b <= hi_byte) : (b += 1) {
                        if (b < 128) class_lo |= @as(u128, 1) << @intCast(b);
                    }
                } else {
                    if (lo_byte < 128) class_lo |= @as(u128, 1) << @intCast(lo_byte);
                }
            }
            if (self.pos >= self.src.len) return Regex.Error.UnbalancedClass;
            self.pos += 1;
            try out.append(Node{
                .kind = .char_class,
                .class_lo = class_lo,
                .class_negated = negated,
            });
            return;
        }

        if (c == '\\') {
            self.pos += 1;
            if (self.pos >= self.src.len) return Regex.Error.InvalidEscape;
            const esc = self.src[self.pos];
            self.pos += 1;
            switch (esc) {
                'd' => {
                    var lo: u128 = 0;
                    for ('0'..'9' + 1) |b| lo |= @as(u128, 1) << @intCast(b);
                    try out.append(Node{ .kind = .char_class, .class_lo = lo });
                },
                'D' => {
                    var lo: u128 = 0;
                    for ('0'..'9' + 1) |b| lo |= @as(u128, 1) << @intCast(b);
                    try out.append(Node{ .kind = .char_class, .class_lo = lo, .class_negated = true });
                },
                'w' => {
                    var lo: u128 = 0;
                    for ('0'..'9' + 1) |b| lo |= @as(u128, 1) << @intCast(b);
                    for ('a'..'z' + 1) |b| lo |= @as(u128, 1) << @intCast(b);
                    for ('A'..'Z' + 1) |b| lo |= @as(u128, 1) << @intCast(b);
                    lo |= @as(u128, 1) << '_';
                    try out.append(Node{ .kind = .char_class, .class_lo = lo });
                },
                'W' => {
                    var lo: u128 = 0;
                    for ('0'..'9' + 1) |b| lo |= @as(u128, 1) << @intCast(b);
                    for ('a'..'z' + 1) |b| lo |= @as(u128, 1) << @intCast(b);
                    for ('A'..'Z' + 1) |b| lo |= @as(u128, 1) << @intCast(b);
                    lo |= @as(u128, 1) << '_';
                    try out.append(Node{ .kind = .char_class, .class_lo = lo, .class_negated = true });
                },
                's' => {
                    var lo: u128 = 0;
                    lo |= @as(u128, 1) << ' ';
                    lo |= @as(u128, 1) << '\t';
                    lo |= @as(u128, 1) << '\n';
                    lo |= @as(u128, 1) << '\r';
                    lo |= @as(u128, 1) << 0x0C;
                    try out.append(Node{ .kind = .char_class, .class_lo = lo });
                },
                'S' => {
                    var lo: u128 = 0;
                    lo |= @as(u128, 1) << ' ';
                    lo |= @as(u128, 1) << '\t';
                    lo |= @as(u128, 1) << '\n';
                    lo |= @as(u128, 1) << '\r';
                    lo |= @as(u128, 1) << 0x0C;
                    try out.append(Node{ .kind = .char_class, .class_lo = lo, .class_negated = true });
                },
                else => {
                    try out.append(Node{ .kind = .literal, .byte = esc });
                },
            }
            return;
        }

        if (c == '.') {
            self.pos += 1;
            try out.append(Node{ .kind = .any });
            return;
        }

        if (c == '^') {
            self.pos += 1;
            try out.append(Node{ .kind = .start_anchor });
            return;
        }

        if (c == '$') {
            self.pos += 1;
            try out.append(Node{ .kind = .end_anchor });
            return;
        }

        self.pos += 1;
        try out.append(Node{ .kind = .literal, .byte = c });
    }

    fn parseClassChar(self: *Parser) u8 {
        if (self.pos >= self.src.len) return 0;
        const c = self.src[self.pos];
        self.pos += 1;
        if (c == '\\') {
            if (self.pos >= self.src.len) return 0;
            const esc = self.src[self.pos];
            self.pos += 1;
            return esc;
        }
        return c;
    }
};

test "literal match" {
    var re = try Regex.compile(std.testing.allocator, "hello");
    defer re.deinit();
    try std.testing.expect(re.matches("say hello world"));
    try std.testing.expect(re.matches("hello"));
    try std.testing.expect(!re.matches("hey"));
}

test "dot matches any" {
    var re = try Regex.compile(std.testing.allocator, "h.llo");
    defer re.deinit();
    try std.testing.expect(re.matches("hello"));
    try std.testing.expect(re.matches("hxllo"));
    try std.testing.expect(!re.matches("hllo"));
}

test "alternation" {
    var re = try Regex.compile(std.testing.allocator, "error|warning");
    defer re.deinit();
    try std.testing.expect(re.matches("an error occurred"));
    try std.testing.expect(re.matches("a warning was issued"));
    try std.testing.expect(!re.matches("all good"));
}

test "quantifier star" {
    var re = try Regex.compile(std.testing.allocator, "ab*c");
    defer re.deinit();
    try std.testing.expect(re.matches("ac"));
    try std.testing.expect(re.matches("abc"));
    try std.testing.expect(re.matches("abbc"));
    try std.testing.expect(re.matches("abbbc"));
    try std.testing.expect(!re.matches("abdd"));
}

test "quantifier plus" {
    var re = try Regex.compile(std.testing.allocator, "a+b");
    defer re.deinit();
    try std.testing.expect(re.matches("ab"));
    try std.testing.expect(re.matches("aab"));
    try std.testing.expect(re.matches("aaab"));
    try std.testing.expect(!re.matches("b"));
}

test "quantifier question" {
    var re = try Regex.compile(std.testing.allocator, "colou?r");
    defer re.deinit();
    try std.testing.expect(re.matches("color"));
    try std.testing.expect(re.matches("colour"));
    try std.testing.expect(!re.matches("xyz"));
}

test "character class" {
    var re = try Regex.compile(std.testing.allocator, "[a-z]+");
    defer re.deinit();
    try std.testing.expect(re.matches("hello"));
    try std.testing.expect(!re.matches("12345"));
}

test "shorthand d" {
    var re = try Regex.compile(std.testing.allocator, "\\d+");
    defer re.deinit();
    try std.testing.expect(re.matches("12345"));
    try std.testing.expect(re.matches("abc123"));
    try std.testing.expect(re.matches("9"));
    try std.testing.expect(!re.matches("abc"));

    var not_d = try Regex.compile(std.testing.allocator, "^\\D+$");
    defer not_d.deinit();
    try std.testing.expect(not_d.matches("abc"));
    try std.testing.expect(!not_d.matches("9"));
}

test "shorthand w" {
    var re = try Regex.compile(std.testing.allocator, "\\w+");
    defer re.deinit();
    try std.testing.expect(re.matches("hello_world"));
    try std.testing.expect(re.matches("hello world"));
    try std.testing.expect(re.matches("9"));
    try std.testing.expect(re.matches("z"));
    try std.testing.expect(re.matches("Z"));
    try std.testing.expect(!re.matches("   "));

    var not_w = try Regex.compile(std.testing.allocator, "^\\W+$");
    defer not_w.deinit();
    try std.testing.expect(not_w.matches(" -!"));
    try std.testing.expect(!not_w.matches("9"));
    try std.testing.expect(!not_w.matches("z"));
    try std.testing.expect(!not_w.matches("Z"));
}

test "shorthand s" {
    var re = try Regex.compile(std.testing.allocator, "\\s+");
    defer re.deinit();
    try std.testing.expect(re.matches("hello world"));
    try std.testing.expect(!re.matches("helloworld"));
}

test "group with alternation" {
    var re = try Regex.compile(std.testing.allocator, "Build (succeeded|failed)");
    defer re.deinit();
    try std.testing.expect(re.matches("Build succeeded in 3s"));
    try std.testing.expect(re.matches("Build failed"));
    try std.testing.expect(!re.matches("Build cancelled"));
}

test "anchor start" {
    var re = try Regex.compile(std.testing.allocator, "^ERROR");
    defer re.deinit();
    try std.testing.expect(re.matches("ERROR: something"));
    try std.testing.expect(!re.matches("  ERROR: something"));
}

test "anchor end" {
    var re = try Regex.compile(std.testing.allocator, "done\\.$");
    defer re.deinit();
    try std.testing.expect(re.matches("all done."));
    try std.testing.expect(!re.matches("all done!"));
}

test "escaped literal" {
    var re = try Regex.compile(std.testing.allocator, "a\\.b");
    defer re.deinit();
    try std.testing.expect(re.matches("a.b"));
    try std.testing.expect(!re.matches("axb"));
}

test "complex pattern" {
    var re = try Regex.compile(std.testing.allocator, "(error|warning|fatal).*\\d+");
    defer re.deinit();
    try std.testing.expect(re.matches("error: 3 tests failed"));
    try std.testing.expect(re.matches("warning 12"));
    try std.testing.expect(!re.matches("info: all good"));
}

test "negated class" {
    var re = try Regex.compile(std.testing.allocator, "[^0-9]+");
    defer re.deinit();
    try std.testing.expect(re.matches("hello"));
    try std.testing.expect(!re.matches("12345"));
}

test "regex pattern that was previously matched literally" {
    var re = try Regex.compile(std.testing.allocator, "error.*|fatal.*");
    defer re.deinit();
    try std.testing.expect(re.matches("error: something went wrong"));
    try std.testing.expect(re.matches("fatal crash"));
    try std.testing.expect(!re.matches("warning: minor issue"));
}
