//! Reusing recorded resolutions: `git rerere`, as the commands that stop on
//! a conflict run it.
//!
//! When a merge, cherry-pick, revert or rebase stops with a text conflict,
//! the conflict is taken down in `.git/rr-cache/<id>/preimage`: the file
//! with its markers stripped to the bare `<<<<<<<`, `=======` and
//! `>>>>>>>`, the base's lines of a `diff3` conflict dropped, and each
//! conflict's two sides put in byte order, so that the same conflict met
//! from either side has the same name -- the hash of each conflict's two
//! sides, NUL after each. When the conflict is resolved and committed, the
//! file as it was committed is kept beside it as `postimage`. The next time
//! a conflict of that name comes up, the change from the preimage to the
//! postimage is merged into it; if that goes cleanly the file is written
//! resolved, and with `rerere.autoUpdate` staged. `MERGE_RR` lists the
//! paths in play, one `<id>\t<path>` and a NUL each. All of it is git's
//! format, byte for byte, so git and this read each other's records.
//!
//! It runs when `rerere.enabled` says so, or when that is unset and
//! `.git/rr-cache` is there, as with git.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const object = @import("object.zig");
const index_mod = @import("index.zig");
const repo_mod = @import("repo.zig");
const worktree = @import("worktree.zig");
const attributes = @import("attributes.zig");
const blobmerge = @import("blobmerge.zig");
const fs = @import("fs.zig");
const head_mod = @import("head.zig");

const Oid = hash.Oid;
const Index = index_mod.Index;
const Repository = repo_mod.Repository;

/// Errors from reusing resolutions.
pub const Error = error{
    /// `MERGE_RR` does not say what git writes there.
    MalformedMergeRr,
    /// The repository has no working tree.
    BareRepository,
} || Allocator.Error || head_mod.Error || odb_errors || worktree.Error || repo_mod.Error || index_mod.WriteError || index_mod.ReadError;

const odb_errors = @import("odb.zig").Error;

/// How a run goes.
pub const Options = struct {
    /// Stage a file a recorded resolution resolved: `--rerere-autoupdate`
    /// when `true`, `--no-rerere-autoupdate` when `false`, and
    /// `rerere.autoUpdate` when `null`.
    autoupdate: ?bool = null,
};

/// What a run did, path by path, as git reports it.
pub const Outcome = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator.State,
    /// "Recorded preimage for '<path>'".
    recorded_preimage: []const []const u8 = &.{},
    /// "Recorded resolution for '<path>'.".
    recorded_resolution: []const []const u8 = &.{},
    /// "Resolved '<path>' using previous resolution.".
    resolved: []const []const u8 = &.{},
    /// "Staged '<path>' using previous resolution.".
    staged: []const []const u8 = &.{},

    /// Release the lists.
    pub fn deinit(o: *Outcome) void {
        var arena = o.arena.promote(o.gpa);
        arena.deinit();
        o.* = undefined;
    }
};

/// Whether rerere runs here: `rerere.enabled`, or, unset, whether
/// `.git/rr-cache` is there.
pub fn enabled(io: Io, repo: *Repository) bool {
    const setting = repo.config.getBool("rerere.enabled", false) catch null;
    if (repo.config.get("rerere.enabled") == null) return head_mod.stateExists(io, repo.common_dir, "rr-cache");
    return setting orelse false;
}

const has_postimage: u8 = 1;
const has_preimage: u8 = 2;

const Id = struct {
    hex: []const u8,
    variant: i32 = -1,
};

