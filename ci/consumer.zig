//! What a project that depends on relic with `.http = false` writes. Built by
//! `bay check-consumer` with conduit, sweep, parallax, airlock and warp, and
//! aegis and reactor beneath them, to fetch, and none of uplink, cloak and
//! strand: every entry point that may speak HTTP still compiles, and an HTTP
//! remote is `error.HttpUnavailable`.
const relic = @import("relic");

pub fn main() void {
    _ = &relic.transport.clone.clone;
    _ = &relic.transport.fetch.fetch;
    _ = &relic.transport.push.push;
    _ = &relic.lfs.clone.clone;
    _ = &relic.lfs.push.push;
    _ = &relic.lfs.push.beforePush;
    _ = &relic.lfs.api.Server.open;
    _ = &relic.lfs.transfer.download;
    _ = &relic.lfs.transfer.upload;
    _ = &relic.lfs.transfer.fetch;
    _ = &relic.lfs.transfer.pull;
    _ = &relic.lfs.transfer.pushObjects;
    _ = &relic.lfs.locks.lock;
    _ = &relic.lfs.locks.unlock;
    _ = &relic.lfs.locks.unlockPath;
    _ = &relic.lfs.locks.list;
    _ = &relic.lfs.locks.verify;
    _ = &relic.lfs.filter.load;
    _ = &relic.lfs.Lfs.load;
    _ = &relic.lfs.transfer.checkoutPointers;
    _ = &relic.lfs.transfer.sweepTmp;
    _ = &relic.lfs.locks.fixWriteFlags;
    _ = &relic.lfs.locks.Table.cached;
    _ = &relic.lfs.custom.Agent.open;
    _ = &relic.lfs.hooks.Native.lfsHooks;
    _ = &relic.transport.smarthttp.connect;
    _ = &relic.transport.httpsettings.resolve;
    _ = &relic.transport.httpsettings.resolveForRemote;
}
