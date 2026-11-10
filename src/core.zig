//! relic's core: every file but the public roots, `src/relic.zig` and
//! `src/lfs.zig`, and LFS's own under `src/lfs/`. Not an API: the build makes
//! it with `createModule`, under no name a consumer can import, and the
//! `relic` and `relic_lfs` modules are built over the one instance of it, so
//! what each hands out is the same type. This is a plain list of its
//! namespaces, for those two roots to reach them by; nothing here imports
//! either root.

// The namespaces `relic` publishes, each a facade over its implementation.
pub const repo = @import("repo.zig");
pub const hash = @import("hash.zig");
pub const object = @import("object.zig");
pub const odb = @import("odb.zig");
pub const refs = @import("refs.zig");
pub const config = @import("config.zig");
pub const index = @import("index.zig");
pub const worktree = @import("worktree.zig");
pub const diff = @import("diff.zig");
pub const rev_walk = @import("rev_walk.zig");
pub const merge = @import("merge.zig");
pub const commit = @import("commit.zig");
pub const transport = @import("transport.zig");
pub const submodule = @import("submodule.zig");
pub const patch = @import("patch.zig");
pub const grep = @import("grep.zig");
pub const archive = @import("archive.zig");
pub const pretty = @import("pretty.zig");
pub const clean = @import("clean.zig");
pub const fast = @import("fast.zig");
pub const maintenance = @import("maintenance.zig");

// The concerns beneath them, which no public name reaches.
pub const checkout = @import("checkout.zig");
pub const codec = @import("codec.zig");
pub const discover = @import("discover.zig");
pub const fs = @import("fs.zig");
pub const hooks = @import("hooks/hooks.zig");
pub const mail = @import("mail.zig");
pub const names = @import("names.zig");
pub const patterns = @import("patterns.zig");
pub const process = @import("process.zig");
pub const report = @import("report.zig");
pub const stage = @import("stage.zig");
pub const text = @import("text.zig");
pub const walk = @import("walk.zig");
pub const wire = @import("wire.zig");
/// git's smart HTTP served on uplink's server. It names uplink's types, so
/// it is reached only where `relic_options.http` holds.
pub const http_backend = @import("transport/http_backend.zig");

/// The contract a public root keeps: its module table, the README's, and
/// the conventions of every namespace it publishes.
pub const contract = @import("contract.zig");

// A facade publishes every declaration of its implementation, as the
// implementation's type.
comptime {
    for (.{
        .{ repo, "repo", @import("repo/repo.zig") },
        .{ hash, "hash", @import("hash/hash.zig") },
        .{ object, "object", @import("object/object.zig") },
        .{ odb, "odb", @import("odb/odb.zig") },
        .{ refs, "refs", @import("refs/refs.zig") },
        .{ config, "config", @import("config/config.zig") },
        .{ index, "index", @import("index/index.zig") },
        .{ worktree, "worktree", @import("checkout/checkout.zig") },
        .{ diff, "diff", @import("diff/diff.zig") },
        .{ rev_walk, "rev_walk", @import("walk/walk.zig") },
        .{ merge, "merge", @import("merge/merge.zig") },
        .{ commit, "commit", @import("commit/commit.zig") },
        .{ transport, "transport", @import("transport/transport.zig") },
        .{ submodule, "submodule", @import("submodule/submodule.zig") },
        .{ patch, "patch", @import("patch/patch.zig") },
        .{ pretty, "pretty", @import("pretty/pretty.zig") },
        .{ maintenance, "maintenance", @import("maintenance/maintenance.zig") },
    }) |facade| contract.covers(facade[0], facade[1], facade[2]);
}