const Run = struct {
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    repo: *Repository,
    wt: Io.Dir,
    rules: worktree.Rules,
    /// Per conflict name, which variants have a preimage and a postimage.
    dirs: std.StringHashMapUnmanaged(std.ArrayList(u8)) = .empty,

    fn cache(r: *Run) Error!Io.Dir {
        return r.repo.common_dir.openDir(r.io, "rr-cache", .{}) catch |err| switch (err) {
            error.FileNotFound => {
                r.repo.common_dir.createDirPath(r.io, "rr-cache") catch {};
                return r.repo.common_dir.openDir(r.io, "rr-cache", .{ .iterate = true }) catch |e| return e;
            },
            else => |e| return e,
        };
    }

    fn pathOf(r: *Run, id: Id, file: []const u8) Allocator.Error![]const u8 {
        if (id.variant <= 0) return std.fmt.allocPrint(r.arena, "rr-cache/{s}/{s}", .{ id.hex, file });
        return std.fmt.allocPrint(r.arena, "rr-cache/{s}/{s}.{d}", .{ id.hex, file, id.variant });
    }

    /// `find_rerere_dir` and `scan_rerere_dir`.
    fn status(r: *Run, hex: []const u8) Error!*std.ArrayList(u8) {
        const slot = try r.dirs.getOrPut(r.arena, hex);
        if (slot.found_existing) return slot.value_ptr;
        slot.key_ptr.* = try r.arena.dupe(u8, hex);
        slot.value_ptr.* = .empty;
        const sub = try std.fmt.allocPrint(r.arena, "rr-cache/{s}", .{hex});
        var dir = r.repo.common_dir.openDir(r.io, sub, .{ .iterate = true }) catch return slot.value_ptr;
        defer dir.close(r.io);
        var it = dir.iterate();
        while (try it.next(r.io)) |entry| {
            if (variantOf(entry.name, "postimage")) |v| {
                try fit(r.arena, slot.value_ptr, v);
                slot.value_ptr.items[@intCast(v)] |= has_postimage;
            } else if (variantOf(entry.name, "preimage")) |v| {
                try fit(r.arena, slot.value_ptr, v);
                slot.value_ptr.items[@intCast(v)] |= has_preimage;
            }
        }
        return slot.value_ptr;
    }

    fn readFile(r: *Run, sub: []const u8) ?[]u8 {
        return head_mod.readState(r.arena, r.io, r.repo.common_dir, sub) catch null;
    }

    fn writeFile(r: *Run, sub: []const u8, bytes: []const u8) Error!void {
        try head_mod.writeState(r.io, r.repo.common_dir, sub, bytes);
    }

    fn removeFile(r: *Run, sub: []const u8) Error!void {
        try head_mod.removeState(r.io, r.repo.common_dir, sub);
    }

    fn markerSize(r: *Run, path: []const u8) Error!usize {
        const attrs = r.rules.attrs orelse return 7;
        const applied = try attrs.lookup(r.arena, path, false);
        if (applied.value("conflict-marker-size")) |text| {
            if (std.fmt.parseInt(i32, text, 10)) |size| {
                if (size > 0) return @intCast(size);
            } else |_| {}
        }
        return 7;
    }
};

/// The variant a file in a conflict's directory is: `name` itself is 0,
/// `name.<n>` is n.
fn variantOf(file: []const u8, name: []const u8) ?i32 {
    if (std.mem.eql(u8, file, name)) return 0;
    if (!std.mem.startsWith(u8, file, name) or file.len <= name.len + 1 or file[name.len] != '.') return null;
    return std.fmt.parseInt(i32, file[name.len + 1 ..], 10) catch null;
}

fn fit(arena: Allocator, list: *std.ArrayList(u8), variant: i32) Allocator.Error!void {
    const want: usize = @intCast(variant + 1);
    while (list.items.len < want) try list.append(arena, 0);
}

/// `is_cmarker`: exactly `size` of `c`, then whitespace -- a space for `<`
/// and `>`, whose markers always carry a label.
fn isMarker(line: []const u8, c: u8, size: usize) bool {
    if (line.len < size) return false;
    for (line[0..size]) |b| {
        if (b != c) return false;
    }
    if (line.len == size) return false;
    const next = line[size];
    if ((c == '<' or c == '>') and next != ' ') return false;
    return next == ' ' or next == '\t' or next == '\n' or next == '\r' or next == 0x0b or next == 0x0c;
}

