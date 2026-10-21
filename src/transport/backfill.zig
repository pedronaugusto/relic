//! `git backfill`: the blobs a partial clone was promised, fetched in
//! batches by the path that reaches them.
//!
//! It is git 2.55's `builtin/backfill.c`. The blobs come from a path walk
//! (`rev_walk.path_walk`) over the history of `HEAD`, or of the commits
//! given less the history of the ones excluded, with the trees of the
//! excluded commits at the range's edge too unless `include_edges` is
//! off. Each path's blobs that the repository lacks join the batch, and
//! once the batch holds `min_batch_size` or more it is asked of the
//! promisor remote in one request (`partial.Lazy.fetch`); what is left
//! at the end is asked last. A request so carries every version of a file
//! at once, which the server can send as deltas of each other.
//!
//! With sparse checkout on, or `sparse` asked for, only the paths the
//! sparse-checkout patterns take in are walked: in cone mode the
//! directories outside the cone are passed by. A pathspec limits the
//! commits and the paths as `git rev-list -- <paths>` does, and a
//! `sparse:oid=` filter limits the paths to its cone.

const ErrorNamespace = @This();
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const repo_mod = @import("../repo/repo.zig");
const pathspec = @import("../patterns.zig").pathspec;
const sparse = @import("../patterns.zig").sparse;
const filter_spec = @import("../wire.zig").filter_spec;
const path_walk = @import("../rev_walk/path_walk.zig");
const rev_parse = @import("../rev_walk/rev_parse.zig");
const sparse_checkout = @import("../worktree/sparse_checkout.zig");
const partial = @import("partial.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

/// Errors from a backfill.
pub const Error = error{
    /// Sparse checkout asked for with no `info/sparse-checkout`: git's
    /// "problem loading sparse-checkout".
    NoSparseCheckout,
    /// A `blob:limit=` filter: "cannot backfill with blob size limits".
    BlobSizeLimit,
} || path_walk.Error || partial.Error || sparse.Error || sparse_checkout.Error;

/// Which history's blobs.
pub const Inputs = struct {
    /// The commits walked from; `HEAD` when empty, and nothing for an
    /// unborn `HEAD`.
    include: []const []const u8 = &.{},
    /// `^<rev>`: commits whose history is left out.
    exclude: []const []const u8 = &.{},
    /// `-- <paths>`.
    paths: ?*const pathspec.Pathspec = null,
};

/// How the blobs are walked and asked for.
pub const Options = struct {
    /// `--min-batch-size`: a batch is asked for once it holds this many.
    min_batch_size: usize = 50000,
    /// `--sparse` or `--no-sparse`; `null` takes `core.sparseCheckout`.
    sparse: ?bool = null,
    /// `--no-include-edges` turns it off.
    include_edges: bool = true,
    /// `--first-parent`.
    first_parent: bool = false,
    /// `--filter=<spec>`: see `path_walk.Options.filter`.
    filter: ?[]const u8 = null,
    /// What the promisor remote is asked with.
    lazy: partial.Lazy.Options = .{},
};

/// What was asked for.
pub const Outcome = struct {
    /// Requests made, each batch's and any a tree the repository lacked
    /// needed on the way.
    fetches: u32,
    /// Objects asked for.
    objects: u32,
};

pub fn backfill(gpa: Allocator, io: Io, repo: *Repository, inputs: Inputs, options: Options) Self.Error!Outcome {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    if (options.filter) |text| switch (try filter_spec.parse(a, text)) {
        .blob_limit => |limit| if (limit.raw() != 0) return error.BlobSizeLimit,
        else => {},
    };

    var patterns: ?sparse.Patterns = null;
    defer if (patterns) |*p| p.deinit();
    const settings = try sparse_checkout.settings(io, repo);
    if (options.sparse orelse settings.enabled) {
        patterns = try sparse.Patterns.load(gpa, io, repo.gitDirectory(), .{
            .case_fold = try repo.configuration().getBool("core.ignorecase", false),
            .cone = settings.cone,
        }) orelse return error.NoSparseCheckout;
    }

    var include: std.ArrayList(Oid) = .empty;
    for (inputs.include) |name| try include.append(a, try commitOf(a, io, repo, name));
    if (inputs.include.len == 0) {
        if (commitOf(a, io, repo, "HEAD")) |head| {
            try include.append(a, head);
        } else |err| switch (err) {
            error.OutOfMemory, error.Canceled => |e| return e,
            else => {},
        }
    }
    const exclude = try a.alloc(Oid, inputs.exclude.len);
    for (inputs.exclude, exclude) |name, *oid| oid.* = try commitOf(a, io, repo, name);

    var lazy = partial.Lazy.init(gpa, repo, options.lazy);
    defer lazy.deinit();
    // A tree the clone was not given is fetched where the walk needs it.
    lazy.install();
    var pw = try path_walk.PathWalk.init(gpa, io, repo, .{ .include = include.items, .exclude = exclude }, .{
        .commits = false,
        .trees = false,
        .paths = inputs.paths,
        .first_parent = options.first_parent,
        .edges = options.include_edges,
        .sparse = if (patterns) |*p| p else null,
        .sparse_trees = true,
        .filter = options.filter,
    });
    defer pw.deinit();

    const db = repo.objectDatabase();
    var batch: std.ArrayList(Oid) = .empty;
    defer batch.deinit(gpa);
    while (try pw.next(io)) |found| {
        if (found.kind != .blob) continue;
        for (found.oids) |oid| {
            if (!try db.exists(io, oid)) try batch.append(gpa, oid);
        }
        if (batch.items.len >= options.min_batch_size) try download(io, &lazy, &batch);
    }
    try download(io, &lazy, &batch);
    return .{ .fetches = lazy.fetches, .objects = lazy.objects };
}

fn commitOf(a: Allocator, io: Io, repo: *Repository, name: []const u8) rev_parse.Error!Oid {
    return rev_parse.resolve(a, io, repo, try a.print("{s}^{{commit}}", .{name}));
}

/// One request for the batch; what it brings is then looked at again,
/// so no object is asked for twice.
fn download(io: Io, lazy: *partial.Lazy, batch: *std.ArrayList(Oid)) ErrorNamespace.Error!void {
    if (batch.items.len == 0) return;
    try lazy.fetch(io, batch.items);
    try lazy.repo.objectDatabase().refresh(io);
    batch.clearRetainingCapacity();
}
