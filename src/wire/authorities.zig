//! The authorities a server's certificate is checked against, as curl
//! takes them from git's settings: `http.sslCAInfo` in place of the
//! system's, and `http.sslCAPath` besides whichever of the two is used. A
//! proxy's `http.proxySSLCAInfo` is a file read the same way. The trust
//! itself, the system's included, is cloak's.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const cloak = @import("cloak");

/// Errors from reading the authorities.
pub const Error = error{
    /// A file or directory the settings name, or the system's store, could
    /// not be read or holds no certificate; `Failed` says which.
    SslCertificateUnreadable,
} || Allocator.Error || Io.Cancelable;

/// Which source could not be read.
pub const Failed = enum { ca_info, system, ca_path };

/// Where the authorities are, `~` already expanded.
pub const Sources = struct {
    /// A PEM file of authorities used in place of the system's.
    ca_info: ?[]const u8 = null,
    /// A directory of PEM files whose authorities are trusted besides.
    ca_path: ?[]const u8 = null,
};

/// The authorities `sources` name, frozen into a snapshot the caller
/// releases with `deinit` once no client uses it. On
/// `error.SslCertificateUnreadable`, `failed` says which source it was.
pub fn load(gpa: Allocator, io: Io, sources: Sources, failed: *Failed) Error!cloak.Trust.Snapshot {
    var trust: cloak.Trust = .init(gpa);
    defer trust.deinit();
    if (sources.ca_info) |file| {
        trust.addFile(io, file, .{}) catch |err| return refused(err, failed, .ca_info);
    } else {
        trust.addSystem(io, .{}) catch |err| return refused(err, failed, .system);
    }
    if (sources.ca_path) |dir| trust.addDir(io, dir, .{}) catch |err| return refused(err, failed, .ca_path);
    // Nothing to freeze is a file or directory that named no authority.
    return trust.freeze() catch |err| refused(err, failed, if (sources.ca_info != null) .ca_info else .ca_path);
}

fn refused(err: anytype, failed: *Failed, source: Failed) Error {
    // Each loader's own set, widened so one place maps them all.
    const any: anyerror = err;
    if (any == error.OutOfMemory) return error.OutOfMemory;
    if (any == error.Canceled) return error.Canceled;
    failed.* = source;
    return error.SslCertificateUnreadable;
}
