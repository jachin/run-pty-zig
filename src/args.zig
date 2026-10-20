const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const CommandDescription = types.CommandDescription;
const AutoExit = types.AutoExit;
const ParseResult = types.ParseResult;

/// Default sequence sent to a command on "kill all" (Ctrl-C).
const KILL_SEQUENCE = "\x03";

const autoExitHelp =
    \\    --auto-exit=<number>   auto exit when done, with at most <number> parallel processes
    \\    --auto-exit=auto       uses the number of logical CPU cores
    \\    --auto-exit            defaults to auto
    ;

/// Errors that can occur while parsing a JSON command-descriptions file.
pub const ParseError = error{
    InvalidJson,
    NotAnArray,
    NotAnObject,
    MissingCommand,
    CommandNotArray,
    CommandEmpty,
    CommandNotString,
    TitleNotString,
    CwdNotString,
    StatusNotObject,
    StatusValueNotArray,
    StatusTupleNotString,
    DefaultStatusNotArray,
    KillAllNotString,
    ExtraField,
    OutOfMemory,
};

/// Turn a command (argv array) into a human-readable presentation name,
/// quoting any part that contains characters outside the safe set.
pub fn commandToPresentationName(allocator: Allocator, command: []const []const u8) ![]u8 {
    var out: std.array_list.Managed(u8) = .init(allocator);
    defer out.deinit();
    for (command, 0..) |part, i| {
        if (i > 0) try out.append(' ');
        const formatted = try formatPart(allocator, part);
        defer allocator.free(formatted);
        try out.appendSlice(formatted);
    }
    return out.toOwnedSlice();
}

fn formatPart(allocator: Allocator, part: []const u8) ![]u8 {
    if (part.len == 0) return allocator.dupe(u8, "''");
    var out: std.array_list.Managed(u8) = .init(allocator);
    defer out.deinit();
    var i: usize = 0;
    while (i < part.len) {
        var j = i;
        while (j < part.len and part[j] != '\'') j += 1;
        const sub = part[i..j];
        if (sub.len > 0) {
            if (isSafeSubPart(sub)) {
                try out.appendSlice(sub);
            } else {
                try out.append('\'');
                try out.appendSlice(sub);
                try out.append('\'');
            }
        }
        if (j < part.len) {
            try out.append('\\');
            try out.append('\'');
        }
        i = j + 1;
    }
    return out.toOwnedSlice();
}

fn isSafeSubPart(sub: []const u8) bool {
    if (sub.len == 0) return false;
    for (sub) |c| {
        if (!isAllowedChar(c)) return false;
    }
    return true;
}

fn isAllowedChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or
        c == '_' or c == '.' or c == ',' or c == ':' or c == '/' or
        c == '=' or c == '@' or c == '%' or c == '+' or c == '-';
}

/// Parse a JSON command-descriptions file (an array of command objects).
pub fn parseInputFile(allocator: Allocator, content: []const u8) ParseError![]CommandDescription {
    const value = std.json.parseFromSliceLeaky(std.json.Value, allocator, content, .{}) catch
        return error.InvalidJson;
    const arr = switch (value) {
        .array => |a| a,
        else => return error.NotAnArray,
    };
    var commands: std.array_list.Managed(CommandDescription) = .init(allocator);
    defer commands.deinit();
    for (arr.items) |item| {
        try commands.append(try parseCommandDescription(allocator, item));
    }
    return commands.toOwnedSlice();
}

