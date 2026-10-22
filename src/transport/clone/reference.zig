//! The repositories a clone borrows objects from: git's `--reference`,
//! `--reference-if-able` and `--dissociate`, and what a submodule's clone
//! borrows from its superproject's lenders under
//! `submodule.alternateLocation`.
//!
//! A lender is a repository on this machine, named by its working tree,
//! its git directory or a `.git` file, whose `objects` the new repository's
//! `objects/info/alternates` names, so the remote sends only what it
//! lacks. git's `compute_alternate_path` decides which can lend: not one
//! that is missing, not one that is not a repository, not a linked
//! checkout, not a shallow or grafted one, since the history it lends
//! would end early.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const repo_mod = @import("../../repo/repo.zig");
const gitfile = @import("../../discover.zig").gitfile;
const repack_mod = @import("../../maintenance/repack.zig");
const warning = @import("../../report.zig").warning;

const Repository = repo_mod.Repository;

pub const Error = error{
    /// A required lender is not there: git's "path '<path>' does not
    /// exist".
    ReferenceNotFound,
    /// A required lender is no repository: git's "reference repository
    /// '<path>' is not a local repository."
    ReferenceNotARepository,
    /// A required lender is a linked worktree's: git's "reference
    /// repository '<path>' as a linked checkout is not supported yet."
    ReferenceLinkedCheckout,
    /// A required lender is shallow: git's "reference repository '<path>'
    /// is shallow".
    ReferenceShallow,
    /// A required lender is grafted: git's "reference repository '<path>'
    /// is grafted".
    ReferenceGrafted,
    /// `submodule.alternateLocation` is neither `superproject` nor `no`.
    InvalidAlternateLocation,
    /// `submodule.alternateErrorStrategy` is not `die`, `info` or
    /// `ignore`.
    InvalidAlternateErrorStrategy,
} || repo_mod.Error || repack_mod.Error || Io.Dir.RealPathFileAllocError;

/// One `--reference` or `--reference-if-able`.
pub const Reference = struct {
    path: []const u8,
    /// `--reference-if-able`: a lender that cannot lend is a warning and
    /// left out, where `--reference`'s is an error.
    if_able: bool = false,
};

/// Why a repository cannot lend.
pub const Refusal = enum {
    not_found,
    not_a_repository,
    linked_checkout,
    shallow,
    grafted,

    /// git's words for it.
    pub fn message(r: Refusal, arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
        return switch (r) {
            .not_found => arena.print("path '{s}' does not exist", .{path}),
            .not_a_repository => arena.print("reference repository '{s}' is not a local repository.", .{path}),
            .linked_checkout => arena.print("reference repository '{s}' as a linked checkout is not supported yet.", .{path}),
            .shallow => arena.print("reference repository '{s}' is shallow", .{path}),
            .grafted => arena.print("reference repository '{s}' is grafted", .{path}),
        };
    }

    fn err(r: Refusal) Error {
        return switch (r) {
            .not_found => error.ReferenceNotFound,
            .not_a_repository => error.ReferenceNotARepository,
            .linked_checkout => error.ReferenceLinkedCheckout,
            .shallow => error.ReferenceShallow,
            .grafted => error.ReferenceGrafted,
        };
    }
};

/// A lender's git directory, absolute, or why it cannot lend.
pub const Lender = union(enum) { git_dir: []const u8, refused: Refusal };

/// git's `compute_alternate_path`: the git directory of the repository
/// `path` names -- itself, the one a `.git` file in it or at it names, or
/// its `.git` -- when it can lend. `arena`'s.
pub fn lenderAt(arena: Allocator, io: Io, path: []const u8) Self.Error!Lender {
    const real = Io.Dir.cwd().realPathFileAlloc(io, path, arena) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => return .{ .refused = .not_found },
        else => |other| return other,
    };
    const named = (try gitfileAt(arena, io, real, null)) orelse try gitfileAt(arena, io, real, ".git");
    var git_dir = named orelse real;
    if (named == null and isDirectory(io, try arena.print("{s}/.git/objects", .{real}))) {
        git_dir = try arena.print("{s}/.git", .{real});
    } else if (!isDirectory(io, try arena.print("{s}/objects", .{git_dir}))) {
        const linked = exists(io, try arena.print("{s}/commondir", .{git_dir}));
        return .{ .refused = if (linked) .linked_checkout else .not_a_repository };
    }
    if (exists(io, try arena.print("{s}/shallow", .{git_dir}))) return .{ .refused = .shallow };
    if (exists(io, try arena.print("{s}/info/grafts", .{git_dir}))) return .{ .refused = .grafted };
    return .{ .git_dir = git_dir };
}

