//! A remote on this machine: a path, or a `file://` URL.
//!
//! git reaches a repository on the same machine by starting
//! `git-upload-pack` there and talking to it over a pipe. relic has the
//! repository's own reader and needs no second program: the other
//! repository is opened in process, its refs are read as they are, and the
//! objects a fetch needs are found with `object_walk.missing` and written
//! straight into this repository's `objects/pack` as one pack, from the
//! other's object database. Nothing is spawned, and nothing goes through a
//! wire format that both ends of the same process would only have to parse.

const ErrorNamespace = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const refs_mod = @import("../refs/refs.zig");
const repo_mod = @import("../repo/repo.zig");
const odb_mod = @import("../odb/odb.zig");
const pack = @import("../odb/pack.zig");
const protocol = @import("../wire.zig").protocol;
const object_walk = @import("../walk/object/walk.zig");
const url_mod = @import("../wire.zig").url;
const object = @import("../object/object.zig");
const hidden_refs = @import("../wire.zig").hidden;

const Oid = hash.Oid;

/// Errors from a repository on this machine used as a remote.
pub const Error = errors: {
    break :errors error{
        /// The path names no repository.
        NotARepository,
        /// The repository has hooks a push would run — `pre-receive`, `update`,
        /// `post-receive` and the rest — and the caller gave no permission to
        /// run programs (`receive_pack.Options.programs`).
        RemoteHooksNotRun,
    } || repo_mod.Error || repo_mod.Repository.WriteShallowError || object_walk.Error || refs_mod.ReadError || refs_mod.TransactionError;
};

