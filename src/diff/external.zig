//! An external diff program: `diff.external` (or the caller's
//! `GIT_EXTERNAL_DIFF`) and `diff.<driver>.command`, run for a file pair in
//! place of the patch, as git 2.55's `run_external_diff` runs it.
//!
//! The command goes through the shell with seven arguments: the path, then
//! for each side a file holding it, its object name and its mode -- a side
//! that is not there is `/dev/null . .` -- and for a rename or a copy the
//! new path and the metadata lines git would have written. A side is a
//! temporary file `git-blob-XXXXXX/<name>` holding the blob as a checkout
//! writes it, or the working tree's own file where the index vouches that
//! it holds just that (`reuse_worktree_file`). `GIT_DIFF_PATH_COUNTER` and
//! `GIT_DIFF_PATH_TOTAL` say which pair of how many it is. What it writes
//! is the output; it must exit 0, or with `trustExitCode` 0 or 1, and
//! anything else is `error.ExternalDiffFailed`, where git dies.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const odb_mod = @import("../odb/odb.zig");
const config_mod = @import("../config/config.zig");
const program = @import("../process.zig").program;
const fs = @import("../fs/fs.zig");
const attributes = @import("../patterns.zig").attributes;
const checkout = @import("../checkout/checkout.zig");
const convert = @import("../checkout/convert.zig");
const driver_mod = @import("driver.zig");

const Oid = hash.Oid;

/// Errors from running an external diff.
pub const Error = error{
    /// The program failed, or exited other than 0 (or 1 when its exit code
    /// is trusted): git's "external diff died".
    ExternalDiffFailed,
    /// `diff.external` with no value, or a `diff.trustExitCode` that is no
    /// boolean, both of which git dies on.
    InvalidDiffSetting,
    /// A filter would hand the blob over later, which a diff cannot wait
    /// for.
    DelayedContent,
} || program.Error || fs.TempFile.Error || fs.StatError || checkout.Error || convert.Error || odb_mod.Error || attributes.Error || Io.File.ReadStreamingError || Io.Writer.Error || Allocator.Error;

/// `diff.external` and `diff.trustExitCode`, the last of each deciding;
/// `null` with no `diff.external`. git takes `GIT_EXTERNAL_DIFF` (with
/// `GIT_EXTERNAL_DIFF_TRUST_EXIT_CODE`) over these; a caller that reads
/// the environment gives that instead.
pub fn configured(config: *const config_mod.Config) Self.Error!?driver_mod.Command {
    var command: ?[]const u8 = null;
    var trust = false;
    var it = config.iterate(&.{ "diff.external", "diff.trustexitcode" });
    while (it.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, "external")) {
            command = entry.value orelse return error.InvalidDiffSetting;
        } else {
            trust = if (entry.value) |v| config_mod.parseBool(v) catch return error.InvalidDiffSetting else true;
        }
    }
    return .{ .command = command orelse return null, .trust_exit_code = trust };
}

/// What runs the programs: `git diff --ext-diff`, which `git diff` has by
/// default. A file whose path names a driver with a `command` is given to
/// it; any other to `command`, where there is one.
pub const External = struct {
    programs: program.Programs,
    command: ?driver_mod.Command = null,
    /// The working tree the programs run in and blobs are written out for;
    /// `null` runs them where the process runs, each blob as it is.
    worktree: ?Worktree = null,
};

/// A working tree as an external diff uses it.
pub const Worktree = struct {
    dir: Io.Dir,
    /// How a blob is written out: as a checkout writes it.
    conv: *convert.Session,
    /// The index and the files it vouches for, where the diff read the
    /// index -- `git diff --cached`, `git diff <commit>`: a side the index
    /// holds and the working tree still has is lent rather than written
    /// out. git reads no index for a diff of two trees, and lends nothing
    /// there; `null` is that.
    lends: ?checkout.Tracked = null,
};

/// One run of the program, for one file pair.
pub const Run = struct {
    command: driver_mod.Command,
    /// Where the sides' blobs are read.
    db: *odb_mod.Odb,
    /// The attributes a blob is written out by.
    attrs: ?*attributes.Attrs = null,
    /// The path the pair is named by, and for a rename or a copy the other.
    name: []const u8,
    other: ?[]const u8 = null,
    /// The metadata lines for a rename or a copy.
    metainfo: ?[]const u8 = null,
    /// The sides as the repository has them. Neither, for an unmerged
    /// path: the program is given its name alone, as git gives it.
    old: ?Side,
    new: ?Side,
    /// Which pair of how many in the diff, from one.
    counter: usize,
    total: usize,
};

/// A side: its path in the repository, its object and mode.
pub const Side = struct { path: []const u8, oid: Oid, mode: object.Mode };

