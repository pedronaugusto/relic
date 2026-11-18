//! The network relic's core tests reach their servers over: relic's own
//! engines (`wire.engines`), as `relic_net.network` holds them, with no
//! Git LFS engine. relic_lfs's tests reach theirs over `testing/lfs.zig`'s
//! network, which carries relic_lfs's engine.

const network_mod = @import("../wire/network.zig");
const engines = @import("../wire/engines.zig");
const program = @import("../process.zig").program;

/// The core's tests never reach Git LFS's API.
const no_lfs: u8 = 0;

/// relic's engines, as `relic_net.network` holds them.
pub const network: network_mod.Network = engines.network(&no_lfs);

/// What a test that reaches a server over the network is given: the
/// programs it grants, and relic's network.
pub fn means(programs: ?program.Programs) network_mod.Means {
    return .{ .programs = programs, .network = &network };
}
