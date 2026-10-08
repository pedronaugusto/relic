//! Protocol injection: a line break in a `git://` URL's host or path,
//! which git wrote into its request line, so that the request carried a
//! second one of the attacker's. relic has no `git://` client: a session
//! is refused as `UnsupportedTransport` before any request is made. A
//! `.gitmodules` URL is checked by `submodule/gitmodules.zig`'s `checkUrl`
//! (the architecture's `config/`) as git's fsck checks it.

const std = @import("std");

const transport = @import("../../transport/transport.zig");
const gitmodules = @import("../../config/gitmodules.zig");
const fsck = @import("../../object/fsck.zig");

test "CVE-2021-40330, t5570-git-daemon 'client refuses to ask for repo with newline': no request is made for a git:// URL with a line break" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    for ([_][]const u8{ "git://example.com/re\npo.git", "git://exa\nmple.com/repo.git", "git://example.com/re%0apo.git" }) |url| {
        try std.testing.expectError(error.UnsupportedTransport, transport.Session.open(gpa, io, url, .{ .service = .upload_pack, .kind = .sha1 }, .{}));
    }
    // From a `.gitmodules`, decoded or not, it is a URL fsck refuses.
    for ([_][]const u8{ "git://example.com/re%0apo.git", "git://example.com/re%0Apo.git" }) |url| {
        try std.testing.expect(!gitmodules.checkUrl(url));
        const text = try gpa.print("[submodule \"x\"]\n\tpath = x\n\turl = {s}\n", .{url});
        defer gpa.free(text);
        const finding = (try fsck.checkBlob(gpa, &fsck.baseline, .{ .oid = .zero(.sha1), .as = .modules, .bytes = text }, .{ .sink = null })).?;
        try std.testing.expectEqual(fsck.Problem.gitmodules_url, finding.problem.?);
    }
    try std.testing.expect(gitmodules.checkUrl("git://example.com/repo.git"));
}