/// Run `run.command` for one pair, its output appended to `w`.
pub fn run(ext: *const External, gpa: Allocator, io: Io, spec: Run, w: *Io.Writer) Self.Error!void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var prepared: [2]Prepared = undefined;
    var made: usize = 0;
    defer for (prepared[0..made]) |*p| if (p.temp) |*t| t.remove(io);
    for ([_]?Side{ spec.old, spec.new }, &prepared) |side, *p| {
        p.* = try prepare(ext, a, io, spec, side);
        made += 1;
    }
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ spec.command.command, spec.name });
    if (spec.old != null or spec.new != null) for (prepared) |p| try argv.appendSlice(a, &.{ p.name, p.hex, p.mode });
    if (spec.other) |other| {
        try argv.append(a, other);
        if (spec.metainfo) |m| try argv.append(a, m);
    }
    const set = [_]program.Var{
        .{ .name = "GIT_DIFF_PATH_COUNTER", .value = try a.print("{d}", .{spec.counter}) },
        .{ .name = "GIT_DIFF_PATH_TOTAL", .value = try a.print("{d}", .{spec.total}) },
    };
    var outcome = try program.run(gpa, io, ext.programs, .{
        .argv = argv.items,
        .shell = true,
        .cwd = if (ext.worktree) |wt| .{ .dir = wt.dir } else .inherit,
        .set = &set,
        .stderr = .inherit,
    }, .{});
    defer outcome.deinit(gpa);
    try w.writeAll(outcome.stdout);
    const code: ?u32 = switch (outcome.term) {
        .exited => |c| c,
        else => null,
    };
    const fine = code == 0 or (spec.command.trust_exit_code and code == 1);
    if (!fine) return error.ExternalDiffFailed;
}

/// A side as the program is given it: a file's name, its object, its mode.
const Prepared = struct {
    name: []const u8,
    hex: []const u8,
    mode: []const u8,
    temp: ?fs.TempFile = null,
};

/// git's `prepare_temp_file`.
fn prepare(ext: *const External, a: Allocator, io: Io, spec: Run, side: ?Side) Self.Error!Prepared {
    const s = side orelse return .{ .name = "/dev/null", .hex = ".", .mode = "." };
    var hex_buf: [hash.max_hex_len]u8 = undefined;
    const hex = try a.dupe(u8, s.oid.hex(&hex_buf));
    var mode_buf: [6]u8 = undefined;
    const mode = try a.print("{s:0>6}", .{s.mode.text(&mode_buf)});
    if (s.mode != .gitlink and try lends(ext, a, io, s)) return .{ .name = s.path, .hex = hex, .mode = mode };
    const bytes = try blobBytes(ext, a, io, spec, s);
    const temp = try fs.TempFile.create(a, io, ext.programs.environ, .{ .prefix = "git-blob-", .suffix = std.Io.Dir.path.basenamePosix(s.path), .directory = true }, bytes);
    return .{ .name = temp.path, .hex = hex, .mode = mode, .temp = temp };
}

/// git's `reuse_worktree_file`: whether the working tree's file at the
/// side's path is the index's, a regular file holding the side's object,
/// neither assumed unchanged nor outside the sparse checkout, and its stat
/// (or, where that cannot vouch, its content) matching the entry.
fn lends(ext: *const External, a: Allocator, io: Io, s: Side) Self.Error!bool {
    const wt = ext.worktree orelse return false;
    const t = wt.lends orelse return false;
    const entry = t.index.find(s.path) orelse return false;
    if (!entry.oid.eql(s.oid) or (entry.mode != .file and entry.mode != .exec)) return false;
    if (entry.assume_valid or entry.skip_worktree) return false;
    const found = (try fs.statAt(io, t.wt, s.path)) orelse return false;
    if (t.rules.attrs) |attrs| try attrs.enter(io, t.wt, s.path);
    return t.matches(a, entry.*, s.path, found);
}

/// The side's blob as a checkout writes it (git's `prep_temp_blob`, which
/// converts it for the working tree), a gitlink as its `Subproject commit`
/// line.
fn blobBytes(ext: *const External, a: Allocator, io: Io, spec: Run, s: Side) Self.Error![]const u8 {
    var hex_buf: [hash.max_hex_len]u8 = undefined;
    if (s.mode == .gitlink) return a.print("Subproject commit {s}\n", .{s.oid.hex(&hex_buf)});
    const found = try spec.db.read(io, s.oid);
    defer spec.db.allocator().free(found.bytes);
    const blob = try a.dupe(u8, found.bytes);
    const wt = ext.worktree orelse return blob;
    const attrs = spec.attrs orelse return blob;
    try attrs.enter(io, wt.dir, s.path);
    const applied = try attrs.lookup(a, s.path, .file);
    const content = try wt.conv.toWorktree(a, .{ .path = s.path, .blob = blob, .applied = applied }, .{ .blob = s.oid });
    return switch (content) {
        .bytes => |b| b,
        .file => |file| blk: {
            defer file.close(io);
            var buf: [4096]u8 = undefined;
            var reader = file.readerStreaming(io, &buf);
            break :blk try reader.interface.allocRemaining(a, .unlimited);
        },
        .delayed => error.DelayedContent,
    };
}
