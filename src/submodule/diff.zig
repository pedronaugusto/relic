//! A submodule's change in its superproject's diff, as git 2.55 writes it
//! under `--submodule=log` and `--submodule=diff` (`diff.submodule`):
//! git's `show_submodule_header`, `show_submodule_diff_summary` and
//! `show_submodule_inline_diff`, the submodule's repository opened where
//! git's `open_submodule` finds it. `DiffWriter.writer` is what
//! `diff.UnifiedInputs.submodules` takes.
//!
//! The inline diff is the one git's child `git diff --submodule=diff`
//! writes between the two commits, read with the submodule's own settings:
//! its diff options, renames, drivers and colours, its textconv and
//! external diff where `DiffWriter.programs` allows them to run, and its
//! own submodules the same way. A diff that only a working tree has, the
//! modified or untracked content git marks a submodule dirty by, is not
//! here: the changes a diff of two trees writes never carry it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const abbrev = @import("../odb/abbrev.zig");
const diff = @import("../diff/diff.zig");
const external_mod = @import("../diff/external.zig");
const textconv_mod = @import("../diff/textconv.zig");
const driver_mod = @import("../diff/driver.zig");
const paint = @import("../diff/paint.zig");
const color = @import("../config/color.zig");
const message = @import("../object/message.zig");
const repo_mod = @import("../repo/repo.zig");
const walk_mod = @import("../walk/walk.zig");
const pretty = @import("../pretty/pretty.zig");
const attributes = @import("../patterns.zig").attributes;
const gitlink = @import("../discover.zig").gitlink;
const program = @import("../process.zig").program;
const submodule = @import("submodule.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

/// Writes a superproject's gitlink changes as `diff.submodule` asks.
pub const DiffWriter = struct {
    gpa: Allocator,
    /// The superproject, whose working tree the submodules are in.
    repo: *Repository,
    /// The permission to run a submodule's textconv and external diff
    /// programs in an inline diff, as git's child `git diff` runs them;
    /// `null` runs none.
    programs: ?program.Programs = null,
    /// What a commit's subject is written in: the superproject's
    /// `i18n.logOutputEncoding`, as git's `get_log_output_encoding` is.
    log_encoding: []const u8,

    /// A writer for `repo`'s submodules, running `programs` where an
    /// inline diff asks.
    pub fn init(gpa: Allocator, repo: *Repository, programs: ?program.Programs) error{InvalidEncodingSetting}!DiffWriter {
        return .{ .gpa = gpa, .repo = repo, .programs = programs, .log_encoding = try message.logOutputEncoding(repo.configuration()) };
    }

    /// What `diff.unified` writes the gitlink changes through.
    pub fn writer(d: *DiffWriter) diff.SubmoduleWriter {
        return .{ .context = d, .writeFn = writeFn };
    }

    fn writeFn(io: Io, context: *anyopaque, w: *Io.Writer, change: diff.SubmoduleChange) diff.SubmoduleWriter.Error!void {
        const d: *DiffWriter = @ptrCast(@alignCast(context)); // aegis: no-danger: `writer` makes the context from a DiffWriter
        var arena_instance: std.heap.ArenaAllocator = .init(d.gpa);
        defer arena_instance.deinit();
        return d.write(arena_instance.allocator(), io, w, change);
    }

    fn write(d: *DiffWriter, a: Allocator, io: Io, w: *Io.Writer, change: diff.SubmoduleChange) diff.SubmoduleWriter.Error!void {
        var opened = open(d.gpa, io, d.repo, change.path);
        defer if (opened) |*r| r.deinit(io);
        const sub: ?*Repository = if (opened) |*r| r else null;
        const sides = (try header(a, io, d.repo, sub, w, change)) orelse return;
        const repo = sub orelse return;
        switch (change.options.submodule) {
            .short => unreachable,
            .log => {
                const left = sides.left orelse return;
                const right = sides.right orelse return;
                summary(a, io, repo, w, .{ .left = left, .right = right, .bases = sides.bases }, change.options, d.log_encoding) catch |err| switch (err) {
                    error.WriteFailed, error.OutOfMemory => |e| return e,
                    else => try w.writeAll("(revision walker failed)\n"),
                };
            },
            .diff => {
                if (sides.left == null and change.old != null) return;
                if (sides.right == null and change.new != null) return;
                var out: Io.Writer.Allocating = .init(a);
                const failed = if (d.inlineDiff(a, io, repo, &out.writer, sides, change)) false else |err| switch (err) {
                    error.WriteFailed, error.OutOfMemory => |e| return e,
                    else => true,
                };
                try w.writeAll(out.written());
                if (failed) try w.writeAll("(diff failed)\n");
            },
        }
    }

    /// The submodule's diff between the two commits, as git's child
    /// `git diff --submodule=diff <old> <new>` writes it, each path under
    /// `<prefix><path>/`.
    fn inlineDiff(d: *DiffWriter, a: Allocator, io: Io, sub: *Repository, w: *Io.Writer, sides: Sides, change: diff.SubmoduleChange) !void {
        const db = sub.objectDatabase();
        const kind = sub.objectFormat();
        const old_tree = if (sides.left) |c| try sub.commitTree(io, c) else kind.emptyTree();
        const new_tree = if (sides.right) |c| try sub.commitTree(io, c) else kind.emptyTree();
        const config = sub.configuration();
        var changes = try diff.tree(d.gpa, io, db, .{ .old = old_tree, .new = new_tree }, .{ .renames = (try diff.RenameSettings.read(config)).options() });
        defer changes.deinit();
        const colors: ?*const paint.Colors = if (change.options.colors != null) blk: {
            const c = try a.create(paint.Colors);
            c.* = try paint.Colors.read(config);
            break :blk c;
        } else null;
        const options = try diff.configured(config, .{
            .prefixes = .{
                .src = try std.mem.concat(a, u8, &.{ change.options.prefixes.src, change.path, "/" }),
                .dst = try std.mem.concat(a, u8, &.{ change.options.prefixes.dst, change.path, "/" }),
            },
            .colors = colors,
            .abbrev = abbrev.defaultLength(config, db),
            .submodule = .diff,
        });
        var attrs: ?attributes.Attrs = if (sub.workDirectory() != null) try sub.loadAttrs(io) else null;
        defer if (attrs) |*x| x.deinit();
        const drivers: driver_mod.Drivers = .{ .attrs = if (attrs) |*x| x else null, .work_dir = if (sub.workDirectory()) |work| work.get() else null, .config = config };
        var nested = try DiffWriter.init(d.gpa, sub, d.programs);
        const textconv: ?textconv_mod.Textconv = if (d.programs) |p| .{ .programs = p } else null;
        const external: ?external_mod.External = if (d.programs) |p| .{ .programs = p, .command = try external_mod.configured(config) } else null;
        try diff.unified(d.gpa, io, w, .{
            .db = db,
            .changes = changes.items,
            .drivers = drivers,
            .textconv = if (textconv) |*t| t else null,
            .external = if (external) |*e| e else null,
            .submodules = nested.writer(),
        }, options);
    }
};

/// The repository of the submodule at `path`, as git's `open_submodule`
/// finds it: its working tree's `.git`, else the one `.gitmodules` names
/// it by in `modules`; `null` when there is none, or it does not open.
fn open(gpa: Allocator, io: Io, repo: *Repository, path: []const u8) ?Repository {
    const wt = (repo.workDirectory() orelse return null).get();
    if (gitlink.isRepository(gpa, io, wt, path) catch false) {
        return submodule.openRepository(gpa, io, repo, .{ .path = path, .name = path }, .{}) catch null;
    }
    var index = repo.openIndex(io) catch return null;
    defer index.deinit();
    var modules = submodule.loadGitmodules(gpa, io, repo, &index) catch return null;
    defer modules.deinit();
    const module = modules.byPath(path) orelse return null;
    return submodule.openRepository(gpa, io, repo, .{ .path = path, .name = module.name }, .{}) catch null;
}

/// The two commits as the submodule has them, and their merge bases.
const Sides = struct {
    left: ?Oid = null,
    right: ?Oid = null,
    bases: []const Oid = &.{},
};

/// git's `show_submodule_header`: `Submodule <path> <old>..<new>:`, with
/// `...` where neither commit descends from the other, ` (rewind)` where
/// the old one descends from the new, or what stands in for the commits.
/// `null` where the two are one commit, which writes nothing.
fn header(a: Allocator, io: Io, repo: *Repository, sub: ?*Repository, w: *Io.Writer, change: diff.SubmoduleChange) diff.SubmoduleWriter.Error!?Sides {
    const kind = repo.objectFormat();
    const one = change.old orelse Oid.zero(kind);
    const two = change.new orelse Oid.zero(kind);
    var note: ?[]const u8 = if (change.old == null) "(new submodule)" else if (change.new == null) "(submodule deleted)" else null;
    var sides: Sides = .{};
    var fast_forward = false;
    var fast_backward = false;
    if (sub) |s| found: {
        sides.left = if (change.old) |o| commitOf(io, s, o) else null;
        sides.right = if (change.new) |n| commitOf(io, s, n) else null;
        if ((change.old != null and sides.left == null) or (change.new != null and sides.right == null)) note = "(commits not present)";
        if (sides.left != null and sides.right != null) {
            sides.bases = walk_mod.mergeBases(a, io, s.objectDatabase(), .{ .a = sides.left.?, .b = sides.right.? }, .{}) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                else => {
                    note = "(corrupt repository)";
                    break :found;
                },
            };
            if (sides.bases.len > 0) {
                if (sides.bases[0].eql(sides.left.?)) fast_forward = true else if (sides.bases[0].eql(sides.right.?)) fast_backward = true;
            }
        }
        if (one.eql(two)) return null;
    } else if (note == null) note = "(commits not present)";
    const db = repo.objectDatabase();
    const len = abbrev.defaultLength(repo.configuration(), db);
    var one_buf: [hash.max_hex_len]u8 = undefined;
    var two_buf: [hash.max_hex_len]u8 = undefined;
    const one_hex = abbrev.unique(io, db, one, len, &one_buf) catch one.abbrev(&one_buf, len);
    const two_hex = abbrev.unique(io, db, two, len, &two_buf) catch two.abbrev(&two_buf, len);
    try w.print("Submodule {s} {s}{s}{s}", .{ change.path, one_hex, if (fast_forward or fast_backward) ".." else "...", two_hex });
    if (note) |n| try w.print(" {s}\n", .{n}) else try w.print("{s}:\n", .{if (fast_backward) " (rewind)" else ""});
    return sides;
}

