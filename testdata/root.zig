//! relic's test data: the keys and certificates its client-certificate tests write out
//! (certs/) and go-netrc's and Go's encoding/json's recorded answers (lfs/). It stays out of
//! src/ and of the package a project fetches (build.zig.zon's paths), and reaches the tests only
//! as the development build's module `testdata`.

/// The file at `path` under testdata/, embedded: `file("certs/p256.cert.pem")`.
pub fn file(comptime path: []const u8) @TypeOf(@embedFile(path)) {
    return @embedFile(path);
}
