//! A remote on this machine: a path, or a `file://` URL.
//!
//! git reaches a repository on the same machine by starting
//! `git-upload-pack` there and talking to it over a pipe. relic has the
//! repository's own reader and needs no second program: the other
//! repository is opened in process, its refs are read as they are, and the
//! objects a fetch needs are found with `objectwalk.missing` and written
//! straight into this repository's `objects/pack` as one pack, from the
//! other's object database. Nothing is spawned, and nothing goes through a
//! wire format that both ends of the same process would only have to parse.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const refs_mod = @import("refs.zig");
const repo_mod = @import("repo.zig");
const odb_mod = @import("odb.zig");
const pack = @import("pack.zig");
const protocol = @import("protocol.zig");
const objectwalk = @import("objectwalk.zig");
const url_mod = @import("url.zig");

const Oid = hash.Oid;

pub const Error = error{
    /// The path names no repository.
    NotARepository,
} || repo_mod.Error || objectwalk.Error || refs_mod.ReadError;

/// Another repository, open.
pub const Remote = struct {
    gpa: Allocator,
    repo: repo_mod.Repository,

    /// Open the repository at `location`: a path, relative to the current
    /// directory or absolute, or a `file://` URL. The path is the
    /// repository — its working tree, its `.git`, or a bare repository —
    /// and is not searched above, as git does not search above a remote's.
    pub fn open(gpa: Allocator, io: Io, location: []const u8) Error!Remote {
        const parsed = url_mod.Url.parse(location) catch return error.NotARepository;
        if (!parsed.isLocalRepository()) return error.NotARepository;
        var dir = Io.Dir.cwd().openDir(io, parsed.path, .{ .iterate = true }) catch return error.NotARepository;
        defer dir.close(io);
        const repo = repo_mod.Repository.open(gpa, io, dir, .{
            .discover = false,
            .odb = .{ .probe_timestamp_resolution = false },
        }) catch |err| switch (err) {
            error.NotARepository => return error.NotARepository,
            else => |e| return e,
        };
        return .{ .gpa = gpa, .repo = repo };
    }

    pub fn deinit(r: *Remote, io: Io) void {
        r.repo.deinit(io);
        r.* = undefined;
    }

    /// The refs the other repository has, as a server lists them: `HEAD`
    /// first, with its target, then every ref under `refs/` in name order,
    /// each annotated tag with what it peels to.
    pub fn listRefs(r: *Remote, gpa: Allocator, io: Io, prefixes: []const []const u8) Error!protocol.RefList {
        var list: protocol.RefList = .{ .arena = .init(gpa), .refs = &.{} };
        errdefer list.arena.deinit();
        const arena = list.arena.allocator();
        var out: std.ArrayList(protocol.RemoteRef) = .empty;
        const kind = r.repo.kind;

        if (matches("HEAD", prefixes)) {
            if (try r.repo.refs.read(gpa, io, "HEAD")) |head| switch (head) {
                .symbolic => |target| {
                    defer gpa.free(target);
                    const resolved = try r.repo.refs.resolve(gpa, io, "HEAD");
                    if (resolved) |res| {
                        defer gpa.free(res.name);
                        try out.append(arena, .{
                            .name = "HEAD",
                            .oid = res.oid,
                            .symref_target = try arena.dupe(u8, target),
                        });
                    } else {
                        try out.append(arena, .{
                            .name = "HEAD",
                            .oid = .zero(kind),
                            .symref_target = try arena.dupe(u8, target),
                            .unborn = true,
                        });
                    }
                },
                .direct => |oid| try out.append(arena, .{ .name = "HEAD", .oid = oid }),
            };
        }

        var listing = try r.repo.refs.list(gpa, io, "refs/");
        defer listing.deinit();
        for (listing.entries) |entry| {
            if (!matches(entry.name, prefixes)) continue;
            var ref: protocol.RemoteRef = .{ .name = try arena.dupe(u8, entry.name), .oid = .zero(kind) };
            switch (entry.target) {
                .direct => |oid| ref.oid = oid,
                .symbolic => |target| {
                    const resolved = (try r.repo.refs.resolve(gpa, io, entry.name)) orelse continue;
                    defer gpa.free(resolved.name);
                    ref.oid = resolved.oid;
                    ref.symref_target = try arena.dupe(u8, target);
                },
            }
            if (entry.peeled) |peeled| {
                ref.peeled = peeled;
            } else if (try r.repo.odb.exists(io, ref.oid)) {
                const header = try r.repo.odb.readHeader(io, ref.oid);
                if (header.type == .tag) ref.peeled = try r.repo.peel(io, ref.oid);
            }
            try out.append(arena, ref);
        }
        list.refs = out.items;
        return list;
    }

    /// Put in `into` — whose `objects/pack` is `pack_dir` — every object
    /// reachable from `wants` that is not reachable from `haves`, as one
    /// pack written from this repository's objects. With `include_tags`,
    /// every annotated tag that points at something in the pack comes too,
    /// as a server's `include-tag` sends it. `null` when there is nothing to
    /// copy. `into` is refreshed to read the new pack.
    pub fn copyObjects(
        r: *Remote,
        io: Io,
        into: *odb_mod.Odb,
        pack_dir: Io.Dir,
        wants: []const Oid,
        haves: []const Oid,
        include_tags: bool,
        options: odb_mod.PackOptions,
    ) Error!?pack.WriteReport {
        var collected = try objectwalk.missing(r.gpa, io, &r.repo.odb, wants, haves);
        defer collected.deinit();
        if (collected.entries.len == 0) return null;

        if (include_tags) {
            var sending: Oid.Set = .empty;
            defer sending.deinit(r.gpa);
            for (collected.entries) |entry| try sending.put(r.gpa, entry.oid, {});
            var extra: std.ArrayList(odb_mod.PackEntry) = .empty;
            defer extra.deinit(r.gpa);
            var tags = try r.repo.refs.list(r.gpa, io, "refs/tags/");
            defer tags.deinit();
            for (tags.entries) |entry| {
                const start = switch (entry.target) {
                    .direct => |oid| oid,
                    .symbolic => continue,
                };
                // A chain of tags: every tag object on it, if it ends at
                // something being sent.
                var chain: std.ArrayList(Oid) = .empty;
                defer chain.deinit(r.gpa);
                var current = start;
                var depth: u8 = 0;
                while (depth < 16) : (depth += 1) {
                    if (!try r.repo.odb.exists(io, current)) break;
                    const header = try r.repo.odb.readHeader(io, current);
                    if (header.type != .tag) break;
                    try chain.append(r.gpa, current);
                    const found = try r.repo.odb.read(io, current);
                    defer r.gpa.free(found.bytes);
                    var tag = try @import("object.zig").Tag.parse(r.gpa, r.repo.kind, found.bytes);
                    defer tag.deinit();
                    current = tag.target;
                }
                if (chain.items.len == 0 or !sending.contains(current)) continue;
                for (chain.items) |tag_oid| {
                    if (sending.contains(tag_oid) or try into.exists(io, tag_oid)) continue;
                    try sending.put(r.gpa, tag_oid, {});
                    try extra.append(r.gpa, .{ .oid = tag_oid });
                }
            }
            if (extra.items.len != 0) {
                const arena = collected.arena.allocator();
                collected.entries = try std.mem.concat(arena, odb_mod.PackEntry, &.{ collected.entries, extra.items });
            }
        }

        const report = try r.repo.odb.writePack(io, pack_dir, collected.entries, options);
        try into.refresh(io);
        return report;
    }
};

fn matches(name: []const u8, prefixes: []const []const u8) bool {
    if (prefixes.len == 0) return true;
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) return true;
    }
    return false;
}