fn parseCommandDescription(allocator: Allocator, value: std.json.Value) ParseError!CommandDescription {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.NotAnObject,
    };

    const command_value = obj.get("command") orelse return error.MissingCommand;
    const command_arr = switch (command_value) {
        .array => |a| a,
        else => return error.CommandNotArray,
    };
    if (command_arr.items.len == 0) return error.CommandEmpty;
    var command: std.array_list.Managed([]const u8) = .init(allocator);
    defer command.deinit();
    for (command_arr.items) |c| {
        const s = switch (c) {
            .string => |s| s,
            else => return error.CommandNotString,
        };
        try command.append(s);
    }
    const command_owned = try command.toOwnedSlice();

    var title: []const u8 = undefined;
    if (obj.get("title")) |t| {
        title = switch (t) {
            .string => |s| s,
            else => return error.TitleNotString,
        };
    } else {
        title = try commandToPresentationName(allocator, command_owned);
    }

    var cwd: []const u8 = ".";
    if (obj.get("cwd")) |c| {
        cwd = switch (c) {
            .string => |s| s,
            else => return error.CwdNotString,
        };
    }

    var status: std.array_list.Managed(types.StatusRule) = .init(allocator);
    defer status.deinit();
    if (obj.get("status")) |s| {
        const status_obj = switch (s) {
            .object => |o| o,
            else => return error.StatusNotObject,
        };
        var it = status_obj.iterator();
        while (it.next()) |kv| {
            try status.append(.{
                .pattern = kv.key_ptr.*,
                .status = try parseStatusTuple(kv.value_ptr.*),
            });
        }
    }
    const status_owned = try status.toOwnedSlice();

    var default_status: ?types.StatusTuple = undefined;
    if (obj.get("defaultStatus")) |ds| {
        default_status = try parseStatusTuple(ds);
    }

    var kill_all_sequence: []const u8 = KILL_SEQUENCE;
    if (obj.get("killAllSequence")) |k| {
        kill_all_sequence = switch (k) {
            .string => |s| s,
            else => return error.KillAllNotString,
        };
    }

    const known_fields = [_][]const u8{ "command", "title", "cwd", "status", "defaultStatus", "killAllSequence" };
    {
        var it = obj.iterator();
        while (it.next()) |kv| {
            const key = kv.key_ptr.*;
            var found = false;
            for (known_fields) |k| {
                if (std.mem.eql(u8, k, key)) {
                    found = true;
                    break;
                }
            }
            if (!found) return error.ExtraField;
        }
    }

    return .{
        .command = command_owned,
        .title = title,
        .cwd = cwd,
        .status = status_owned,
        .default_status = default_status,
        .kill_all_sequence = kill_all_sequence,
    };
}

/// Parse a status value: `null` (reset) or a two-string tuple.
fn parseStatusTuple(value: std.json.Value) ParseError!?types.StatusTuple {
    return switch (value) {
        .null => null,
        .array => |a| parseStatusArray(a),
        else => error.StatusValueNotArray,
    };
}

fn parseStatusArray(arr: std.json.Array) ParseError!?types.StatusTuple {
    if (arr.items.len != 2) return error.StatusValueNotArray;
    const primary = switch (arr.items[0]) {
        .string => |s| s,
        else => return error.StatusTupleNotString,
    };
    const degraded = switch (arr.items[1]) {
        .string => |s| s,
        else => return error.StatusTupleNotString,
    };
    return .{ .primary = primary, .degraded = degraded };
}

/// Parse the command line into a `ParseResult`.
pub fn parseArgs(allocator: Allocator, args: []const []const u8) !ParseResult {
    if (args.len == 0) return .help;

    const parts = partitionArgs(args);
    var auto_exit: AutoExit = .none;

    for (parts.flags) |flag| {
        if (std.mem.eql(u8, flag, "-h") or std.mem.eql(u8, flag, "--help")) {
            return .help;
        }
        switch (parseAutoExitFlag(flag)) {
            .not_auto_exit => {
                return .{ .error_message = try formatBadFlag(allocator, flag) };
            },
            .auto => {
                const cpus = std.Thread.getCpuCount() catch 1;
                auto_exit = .{ .auto_exit = @intCast(cpus) };
            },
            .fixed => |n| {
                if (n == 0) {
                    return .{ .error_message = try allocator.dupe(u8, "--auto-exit=0 will never finish.") };
                }
                auto_exit = .{ .auto_exit = n };
            },
        }
    }

    if (parts.rest.len == 1) {
        const content = readFileContent(allocator, parts.rest[0]) catch
            return .{ .error_message = try formatFileError(allocator) };
        defer allocator.free(content);
        const commands = parseInputFile(allocator, content) catch |err|
            return .{ .error_message = try formatParseError(allocator, err) };
        return if (commands.len == 0)
            .no_commands
        else
            .{ .parsed = .{ .commands = commands, .auto_exit = auto_exit } };
    }

    const delimiter = parts.rest[0];
    var commands: std.array_list.Managed([]const []const u8) = .init(allocator);
    defer commands.deinit();
    var current: std.array_list.Managed([]const u8) = .init(allocator);
    defer current.deinit();
    for (parts.rest) |arg| {
        if (std.mem.eql(u8, arg, delimiter)) {
            if (current.items.len > 0) {
                try commands.append(try current.toOwnedSlice());
            }
        } else {
            try current.append(arg);
        }
    }
    if (current.items.len > 0) {
        try commands.append(try current.toOwnedSlice());
    }

    if (commands.items.len == 0) return .no_commands;

    var descriptions: std.array_list.Managed(CommandDescription) = .init(allocator);
    defer descriptions.deinit();
    for (commands.items) |command| {
        try descriptions.append(.{
            .title = try commandToPresentationName(allocator, command),
            .cwd = ".",
            .command = command,
            .status = &.{},
            .default_status = null,
            .kill_all_sequence = KILL_SEQUENCE,
        });
    }
    return .{ .parsed = .{ .commands = try descriptions.toOwnedSlice(), .auto_exit = auto_exit } };
}