/// The lines of `bytes`, each with its newline.
const Lines = struct {
    bytes: []const u8,
    at: usize = 0,

    fn next(l: *Lines) ?[]const u8 {
        if (l.at >= l.bytes.len) return null;
        const end = if (std.mem.indexOfScalarPos(u8, l.bytes, l.at, '\n')) |nl| nl + 1 else l.bytes.len;
        const line = l.bytes[l.at..end];
        l.at = end;
        return line;
    }
};

/// What `handle_path` makes of a file: whether it has conflicts, its
/// normalized form, and its conflict name.
const Normalized = struct {
    conflicts: i8,
    text: []const u8,
    id: ?[]const u8,
};

/// `handle_conflict`: one conflict, from after its `<` marker, into `out`.
fn handleConflict(arena: Allocator, out: *std.ArrayList(u8), lines: *Lines, size: usize, hasher: ?*hash.Hasher) Allocator.Error!i8 {
    var one: std.ArrayList(u8) = .empty;
    var two: std.ArrayList(u8) = .empty;
    const Hunk = enum { side1, side2, original };
    var hunk: Hunk = .side1;
    while (lines.next()) |line| {
        if (isMarker(line, '<', size)) {
            var nested: std.ArrayList(u8) = .empty;
            if (try handleConflict(arena, &nested, lines, size, null) < 0) break;
            if (hunk == .side1) try one.appendSlice(arena, nested.items) else try two.appendSlice(arena, nested.items);
        } else if (isMarker(line, '|', size)) {
            if (hunk != .side1) break;
            hunk = .original;
        } else if (isMarker(line, '=', size)) {
            if (hunk != .side1 and hunk != .original) break;
            hunk = .side2;
        } else if (isMarker(line, '>', size)) {
            if (hunk != .side2) break;
            if (std.mem.order(u8, one.items, two.items) == .gt) std.mem.swap(std.ArrayList(u8), &one, &two);
            try putMarker(arena, out, '<', size);
            try out.appendSlice(arena, one.items);
            try putMarker(arena, out, '=', size);
            try out.appendSlice(arena, two.items);
            try putMarker(arena, out, '>', size);
            if (hasher) |h| {
                h.update(one.items);
                h.update(&.{0});
                h.update(two.items);
                h.update(&.{0});
            }
            return 1;
        } else switch (hunk) {
            .side1 => try one.appendSlice(arena, line),
            .original => {},
            .side2 => try two.appendSlice(arena, line),
        }
    }
    return -1;
}

fn putMarker(arena: Allocator, out: *std.ArrayList(u8), c: u8, size: usize) Allocator.Error!void {
    for (0..size) |_| try out.append(arena, c);
    try out.append(arena, '\n');
}

/// `handle_path`.
fn normalize(arena: Allocator, bytes: []const u8, size: usize, kind: hash.Kind) Allocator.Error!Normalized {
    var hasher: hash.Hasher = .init(kind);
    var out: std.ArrayList(u8) = .empty;
    var lines: Lines = .{ .bytes = bytes };
    var conflicts: i8 = 0;
    while (lines.next()) |line| {
        if (isMarker(line, '<', size)) {
            var chunk: std.ArrayList(u8) = .empty;
            conflicts = try handleConflict(arena, &chunk, &lines, size, &hasher);
            if (conflicts < 0) break;
            try out.appendSlice(arena, chunk.items);
        } else try out.appendSlice(arena, line);
    }
    var id: ?[]const u8 = null;
    if (conflicts > 0) {
        var buf: [hash.max_hex_len]u8 = undefined;
        id = try arena.dupe(u8, hasher.final().hex(&buf));
    }
    return .{ .conflicts = conflicts, .text = out.items, .id = id };
}

