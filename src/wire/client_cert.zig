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
//! The files are read here and parsed by cloak; the handshake that presents
//! them is uplink's.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const cloak = @import("cloak");

/// Errors from reading a certificate and its key.
pub const Error = error{
    /// `http.sslCertType` or `http.sslKeyType` names a kind relic does not
    /// read: `P12`, `ENG`, or any but `PEM` and `DER`.
    SslCertTypeUnsupported,
    /// The certificate file could not be read, or holds no certificate.
    SslClientCertificateUnreadable,
    /// The key file could not be read, or holds no key relic reads: an
    /// algorithm other than RSA, ECDSA on P-256 or P-384, and Ed25519, or
    /// an encryption other than AES or triple DES in CBC mode.
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
    /// `http.sslCertType` and `http.sslKeyType`, read with `Format.parse`.
    cert_format: Format = .pem,
    key_format: Format = .pem,
};

/// The file the key is read from.
pub fn keyPath(files: Files) []const u8 {
    return files.key orelse files.cert;
}

/// Whether the key's file holds an encrypted key; `false` when it cannot
/// be read, which `load` names.
pub fn keyIsEncrypted(arena: Allocator, io: Io, files: Files) bool {
    const bytes = readAll(arena, io, keyPath(files)) catch return false;
    return cloak.PrivateKey.isEncrypted(bytes);
}

/// How `load` reads the files: `arena` holds their bytes, and `passphrase`
/// opens the key when it is encrypted.
pub const LoadOptions = struct { arena: Allocator, passphrase: ?[]const u8 = null };

/// Read the certificate chain and the key. The result is `gpa`'s, released
/// with `deinit`; the files' bytes are the arena's.
pub fn load(gpa: Allocator, io: Io, files: Files, options: LoadOptions) Self.Error!cloak.ClientAuth {
    const arena = options.arena;
    const cert_der = files.cert_format == .der;
    const key_der = files.key_format == .der;
    const cert_bytes = readAll(arena, io, files.cert) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return error.SslClientCertificateUnreadable,
    };
    if (cert_der and std.mem.find(u8, cert_bytes, "-----BEGIN ") != null) return error.SslClientCertificateUnreadable;
    const key_bytes = if (files.key) |path| readAll(arena, io, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return error.SslClientKeyUnreadable,
    } else cert_bytes;
    if (key_der and std.mem.find(u8, key_bytes, "-----BEGIN ") != null) return error.SslClientKeyUnreadable;
    // An RSA key's primes are checked with witnesses drawn from `io`.
    const key = cloak.PrivateKey.parse(gpa, key_bytes, .{ .passphrase = options.passphrase, .entropy = .fromIo(&io) }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.PasswordRequired => error.SslClientKeyPassphraseRequired,
        error.BadPassword => error.SslClientKeyPassphraseWrong,
        else => error.SslClientKeyUnreadable,
    };
    defer key.deinit();
    // A PEM certificate file may hold the key too, as curl reads it.
    const made = if (cert_der)
        cloak.ClientAuth.init(gpa, &.{cert_bytes}, key, .{})
    else
        cloak.ClientAuth.initPem(gpa, cert_bytes, key, .{ .other_blocks = .skip });
    return made catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.KeyMismatch => error.SslClientKeyMismatch,
        else => error.SslClientCertificateUnreadable,
    };
}

/// What kind of file a certificate or a key is.
pub const Format = enum {
    pem,
    der,

    /// `PEM` or `DER`, in any case, as curl reads `http.sslCertType` and
    /// `http.sslKeyType`; `null` is `PEM`. Anything else (`P12`, `ENG`) is
    /// `error.SslCertTypeUnsupported`.
    pub fn parse(text: ?[]const u8) error{SslCertTypeUnsupported}!Format {
        const k = text orelse return .pem;
        if (std.ascii.eqlIgnoreCase(k, "PEM")) return .pem;
        if (std.ascii.eqlIgnoreCase(k, "DER")) return .der;
        return error.SslCertTypeUnsupported;
    }
};

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
    const cert = @embedFile("../testing/certs/p256.cert.pem");
    const key = @embedFile("../testing/certs/p256.sec1.pem");
    try dir.dir.writeFile(io, .{ .sub_path = "cert.pem", .data = cert });
    try dir.dir.writeFile(io, .{ .sub_path = "key.pem", .data = key });
    try dir.dir.writeFile(io, .{ .sub_path = "both.pem", .data = cert ++ key });
    try dir.dir.writeFile(io, .{ .sub_path = "enc.pem", .data = @embedFile("../testing/certs/p256.enc-aes128-sha1.pem") });
    try dir.dir.writeFile(io, .{ .sub_path = "other.pem", .data = @embedFile("../testing/certs/p384.pkcs8.pem") });
    const base = try dir.dir.realPathFileAlloc(io, ".", arena);
    const at = struct {
        fn f(a: Allocator, b: []const u8, name: []const u8) []const u8 {
            return std.Io.Dir.path.join(a, &.{ b, name }) catch unreachable;
        }
    }.f;

    const two = try load(gpa, io, .{ .cert = at(arena, base, "cert.pem"), .key = at(arena, base, "key.pem") }, .{ .arena = arena });
    two.deinit();
    const one = try load(gpa, io, .{ .cert = at(arena, base, "both.pem") }, .{ .arena = arena, .passphrase = null });
    one.deinit();
    const opened = try load(gpa, io, .{ .cert = at(arena, base, "cert.pem"), .key = at(arena, base, "enc.pem") }, .{ .arena = arena, .passphrase = "correct-horse" });
    opened.deinit();
    try testing.expect(keyIsEncrypted(arena, io, .{ .cert = at(arena, base, "cert.pem"), .key = at(arena, base, "enc.pem") }));

    try testing.expectError(error.SslClientKeyPassphraseRequired, load(gpa, io, .{ .cert = at(arena, base, "cert.pem"), .key = at(arena, base, "enc.pem") }, .{ .arena = arena, .passphrase = null }));
    try testing.expectError(error.SslClientKeyPassphraseWrong, load(gpa, io, .{ .cert = at(arena, base, "cert.pem"), .key = at(arena, base, "enc.pem") }, .{ .arena = arena, .passphrase = "nope" }));
    try testing.expectError(error.SslClientKeyMismatch, load(gpa, io, .{ .cert = at(arena, base, "cert.pem"), .key = at(arena, base, "other.pem") }, .{ .arena = arena, .passphrase = null }));
    try testing.expectError(error.SslClientKeyUnreadable, load(gpa, io, .{ .cert = at(arena, base, "cert.pem") }, .{ .arena = arena, .passphrase = null }));
    try testing.expectError(error.SslClientCertificateUnreadable, load(gpa, io, .{ .cert = at(arena, base, "nothere.pem") }, .{ .arena = arena, .passphrase = null }));
    try testing.expectError(error.SslCertTypeUnsupported, Format.parse("P12"));
    try testing.expectEqual(Format.der, try Format.parse("der"));
    try testing.expectError(error.SslClientCertificateUnreadable, load(gpa, io, .{ .cert = at(arena, base, "both.pem"), .cert_format = .der }, .{ .arena = arena, .passphrase = null }));
}
