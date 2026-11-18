//! relic_net — the network relic reaches remotes over: HTTP and HTTPS,
//! git's daemon over TCP, and Git LFS's HTTP API, over uplink and cloak.
//!
//! The `relic_net` module of the relic package. relic's core reaches the
//! network only through the `transport.Means` an operation is given;
//! `network` is the `transport.Network` to put in one:
//!
//!     .means = .{ .programs = programs, .network = &relic_net.network },
//!
//! A program that never names this module compiles neither uplink nor
//! cloak, and an `http(s)` remote is `error.HttpUnavailable` to it. Git's
//! smart HTTP served on uplink's server, `http_backend`, is here too.
//!
//! The table below describes its namespaces; it is checked against the
//! API, and the README's against both, wherever relic_net compiles.
//!
//! | Module | Purpose |
//! |---|---|
//! | `http_backend` | `Backend` — git's smart HTTP served on uplink's server: clone, fetch and push over `http://`. |

const core = @import("relic_core");
const lfs = @import("relic_lfs");

/// The network relic's engines make: smart and dumb HTTP over uplink's
/// client, with cloak's certificates, keys and trust; a TCP dial to a git
/// daemon; Git LFS's batch, transfer and locking requests.
pub const network: core.transport.Network = core.wire.engines.network(lfs.api.engine());

pub const http_backend = core.http_backend;

// relic_net's public surface keeps relic's contract (`core.contract`).
comptime {
    core.contract.check(@This(), .{
        .source = @embedFile("net.zig"),
        .path = "src/net.zig",
        .readme = @embedFile("README.md"),
        .begin = "<!-- BEGIN NET MODULES -->",
        .end = "<!-- END NET MODULES -->",
        .depth = 1,
    });
}
