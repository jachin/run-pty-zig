const std = @import("std");

/// A status indicator is a pair of strings:
/// - `primary`: drawn in 2 character slots (emoji or colored).
/// - `degraded`: drawn in 1 character slot (used for NO_COLOR / Windows).
pub const StatusTuple = struct {
    primary: []const u8,
    degraded: []const u8,
};

/// Maps a pattern found in a command's output to a status indicator.
/// `status == null` means "reset to the default running indicator".
pub const StatusRule = struct {
    pattern: []const u8,
    status: ?StatusTuple,
};

/// A fully-resolved description of one command to run.
pub const CommandDescription = struct {
    command: []const []const u8,
    title: []const u8,
    cwd: []const u8,
    status: []StatusRule,
    default_status: ?StatusTuple,
    kill_all_sequence: []const u8,
};

/// Whether the tool should auto-exit once all commands have finished.
pub const AutoExit = union(enum) {
    none: void,
    /// Maximum number of commands to run in parallel.
    auto_exit: u32,
};

/// The result of parsing the command line.
pub const ParseResult = union(enum) {
    help: void,
    no_commands: void,
    error_message: []const u8,
    parsed: struct {
        commands: []CommandDescription,
        auto_exit: AutoExit,
    },
};
