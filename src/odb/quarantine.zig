//! Objects held apart until they are accepted: git's `tmp_objdir`.
//!
//! A push's pack is received into a directory of its own under `objects`,
//! `tmp_objdir-incoming-<random>`, which no reader of the repository looks
//! in. A database opened on it reads its own objects first and then the
//! repository's (`Odb.borrow`), so a thin pack's bases are found and the
//! push can be checked whole — connected, its hooks run with the
//! quarantine as their object directory (`environment`). Accepted, its
//! files are moved into the repository's own `objects` (`migrate`), packs
//! with their index last so no reader meets an index whose pack is not
//! there; refused, the directory is removed (`discard`) and nothing of the
//! push is left behind.
//!
//! `git log --remerge-diff` holds the objects of each merge it makes again
//! in one too, `tmp_objdir-remerge-diff-<random>`, and discards them.

const ErrorNamespace = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const odb_mod = @import("odb.zig");
const keep = @import("keep.zig");
const fs = @import("../fs/fs.zig");
const hash = @import("../hash/hash.zig");

const Odb = odb_mod.Odb;

/// Errors from a quarantine.
pub const Error = odb_mod.Error || keep.Error || Io.Dir.RealPathError || Io.Dir.RenameError || Io.Dir.CreateDirError || Io.Dir.OpenError || Io.Dir.DeleteTreeError;