/// The directory the `.git` file at `<dir>/<name>` (or `dir` itself)
/// names, absolute, or `null` when there is none.
fn gitfileAt(arena: Allocator, io: Io, dir: []const u8, name: ?[]const u8) Self.Error!?[]const u8 {
    const file = if (name) |n| try arena.print("{s}/{s}", .{ dir, n }) else dir;
    const target = (gitfile.read(arena, io, Io.Dir.cwd(), file) catch |e| switch (e) {
        error.IsDir => return null,
        else => |other| return other,
    }) orelse return null;
    const base = Io.Dir.path.dirname(file) orelse ".";
    const joined = if (Io.Dir.path.isAbsolute(target)) target else try Io.Dir.path.join(arena, &.{ base, target });
    return Io.Dir.cwd().realPathFileAlloc(io, joined, arena) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => null,
        else => |other| other,
    };
}

fn isDirectory(io: Io, path: []const u8) bool {
    var dir = Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// git's `setup_reference`: each of `references` that can lend named in
/// `repo`'s alternates, as `<git dir>/objects`; one that cannot is its
/// error, or, `if_able`, git's "Could not add alternate" warning.
pub fn borrow(arena: Allocator, io: Io, repo: *Repository, references: []const Reference, warnings: ?*warning.Warnings) Self.Error!void {
    for (references) |reference| switch (try lenderAt(arena, io, reference.path)) {
        .git_dir => |dir| try repo.objectDatabase().addAlternate(io, try arena.print("{s}/objects", .{dir})),
        .refused => |why| {
            if (!reference.if_able) return why.err();
            try warning.note(warnings, .{ .alternate_not_added = .{ .path = reference.path, .reason = try why.message(arena, reference.path) } });
        },
    };
}

/// git's `dissociate_from_references`: what the lenders hold copied in --
/// `repack -a -d` -- and the alternates file removed.
pub fn dissociate(gpa: Allocator, io: Io, repo: *Repository) Self.Error!void {
    if (!repo.objectDatabase().hasAlternates()) return;
    _ = try repack_mod.repack(gpa, io, repo, .{ .mode = .all, .delete = true });
    repo.gitDirectory().deleteFile(io, "objects/info/alternates") catch |e| switch (e) {
        error.FileNotFound => {},
        else => |other| return other,
    };
}

/// What `submodule.alternateErrorStrategy` does with a lender that cannot
/// lend.
const Strategy = enum { die, info, ignore };

/// git's `prepare_possible_alternates`: under
/// `submodule.alternateLocation=superproject`, for each of `superproject`'s
/// lenders that is a repository's `objects`, that repository's
/// `modules/<name>`, when it can lend. One that cannot is, by
/// `submodule.alternateErrorStrategy`, an error (`die`, the default), git's
/// "submodule '<name>' cannot add alternate" warning (`info`), or nothing
/// (`ignore`). `arena`'s.
pub fn forSubmodule(arena: Allocator, io: Io, superproject: *Repository, name: []const u8, warnings: ?*warning.Warnings) Self.Error![]const Reference {
    const config = superproject.configuration();
    const location = config.get("submodule.alternatelocation") orelse return &.{};
    const text = config.get("submodule.alternateerrorstrategy") orelse "die";
    const strategy = std.meta.stringToEnum(Strategy, text) orelse return error.InvalidAlternateErrorStrategy;
    if (std.mem.eql(u8, location, "no")) return &.{};
    if (!std.mem.eql(u8, location, "superproject")) return error.InvalidAlternateLocation;

    var listed = try superproject.objectDatabase().listAlternates(arena, io);
    defer listed.deinit();
    const objects = try superproject.gitDirectory().realPathFileAlloc(io, "objects", arena);
    var out: std.ArrayList(Reference) = .empty;
    for (listed.paths) |raw| {
        const path = if (Io.Dir.path.isAbsolute(raw)) raw else try Io.Dir.path.join(arena, &.{ objects, raw });
        const trimmed = std.mem.trimEnd(u8, path, "/");
        if (!std.mem.endsWith(u8, trimmed, "/objects")) continue;
        // The trailing `/` keeps a name holding `/` a directory.
        const module = try arena.print("{s}/modules/{s}/", .{ trimmed[0 .. trimmed.len - "/objects".len], name });
        switch (try lenderAt(arena, io, module)) {
            .git_dir => try out.append(arena, .{ .path = module }),
            .refused => |why| switch (strategy) {
                .die => return why.err(),
                .info => try warning.note(warnings, .{ .submodule_alternate_not_added = .{ .name = name, .reason = try why.message(arena, module) } }),
                .ignore => {},
            },
        }
    }
    return out.items;
}