/// `repo_rerere`: record the preimages of new text conflicts, replay a
/// recorded resolution where one merges cleanly, and record the
/// resolution of each path in `MERGE_RR` that is no longer conflicted.
/// `index` is the index as the conflict left it; a path a resolution is
/// staged for is changed in it, and the caller writes it. Nothing happens
/// when rerere is not enabled.
pub fn run(gpa: Allocator, io: Io, repo: *Repository, index: *Index, options: Options) Error!Outcome {
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var outcome: Outcome = .{ .gpa = gpa, .arena = undefined };
    if (!enabled(io, repo)) {
        outcome.arena = arena_instance.state;
        return outcome;
    }
    const wt = repo.work_dir orelse return error.BareRepository;
    // `rerere.enabled` true makes the directory.
    repo.common_dir.createDirPath(io, "rr-cache") catch {};

    var attrs = try repo.loadAttrs(io);
    defer attrs.deinit();
    var rules = repo.worktreeRules();
    rules.attrs = &attrs;
    var r: Run = .{ .gpa = gpa, .arena = arena, .io = io, .repo = repo, .wt = wt, .rules = rules };
    const autoupdate = options.autoupdate orelse (repo.config.getBool("rerere.autoupdate", false) catch false);

    // `read_rr`.
    var rr: std.StringArrayHashMapUnmanaged(?Id) = .empty;
    if (try head_mod.readState(arena, io, repo.git_dir, "MERGE_RR")) |text| {
        const hex_len = repo.kind.hexLen();
        var records = std.mem.splitScalar(u8, text, 0);
        while (records.next()) |record| {
            if (record.len == 0) continue;
            if (record.len < hex_len + 2) return error.MalformedMergeRr;
            const hex = record[0..hex_len];
            _ = Oid.parse(repo.kind, hex) catch return error.MalformedMergeRr;
            var rest = record[hex_len..];
            var variant: i32 = 0;
            if (rest[0] == '.') {
                const tab = std.mem.indexOfScalar(u8, rest, '\t') orelse return error.MalformedMergeRr;
                variant = std.fmt.parseInt(i32, rest[1..tab], 10) catch return error.MalformedMergeRr;
                rest = rest[tab..];
            }
            if (rest[0] != '\t') return error.MalformedMergeRr;
            const st = try r.status(hex);
            try fit(arena, st, variant);
            try rr.put(arena, try arena.dupe(u8, rest[1..]), .{ .hex = try arena.dupe(u8, hex), .variant = variant });
        }
    }

    // `find_conflict`: regular files at both stage 2 and stage 3.
    var conflicts: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    const entries = index.entries.items;
    while (i < entries.len) {
        const e = entries[i];
        if (e.stage == 0) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < entries.len and entries[j].stage == 1 and std.mem.eql(u8, entries[j].path, e.path)) j += 1;
        if (j + 1 < entries.len and entries[j].stage == 2 and entries[j + 1].stage == 3 and
            std.mem.eql(u8, entries[j + 1].path, e.path) and isReg(entries[j].mode) and isReg(entries[j + 1].mode))
        {
            try conflicts.append(arena, try arena.dupe(u8, e.path));
        }
        while (j < entries.len and std.mem.eql(u8, entries[j].path, e.path)) j += 1;
        i = j;
    }

    // `do_plain_rerere`.
    for (conflicts.items) |path| {
        const bytes = readWorktree(&r, path) orelse continue;
        const n = try normalize(arena, bytes, try r.markerSize(path), repo.kind);
        if (n.conflicts != 0) {
            if (rr.get(path)) |existing| {
                if (existing) |id| try removeVariant(&r, id);
                _ = rr.orderedRemove(path);
            }
        }
        if (n.conflicts < 1) continue;
        try rr.put(arena, path, .{ .hex = n.id.? });
        _ = try r.status(n.id.?);
        const sub = try std.fmt.allocPrint(arena, "rr-cache/{s}", .{n.id.?});
        repo.common_dir.createDirPath(io, sub) catch {};
    }
    // The list is git's `string_list`, sorted by path.
    const Sorter = struct {
        keys: []const []const u8,
        pub fn lessThan(s: @This(), a: usize, b: usize) bool {
            return std.mem.order(u8, s.keys[a], s.keys[b]) == .lt;
        }
    };
    rr.sort(Sorter{ .keys = rr.keys() });

    var recorded_preimage: std.ArrayList([]const u8) = .empty;
    var recorded_resolution: std.ArrayList([]const u8) = .empty;
    var resolved: std.ArrayList([]const u8) = .empty;
    var update: std.ArrayList([]const u8) = .empty;
    for (rr.keys(), rr.values()) |path, *slot| {
        const id = slot.* orelse continue;
        const outcome_kind = try oneAtPath(&r, path, id, autoupdate);
        switch (outcome_kind.kind) {
            .recorded_resolution => try recorded_resolution.append(arena, path),
            .resolved => try resolved.append(arena, path),
            .staged => try update.append(arena, path),
            .recorded_preimage => try recorded_preimage.append(arena, path),
            .none => {},
        }
        slot.* = outcome_kind.id;
    }
    for (update.items) |path| try stagePath(&r, index, path);

    // `write_rr`.
    var out: std.ArrayList(u8) = .empty;
    for (rr.keys(), rr.values()) |path, slot| {
        const id = slot orelse continue;
        if (id.variant > 0) {
            try out.print(arena, "{s}.{d}\t{s}", .{ id.hex, id.variant, path });
        } else try out.print(arena, "{s}\t{s}", .{ id.hex, path });
        try out.append(arena, 0);
    }
    try head_mod.writeState(io, repo.git_dir, "MERGE_RR", out.items);

    outcome.recorded_preimage = recorded_preimage.items;
    outcome.recorded_resolution = recorded_resolution.items;
    outcome.resolved = resolved.items;
    outcome.staged = update.items;
    outcome.arena = arena_instance.state;
    return outcome;
}

