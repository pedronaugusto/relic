//! What a project that depends on relic writes: the three modules, over
//! every package relic takes. The entry points that reach a remote take a
//! `transport.Means`; relic_net's network is the one put in it; relic_lfs
//! takes relic's own repository, and its server is uplink's handler.
const relic = @import("relic");
const relic_lfs = @import("relic_lfs");
const relic_net = @import("relic_net");

pub fn main() void {
    _ = &relic.transport.clone.clone;
    _ = &relic.transport.fetch.fetch;
    _ = &relic.transport.push.push;
    _ = &relic.transport.Session.open;
    _ = &relic.transport.http_settings.resolve;
    // A named remote's settings (its `remote.<name>.proxy`) through the same entry point.
    const sources: relic.transport.http_settings.Sources = .{ .remote_name = "origin" };
    _ = sources;
    // The network's engines, reached only through relic_net.
    const means: relic.transport.Means = .{ .programs = null, .network = &relic_net.network };
    _ = means;
    if (@hasDecl(relic.transport.smart_http, "connect")) @compileError("relic.transport.smart_http publishes its engine");
    if (@hasDecl(relic.transport, "http_backend")) @compileError("git's http-backend is relic_net's");
    _ = &relic_net.http_backend.Backend;
    lfs();
}

/// relic_lfs's entry points, and its server.
fn lfs() void {
    _ = &relic_lfs.clone.clone;
    _ = &relic_lfs.push.push;
    _ = &relic_lfs.push.beforePush;
    _ = &relic_lfs.api.Server.open;
    _ = &relic_lfs.transfer.download;
    _ = &relic_lfs.transfer.upload;
    _ = &relic_lfs.transfer.fetch;
    _ = &relic_lfs.transfer.pull;
    _ = &relic_lfs.transfer.pushObjects;
    _ = &relic_lfs.locks.lock;
    _ = &relic_lfs.locks.unlock;
    _ = &relic_lfs.locks.unlockPath;
    _ = &relic_lfs.locks.list;
    _ = &relic_lfs.locks.verify;
    _ = &relic_lfs.filter.load;
    _ = &relic_lfs.Lfs.load;
    _ = &relic_lfs.transfer.checkoutPointers;
    _ = &relic_lfs.transfer.sweepTmp;
    _ = &relic_lfs.locks.fixWriteFlags;
    _ = &relic_lfs.locks.Table.cached;
    _ = &relic_lfs.custom.Agent.open;
    _ = &relic_lfs.hooks.Native.lfsHooks;
    _ = &relic_lfs.server.Backend;
    // What relic_lfs takes is relic's own repository: one core beneath all three.
    const takes = @typeInfo(@TypeOf(relic_lfs.filter.load)).@"fn".param_types[2].?;
    if (takes != *relic.repo.Repository) @compileError("relic_lfs takes a repository that is not relic's");
}
