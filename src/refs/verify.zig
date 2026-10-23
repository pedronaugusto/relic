//! git's `refs verify` over one worktree's store: what is wrong with the
//! refs themselves, each named by its `fsck.<msg-id>` and reported at the
//! level the rules give it.
//!
//! A listing passes over a loose ref it cannot read (`Listing.broken`), and
//! a read takes an object name with anything after it; this says what each
//! of those is, as `files_fsck_refs_content`, `packed_fsck` and
//! `reftable_be_fsck` say it: content that is no ref, a missing newline or
//! trailing content, a name no ref may have, a file that is neither a ref
//! nor a link, a symbolic ref pointing where none may, `packed-refs`
//! lines, and reftable table names.

const ErrorNamespace = @This();
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const fs = @import("../fs/fs.zig");
const ctype = @import("../text.zig").ctype;
const decimal = @import("../text.zig").decimal;
const names = @import("../names.zig").ref;
const fsck = @import("../object/fsck.zig");
const refs = @import("refs.zig");
const stack_engine = @import("reftable/stack/transaction.zig");

const Kind = hash.Kind;
const Oid = hash.Oid;

/// Errors from verifying, apart from what is found: a directory or file
/// that could not be read for a reason other than its absence.
pub const Error = refs.ReadError || Io.Dir.RealPathFileAllocError || Io.Dir.StatFileError;

/// What one check found.
pub const Finding = struct {
    /// What git names in its message: the ref (`refs/heads/x`, with
    /// `worktrees/<id>/` before a linked worktree's), `packed-refs`,
    /// `packed-refs.header`, `packed-refs line <n>`, or a reftable table.
    path: []const u8,
    problem: fsck.Problem,
    /// `error` or `warn`: the level the rules give the problem, a fatal one
    /// an error and information a warning, as git reports them.
    level: fsck.Level,
    /// git's words after the message id.
    text: []const u8,

    /// git's line: `<path>: <msg-id>: <text>`, which it prints after
    /// `error: ` or `warning: `.
    pub fn format(f: Finding, w: *Io.Writer) Io.Writer.Error!void {
        try w.print("{s}: {s}: {s}", .{ f.path, f.problem.id(), f.text });
    }
};

/// Everything found, in the order git checks: the loose refs by name, the
/// root refs, then `packed-refs`, or the reftable stack's tables and refs.
pub const Report = struct {
    pub const Error = ErrorNamespace.Error;

    arena: std.heap.ArenaAllocator,
    findings: []const Finding,

    pub fn deinit(report: *Report) void {
        report.arena.deinit();
        report.* = undefined;
    }

    /// Whether anything was found at the error level, which makes git's
    /// `refs verify` fail.
    pub fn failed(report: *const Report) bool {
        for (report.findings) |f| if (f.level == .@"error") return true;
        return false;
    }
};

/// How to verify.
pub const Options = struct {
    /// The levels: `fsck.<msg-id>` read with `fsck.Rules.load`, and
    /// `strict` for `--strict`.
    rules: *const fsck.Rules,
    /// The linked worktree the store is, by its id, whose names git reports
    /// under `worktrees/<id>/`; `null` for the main worktree, the only one
    /// `packed-refs` is checked for.
    worktree: ?[]const u8 = null,
};

/// The most a loose ref file is read to: no ref comes near it.
const max_ref_file = 1 << 20;