fn isReg(mode: object.Mode) bool {
    return mode == .file or mode == .exec;
}

fn readWorktree(r: *Run, path: []const u8) ?[]u8 {
    return r.wt.readFileAlloc(r.io, path, r.arena, .limited(1 << 30)) catch null;
}

fn removeVariant(r: *Run, id: Id) Error!void {
    try r.removeFile(try r.pathOf(id, "postimage"));
    try r.removeFile(try r.pathOf(id, "preimage"));
    const st = try r.status(id.hex);
    if (id.variant >= 0 and @as(usize, @intCast(id.variant)) < st.items.len) st.items[@intCast(id.variant)] = 0;
}

const OneKind = enum { none, recorded_resolution, resolved, staged, recorded_preimage };

/// `do_rerere_one_path`.
fn oneAtPath(r: *Run, path: []const u8, id_in: Id, autoupdate: bool) Error!struct { kind: OneKind, id: ?Id } {
    var id = id_in;
    const st = try r.status(id.hex);
    const size = try r.markerSize(path);

    // Resolved by hand already?
    if (id.variant >= 0) {
        if (readWorktree(r, path)) |bytes| {
            const n = try normalize(r.arena, bytes, size, r.repo.kind);
            if (n.conflicts == 0) {
                try r.writeFile(try r.pathOf(id, "postimage"), bytes);
                st.items[@intCast(id.variant)] |= has_postimage;
                return .{ .kind = .recorded_resolution, .id = null };
            }
        }
    }

    // Does a recorded resolution apply cleanly?
    var variant: i32 = 0;
    while (variant < st.items.len) : (variant += 1) {
        const both = has_preimage | has_postimage;
        if (st.items[@intCast(variant)] & both != both) continue;
        const vid: Id = .{ .hex = id.hex, .variant = variant };
        if (!try replay(r, vid, path, size)) continue;
        if (0 <= id.variant and id.variant != variant) try removeVariant(r, id);
        return .{ .kind = if (autoupdate) .staged else .resolved, .id = null };
    }

    // None does: a new variant, and its preimage.
    if (id.variant < 0) {
        var v: i32 = 0;
        while (v < st.items.len and st.items[@intCast(v)] != 0) v += 1;
        id.variant = v;
    }
    try fit(r.arena, st, id.variant);
    if (readWorktree(r, path)) |bytes| {
        const n = try normalize(r.arena, bytes, size, r.repo.kind);
        try r.writeFile(try r.pathOf(id, "preimage"), n.text);
    }
    if (st.items[@intCast(id.variant)] & has_postimage != 0) {
        try r.removeFile(try r.pathOf(id, "postimage"));
        st.items[@intCast(id.variant)] &= ~has_postimage;
    }
    st.items[@intCast(id.variant)] |= has_preimage;
    return .{ .kind = .recorded_preimage, .id = id };
}

