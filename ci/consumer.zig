//! What a project that depends on relic writes, in each of its four builds
//! (`.http` and `.lfs` on and off). Built by `bay check-consumer` with only
//! the packages that build fetches: every entry point that may speak HTTP
//! compiles without uplink and cloak, where an HTTP remote is
//! `error.HttpUnavailable`; `relic_lfs` is imported where `.lfs` built it;
//! and a declaration whose types a build left out is absent from it.
const relic = @import("relic");

pub fn main() void {
    _ = &relic.transport.clone.clone;
    _ = &relic.transport.fetch.fetch;
    _ = &relic.transport.push.push;
    _ = &relic.transport.smart_http.connect;
    _ = &relic.transport.http_settings.resolve;
    // A named remote's settings (its `remote.<name>.proxy`) through the same entry point.
    const sources: relic.transport.http_settings.Sources = .{ .remote_name = "origin" };
    _ = sources;
    if (relic.built_with.http) {
        _ = &relic.transport.http_backend.Backend;
        _ = &relic.transport.smart_http.Files.open;
        _ = &relic.transport.smart_http.Early.send;
    } else {
        if (@hasDecl(relic.transport, "http_backend")) @compileError("transport.http_backend without http");
        // A dumb server's files, and the requests they send, are uplink's.
        if (@hasDecl(relic.transport.smart_http, "Files")) @compileError("transport.smart_http.Files without http");
        if (@hasDecl(relic.transport.smart_http, "Early")) @compileError("transport.smart_http.Early without http");
    }
    if (relic.built_with.lfs) lfs(@import("relic_lfs"));
}

/// relic_lfs's entry points, each of which compiles without uplink and
/// cloak, and its server, which exists only with them.
fn lfs(comptime relic_lfs: type) void {
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
    // What relic_lfs takes is relic's own repository: one core beneath both.
    const takes = @typeInfo(@TypeOf(relic_lfs.filter.load)).@"fn".param_types[2].?;
    if (takes != *relic.repo.Repository) @compileError("relic_lfs takes a repository that is not relic's");
    if (relic.built_with.http) {
        _ = &relic_lfs.server.Backend;
    } else if (@hasDecl(relic_lfs, "server")) @compileError("relic_lfs.server without http");
}