/// git's `lookup_commit_reference`: `oid`, a tag peeled, as a commit the
/// submodule holds; `null` where it holds none.
fn commitOf(io: Io, sub: *Repository, oid: Oid) ?Oid {
    const peeled = sub.peel(io, oid) catch return null;
    const found = sub.objectDatabase().readHeader(io, peeled) catch return null;
    return if (found.type == .commit) peeled else null;
}

/// git's `show_submodule_diff_summary` after the header: each commit on
/// one side and not the other, first parents only, newest first, as
/// `  < <subject>` in the old colour for the old side and `  > <subject>`
/// in the new one for the new.
fn summary(a: Allocator, io: Io, sub: *Repository, w: *Io.Writer, sides: Sides, options: *const diff.Options, encoding: []const u8) !void {
    const left = sides.left.?;
    const right = sides.right.?;
    const bases = sides.bases;
    const db = sub.objectDatabase();
    var left_side: Oid.Map(void) = .empty;
    {
        var walk = walk_mod.Walk.init(a, db);
        defer walk.deinit();
        walk.first_parent = true;
        try walk.push(left);
        for (bases) |b| try walk.hide(b);
        while (try walk.next(io)) |c| try left_side.put(a, c.oid, {});
    }
    var walk = walk_mod.Walk.init(a, db);
    defer walk.deinit();
    walk.first_parent = true;
    try walk.push(left);
    try walk.push(right);
    for (bases) |b| try walk.hide(b);
    const reset: []const u8 = if (options.colors != null) color.reset else "";
    while (try walk.next(io)) |c| {
        const on_left = left_side.contains(c.oid);
        var subject: std.ArrayList(u8) = .empty;
        try pretty.formatCommit(a, io, .{ .db = db, .oid = c.oid, .format = "%s" }, &subject, .{ .output_encoding = encoding });
        const set: []const u8 = if (options.colors) |colors| (if (on_left) colors.old.bytes() else colors.new.bytes()) else "";
        try w.print("{s}  {s} {s}{s}\n", .{ set, if (on_left) "<" else ">", subject.items, reset });
    }
}