/// `merge`: the change from `vid`'s preimage to its postimage, merged into
/// the conflict at `path`; the file is rewritten when that is clean.
fn replay(r: *Run, vid: Id, path: []const u8, size: usize) Error!bool {
    const bytes = readWorktree(r, path) orelse return false;
    const n = try normalize(r.arena, bytes, size, r.repo.kind);
    if (n.conflicts < 0) return false;
    try r.writeFile(try r.pathOf(vid, "thisimage"), n.text);
    const base = r.readFile(try r.pathOf(vid, "preimage")) orelse return false;
    const other = r.readFile(try r.pathOf(vid, "postimage")) orelse return false;
    // `ll_merge` with its defaults: the driver the attributes name, and
    // Myers.
    var favor: blobmerge.Favor = .none;
    if (r.rules.attrs) |attrs| {
        const applied = try attrs.lookup(r.arena, path, false);
        if (applied.get("merge")) |state| switch (state) {
            .unset => return false,
            .value => |name| {
                if (std.mem.eql(u8, name, "binary")) return false;
                if (std.mem.eql(u8, name, "union")) favor = .union_;
            },
            else => {},
        };
    }
    var merged = blobmerge.blobs(r.arena, base, n.text, other, .{ .labels = .{ .ours = "", .base = "", .theirs = "" }, .marker_size = @intCast(@min(size, 255)), .favor = favor }) catch |err| switch (err) {
        error.BinaryBlob => return false,
        error.OutOfMemory => return error.OutOfMemory,
    };
    if (!merged.isClean()) return false;
    try fs.atomicWrite(r.io, r.wt, path, merged.bytes, ".relic-rerere-", .none);
    return true;
}

/// `add_file_to_index`: the file as it is now, at stage 0.
fn stagePath(r: *Run, index: *Index, path: []const u8) Error!void {
    const bytes = readWorktree(r, path) orelse return;
    var mode: object.Mode = .file;
    if (index.findStage(path, 2)) |ours| mode = ours.mode;
    var content: []const u8 = bytes;
    if (r.rules.attrs) |attrs| {
        const applied = try attrs.lookup(r.arena, path, false);
        content = (try attributes.toGit(r.arena, bytes, applied, r.rules.core)).bytes;
    }
    const oid = try r.repo.odb.write(r.io, .blob, content);
    const found = try fs.statAt(r.io, r.wt, path);
    _ = index.remove(path);
    try index.add(.{ .path = path, .oid = oid, .mode = mode, .stat = if (found) |f| f.stat else .none });
    const tree = try index.cacheTree();
    tree.invalidate(path);
}

/// `rerere_clear`: forget the conflicts in play that have no resolution,
/// and `MERGE_RR` -- what an aborted rebase does.
pub fn clear(gpa: Allocator, io: Io, repo: *Repository) Error!void {
    if (!enabled(io, repo)) return;
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var r: Run = .{ .gpa = gpa, .arena = arena, .io = io, .repo = repo, .wt = repo.work_dir orelse return error.BareRepository, .rules = .{} };
    if (try head_mod.readState(arena, io, repo.git_dir, "MERGE_RR")) |text| {
        const hex_len = repo.kind.hexLen();
        var records = std.mem.splitScalar(u8, text, 0);
        while (records.next()) |record| {
            if (record.len < hex_len + 2) continue;
            const hex = record[0..hex_len];
            var variant: i32 = 0;
            if (record[hex_len] == '.') {
                const tab = std.mem.indexOfScalarPos(u8, record, hex_len, '\t') orelse continue;
                variant = std.fmt.parseInt(i32, record[hex_len + 1 .. tab], 10) catch continue;
            }
            const st = try r.status(hex);
            try fit(arena, st, variant);
            const both = has_preimage | has_postimage;
            if (st.items[@intCast(variant)] & both == both) continue;
            // `unlink_rr_item`: this variant's files, then the directory
            // if nothing else is in it.
            const id: Id = .{ .hex = hex, .variant = variant };
            try r.removeFile(try r.pathOf(id, "thisimage"));
            try r.removeFile(try r.pathOf(id, "preimage"));
            try r.removeFile(try r.pathOf(id, "postimage"));
            const sub = try std.fmt.allocPrint(arena, "rr-cache/{s}", .{hex});
            repo.common_dir.deleteDir(io, sub) catch {};
        }
    }
    try head_mod.removeState(io, repo.git_dir, "MERGE_RR");
}

