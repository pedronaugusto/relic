//! A client certificate and its key, read from the files git's settings
//! name, as curl reads them for git: `http.sslCert` holds the certificate —
//! the chain after it, in PEM — and `http.sslKey` the key, which is looked
//! for in the certificate's file when no key file is named;
//! `http.sslCertType` and `http.sslKeyType` say `PEM` or `DER`. A key
//! encrypted with a passphrase is opened with the one `credential.zig`
//! finds for it, when `http.sslCertPasswordProtected` says to ask; without
//! it, where OpenSSL would ask on the terminal, the key is refused by name.
//! The same for an `https` proxy with `http.proxySSLCert`, `http.proxySSLKey`
//! and `http.proxySSLCertPasswordProtected`.
//!
//! The files are read here; the handshake that presents them is
//! `tls/Client.zig`'s.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const tls = @import("tls/root.zig");

/// Errors from reading a certificate and its key.
pub const Error = error{
    /// `http.sslCertType` or `http.sslKeyType` names a kind relic does not
    /// read: `P12`, `ENG`, or any but `PEM` and `DER`.
    SslCertTypeUnsupported,
    /// The certificate file could not be read, or holds no certificate.
    SslClientCertificateUnreadable,
    /// The key file could not be read, or holds no key relic reads: an
    /// algorithm other than RSA, ECDSA on P-256 or P-384, and Ed25519, or
    /// an encryption other than AES-128 and AES-256 in CBC mode.
    SslClientKeyUnreadable,
    /// The key is encrypted and no passphrase was asked for: git would
    /// leave OpenSSL to ask on the terminal, which relic never does. Set
    /// `http.sslCertPasswordProtected`.
    SslClientKeyPassphraseRequired,
    /// The passphrase does not open the key.
    SslClientKeyPassphraseWrong,
    /// The key is not the certificate's.
    SslClientKeyMismatch,
} || Allocator.Error || Io.Cancelable;

/// Where the certificate and the key are, and what kind of file each is.
pub const Files = struct {
    cert: []const u8,
    /// The key's file; the certificate's when `null`.
    key: ?[]const u8 = null,
    /// `PEM` or `DER`, in any case; `PEM` when `null`.
    cert_type: ?[]const u8 = null,
    key_type: ?[]const u8 = null,
};

/// The file the key is read from.
pub fn keyPath(files: Files) []const u8 {
    return files.key orelse files.cert;
}

/// Whether the key's file holds an encrypted key; `false` when it cannot
/// be read, which `load` names.
pub fn keyIsEncrypted(arena: Allocator, io: Io, files: Files) bool {
    const bytes = readAll(arena, io, keyPath(files)) catch return false;
    return tls.key.PrivateKey.isEncrypted(bytes);
}

/// Read the certificate chain and the key, opening the key with
/// `passphrase` when it is encrypted. The key's numbers are `arena`'s; the
/// result's encoded chain is `gpa`'s, freed with `deinit`.
pub fn load(gpa: Allocator, arena: Allocator, io: Io, files: Files, passphrase: ?[]const u8) Error!tls.ClientAuth {
    const cert_der = try isDer(files.cert_type);
    const key_der = try isDer(files.key_type);
    const cert_bytes = readAll(arena, io, files.cert) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return error.SslClientCertificateUnreadable,
    };
    if (cert_der and std.mem.indexOf(u8, cert_bytes, "-----BEGIN ") != null) return error.SslClientCertificateUnreadable;
    const chain = tls.key.certificates(arena, cert_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SslClientCertificateUnreadable,
    };
    const key_bytes = if (files.key) |path| readAll(arena, io, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return error.SslClientKeyUnreadable,
    } else cert_bytes;
    if (key_der and std.mem.indexOf(u8, key_bytes, "-----BEGIN ") != null) return error.SslClientKeyUnreadable;
    const key = tls.key.PrivateKey.parse(arena, key_bytes, passphrase) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.KeyPassphraseRequired => error.SslClientKeyPassphraseRequired,
        error.KeyPassphraseWrong => error.SslClientKeyPassphraseWrong,
        error.MalformedKey, error.KeyAlgorithmUnsupported, error.KeyEncryptionUnsupported, error.CertificateMissing => error.SslClientKeyUnreadable,
    };
    return tls.ClientAuth.init(gpa, chain, key) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.KeyCertificateMismatch => error.SslClientKeyMismatch,
        error.CertificateMissing, error.CertificateChainTooLong => error.SslClientCertificateUnreadable,
    };
}