/// Split leading flags (matching `-x` / `--x`) from the rest of the arguments.
fn partitionArgs(args: []const []const u8) struct {
    flags: []const []const u8,
    rest: []const []const u8,
} {
    var index: usize = 0;
    while (index < args.len and looksLikeFlag(args[index])) index += 1;
    return .{ .flags = args[0..index], .rest = args[index..] };
}

fn looksLikeFlag(arg: []const u8) bool {
    if (arg.len < 2 or arg[0] != '-') return false;
    if (arg[1] == '-') {
        return arg.len >= 3 and isWordChar(arg[2]);
    }
    return isWordChar(arg[1]);
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Classify an `--auto-exit` flag.
fn parseAutoExitFlag(flag: []const u8) union(enum) {
    not_auto_exit: void,
    auto: void,
    fixed: u32,
} {
    const prefix = "--auto-exit";
    if (!std.mem.startsWith(u8, flag, prefix)) return .not_auto_exit;
    const rest = flag[prefix.len..];
    if (rest.len == 0) return .auto;
    if (!std.mem.startsWith(u8, rest, "=")) return .not_auto_exit;
    const value = rest[1..];
    if (std.mem.eql(u8, value, "auto")) return .auto;
    if (value.len == 0) return .not_auto_exit;
    for (value) |c| {
        if (!std.ascii.isDigit(c)) return .not_auto_exit;
    }
    const n = std.fmt.parseInt(u32, value, 10) catch return .not_auto_exit;
    return .{ .fixed = n };
}

fn readFileContent(allocator: Allocator, path: []const u8) ![]u8 {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{}, 0) catch |err|
        return switch (err) {
            error.FileNotFound => error.FileNotFound,
            else => error.FileNotFound,
        };
    defer _ = std.c.close(fd);
    var out: std.array_list.Managed(u8) = .init(allocator);
    defer out.deinit();
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = std.posix.read(fd, &buf) catch break;
        if (n == 0) break;
        try out.appendSlice(buf[0..n]);
    }
    return out.toOwnedSlice();
}

fn formatBadFlag(allocator: Allocator, flag: []const u8) ![]u8 {
    var out: std.array_list.Managed(u8) = .init(allocator);
    defer out.deinit();
    try out.appendSlice("Bad flag: ");
    try out.appendSlice(flag);
    try out.appendSlice("\nOnly these forms are accepted:\n");
    try out.appendSlice(autoExitHelp);
    return out.toOwnedSlice();
}

fn formatFileError(allocator: Allocator) ![]u8 {
    return allocator.dupe(u8,
        \\The first argument is either the delimiter to use between commands,
        \\or the path to a JSON file that describes the commands.
        \\If you meant to use a file, make sure it exists.
        \\Otherwise, choose a delimiter like % and provide at least one command.
    );
}

fn formatParseError(allocator: Allocator, err: ParseError) ![]u8 {
    const msg = switch (err) {
        error.InvalidJson => "Invalid JSON syntax.",
        error.NotAnArray => "Expected a JSON array of command descriptions.",
        error.NotAnObject => "Each command description must be a JSON object.",
        error.MissingCommand => "Missing required field: command.",
        error.CommandNotArray => "Field 'command' must be an array of strings.",
        error.CommandEmpty => "Field 'command' must be a non-empty array.",
        error.CommandNotString => "Each element of 'command' must be a string.",
        error.TitleNotString => "Field 'title' must be a string.",
        error.CwdNotString => "Field 'cwd' must be a string.",
        error.StatusNotObject => "Field 'status' must be an object.",
        error.StatusValueNotArray => "Each 'status' value must be an array of two strings or null.",
        error.StatusTupleNotString => "Each element of a 'status' value must be a string.",
        error.DefaultStatusNotArray => "Field 'defaultStatus' must be an array of two strings or null.",
        error.KillAllNotString => "Field 'killAllSequence' must be a string.",
        error.ExtraField => "Unknown field in command description.",
        error.OutOfMemory => "Out of memory.",
    };
    return allocator.dupe(u8, msg);
}

