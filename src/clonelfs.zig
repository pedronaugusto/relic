//! The LFS objects a clone's checkout finds missing, fetched from the
//! remote's LFS server: what git-lfs's smudge does during `git clone`.
//!
//! The server is opened only when the checkout first asks, so a clone with
//! no LFS content, or one whose filters are not git-lfs's, never looks for
//! an LFS endpoint. What it finds and how it fetches are `lfsapi.Server` and
//! `lfstransfer.Fetcher`'s, the same as a fetch's.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const repo_mod = @import("repo.zig");
const lfs = @import("lfs.zig");
const lfsapi = @import("lfsapi.zig");
const lfstransfer = @import("lfstransfer.zig");

/// A fetcher for one clone's checkout.
pub const Fetcher = struct {
    gpa: Allocator,
    io: Io,
    repo: *repo_mod.Repository,
    /// The remote the clone came from.
    remote: []const u8,
    options: lfsapi.Options,
    server: ?*lfsapi.Server = null,
    inner: ?lfstransfer.Fetcher = null,
    /// Why the server could not be opened, when it could not.
    open_error: ?anyerror = null,

    /// The `lfs.Fetcher` a checkout is handed.
    pub fn fetcher(f: *Fetcher) lfs.Fetcher {
        return .{ .context = f, .fetchFn = fetchFn };
    }

    /// The last fetch's outcome, when there was one.
    pub fn last(f: *const Fetcher) ?*const lfstransfer.Outcome {
        const inner = &(f.inner orelse return null);
        return if (inner.last) |*o| o else null;
    }

    /// Close the server, when it was opened.
    pub fn deinit(f: *Fetcher) void {
        if (f.inner) |*i| i.deinit();
        if (f.server) |s| s.close();
        f.* = undefined;
    }

    fn fetchFn(context: *anyopaque, io: Io, store: *const lfs.Store, settings: *const lfs.Settings, wanted: []const lfs.Wanted) lfs.FetchError!void {
        const f: *Fetcher = @ptrCast(@alignCast(context));
        if (f.server == null) {
            f.server = lfsapi.Server.open(f.gpa, f.io, f.repo, f.remote, f.options) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                else => {
                    f.open_error = err;
                    return error.LfsFetchFailed;
                },
            };
            f.inner = .{ .server = f.server.? };
        }
        return f.inner.?.fetcher().fetch(io, store, settings, wanted);
    }
};
