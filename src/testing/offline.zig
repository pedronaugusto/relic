//! `check-offline`, for `relic`: a program over relic alone, every public
//! declaration referenced, compiled with uplink and cloak replaced by
//! `poison.zig`. It compiles only while nothing but relic_net reaches the
//! network's engines.
const relic = @import("relic");
const refs = @import("offline_refs.zig");

comptime {
    refs.all(relic, &.{});
    // The remote entry points that are a type's methods.
    _ = &relic.transport.Session.open;
    _ = &relic.transport.Session.fetch;
    _ = &relic.transport.Session.push;
    _ = &relic.transport.partial.Lazy.init;
    _ = &relic.transport.partial.Lazy.fetch;
}
