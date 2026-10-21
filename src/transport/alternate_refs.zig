//! What the repositories this one borrows objects from have at their refs,
//! as git's `odb_for_each_alternate_ref` reads it: for each alternate that
//! is a repository -- `<repository>/objects`, with `refs` beside it -- the
//! objects `core.alternateRefsCommand` prints when this repository sets
//! it, run through the shell with the alternate's path, and otherwise the
//! objects the alternate's refs name, only those under
//! `core.alternateRefsPrefixes` when that is set. A server shows them to a
//! pushing client as `.have`, and a fetch starts its negotiation from them,
//! so what an alternate holds is not sent again.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const program = @import("../process.zig").program;
const repo_mod = @import("../repo/repo.zig");
const warning = @import("../report.zig").warning;
const local = @import("local.zig");

const Oid = hash.Oid;

/// Errors from reading the alternates' refs.
pub const Error = error{
    /// `core.alternateRefsCommand` is set and the caller gave no
    /// `program.Programs` to run it with.
    AlternateRefsCommandNotRun,
} || program.Error || local.Error || Allocator.Error || Io.Cancelable;

/// Every object the alternates' refs name, in the order git reads them;
/// the caller's, freed with `gpa`. A command whose output stops being
/// object names is read to there, with git's warning.
pub fn read(gpa: Allocator, io: Io, repo: *repo_mod.Repository, programs: ?program.Programs, warnings: ?*warning.Warnings) Error![]Oid {
    var out: std.ArrayList(Oid) = .empty;
    errdefer out.deinit(gpa);
    var alternates = try repo.objectDatabase().listAlternates(gpa, io);
    defer alternates.deinit();
    const config = repo.configuration();
    const command = config.get("core.alternaterefscommand");
    const prefixes = config.get("core.alternaterefsprefixes");
    for (alternates.paths) |path| {
        // As written, from this repository's `objects`.
        const objects = repo.objectDatabase().objectsDirectory().realPathFileAlloc(io, path, gpa) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => continue,
        };
        defer gpa.free(objects);
        if (!std.mem.endsWith(u8, objects, "/objects")) continue;
        const repo_path = objects[0 .. objects.len - "/objects".len];
        var top = Io.Dir.cwd().openDir(io, repo_path, .{}) catch continue;
        defer top.close(io);
        const refs = top.statFile(io, "refs", .{}) catch continue;
        if (refs.kind != .directory) continue;
        if (command) |line| {
            const allowed = programs orelse return error.AlternateRefsCommandNotRun;
            try fromCommand(gpa, io, allowed, line, repo_path, repo.objectFormat(), &out, warnings);
        } else try fromRefs(gpa, io, repo_path, prefixes, &out);
    }
    return out.toOwnedSlice(gpa);
}

/// git's `for-each-ref --format=%(objectname) [-- <prefixes>]` in the
/// alternate.
fn fromRefs(gpa: Allocator, io: Io, repo_path: []const u8, prefixes: ?[]const u8, out: *std.ArrayList(Oid)) Error!void {
    var other = local.Remote.open(gpa, io, repo_path, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return,
    };
    defer other.deinit(io);
    var refs = try other.listRefs(gpa, io, &.{"refs/"});
    defer refs.deinit();
    for (refs.refs) |ref| {
        if (prefixes) |list| if (!underAny(ref.name, list)) continue;
        try out.append(gpa, ref.oid);
    }
}

/// Whether `name` is one of `list`'s whitespace-separated patterns, or
/// under one, as `for-each-ref` matches a pattern with no wildcard.
fn underAny(name: []const u8, list: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, list, " \t\n");
    while (it.next()) |p| {
        if (!std.mem.startsWith(u8, name, p)) continue;
        if (name.len == p.len or p[p.len - 1] == '/' or name[p.len] == '/') return true;
    }
    return false;
}

/// `<command> <repo_path>` through the shell, with the variables that
/// point git at a repository cleared, each line of its output an object's
/// name.
fn fromCommand(gpa: Allocator, io: Io, programs: program.Programs, line: []const u8, repo_path: []const u8, kind: hash.Kind, out: *std.ArrayList(Oid), warnings: ?*warning.Warnings) Error!void {
    var outcome = try program.run(gpa, io, programs, .{
        .argv = &.{ line, repo_path },
        .shell = true,
        .unset = &program.repository_variables,
        .stderr = .inherit,
    }, .{});
    defer outcome.deinit(gpa);
    var lines = std.mem.splitScalar(u8, outcome.stdout, '\n');
    while (lines.next()) |text| {
        if (text.len == 0 and lines.peek() == null) break;
        const oid = Oid.parse(kind, text) catch {
            if (warnings) |sink| try sink.add(.{ .alternate_refs_line = text });
            return;
        };
        try out.append(gpa, oid);
    }
}

test "a pattern takes a ref at it or under it, as for-each-ref's does" {
    try std.testing.expect(underAny("refs/heads/main", "refs/heads"));
    try std.testing.expect(underAny("refs/heads/main", "refs/tags refs/heads/"));
    try std.testing.expect(underAny("refs/heads/main", "refs/heads/main"));
    try std.testing.expect(!underAny("refs/heads/main", "refs/heads/ma"));
    try std.testing.expect(!underAny("refs/tags/v1", "refs/heads"));
}
