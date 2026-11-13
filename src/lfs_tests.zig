//! relic_lfs's tests: the module's root, files and tests, and the LFS tests
//! of what the core does with LFS supplied (a clone through git-lfs's
//! filters, a snapshot, a configuration an LFS server teaches). `tests.zig`
//! names them where relic is built with `lfs`.

const std = @import("std");
const builtin = @import("builtin");
const features = @import("relic_options");
const lfs = @import("lfs/lfs.zig");
const api_mod = @import("lfs/api.zig");
/// The module's root: `server` is in it only where `http` is on.
const root = @import("lfs.zig");

test "the plumbing is relic_lfs's own: no public name reaches it" {
    try std.testing.expect(!@hasDecl(lfs, "time_text"));
    try std.testing.expect(!@hasDecl(lfs, "mime_sniff"));
    try std.testing.expect(!@hasDecl(api_mod, "timeoutsFor"));
    try std.testing.expect(!@hasField(api_mod.Exchange, "response"));
    try std.testing.expect(!@hasField(api_mod.Exchange, "diagnostics"));
    // An exchange's network state and the client's transports are the
    // module's own types, named by no public declaration.
    try std.testing.expect(!@hasDecl(api_mod, "ExchangeState"));
    try std.testing.expect(!@hasDecl(api_mod, "TransportPool"));
}

test {
    // Every module the API reaches, one level down as well as at the top,
    // so that every file under the root is compiled and its tests run;
    // `server` only where `http` is on, a compile error elsewhere.
    inline for (@typeInfo(root).@"struct".decl_names) |name| {
        if (comptime !features.http and std.mem.eql(u8, name, "server")) continue;
        _ = &@field(root, name);
        if (@TypeOf(@field(root, name)) == type and @typeInfo(@field(root, name)) == .@"struct") std.testing.refAllDecls(@field(root, name));
    }
    if (builtin.is_test) {
        // the plumbing the module keeps to itself
        _ = @import("lfs/time_text.zig");
        _ = @import("lfs/mime_sniff.zig");
        _ = @import("lfs/settings.zig");
        _ = @import("lfs/clone.zig");
        _ = @import("lfs/filter.zig");
        _ = @import("lfs/locks.zig");
        _ = @import("lfs/transfer.zig");
        _ = @import("lfs/netrc.zig");
        _ = @import("lfs/ssh.zig");
        _ = @import("lfs/custom.zig");
        _ = @import("testing/lfs.zig");
        _ = @import("lfs/lfs_test.zig");
        _ = @import("lfs/transfer_test.zig");
        _ = @import("lfs/locks_test.zig");
        _ = @import("lfs/json_test.zig");
        _ = @import("lfs/push_test.zig");
        _ = @import("lfs/ssh_test.zig");
        _ = @import("lfs/custom_test.zig");
        _ = @import("lfs/clone_test.zig");
        _ = @import("lfs/snapshot_test.zig");
        _ = @import("lfs/clone_config_test.zig");
        _ = @import("lfs/config_refresh_test.zig");
        if (features.http) {
            _ = @import("lfs/server.zig");
            _ = @import("lfs/server/transfer.zig");
            _ = @import("lfs/server_test.zig");
            _ = @import("lfs/server/transfer_test.zig");
        }
    }
}