/// What `git commit` does to a stop's files once the commit that ends it
/// is made: `MERGE_HEAD`, `MERGE_MSG`, `MERGE_MODE`, `SQUASH_MSG` and
/// `AUTO_MERGE` go, and rerere records how each conflict it took down was
/// resolved.
pub fn afterCommit(gpa: Allocator, io: Io, repo: *Repository) Error!void {
    for ([_][]const u8{ "MERGE_HEAD", "MERGE_MSG", "MERGE_MODE", "SQUASH_MSG" }) |name| {
        try head_mod.removeState(io, repo.git_dir, name);
    }
    try head_mod.deleteRef(io, repo, "AUTO_MERGE");
    var index = try repo.openIndex(io);
    defer index.deinit();
    var outcome = try run(gpa, io, repo, &index, .{ .autoupdate = false });
    outcome.deinit();
}

/// Run rerere on a stop, as git does once a merge has left conflicts,
/// writing the index again when it staged a resolution. The paths it
/// resolved come back in `arena`.
pub fn afterStop(gpa: Allocator, io: Io, repo: *Repository, index: *Index, arena: Allocator, autoupdate: ?bool) Error![]const []const u8 {
    var outcome = try run(gpa, io, repo, index, .{ .autoupdate = autoupdate });
    defer outcome.deinit();
    if (outcome.staged.len != 0) try index.write(io, repo.git_dir, "index", .{});
    var reused: std.ArrayList([]const u8) = .empty;
    for (outcome.resolved) |p| try reused.append(arena, try arena.dupe(u8, p));
    for (outcome.staged) |p| try reused.append(arena, try arena.dupe(u8, p));
    return reused.items;
}

//=========================================================================
// Tests
//=========================================================================

test "a conflict is named and normalized as git's rerere names it, whichever side it is met from" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const ours_first = "top\n<<<<<<< HEAD\nmine\n||||||| base\nold\n=======\nyours\n>>>>>>> topic\nend\n";
    const theirs_first = "top\n<<<<<<< topic\nyours\n=======\nmine\n>>>>>>> HEAD\nend\n";
    const one = try normalize(a, ours_first, 7, .sha1);
    const two = try normalize(a, theirs_first, 7, .sha1);
    try std.testing.expectEqual(@as(i8, 1), one.conflicts);
    try std.testing.expectEqualStrings(one.id.?, two.id.?);
    try std.testing.expectEqualStrings("top\n<<<<<<<\nmine\n=======\nyours\n>>>>>>>\nend\n", one.text);
    try std.testing.expectEqualStrings(one.text, two.text);
    const clean = try normalize(a, "no markers here\n<<<<<<<< eight\n", 7, .sha1);
    try std.testing.expectEqual(@as(i8, 0), clean.conflicts);
}

test "fuzz: any bytes normalize or are a named failure" {
    try std.testing.fuzz({}, fuzzNormalize, .{});
}

fn fuzzNormalize(_: void, smith: *std.testing.Smith) anyerror!void {
    var input: [512]u8 = undefined;
    const text = input[0..smith.slice(&input)];
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    _ = try normalize(arena.allocator(), text, 7, .sha1);
}
