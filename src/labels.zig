const std = @import("std");

const ALPHABET = "abcdefghijklmnopqrstuvwxyz";
const ALPHABET_UPPER = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";

/// The three label groups, in order: digits, lowercase letters, uppercase letters.
pub const LABEL_GROUPS = [_][]const u8{ "123456789", ALPHABET, ALPHABET_UPPER };

/// Every possible label, in order. Each command is assigned a label by index.
pub const ALL_LABELS = "123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";

/// Summarize the first `num_labels` labels into a compact string, e.g.
/// 1 -> "1", 2 -> "1-2", 10 -> "1-9/a", 35 -> "1-9/a-z", 61 -> "1-9/a-z/A-Z".
pub fn summarizeLabels(allocator: std.mem.Allocator, num_labels: usize) ![]u8 {
    var out: std.array_list.Managed(u8) = .init(allocator);
    defer out.deinit();
    var previous_length: usize = 0;
    var first = true;
    for (LABEL_GROUPS) |group| {
        const current_length = previous_length + group.len;
        if (num_labels > previous_length) {
            const part = if (num_labels < current_length)
                group[0 .. num_labels - previous_length]
            else
                group;
            if (!first) try out.append('/');
            first = false;
            if (part.len == 1) {
                try out.append(part[0]);
            } else {
                try out.append(part[0]);
                try out.append('-');
                try out.append(part[part.len - 1]);
            }
        }
        previous_length = current_length;
    }
    return out.toOwnedSlice();
}

test "summarizeLabels" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { n: usize, expected: []const u8 }{
        .{ .n = 1, .expected = "1" },
        .{ .n = 2, .expected = "1-2" },
        .{ .n = 9, .expected = "1-9" },
        .{ .n = 10, .expected = "1-9/a" },
        .{ .n = 35, .expected = "1-9/a-z" },
        .{ .n = 61, .expected = "1-9/a-z/A-Z" },
    };
    for (cases) |c| {
        const result = try summarizeLabels(allocator, c.n);
        defer allocator.free(result);
        try std.testing.expectEqualStrings(c.expected, result);
    }
}