test "commandToPresentationName" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { parts: []const []const u8, expected: []const u8 }{
        .{ .parts = &.{"node", "--run", "frontend"}, .expected = "node --run frontend" },
        .{ .parts = &.{"", }, .expected = "''" },
        .{ .parts = &.{"hello world"}, .expected = "'hello world'" },
        .{ .parts = &.{"a'b"}, .expected = "a\\'b" },
    };
    for (cases) |c| {
        const result = try commandToPresentationName(allocator, c.parts);
        defer allocator.free(result);
        try std.testing.expectEqualStrings(c.expected, result);
    }
}

test "parseArgs: no args -> help" {
    const allocator = std.testing.allocator;
    const result = try parseArgs(allocator, &.{});
    switch (result) {
        .help => {},
        else => unreachable,
    }
}

test "parseArgs: -h -> help" {
    const allocator = std.testing.allocator;
    const result = try parseArgs(allocator, &.{"-h"});
    switch (result) {
        .help => {},
        else => unreachable,
    }
}

test "parseArgs: bad flag" {
    const allocator = std.testing.allocator;
    const result = try parseArgs(allocator, &.{"--foo"});
    switch (result) {
        .error_message => |msg| {
            defer allocator.free(msg);
            try std.testing.expect(std.mem.indexOf(u8, msg, "Bad flag: --foo") != null);
        },
        else => unreachable,
    }
}

test "parseArgs: auto-exit=0 -> error" {
    const allocator = std.testing.allocator;
    const result = try parseArgs(allocator, &.{"--auto-exit=0"});
    switch (result) {
        .error_message => |msg| {
            defer allocator.free(msg);
            try std.testing.expectEqualStrings("--auto-exit=0 will never finish.", msg);
        },
        else => unreachable,
    }
}

// These tests use the page allocator: `parseInputFile` relies on
// `std.json.parseFromSliceLeaky`, which intentionally leaks the JSON strings
// (they live as long as the input), and the parsed commands own their titles
// and argv. Full ownership is exercised by the runner in a later phase.
test "parseArgs: delimiter splits commands" {
    const allocator = std.heap.page_allocator;
    const result = try parseArgs(allocator, &.{"%", "node", "--run", "frontend", "%", "make", "watch"});
    switch (result) {
        .parsed => |p| {
            try std.testing.expectEqual(@as(usize, 2), p.commands.len);
            try std.testing.expectEqualStrings("node --run frontend", p.commands[0].title);
            try std.testing.expectEqualStrings("make watch", p.commands[1].title);
            switch (p.auto_exit) {
                .none => {},
                else => unreachable,
            }
        },
        else => unreachable,
    }
}

test "parseInputFile: valid" {
    const allocator = std.heap.page_allocator;
    const json = "[{\"command\": [\"node\", \"--run\", \"frontend\"], \"title\": \"Frontend\"}]";
    const commands = try parseInputFile(allocator, json);
    try std.testing.expectEqual(@as(usize, 1), commands.len);
    try std.testing.expectEqualStrings("Frontend", commands[0].title);
    try std.testing.expectEqual(@as(usize, 3), commands[0].command.len);
}

test "parseInputFile: missing command" {
    const allocator = std.heap.page_allocator;
    const result = parseInputFile(allocator, "[{\"title\": \"x\"}]");
    if (result) |_| {
        unreachable;
    } else |err| {
        try std.testing.expect(err == ParseError.MissingCommand);
    }
}

test "parseInputFile: empty command" {
    const allocator = std.heap.page_allocator;
    const result = parseInputFile(allocator, "[{\"command\": []}]");
    if (result) |_| {
        unreachable;
    } else |err| {
        try std.testing.expect(err == ParseError.CommandEmpty);
    }
}

test "parseInputFile: extra field" {
    const allocator = std.heap.page_allocator;
    const result = parseInputFile(allocator, "[{\"command\": [\"x\"], \"bogus\": 1}]");
    if (result) |_| {
        unreachable;
    } else |err| {
        try std.testing.expect(err == ParseError.ExtraField);
    }
}

test "parseInputFile: not an array" {
    const allocator = std.heap.page_allocator;
    const result = parseInputFile(allocator, "{\"command\": [\"x\"]}");
    if (result) |_| {
        unreachable;
    } else |err| {
        try std.testing.expect(err == ParseError.NotAnArray);
    }
}