fn isDer(kind: ?[]const u8) Error!bool {
    const k = kind orelse return false;
    if (std.ascii.eqlIgnoreCase(k, "PEM")) return false;
    if (std.ascii.eqlIgnoreCase(k, "DER")) return true;
    return error.SslCertTypeUnsupported;
}

fn readAll(arena: Allocator, io: Io, path: []const u8) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20));
}

test "a certificate and key are read from one file or two, and each refusal has its name" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dir = testing.tmpDir(.{});
    defer dir.cleanup();
    const cert = @embedFile("tls/testdata/p256.cert.pem");
    const key = @embedFile("tls/testdata/p256.sec1.pem");
    try dir.dir.writeFile(io, .{ .sub_path = "cert.pem", .data = cert });
    try dir.dir.writeFile(io, .{ .sub_path = "key.pem", .data = key });
    try dir.dir.writeFile(io, .{ .sub_path = "both.pem", .data = cert ++ key });
    try dir.dir.writeFile(io, .{ .sub_path = "enc.pem", .data = @embedFile("tls/testdata/p256.enc-aes128-sha1.pem") });
    try dir.dir.writeFile(io, .{ .sub_path = "other.pem", .data = @embedFile("tls/testdata/p384.pkcs8.pem") });
    const base = try dir.dir.realPathFileAlloc(io, ".", arena);
    const at = struct {
        fn f(a: Allocator, b: []const u8, name: []const u8) []const u8 {
            return std.fs.path.join(a, &.{ b, name }) catch unreachable;
        }
    }.f;

    var two = try load(gpa, arena, io, .{ .cert = at(arena, base, "cert.pem"), .key = at(arena, base, "key.pem") }, null);
    two.deinit();
    var one = try load(gpa, arena, io, .{ .cert = at(arena, base, "both.pem") }, null);
    one.deinit();
    var opened = try load(gpa, arena, io, .{ .cert = at(arena, base, "cert.pem"), .key = at(arena, base, "enc.pem") }, "correct-horse");
    opened.deinit();
    try testing.expect(keyIsEncrypted(arena, io, .{ .cert = at(arena, base, "cert.pem"), .key = at(arena, base, "enc.pem") }));

    try testing.expectError(error.SslClientKeyPassphraseRequired, load(gpa, arena, io, .{ .cert = at(arena, base, "cert.pem"), .key = at(arena, base, "enc.pem") }, null));
    try testing.expectError(error.SslClientKeyPassphraseWrong, load(gpa, arena, io, .{ .cert = at(arena, base, "cert.pem"), .key = at(arena, base, "enc.pem") }, "nope"));
    try testing.expectError(error.SslClientKeyMismatch, load(gpa, arena, io, .{ .cert = at(arena, base, "cert.pem"), .key = at(arena, base, "other.pem") }, null));
    try testing.expectError(error.SslClientKeyUnreadable, load(gpa, arena, io, .{ .cert = at(arena, base, "cert.pem") }, null));
    try testing.expectError(error.SslClientCertificateUnreadable, load(gpa, arena, io, .{ .cert = at(arena, base, "nothere.pem") }, null));
    try testing.expectError(error.SslCertTypeUnsupported, load(gpa, arena, io, .{ .cert = at(arena, base, "both.pem"), .cert_type = "P12" }, null));
    try testing.expectError(error.SslClientCertificateUnreadable, load(gpa, arena, io, .{ .cert = at(arena, base, "both.pem"), .cert_type = "der" }, null));
}
