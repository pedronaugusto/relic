//! The engines relic makes for a `transport.Network`: smart and dumb HTTP
//! over uplink's client (`smart_http.zig`), a TCP dial to a git daemon
//! (`daemon.zig`), and Git LFS's, which relic_lfs supplies. Nothing in the
//! core names this file: `relic_net` does, and the tests, so that only a
//! program that names relic_net compiles uplink and cloak.

const Network = @import("network.zig").Network;
const smart_http = @import("smart_http.zig");
const daemon = @import("daemon.zig");

/// The network over relic's engines, with `lfs`, relic_lfs's
/// `api.engine`, for Git LFS.
pub fn network(comptime lfs: *const anyopaque) Network {
    return .{
        .connect = smart_http.connect,
        .openFiles = smart_http.openFiles,
        .download = smart_http.download,
        .dial = daemon.dial,
        .lfs = lfs,
    };
}
