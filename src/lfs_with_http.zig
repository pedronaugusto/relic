//! relic_lfs's root with `http`: every name of `lfs.zig`, and `server`, a Git
//! LFS server on uplink's server. `lfs.zig` holds the module's documentation
//! and its table, which this root is checked against.

const base = @import("lfs.zig");

pub const filter = base.filter;
pub const clone = base.clone;
pub const netrc = base.netrc;
pub const ssh = base.ssh;
pub const hooks = base.hooks;
pub const push = base.push;
pub const locks = base.locks;
pub const transfer = base.transfer;
pub const custom = base.custom;
pub const api = base.api;
pub const settings = base.settings;
pub const spec_version = base.spec_version;
pub const accepted_versions = base.accepted_versions;
pub const pointer_size_cutoff = base.pointer_size_cutoff;
pub const empty_oid = base.empty_oid;
pub const Pointer = base.Pointer;
pub const Store = base.Store;
pub const hashOnly = base.hashOnly;
pub const configValue = base.configValue;
pub const configBool = base.configBool;
pub const configInt = base.configInt;
pub const Settings = base.Settings;
pub const FetchPattern = base.FetchPattern;
pub const Wanted = base.Wanted;
pub const FetchError = base.FetchError;
pub const Fetcher = base.Fetcher;
pub const Lfs = base.Lfs;
pub const Error = base.Error;
pub const server = @import("lfs/server.zig");

const core = @import("relic_core");

// relic_lfs's public surface keeps relic's contract (`core.contract`),
// publishes every declaration of its implementation, and is `lfs.zig`'s
// with `server` added.
comptime {
    core.contract.sameNamesBut(base, @This(), "server");
    core.contract.check(@This(), .{
        .source = @embedFile("lfs.zig"),
        .path = "src/lfs.zig",
        .readme = @embedFile("README.md"),
        .begin = "<!-- BEGIN LFS MODULES -->",
        .end = "<!-- END LFS MODULES -->",
        .depth = 2,
    });
    core.contract.covers(@This(), "relic_lfs", @import("lfs/lfs.zig"));
}