const Checker = struct {
    a: Allocator,
    io: Io,
    store: *const refs.Store,
    options: Options,
    found: std.ArrayList(Finding) = .empty,

    /// Report a problem at its level; whether that is an error, after
    /// which git checks no further in the same place.
    fn report(c: *Checker, path: []const u8, problem: fsck.Problem, comptime fmt: []const u8, args: anytype) Allocator.Error!bool {
        const level: fsck.Level = switch (c.options.rules.level(problem)) {
            .ignore => return false,
            .fatal, .@"error" => .@"error",
            .warn, .info => .warn,
        };
        try c.found.append(c.a, .{ .path = path, .problem = problem, .level = level, .text = try c.a.print(fmt, args) });
        return level == .@"error";
    }

    fn reported(c: *Checker, path: []const u8, problem: fsck.Problem, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        _ = try c.report(path, problem, fmt, args);
    }

    fn named(c: *Checker, name: []const u8) Allocator.Error![]const u8 {
        const id = c.options.worktree orelse return name;
        return c.a.print("worktrees/{s}/{s}", .{ id, name });
    }

    /// `refs_fsck_ref`: an object name may not be the null one.
    fn direct(c: *Checker, path: []const u8, oid: Oid) Allocator.Error!void {
        if (!oid.isZero()) return;
        var hex: [hash.max_hex_len]u8 = undefined;
        _ = try c.report(path, .bad_ref_oid, "points to invalid object ID '{s}'", .{oid.hex(&hex)});
    }

    /// `refs_fsck_symref`: where a symbolic ref may point.
    fn symbolic(c: *Checker, path: []const u8, name: []const u8, target: []const u8) Allocator.Error!void {
        if (std.mem.eql(u8, stripWorktree(name), "HEAD") and !std.mem.startsWith(u8, target, "refs/heads/")) {
            if (try c.report(path, .bad_head_target, "HEAD points to non-branch '{s}'", .{target})) return;
        }
        if (names.isRootRef(target)) return;
        if (!names.checkFormat(target, .{})) {
            if (try c.report(path, .bad_referent_name, "points to invalid refname '{s}'", .{target})) return;
        }
        if (!std.mem.startsWith(u8, target, "refs/") and !std.mem.startsWith(u8, target, "worktrees/")) {
            _ = try c.report(path, .symref_target_is_not_a_ref, "points to non-ref target '{s}'", .{target});
        }
    }

    /// `files_fsck_symref_target`: the newline a symbolic ref's file ends
    /// with, then where it points.
    fn symrefTarget(c: *Checker, path: []const u8, name: []const u8, referent: []const u8, from_link: bool) Allocator.Error!void {
        var target = referent;
        if (!from_link and referent.len > 0) {
            target = std.mem.trimEnd(u8, referent, ctype.space);
            if (target.len == referent.len or (target.len < referent.len and referent[referent.len - 1] != '\n'))
                _ = try c.report(path, .ref_missing_newline, "misses LF at the end", .{});
            if (target.len != referent.len and target.len != referent.len - 1)
                _ = try c.report(path, .trailing_ref_content, "has trailing whitespaces or newlines", .{});
        }
        try c.symbolic(path, name, target);
    }

    /// `files_fsck_ref`: one file under `dir`, at `sub` there, named `name`.
    fn loose(c: *Checker, dir: Io.Dir, sub: []const u8, name: []const u8, kind: Io.File.Kind) Error!void {
        const path = try c.named(name);
        if (kind != .file and kind != .sym_link) return c.reported(path, .bad_ref_filetype, "unexpected file type", .{});
        // `files_fsck_refs_name`
        if (!names.isRootRef(name) and !names.checkFormat(name, .{})) _ = try c.report(path, .bad_ref_name, "invalid refname format", .{});
        // `files_fsck_refs_content`
        if (kind == .sym_link) {
            _ = try c.report(path, .symlink_ref, "use deprecated symbolic link for symref", .{});
            const real = fs.realPathAlloc(c.a, c.io, dir, sub) catch |err| switch (err) {
                error.FileNotFound => return,
                error.OutOfMemory => return error.OutOfMemory,
                else => |e| return e,
            };
            const git_dir = fs.realPathAlloc(c.a, c.io, c.store.gitDir(), ".") catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => |e| return e,
            };
            var referent: []const u8 = real;
            if (std.mem.startsWith(u8, real, git_dir) and real.len > git_dir.len and std.fs.path.isSep(real[git_dir.len]))
                referent = real[git_dir.len + 1 ..];
            return c.symrefTarget(path, name, referent, true);
        }
        // a file another process removed meanwhile is passed over, as git passes it
        const bytes = (try fs.readFileAlloc(c.a, c.io, dir, sub, max_ref_file)) orelse return;
        switch (parseContents(c.store.objectFormat(), bytes)) {
            .broken => _ = try c.report(path, .bad_ref_content, "{s}", .{std.mem.trimEnd(u8, bytes, ctype.space)}),
            .symbolic => |referent| try c.symrefTarget(path, name, referent, false),
            .direct => |d| {
                if (d.trailing.len == 0) return c.reported(path, .ref_missing_newline, "misses LF at the end", .{});
                if (d.trailing[0] != '\n' or d.trailing.len > 1)
                    return c.reported(path, .trailing_ref_content, "has trailing garbage: '{s}'", .{d.trailing});
                try c.direct(path, d.oid);
            },
        }
    }

    /// `files_fsck_refs_dir`: every file under `<git dir>/refs`, in name
    /// order, but a lock file.
    fn looseRefs(c: *Checker) Error!void {
        var refs_dir = c.store.gitDir().openDir(c.io, "refs", .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => |e| return e,
        };
        defer refs_dir.close(c.io);
        const Item = struct { sub: []const u8, kind: Io.File.Kind };
        var items: std.ArrayList(Item) = .empty;
        // The directories left to read, by their paths under `refs`; names
        // as git's `readdir` gives them, composed under
        // `core.precomposeUnicode` on macOS.
        var pending: std.ArrayList([]const u8) = .empty;
        try pending.append(c.a, "");
        while (pending.pop()) |sub_dir| {
            var dir = if (sub_dir.len == 0) refs_dir else refs_dir.openDir(c.io, sub_dir, .{ .iterate = true }) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => continue,
                else => |e| return e,
            };
            defer if (sub_dir.len != 0) dir.close(c.io);
            var it: fs.Names = .init(dir, c.store.precomposeUnicode());
            while (try it.next(c.io)) |entry| {
                const sub = if (sub_dir.len == 0) try c.a.dupe(u8, entry.name) else try c.a.print("{s}/{s}", .{ sub_dir, entry.name });
                if (entry.kind == .directory) {
                    try pending.append(c.a, sub);
                    continue;
                }
                // a name ending `.lock` is a lock unless it starts with a dot
                if (entry.name.len > 0 and entry.name[0] != '.' and std.mem.endsWith(u8, entry.name, ".lock")) continue;
                try items.append(c.a, .{ .sub = sub, .kind = entry.kind });
            }
        }
        std.mem.sort(Item, items.items, {}, struct {
            fn lessThan(_: void, x: Item, y: Item) bool {
                return std.mem.order(u8, x.sub, y.sub) == .lt;
            }
        }.lessThan);
        for (items.items) |item| {
            const name = try c.a.print("refs/{s}", .{item.sub});
            try c.loose(c.store.gitDir(), name, name, item.kind);
        }
    }

    /// `for_each_root_ref` with `files_fsck_root_ref`: the root refs in
    /// the git directory, in the order the directory gives them, until one
    /// is found in error, after which git looks at no more of them.
    fn rootRefs(c: *Checker) Error!void {
        var it = c.store.gitDir().iterate();
        while (try it.next(c.io)) |entry| {
            if (entry.name.len == 0 or entry.name[0] == '.' or std.mem.endsWith(u8, entry.name, ".lock")) continue;
            if (!names.isRootRef(entry.name)) continue;
            const st = c.store.gitDir().statFile(c.io, entry.name, .{ .follow_symlinks = true }) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => |e| return e,
            };
            if (st.kind != .file) continue;
            const name = try c.a.dupe(u8, entry.name);
            const errors_before = c.errorCount();
            try c.loose(c.store.gitDir(), name, name, st.kind);
            if (c.errorCount() != errors_before) return;
        }
    }

    /// `packed_fsck`.
    fn packedRefs(c: *Checker) Error!void {
        const dir = c.store.commonDir();
        const st = dir.statFile(c.io, "packed-refs", .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => |e| return e,
        };
        if (st.kind == .sym_link) return c.reported("packed-refs", .bad_ref_filetype, "not a regular file but a symlink", .{});
        if (st.kind != .file) return c.reported("packed-refs", .bad_ref_filetype, "not a regular file", .{});
        const bytes = (try fs.readFileAlloc(c.a, c.io, dir, "packed-refs", std.math.maxInt(u32))) orelse return;
        if (bytes.len == 0) return c.reported("packed-refs", .empty_packed_refs_file, "file is empty", .{});
        const errors_before = c.errorCount();
        const sorted = try c.packedContent(bytes);
        if (sorted and c.errorCount() == errors_before) try c.packedSorted(bytes);
    }

    fn errorCount(c: *const Checker) usize {
        var n: usize = 0;
        for (c.found.items) |f| n += @intFromBool(f.level == .@"error");
        return n;
    }

    fn lineName(c: *Checker, line: usize) Allocator.Error![]const u8 {
        return c.a.print("packed-refs line {d}", .{line});
    }

    /// `packed_fsck_ref_next_line`: the line at `start`, its newline
    /// reported missing.
    fn nextLine(c: *Checker, bytes: []const u8, start: usize, line: usize) Allocator.Error![]const u8 {
        if (std.mem.findScalarPos(u8, bytes, start, '\n')) |eol| return bytes[start..eol];
        _ = try c.report(try c.lineName(line), .packed_ref_entry_not_terminated, "'{s}' is not terminated with a newline", .{bytes[start..]});
        return bytes[start..];
    }

    /// `packed_fsck_ref_content`: whether the header says `sorted`.
    fn packedContent(c: *Checker, bytes: []const u8) Allocator.Error!bool {
        const hex_len = c.store.objectFormat().hexLen();
        var sorted = false;
        var line: usize = 1;
        var at: usize = 0;
        var text = try c.nextLine(bytes, at, line);
        if (bytes[0] == '#') {
            if (std.mem.startsWith(u8, text, "# pack-refs with: ")) {
                var traits = std.mem.splitScalar(u8, text["# pack-refs with: ".len..], ' ');
                while (traits.next()) |trait| sorted = sorted or std.mem.eql(u8, trait, "sorted");
            } else _ = try c.report("packed-refs.header", .bad_packed_ref_header, "'{s}' does not start with '# pack-refs with: '", .{text});
            at += text.len + 1;
            line += 1;
        }
        while (at < bytes.len) {
            text = try c.nextLine(bytes, at, line);
            try c.packedMain(text, line, hex_len);
            at += text.len + 1;
            line += 1;
            if (at < bytes.len and bytes[at] == '^') {
                text = try c.nextLine(bytes, at, line);
                try c.packedPeeled(text, line, hex_len);
                at += text.len + 1;
                line += 1;
            }
        }
        return sorted;
    }

    /// `parse_oid_hex_algop`: the object name `text` starts with, if any.
    fn leadingOid(kind: Kind, text: []const u8) ?Oid {
        if (text.len < kind.hexLen()) return null;
        return Oid.parse(kind, text[0..kind.hexLen()]) catch null;
    }

    fn packedMain(c: *Checker, text: []const u8, line: usize, hex_len: usize) Allocator.Error!void {
        const oid = leadingOid(c.store.objectFormat(), text) orelse
            return c.reported(try c.lineName(line), .bad_packed_ref_entry, "'{s}' has invalid oid", .{text});
        const rest = text[hex_len..];
        if (rest.len == 0 or !ctype.isSpace(rest[0])) {
            var hex: [hash.max_hex_len]u8 = undefined;
            return c.reported(try c.lineName(line), .bad_packed_ref_entry, "has no space after oid '{s}' but with '{s}'", .{ oid.hex(&hex), rest });
        }
        // a C string: the name ends at a NUL, which is reported
        const name = rest[1..];
        const shown = if (std.mem.findScalar(u8, name, 0)) |nul| name[0..nul] else name;
        if (shown.len != name.len)
            _ = try c.report(try c.lineName(line), .bad_packed_ref_entry, "refname '{s}' contains NULL binaries", .{shown});
        if (!names.checkFormat(shown, .{}))
            _ = try c.report(try c.lineName(line), .bad_ref_name, "has bad refname '{s}'", .{shown});
    }

    fn packedPeeled(c: *Checker, text: []const u8, line: usize, hex_len: usize) Allocator.Error!void {
        const value = text[1..];
        _ = leadingOid(c.store.objectFormat(), value) orelse
            return c.reported(try c.lineName(line), .bad_packed_ref_entry, "'{s}' has invalid peeled oid", .{value});
        if (value.len != hex_len)
            _ = try c.report(try c.lineName(line), .bad_packed_ref_entry, "has trailing garbage after peeled oid '{s}'", .{value[hex_len..]});
    }

    /// `packed_fsck_ref_sorted`: each name after the one before it, by
    /// `cmp_packed_refname`; the first out of order is reported.
    fn packedSorted(c: *Checker, bytes: []const u8) Allocator.Error!void {
        const hex_len = c.store.objectFormat().hexLen();
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        var line: usize = 0;
        var former: ?[]const u8 = null;
        while (lines.next()) |text| {
            line += 1;
            if (lines.index == null and text.len == 0) break;
            if (line == 1 and text.len > 0 and text[0] == '#') continue;
            if (text.len > 0 and text[0] == '^') continue;
            const current = if (text.len > hex_len) text[hex_len + 1 ..] else "";
            if (former) |f| {
                if (std.mem.order(u8, f, current) != .lt)
                    return c.reported(try c.lineName(line), .packed_ref_unsorted, "refname '{s}' is less than previous refname '{s}'", .{ current, f });
            }
            former = current;
        }
    }

    /// `reftable_be_fsck`: the stack's table names, then every ref it holds.
    fn reftableStack(c: *Checker) Error!void {
        const dir = if (c.options.worktree == null) c.store.commonDir() else c.store.gitDir();
        if (try fs.readFileAlloc(c.a, c.io, dir, "reftable/tables.list", 1 << 24)) |list| {
            var tables = std.mem.splitScalar(u8, list, '\n');
            while (tables.next()) |table| {
                if (table.len == 0) continue;
                if (!validTableName(table)) _ = try c.report(table, .bad_reftable_table_name, "invalid reftable table name", .{});
            }
        }
        var listing = try stack_engine.list(c.a, c.io, c.store, "");
        defer listing.deinit();
        for (listing.entries) |entry| {
            const path = try c.named(entry.name);
            switch (entry.target) {
                .direct => |oid| try c.direct(path, oid),
                .symbolic => |target| try c.symbolic(path, entry.name, target),
            }
        }
    }
};