test "parseInputFile: command not an array" {
    const allocator = std.heap.page_allocator;
    const result = parseInputFile(allocator, "[{\"command\": \"echo\"}]");
    if (result) |_| {
        unreachable;
    } else |err| {
        try std.testing.expect(err == ParseError.CommandNotArray);
    }
}

test "parseInputFile: command element not a string" {
    const allocator = std.heap.page_allocator;
    const result = parseInputFile(allocator, "[{\"command\": [1, 2]}]");
    if (result) |_| {
        unreachable;
    } else |err| {
        try std.testing.expect(err == ParseError.CommandNotString);
    }
}

test "parseInputFile: title not a string" {
    const allocator = std.heap.page_allocator;
    const result = parseInputFile(allocator, "[{\"command\": [\"x\"], \"title\": 42}]");
    if (result) |_| {
        unreachable;
    } else |err| {
        try std.testing.expect(err == ParseError.TitleNotString);
    }
}

test "parseInputFile: cwd not a string" {
    const allocator = std.heap.page_allocator;
    const result = parseInputFile(allocator, "[{\"command\": [\"x\"], \"cwd\": 42}]");
    if (result) |_| {
        unreachable;
    } else |err| {
        try std.testing.expect(err == ParseError.CwdNotString);
    }
}

test "parseInputFile: status value not an array" {
    const allocator = std.heap.page_allocator;
    const result = parseInputFile(allocator, "[{\"command\": [\"x\"], \"status\": {\"Building\": \"🔨\"}}]");
    if (result) |_| {
        unreachable;
    } else |err| {
        try std.testing.expect(err == ParseError.StatusValueNotArray);
    }
}

test "parseInputFile: status tuple wrong length" {
    const allocator = std.heap.page_allocator;
    const result = parseInputFile(allocator, "[{\"command\": [\"x\"], \"status\": {\"Building\": [\"🔨\"]}}]");
    if (result) |_| {
        unreachable;
    } else |err| {
        try std.testing.expect(err == ParseError.StatusValueNotArray);
    }
}

test "parseArgs: single non-file arg returns error" {
    const allocator = std.heap.page_allocator;
    const result = parseArgs(allocator, &.{"%"});
    // A single arg that's not a valid file returns an error message.
    if (result) |r| {
        switch (r) {
            .error_message => |msg| allocator.free(msg),
            else => @panic("expected error_message"),
        }
    } else |_| {
        @panic("expected success with error_message");
    }
}

test "parseArgs: repeated delimiters with no commands" {
    const allocator = std.heap.page_allocator;
    const result = try parseArgs(allocator, &.{"%", "%", "%"});
    try std.testing.expect(result == .no_commands);
}

test "parseArgs: --auto-exit=auto" {
    const allocator = std.heap.page_allocator;
    const result = try parseArgs(allocator, &.{"--auto-exit=auto", "%", "echo", "hi"});
    switch (result) {
        .parsed => |p| {
            defer allocator.free(p.commands);
            try std.testing.expect(p.auto_exit == .auto_exit);
        },
        else => @panic("expected parsed"),
    }
}

test "parseArgs: --auto-exit=234" {
    const allocator = std.heap.page_allocator;
    const result = try parseArgs(allocator, &.{"--auto-exit=234", "%", "echo", "hi"});
    switch (result) {
        .parsed => |p| {
            defer allocator.free(p.commands);
            try std.testing.expectEqual(@as(u32, 234), p.auto_exit.auto_exit);
        },
        else => @panic("expected parsed"),
    }
}

test "parseArgs: --auto-exit=nope is an error" {
    const allocator = std.heap.page_allocator;
    const result = try parseArgs(allocator, &.{"--auto-exit=nope", "%", "echo", "hi"});
    switch (result) {
        .error_message => |msg| {
            allocator.free(msg);
        },
        else => @panic("expected error_message"),
    }
}

test "parseArgs: --auto-exit after delimiter is a command arg" {
    const allocator = std.heap.page_allocator;
    const result = try parseArgs(allocator, &.{"%", "echo", "--auto-exit=2"});
    switch (result) {
        .parsed => |p| {
            defer allocator.free(p.commands);
            try std.testing.expectEqual(@as(usize, 1), p.commands.len);
            try std.testing.expectEqualStrings("echo", p.commands[0].command[0]);
        },
        else => @panic("expected parsed"),
    }
}
