const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const fs = @import("../../fs.zig");
const reftable = @import("../reftable.zig");
/// How the stack writes and compacts. The defaults are git's, and
/// `Repository` fills them in from `reftable.*` in the configuration.
pub const Options = struct {
    /// Block size, restart interval and object index.
    write: reftable.WriteOptions = .{},
    /// Compact after every addition, by the geometric rule. git turns this
    /// off only for its own tests; it is here for a caller that compacts
    /// on its own schedule.
    auto_compact: bool = true,
    /// `reftable.geometricFactor`: how much larger each older table must be
    /// than everything after it.
    geometric_factor: u8 = 2,
    /// `reftable.lockTimeout`: how long to wait for `tables.list.lock`, with
    /// git's backoff. git waits 100 milliseconds unless told otherwise.
    lock: fs.OnContention = .{ .wait_ms = 100 },
    /// What `core.sharedRepository` asks of the permissions of the tables,
    /// the list and the directory.
    shared: fs.Shared = .umask,
};

/// Errors from reading a stack.
pub const Error = error{
    /// `tables.list` names a table that is not there, and still does after
    /// reading it again; or it could not be looked at at all.
    ReftableMissing,
    /// A line of `tables.list` that is not a table's name.
    MalformedTablesList,
} || reftable.Error || Allocator.Error || Io.Dir.ReadFileAllocError || Io.Dir.OpenError || Io.Cancelable;