/// The name a worktree's own ref has in its store: `worktrees/<id>/` and
/// `main-worktree/` taken off, as `parse_worktree_ref` takes them.
fn stripWorktree(name: []const u8) []const u8 {
    if (std.mem.startsWith(u8, name, "main-worktree/")) return name["main-worktree/".len..];
    if (std.mem.startsWith(u8, name, "worktrees/")) {
        const rest = name["worktrees/".len..];
        if (std.mem.findScalar(u8, rest, '/')) |slash| return rest[slash + 1 ..];
    }
    return name;
}

/// What `parse_loose_ref_contents` makes of a file: `ref:` and whatever
/// follows its spaces, or an object name and what comes after it, which
/// must start with a space if anything does.
const Contents = union(enum) {
    broken,
    symbolic: []const u8,
    direct: struct { oid: Oid, trailing: []const u8 },
};

fn parseContents(kind: Kind, bytes: []const u8) Contents {
    if (std.mem.startsWith(u8, bytes, "ref:")) {
        var rest = bytes[4..];
        while (rest.len > 0 and ctype.isSpace(rest[0])) rest = rest[1..];
        // a C string: the referent ends at a NUL
        if (std.mem.findScalar(u8, rest, 0)) |nul| rest = rest[0..nul];
        return .{ .symbolic = rest };
    }
    const oid = Checker.leadingOid(kind, bytes) orelse return .broken;
    var trailing = bytes[kind.hexLen()..];
    if (std.mem.findScalar(u8, trailing, 0)) |nul| trailing = trailing[0..nul];
    if (trailing.len > 0 and !ctype.isSpace(trailing[0])) return .broken;
    return .{ .direct = .{ .oid = oid, .trailing = trailing } };
}

/// `table_has_valid_name`: `<hex>-<hex>-<hex>` read as `strtoull` and
/// `strtoul` read them, then `.ref` or `.log`.
fn validTableName(name: []const u8) bool {
    var rest = name;
    for (0..3) |i| {
        const r = decimal.strtoul(rest, 16, 64);
        if (r.overflow) return false;
        rest = rest[r.end..];
        if (i < 2) {
            if (rest.len == 0 or rest[0] != '-') return false;
            rest = rest[1..];
        }
    }
    return std.mem.eql(u8, rest, ".ref") or std.mem.eql(u8, rest, ".log");
}

/// Verify `store`'s refs as `git refs verify` verifies one worktree's.
/// The report is `gpa`'s.
pub fn check(gpa: Allocator, io: Io, store: *const refs.Store, options: Options) Self.Error!Report {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    var c: Checker = .{ .a = arena.allocator(), .io = io, .store = store, .options = options };
    switch (store.refFormat()) {
        .files => {
            try c.looseRefs();
            try c.rootRefs();
            if (options.worktree == null) try c.packedRefs();
        },
        .reftable => try c.reftableStack(),
    }
    return .{ .arena = arena, .findings = c.found.items };
}
