//! `check-offline`, for `relic_lfs`: a program over relic and relic_lfs,
//! every public declaration referenced, compiled with cloak replaced by
//! `poison.zig`. It compiles only while nothing but relic_net reaches Git
//! LFS's HTTP client. `server`, a handler for uplink's server, and
//! `api.engine`, relic_net's, are the names left out: a program that names
//! either has chosen uplink.
const relic = @import("relic");
const relic_lfs = @import("relic_lfs");
const refs = @import("offline_refs.zig");

comptime {
    refs.all(relic, &.{});
    refs.all(relic_lfs, &.{ "server", "engine" });
    // The remote entry points that are a type's methods.
    _ = &relic_lfs.api.Server.open;
    _ = &relic_lfs.api.Client.send;
    _ = &relic_lfs.api.Client.api;
    _ = &relic_lfs.api.Exchange.reader;
    _ = &relic_lfs.api.Exchange.deinit;
}