/// Objects received apart from `main`.
pub const Quarantine = struct {
    pub const Error = ErrorNamespace.Error;

    gpa: Allocator,
    /// Reads the quarantine, then the repository; writes the quarantine.
    db: Odb,
    /// The repository's `objects`, borrowed.
    objects: Io.Dir,
    /// The quarantine directory's name under `objects`.
    name_buf: [64]u8,
    name_len: usize,
    /// Absolute paths: the quarantine, and the repository's `objects`.
    path: []u8,
    objects_path: []u8,
    /// The repository's permissions, for the directories made in it.
    shared: fs.Shared,
    /// Whether the directory is still there.
    open: bool = true,

    /// What the objects are held for, which names the directory.
    pub const Purpose = enum {
        /// A push's pack, until the push is accepted.
        incoming,
        /// The objects of a merge made again for its diff.
        remerge_diff,

        fn prefix(p: Purpose) []const u8 {
            return switch (p) {
                .incoming => "tmp_objdir-incoming-",
                .remerge_diff => "tmp_objdir-remerge-diff-",
            };
        }
    };

    /// Make the directory beside `main`'s objects and open a database on it.
    pub fn begin(gpa: Allocator, io: Io, main: *Odb, purpose: Purpose) ErrorNamespace.Error!Quarantine {
        const objects = main.objectsDirectory();
        var q: Quarantine = .{ .gpa = gpa, .db = undefined, .objects = objects, .name_buf = undefined, .name_len = 0, .path = &.{}, .objects_path = &.{}, .shared = main.sharedPermissions() };
        const dir_name = fs.tempName(io, &q.name_buf, purpose.prefix());
        q.name_len = dir_name.len;
        try objects.createDir(io, dir_name, .default_dir);
        errdefer objects.deleteTree(io, dir_name) catch {}; // glint-ignore: Z026 -- a quarantine never opened is removed on a best-effort basis; nothing in it was accepted
        var dir = try objects.openDir(io, dir_name, .{ .iterate = true });
        defer dir.close(io);
        q.db = try Odb.openAt(gpa, io, dir, main.objectFormat(), main.settings());
        errdefer q.db.deinit(io);
        try q.db.borrow(io, objects);
        const real = try objects.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(real);
        q.objects_path = try gpa.dupe(u8, real);
        errdefer gpa.free(q.objects_path);
        q.path = try std.Io.Dir.path.join(gpa, &.{ q.objects_path, dir_name });
        return q;
    }

    /// The quarantine directory's name under `objects`.
    pub fn name(q: *const Quarantine) []const u8 {
        return q.name_buf[0..q.name_len];
    }

    /// What a program reading the push sees as its objects, as git's
    /// `tmp_objdir_env`: `GIT_OBJECT_DIRECTORY` and `GIT_QUARANTINE_PATH`
    /// the quarantine, `GIT_ALTERNATE_OBJECT_DIRECTORIES` the repository's
    /// own after any `inherited`. The values live in `arena`.
    pub fn environment(q: *const Quarantine, arena: Allocator, inherited: ?[]const u8) Allocator.Error![3]Var {
        const alternates = if (inherited) |before|
            try std.mem.concat(arena, u8, &.{ before, &.{std.Io.Dir.path.delimiter}, q.objects_path })
        else
            q.objects_path;
        return .{
            .{ .name = "GIT_ALTERNATE_OBJECT_DIRECTORIES", .value = alternates },
            .{ .name = "GIT_OBJECT_DIRECTORY", .value = q.path },
            .{ .name = "GIT_QUARANTINE_PATH", .value = q.path },
        };
    }

    /// One variable of `environment`.
    pub const Var = struct { name: []const u8, value: []const u8 };

    /// Move every object into `main`, as git's `tmp_objdir_migrate`: loose
    /// objects into their fan-out directories, and each pack's files into
    /// `objects/pack` with the index last. A pack is held by a `.keep`
    /// (returned, one per pack) from before its index is published until
    /// the caller lets it go, so nothing prunes it before a ref names it.
    /// The quarantine is gone afterwards; `main` reads what it held.
    pub fn migrate(q: *Quarantine, io: Io, main: *Odb, keeps: *std.ArrayList(keep.Token)) ErrorNamespace.Error!void {
        var dir = try q.objects.openDir(io, q.name(), .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .directory) continue;
            if (std.mem.eql(u8, entry.name, "pack") or std.mem.eql(u8, entry.name, "info")) continue;
            if (entry.name.len != 2) continue;
            try q.moveLoose(io, dir, entry.name);
        }
        if (dir.openDir(io, "pack", .{ .iterate = true })) |pack_dir_in| {
            var pack_in = pack_dir_in;
            defer pack_in.close(io);
            var pack_out = try main.openPackDirectory(io);
            defer pack_out.close(io);
            // Every pack's companions first, its index after them.
            var names: std.ArrayList([]u8) = .empty;
            defer {
                for (names.items) |n| q.gpa.free(n);
                names.deinit(q.gpa);
            }
            var pit = pack_in.iterate();
            while (try pit.next(io)) |entry| {
                if (entry.kind == .directory) continue;
                if (std.mem.endsWith(u8, entry.name, ".keep")) continue;
                try names.append(q.gpa, try q.gpa.dupe(u8, entry.name));
            }
            std.mem.sort([]u8, names.items, {}, struct {
                fn lessThan(_: void, a: []u8, b: []u8) bool {
                    return priority(a) < priority(b);
                }
            }.lessThan);
            for (names.items) |n| {
                if (std.mem.endsWith(u8, n, ".idx")) {
                    if (packName(main.objectFormat(), n)) |oid| try keeps.append(q.gpa, try keep.Token.open(q.gpa, io, pack_out, oid));
                }
                try moveFile(io, pack_in, n, pack_out, n);
            }
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        }
        try main.refresh(io);
        q.discard(io);
    }

    fn moveLoose(q: *Quarantine, io: Io, dir: Io.Dir, fanout: []const u8) ErrorNamespace.Error!void {
        var from = try dir.openDir(io, fanout, .{ .iterate = true });
        defer from.close(io);
        try fs.makeDirs(io, q.objects, fanout, q.shared);
        var to = try q.objects.openDir(io, fanout, .{});
        defer to.close(io);
        var it = from.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind == .directory) continue;
            try moveFile(io, from, entry.name, to, entry.name);
        }
    }

    /// Remove the quarantine and whatever is still in it.
    pub fn discard(q: *Quarantine, io: Io) void {
        if (!q.open) return;
        q.open = false;
        q.db.deinit(io);
        // glint-ignore: Z026 -- what is left of a refused push is removed on a best-effort basis, as git's tmp_objdir_destroy removes it
        q.objects.deleteTree(io, q.name()) catch {};
    }

    /// Release everything; a quarantine not migrated is discarded.
    pub fn deinit(q: *Quarantine, io: Io) void {
        q.discard(io);
        q.gpa.free(q.path);
        q.gpa.free(q.objects_path);
        q.* = undefined;
    }
};

/// git's `pack_copy_priority`: a pack's own file first, its index last.
fn priority(name: []const u8) u8 {
    if (!std.mem.startsWith(u8, name, "pack")) return 0;
    if (std.mem.endsWith(u8, name, ".pack")) return 1;
    if (std.mem.endsWith(u8, name, ".idx")) return 3;
    return 2;
}

/// The name a pack's file carries, `pack-<name>.<ext>`.
fn packName(kind: hash.Kind, file: []const u8) ?hash.Oid {
    if (!std.mem.startsWith(u8, file, "pack-")) return null;
    const rest = file["pack-".len..];
    if (rest.len < kind.hexLen()) return null;
    return hash.Oid.parse(kind, rest[0..kind.hexLen()]) catch null;
}

/// Move `from_name` to `to_name`, as git's `finalize_object_file`: an
/// object already there is the same object and is kept.
fn moveFile(io: Io, from: Io.Dir, from_name: []const u8, to: Io.Dir, to_name: []const u8) ErrorNamespace.Error!void {
    if (to.access(io, to_name, .{})) |_| {
        return;
    } else |_| {}
    try Io.Dir.rename(from, from_name, to, to_name, io);
}
