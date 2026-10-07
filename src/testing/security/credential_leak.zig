//! Credential leaks: a password written into a remote's URL, where it sits
//! in configuration files and process listings. git 2.37 let a person
//! refuse or be warned of such URLs with `transfer.credentialsInUrl`. The
//! owner is the transport gate, `transport.Session.open`, which every
//! fetch, clone and push opens its remote through.

const std = @import("std");

const transport = @import("../../transport.zig");
const config_mod = @import("../../config.zig");
const warning = @import("../../repo/warning.zig");

/// Open `url` with `transfer.credentialsInUrl` set to `value`, warning
/// into `warnings`. No programs are granted, so an ssh URL that passes the
/// gate ends at `ProgramsNotGranted` without a connection.
fn open(gpa: std.mem.Allocator, url: []const u8, value: []const u8, warnings: *warning.Warnings) anyerror!void {
    const text = try gpa.print("[transfer]\n\tcredentialsInUrl = {s}\n", .{value});
    defer gpa.free(text);
    var config = try config_mod.Config.parseText(gpa, text, .local);
    defer config.deinit();
    var session = try transport.Session.open(gpa, std.testing.io, url, .upload_pack, .sha1, .{
        .config = &config,
        .warnings = warnings,
    });
    session.close(std.testing.io);
    return error.TestUnexpectedResult;
}

test "git 2.37.0 transfer.credentialsInUrl, t5551-http-fetch-smart 'clone warns or fails when using username:password': a password in a URL is let through, warned of or refused" {
    const gpa = std.testing.allocator;
    const with_password = "ssh://user:pass@example.com/r.git";
    const blank_password = "ssh://user:@example.com/r.git";

    var warnings: warning.Warnings = .init(gpa);
    defer warnings.deinit();
    try std.testing.expectError(error.ProgramsNotGranted, open(gpa, with_password, "allow", &warnings));
    try std.testing.expectEqual(@as(usize, 0), warnings.items.items.len);

    try std.testing.expectError(error.ProgramsNotGranted, open(gpa, with_password, "warn", &warnings));
    try std.testing.expectEqual(@as(usize, 1), warnings.items.items.len);
    const text = try warnings.items.items[0].message(warnings.arena.allocator());
    try std.testing.expectEqualStrings("URL 'ssh://user:<redacted>@example.com/r.git' uses plaintext credentials", text);

    for ([_][]const u8{ with_password, blank_password }) |url| {
        try std.testing.expectError(error.CredentialsInUrl, open(gpa, url, "die", &warnings));
    }
}

test "git 2.37.0 transfer.credentialsInUrl, t5551-http-fetch-smart 'clone does not detect username:password when it is https://username@domain:port/': a user alone is no credential" {
    const gpa = std.testing.allocator;
    var warnings: warning.Warnings = .init(gpa);
    defer warnings.deinit();
    for ([_][]const u8{ "ssh://user@example.com:2222/r.git", "ssh://example.com/r.git" }) |url| {
        try std.testing.expectError(error.ProgramsNotGranted, open(gpa, url, "die", &warnings));
        try std.testing.expectError(error.ProgramsNotGranted, open(gpa, url, "warn", &warnings));
    }
    try std.testing.expectEqual(@as(usize, 0), warnings.items.items.len);
}