/// Another repository, open.
pub const Remote = struct {
    pub const Error = ErrorNamespace.Error;

    gpa: Allocator,
    repo: repo_mod.Repository,
    /// The refs not shown: `uploadpack.hideRefs` and `transfer.hideRefs`
    /// from the repository's configuration, or `receive.hideRefs` once
    /// `serve` says a push is coming.
    hidden: hidden_refs.Refs,

    /// Open the repository at `location`: a path, relative to the current
    /// directory or absolute, or a `file://` URL. The path is the
    /// repository — its working tree, its `.git`, or a bare repository —
    /// and is not searched above, as git does not search above a remote's.
    pub fn open(gpa: Allocator, io: Io, location: []const u8, options: repo_mod.Repository.OpenOptions) ErrorNamespace.Error!Remote {
        var identity = url_mod.Identity.parse(gpa, location) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NotARepository,
        };
        defer identity.deinit();
        const parsed = identity.url;
        if (!parsed.isLocalRepository()) return error.NotARepository;
        var dir = Io.Dir.cwd().openDir(io, parsed.path, .{ .iterate = true }) catch return error.NotARepository;
        defer dir.close(io);
        var open_options = options;
        open_options.discover = false;
        open_options.odb.probe_timestamp_resolution = false;
        const repo = repo_mod.Repository.open(gpa, io, dir, open_options) catch |err| switch (err) {
            error.NotARepository => return error.NotARepository,
            else => |e| return e,
        };
        var opened = repo;
        errdefer opened.deinit(io);
        const hidden = try hidden_refs.Refs.load(gpa, opened.configuration(), .upload_pack);
        return .{ .gpa = gpa, .repo = opened, .hidden = hidden };
    }

    /// Close the repository.
    pub fn deinit(r: *Remote, io: Io) void {
        r.hidden.deinit();
        r.repo.deinit(io);
        r.* = undefined;
    }

    /// Hide what the repository hides from `service`: a push is shown
    /// what `receive.hideRefs` leaves.
    pub fn serve(r: *Remote, service: hidden_refs.Service) ErrorNamespace.Error!void {
        const hidden = try hidden_refs.Refs.load(r.gpa, r.repo.configuration(), service);
        r.hidden.deinit();
        r.hidden = hidden;
    }

    /// Whether `name` is a ref the repository does not show.
    pub fn isHidden(r: *const Remote, name: []const u8) bool {
        return r.hidden.isHidden(name, name);
    }

    /// The refs the other repository shows, as a server lists them: `HEAD`
    /// first, with its target, then every ref under `refs/` in name order,
    /// each annotated tag with what it peels to. A hidden ref is left out.
    pub fn listRefs(r: *Remote, gpa: Allocator, io: Io, prefixes: []const []const u8) ErrorNamespace.Error!protocol.RefList {
        return r.listWith(gpa, io, prefixes, false);
    }

    /// `listRefs`, the hidden refs included: what a server asks of itself
    /// when it decides whether a want is a ref's tip.
    pub fn listAllRefs(r: *Remote, gpa: Allocator, io: Io, prefixes: []const []const u8) ErrorNamespace.Error!protocol.RefList {
        return r.listWith(gpa, io, prefixes, true);
    }

    fn listWith(r: *Remote, gpa: Allocator, io: Io, prefixes: []const []const u8, include_hidden: bool) ErrorNamespace.Error!protocol.RefList {
        var list: protocol.RefList = .{ .arena = .init(gpa), .refs = &.{} };
        errdefer list.arena.deinit();
        const arena = list.arena.allocator();
        var out: std.ArrayList(protocol.RemoteRef) = .empty;
        const kind = r.repo.objectFormat();

        if (matches("HEAD", prefixes) and (include_hidden or !r.isHidden("HEAD"))) {
            if (try r.repo.refStore().read(gpa, io, "HEAD")) |head| switch (head) {
                .symbolic => |target| broken: {
                    defer gpa.free(target);
                    // A `HEAD` that goes round in a circle is broken, and
                    // left out as git leaves a broken ref out.
                    const resolved = r.repo.refStore().resolve(gpa, io, "HEAD") catch |err| switch (err) {
                        error.SymbolicRefLoop => break :broken,
                        else => |e| return e,
                    };
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

        var listing = try r.repo.refStore().list(gpa, io, "refs/");
        defer listing.deinit();
        for (listing.entries) |entry| {
            if (!matches(entry.name, prefixes)) continue;
            if (!include_hidden and r.isHidden(entry.name)) continue;
            var ref: protocol.RemoteRef = .{ .name = try arena.dupe(u8, entry.name), .oid = .zero(kind) };
            switch (entry.target) {
                .direct => |oid| ref.oid = oid,
                .symbolic => |target| {
                    // A dangling or circular one is left out, as git
                    // leaves a broken ref out.
                    const resolved = (r.repo.refStore().resolve(gpa, io, entry.name) catch |err| switch (err) {
                        error.SymbolicRefLoop => continue,
                        else => |e| return e,
                    }) orelse continue;
                    defer gpa.free(resolved.name);
                    ref.oid = resolved.oid;
                    ref.symref_target = try arena.dupe(u8, target);
                },
            }
            if (entry.peeled) |peeled| {
                ref.peeled = peeled;
            } else if (try r.repo.objectDatabase().exists(io, ref.oid)) {
                const header = try r.repo.objectDatabase().readHeader(io, ref.oid);
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
    /// `pack` `null` takes the source repository's settings, as the upload-pack
    /// git runs there builds the pack.
    pub const CopyOptions = struct { pack_dir: Io.Dir, haves: []const Oid = &.{}, include_tags: bool = false, pack: ?odb_mod.PackOptions = null };
    pub fn copyObjects(
        r: *Remote,
        io: Io,
        into: *odb_mod.Odb,
        wants: []const Oid,
        with: CopyOptions,
    ) ErrorNamespace.Error!?pack.WriteReport {
        // git's upload-pack and pack-objects run with replace refs off.
        const followed = r.repo.objectDatabase().pauseReplacements();
        defer r.repo.objectDatabase().resumeReplacements(followed);
        const pack_dir = with.pack_dir;
        const haves = with.haves;
        const include_tags = with.include_tags;
        const options = with.pack orelse r.repo.objectDatabase().packOptions();
        var collected = try object_walk.missing(r.gpa, io, r.repo.objectDatabase(), wants, .{ .exclude = haves });
        defer collected.deinit();
        if (collected.entries.len == 0) return null;

        if (include_tags) {
            var sending: Oid.Set = .empty;
            defer sending.deinit(r.gpa);
            for (collected.entries) |entry| try sending.put(r.gpa, entry.oid, {});
            var extra: std.ArrayList(odb_mod.PackEntry) = .empty;
            defer extra.deinit(r.gpa);
            var tags = try r.repo.refStore().list(r.gpa, io, "refs/tags/");
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
                    if (!try r.repo.objectDatabase().exists(io, current)) break;
                    const header = try r.repo.objectDatabase().readHeader(io, current);
                    if (header.type != .tag) break;
                    try chain.append(r.gpa, current);
                    const found = try r.repo.objectDatabase().read(io, current);
                    defer r.repo.objectDatabase().allocator().free(found.bytes);
                    var tag = try object.Tag.parse(r.gpa, r.repo.objectFormat(), found.bytes);
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

        var report = try r.repo.objectDatabase().writePack(io, pack_dir, collected.entries, options);
        errdefer if (report.keep) |*token| token.deinit(io);
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
