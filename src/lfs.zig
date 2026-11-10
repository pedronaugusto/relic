//! relic_lfs — Git LFS without git-lfs: pointers and the store, the native
//! filters, clone and push with LFS, transfers, locks, custom transfer agents,
//! and with `http` a server.
//!
//! The `relic_lfs` module of the relic package, built over relic's core and
//! strand. It exists only while relic's `lfs` option is on (the default), and
//! what it hands out are relic's own types: a `relic.repo.Repository` is
//! what its operations take. Over ssh and custom agents it needs `lfs` alone;
//! over HTTP(S), `http` too. The build roots it here without `http`, and at
//! `lfs_with_http.zig`, every name of this file and `server`, with it.
//!
//! The table below describes its namespaces; it is checked against the API,
//! and the README's against both, wherever relic_lfs compiles.
//!
//! | Module | Purpose |
//! |---|---|
//! | `filter` | Native LFS filters selected by an operation owner. |
//! | `clone` | Clone with native LFS checkout and downloads. |
//! | `netrc` | Module within `relic_lfs`. |
//! | `ssh` | Module within `relic_lfs`. |
//! | `hooks` | Module within `relic_lfs`. |
//! | `push` | Module within `relic_lfs`. |
//! | `locks` | Module within `relic_lfs`. |
//! | `transfer` | Module within `relic_lfs`. |
//! | `custom` | Module within `relic_lfs`. |
//! | `api` | Module within `relic_lfs`. |
//! | `settings` | git-lfs's configuration and `.lfsconfig`, read as git-lfs reads them. |
//! | `server` | Module within `relic_lfs`. Only with `http`. |

pub const filter = @import("lfs/filter.zig");
pub const clone = @import("lfs/clone.zig");
pub const netrc = @import("lfs/netrc.zig");
pub const ssh = @import("lfs/ssh.zig");
pub const hooks = @import("lfs/hooks.zig");
pub const push = @import("lfs/push.zig");
pub const locks = @import("lfs/locks.zig");
pub const transfer = @import("lfs/transfer.zig");
pub const custom = @import("lfs/custom.zig");
pub const api = @import("lfs/api.zig");
pub const settings = @import("lfs/settings.zig");
pub const spec_version = implementation.spec_version;
pub const accepted_versions = implementation.accepted_versions;
pub const pointer_size_cutoff = implementation.pointer_size_cutoff;
pub const empty_oid = implementation.empty_oid;
pub const Pointer = implementation.Pointer;
pub const Store = implementation.Store;
pub const hashOnly = implementation.hashOnly;
pub const configValue = settings.configValue;
pub const configBool = settings.configBool;
pub const configInt = settings.configInt;
pub const Settings = implementation.Settings;
pub const FetchPattern = implementation.FetchPattern;
pub const Wanted = implementation.Wanted;
pub const FetchError = implementation.FetchError;
pub const Fetcher = implementation.Fetcher;
pub const Lfs = implementation.Lfs;
pub const Error = implementation.Error;

const implementation = @import("lfs/lfs.zig");
const core = @import("relic_core");

// relic_lfs's public surface keeps relic's contract (`core.contract`), and
// publishes every declaration of its implementation. With `http` the root
// is `lfs_with_http.zig`, which checks itself.
comptime {
    if (!@import("relic_options").http) {
        core.contract.check(@This(), surface);
        core.contract.covers(@This(), "relic_lfs", implementation);
    }
}

/// relic_lfs's module tables, this file's and the README's.
const surface: core.contract.Surface = .{
    .source = @embedFile("lfs.zig"),
    .path = "src/lfs.zig",
    .readme = @embedFile("README.md"),
    .begin = "<!-- BEGIN LFS MODULES -->",
    .end = "<!-- END LFS MODULES -->",
    .depth = 2,
};
