//! `git fast-export`: history written as a fast-import stream, byte for
//! byte the stream git writes for the same refs and options.
//!
//! The commits come oldest first in git's topological order, each named by
//! the first ref given that reaches it — `revision.c`'s sources, handed
//! down from child to parent in the order its date walk meets them — and
//! carrying the blobs it adds before it, marked from 1 up. A ref whose
//! commit went out under another name is reset to it at the end, and the
//! tags given are written after the commits. A commit's changes are the
//! diff against its first parent when that parent is in the stream, and
//! the whole tree otherwise; `RenameOptions` makes them renames and copies
//! as `-M` and `-C` do. Marks files are read and written as git's are.
//!
//! What git's command line takes beside: `--anonymize` and a path limit are
//! not offered, nor is `--reencode=yes`, which needs a character set
//! converter; a commit in another encoding is written as it is
//! (`Reencode.no`) or refused.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash/hash.zig");
const object = @import("object/object.zig");
const odb_mod = @import("odb/odb.zig");
const repo_mod = @import("repo/repo.zig");
const revwalk = @import("walk/walk.zig");
const diff = @import("diff/diff.zig");
const cquote = @import("text/cquote.zig");
const signing = @import("object/signing.zig");
const refspec_mod = @import("wire/refspec.zig");
const fastimport = @import("fastimport.zig");
const fs = @import("fs/fs.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

/// Errors from an export, each where git's fast-export dies.
pub const Error = error{
    /// A commit with a message in another encoding, under `Reencode.abort`.
    EncodedCommit,
    /// A signed commit or tag under `SignMode.abort`.
    SignedObject,
    /// A tag of an object the stream does not carry, under
    /// `TagOfFiltered.abort`.
    TagOfFilteredObject,
    /// A tag of a tag the stream does not carry, without `mark_tags`.
    NestedTag,
    /// A commit with no author or committer line.
    MalformedCommit,
    /// A marks file line that is not `:<mark> <name>`, or one naming
    /// something this repository lacks.
    CorruptMarks,
    /// A `refspecs` entry that does not parse.
    InvalidRefspec,
} || Allocator.Error || odb_mod.Error || revwalk.Error || diff.Error || Io.Writer.Error ||
    Io.Dir.ReadFileAllocError || Io.Dir.CreateDirPathError || fs.LockError || fs.CommitError || object.ParseError;

/// What becomes of a signature: git's `--signed-tags` and
/// `--signed-commits`.
/// A tag of something the stream leaves out: git's
/// `--tag-of-filtered-object`.
pub const TagOfFiltered = enum { abort, drop, rewrite };

/// A commit in another encoding: git's `--reencode`, less `yes`.
pub const Reencode = enum {
    /// Stop with `error.EncodedCommit`.
    abort,
    /// Write the message as it is, and its `encoding`.
    no,
};

/// One revision to export, as git's command line names one.
pub const Tip = struct {
    /// The ref's full name, as git names a ref it is given — `HEAD` is the
    /// branch it points at. The stream writes commits and resets to it.
    name: []const u8,
    /// A commit, a tag (whose chain of tags is written too) or a blob.
    oid: Oid,
    /// Whether `name` is a ref. One that is not — a revision such as
    /// `main~2` — names its commits and is never reset or tagged.
    ref: bool = true,
};

/// How a stream is written.
pub const Options = struct {
    tips: []const Tip,
    /// `^<rev>`: commits these reach are left out.
    exclude: []const Oid = &.{},
    signed_tags: fastimport.SignMode = .abort,
    signed_commits: fastimport.SignMode = .strip,
    tag_of_filtered: TagOfFiltered = .abort,
    reencode: Reencode = .abort,
    /// `--fake-missing-tagger`.
    fake_missing_tagger: bool = false,
    /// `--use-done-feature`.
    use_done_feature: bool = false,
    /// `--no-data`: no blobs, and changes naming objects rather than marks.
    no_data: bool = false,
    /// `--full-tree`: every commit is its whole tree after `deleteall`.
    full_tree: bool = false,
    /// `--reference-excluded-parents`: a parent left out is named by its
    /// object name rather than dropped.
    reference_excluded_parents: bool = false,
    /// `--show-original-ids`.
    show_original_ids: bool = false,
    /// `--mark-tags`.
    mark_tags: bool = false,
    /// `--progress=<n>`: a `progress` line every n objects; zero is none.
    progress: u32 = 0,
    /// `--refspec`: fetch refspecs mapping the refs' names in the stream;
    /// one with no source deletes its destination.
    refspecs: []const []const u8 = &.{},
    /// `-M` and `-C`.
    renames: ?diff.RenameOptions = null,
    /// `--import-marks`: commits already exported, never written again.
    import_marks: ?[]const u8 = null,
    /// `--import-marks-if-exists`.
    import_marks_if_exists: bool = false,
    /// `--export-marks`: written when this export marked anything new.
    export_marks: ?[]const u8 = null,
    /// What marks file paths are relative to; `null` is the process's
    /// working directory.
    cwd: ?Io.Dir = null,
};

/// Write the stream for `options.tips` to `w`.
pub fn write(gpa: Allocator, io: Io, repo: *Repository, w: *Io.Writer, options: Options) Self.Error!void {
    var ex: Exporter = .{
        .gpa = gpa,
        .io = io,
        .repo = repo,
        .w = w,
        .options = options,
        .arena_state = .init(gpa),
        .quote_path = repo.configuration().getBool("core.quotepath", true) catch true,
    };
    defer ex.deinit();
    try ex.run();
}

const Named = struct { name: []const u8, oid: Oid, type: object.Type };

const Exporter = struct {
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    w: *Io.Writer,
    options: Options,
    arena_state: std.heap.ArenaAllocator,
    quote_path: bool,

    marks: Oid.Map(u32) = .empty,
    /// Commits a marks file brought, which are never written: git's
    /// `SHOWN`.
    imported: Oid.Set = .empty,
    last_mark: u32 = 0,
    sources: Oid.Map([]const u8) = .empty,
    extra_refs: std.ArrayList(Named) = .empty,
    tag_refs: std.ArrayList(Named) = .empty,
    refspecs: std.ArrayList(refspec_mod.Refspec) = .empty,
    shown: u32 = 0,

    fn deinit(ex: *Exporter) void {
        ex.marks.deinit(ex.gpa);
        ex.imported.deinit(ex.gpa);
        ex.sources.deinit(ex.gpa);
        ex.extra_refs.deinit(ex.gpa);
        ex.tag_refs.deinit(ex.gpa);
        ex.refspecs.deinit(ex.gpa);
        ex.arena_state.deinit();
        ex.* = undefined;
    }

    fn arena(ex: *Exporter) Allocator {
        return ex.arena_state.allocator();
    }

    fn run(ex: *Exporter) Error!void {
        for (ex.options.refspecs) |text| {
            try ex.refspecs.append(ex.gpa, refspec_mod.Refspec.parse(text, .fetch) catch return error.InvalidRefspec);
        }
        if (ex.options.use_done_feature) try ex.w.writeAll("feature done\n");
        if (ex.options.import_marks) |path| try ex.importMarks(path);
        const last_imported = ex.last_mark;

        var commits: std.ArrayList(Oid) = .empty;
        defer commits.deinit(ex.gpa);
        try ex.collectTips(&commits);

        var exclude: std.ArrayList(Oid) = .empty;
        defer exclude.deinit(ex.gpa);
        for (ex.options.exclude) |oid| if (try ex.peelToCommit(oid)) |c| try exclude.append(ex.gpa, c);

        try ex.assignSources(commits.items, exclude.items);

        var walk = revwalk.Walk.init(ex.gpa, ex.repo.objectDatabase());
        defer walk.deinit();
        walk.sort = .topological;
        walk.reverse = true;
        for (commits.items) |c| try walk.push(c);
        for (exclude.items) |c| try walk.hide(c);
        while (try walk.next(ex.io)) |c| {
            if (ex.imported.contains(c.oid)) continue;
            try ex.commit(c.oid, c.parents);
        }

        try ex.tagsAndDuplicates(ex.extra_refs.items);
        try ex.tagsAndDuplicates(ex.tag_refs.items);
        for (ex.refspecs.items) |spec| {
            if (spec.src.len != 0 or spec.negative) continue;
            try ex.w.print("reset {s}\nfrom {f}\n\n", .{ spec.dst orelse "", Oid.zero(ex.repo.objectFormat()) });
        }
        if (ex.options.export_marks) |path| if (last_imported != ex.last_mark) try ex.exportMarks(path);
        if (ex.options.use_done_feature) try ex.w.writeAll("done\n");
    }

    /// git's `get_tags_and_duplicates`: the commits to walk from, the refs
    /// to reset at the end and the tags to write.
    fn collectTips(ex: *Exporter, commits: *std.ArrayList(Oid)) Error!void {
        for (ex.options.tips) |tip| {
            var name = tip.name;
            if (tip.ref) for (ex.refspecs.items) |spec| {
                if (try spec.mapSource(ex.arena(), name)) |mapped| {
                    name = mapped;
                    break;
                }
            };
            var oid = tip.oid;
            var t = try ex.typeOf(oid);
            // A tag, and the tags it points at, are written after the
            // commits.
            while (t == .tag) {
                if (tip.ref) try ex.tag_refs.append(ex.gpa, .{ .name = name, .oid = oid, .type = .tag });
                oid = try ex.tagTarget(oid);
                t = try ex.typeOf(oid);
            }
            switch (t) {
                .commit => {},
                .blob => {
                    try ex.exportBlob(oid);
                    continue;
                },
                else => continue,
            }
            try commits.append(ex.gpa, oid);
            if (tip.ref and tip.oid.eql(oid)) try ex.extra_refs.append(ex.gpa, .{ .name = name, .oid = oid, .type = .commit });
            const slot = try ex.sources.getOrPut(ex.gpa, oid);
            if (!slot.found_existing) slot.value_ptr.* = name;
        }
        // `string_list_sort_u`: by name, one of each.
        std.mem.sort(Named, ex.extra_refs.items, {}, struct {
            fn lessThan(_: void, a: Named, b: Named) bool {
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.lessThan);
        var kept: usize = 0;
        for (ex.extra_refs.items) |r| {
            if (kept > 0 and std.mem.eql(u8, ex.extra_refs.items[kept - 1].name, r.name)) continue;
            ex.extra_refs.items[kept] = r;
            kept += 1;
        }
        ex.extra_refs.shrinkRetainingCapacity(kept);
    }

    /// Each commit's name, handed from child to parent in the order the
    /// date walk meets them, as `revision.c` hands its sources down.
    fn assignSources(ex: *Exporter, commits: []const Oid, exclude: []const Oid) Error!void {
        var walk = revwalk.Walk.init(ex.gpa, ex.repo.objectDatabase());
        defer walk.deinit();
        for (commits) |c| try walk.push(c);
        for (exclude) |c| try walk.hide(c);
        while (try walk.next(ex.io)) |c| {
            const source = ex.sources.get(c.oid) orelse continue;
            for (c.parents) |p| {
                const slot = try ex.sources.getOrPut(ex.gpa, p);
                if (!slot.found_existing) slot.value_ptr.* = source;
            }
        }
    }

    fn markNext(ex: *Exporter, oid: Oid) Error!u32 {
        ex.last_mark += 1;
        try ex.marks.put(ex.gpa, oid, ex.last_mark);
        return ex.last_mark;
    }

    fn showProgress(ex: *Exporter) Error!void {
        if (ex.options.progress == 0) return;
        ex.shown += 1;
        if (ex.shown % ex.options.progress == 0) try ex.w.print("progress {d} objects\n", .{ex.shown});
    }

    fn exportBlob(ex: *Exporter, oid: Oid) Error!void {
        if (ex.options.no_data or oid.isZero()) return;
        if (ex.marks.contains(oid)) return;
        const found = try ex.repo.objectDatabase().read(ex.io, oid);
        defer ex.gpa.free(found.bytes);
        const mark = try ex.markNext(oid);
        try ex.w.print("blob\nmark :{d}\n", .{mark});
        if (ex.options.show_original_ids) try ex.w.print("original-oid {f}\n", .{oid});
        try ex.w.print("data {d}\n", .{found.bytes.len});
        try ex.w.writeAll(found.bytes);
        try ex.w.writeByte('\n');
        try ex.showProgress();
    }

    /// git's `handle_commit`.
    fn commit(ex: *Exporter, oid: Oid, parents: []const Oid) Error!void {
        const found = try ex.repo.objectDatabase().read(ex.io, oid);
        defer ex.gpa.free(found.bytes);
        const buf = found.bytes;
        const kind = ex.repo.objectFormat();

        const author_at = (std.mem.find(u8, buf, "\nauthor ") orelse return error.MalformedCommit) + 1;
        const author_end = std.mem.findScalarPos(u8, buf, author_at, '\n') orelse buf.len;
        const committer_at = (std.mem.findPos(u8, buf, author_end, "\ncommitter ") orelse return error.MalformedCommit) + 1;
        const committer_end = std.mem.findScalarPos(u8, buf, committer_at, '\n') orelse buf.len;
        var cursor = committer_end;

        var encoding: ?[]const u8 = null;
        if (cursor < buf.len and buf[cursor] == '\n') {
            if (findHeader(buf, cursor + 1, "encoding")) |h| {
                encoding = buf[h.start..h.end];
                cursor = h.end;
            }
        }
        var signatures: std.ArrayList(Signature) = .empty;
        defer {
            for (signatures.items) |s| ex.gpa.free(s.text);
            signatures.deinit(ex.gpa);
        }
        if (cursor < buf.len and buf[cursor] == '\n') {
            const after_sha1 = try ex.collectSignatures(&signatures, buf, cursor, "gpgsig", "sha1");
            const after_sha256 = try ex.collectSignatures(&signatures, buf, cursor, "gpgsig-sha256", "sha256");
            cursor = @max(after_sha1, after_sha256);
        }
        var message: []const u8 = "";
        if (std.mem.findPos(u8, buf, cursor, "\n\n")) |m| {
            message = buf[m + 2 ..];
            if (std.mem.findScalar(u8, message, 0)) |nul| message = message[0..nul];
        }

        const tree = try treeOf(kind, buf);
        const first_parent_known = parents.len > 0 and
            (ex.marks.contains(parents[0]) or ex.options.reference_excluded_parents) and !ex.options.full_tree;
        const base: ?Oid = if (first_parent_known) try ex.commitTree(parents[0]) else null;
        var changes = try diff.tree(ex.gpa, ex.io, ex.repo.objectDatabase(), .{ .old = base, .new = tree }, .{ .renames = ex.options.renames });
        defer changes.deinit();
        for (changes.items) |c| {
            const new = c.new orelse continue;
            if (new.mode == .gitlink) continue;
            try ex.exportBlob(new.oid);
        }

        const refname = ex.sources.get(oid) orelse "";
        for (ex.extra_refs.items, 0..) |r, i| if (std.mem.eql(u8, r.name, refname)) {
            _ = ex.extra_refs.orderedRemove(i);
            break;
        };
        const mark = try ex.markNext(oid);
        if (encoding) |e| if (ex.options.reencode == .abort) {
            _ = e;
            return error.EncodedCommit;
        };
        if (parents.len == 0) try ex.w.print("reset {s}\n", .{refname});
        try ex.w.print("commit {s}\nmark :{d}\n", .{ refname, mark });
        if (ex.options.show_original_ids) try ex.w.print("original-oid {f}\n", .{oid});
        try ex.w.print("{s}\n{s}\n", .{ buf[author_at..author_end], buf[committer_at..committer_end] });
        if (signatures.items.len > 0) switch (ex.options.signed_commits) {
            .verbatim => for (signatures.items) |s| {
                const format = if (signing.Format.of(s.text)) |f| @tagName(f) else "unknown";
                try ex.w.print("gpgsig {s} {s}\ndata {d}\n{s}\n", .{ s.algo, format, s.text.len, s.text });
            },
            .strip => {},
            .abort => return error.SignedObject,
        };
        if (encoding) |e| try ex.w.print("encoding {s}\n", .{e});
        try ex.w.print("data {d}\n{s}", .{ message.len, message });

        var written: usize = 0;
        for (parents) |p| {
            const pmark = ex.marks.get(p) orelse 0;
            if (pmark == 0 and !ex.options.reference_excluded_parents) continue;
            try ex.w.writeAll(if (written == 0) "from " else "merge ");
            if (pmark != 0) try ex.w.print(":{d}\n", .{pmark}) else try ex.w.print("{f}\n", .{p});
            written += 1;
        }
        if (ex.options.full_tree) try ex.w.writeAll("deleteall\n");
        try ex.fileChanges(changes.items);
        try ex.w.writeByte('\n');
        try ex.showProgress();
    }

    const Signature = struct { text: []u8, algo: []const u8 };

    /// Every `header` signature after `pos`, unfolded; where the last one
    /// ended. git's `append_signatures_for_header`.
    fn collectSignatures(ex: *Exporter, out: *std.ArrayList(Signature), buf: []const u8, pos: usize, header: []const u8, algo: []const u8) Error!usize {
        var start = pos;
        var end = pos;
        while (start + 1 <= buf.len) {
            const h = findHeader(buf, start + 1, header) orelse break;
            var text: std.ArrayList(u8) = .empty;
            errdefer text.deinit(ex.gpa);
            try text.appendSlice(ex.gpa, buf[h.start..h.end]);
            var eol = h.end;
            while (eol + 1 < buf.len and buf[eol] == '\n' and buf[eol + 1] == ' ') {
                const bol = eol + 2;
                eol = std.mem.findScalarPos(u8, buf, bol, '\n') orelse buf.len;
                try text.append(ex.gpa, '\n');
                try text.appendSlice(ex.gpa, buf[bol..eol]);
            }
            try out.append(ex.gpa, .{ .text = try text.toOwnedSlice(ex.gpa), .algo = algo });
            end = eol;
            start = eol;
        }
        return end;
    }

    /// git's `show_filemodify`.
    fn fileChanges(ex: *Exporter, items: []diff.Change) Error!void {
        std.mem.sort(diff.Change, items, {}, depthFirst);
        var changed: std.StringHashMapUnmanaged(void) = .empty;
        defer changed.deinit(ex.gpa);
        for (items) |c| {
            switch (c.status) {
                .deleted => {
                    const path = c.old.?.path;
                    try ex.w.writeAll("D ");
                    try ex.printPath(path);
                    try changed.put(ex.gpa, path, {});
                    try ex.w.writeByte('\n');
                    continue;
                },
                .renamed, .copied => {
                    const old = c.old.?;
                    const new = c.new.?;
                    if (!changed.contains(old.path)) {
                        try ex.w.print("{c} ", .{c.letter()});
                        try ex.printPath(old.path);
                        try ex.w.writeByte(' ');
                        try ex.printPath(new.path);
                        try changed.put(ex.gpa, new.path, {});
                        try ex.w.writeByte('\n');
                        if (old.oid.eql(new.oid) and old.mode == new.mode) continue;
                    }
                },
                .added, .modified, .type_changed => {},
            }
            const new = c.new.?;
            if (ex.options.no_data or new.mode == .gitlink) {
                try ex.w.print("M {o:0>6} {f} ", .{ new.mode.raw(), new.oid });
            } else {
                try ex.w.print("M {o:0>6} :{d} ", .{ new.mode.raw(), ex.marks.get(new.oid) orelse 0 });
            }
            try ex.printPath(new.path);
            try changed.put(ex.gpa, new.path, {});
            try ex.w.writeByte('\n');
        }
    }

    fn printPath(ex: *Exporter, path: []const u8) Error!void {
        if (cquote.needsQuote(path, ex.quote_path)) return cquote.write(ex.w, path, ex.quote_path);
        if (std.mem.findScalar(u8, path, ' ') != null) return ex.w.print("\"{s}\"", .{path});
        try ex.w.writeAll(path);
    }

    /// git's `handle_tags_and_duplicates`, last first.
    fn tagsAndDuplicates(ex: *Exporter, list: []const Named) Error!void {
        const zero = Oid.zero(ex.repo.objectFormat());
        var i = list.len;
        while (i > 0) {
            i -= 1;
            const r = list[i];
            switch (r.type) {
                .tag => try ex.tag(r.name, r.oid),
                .commit => {
                    const mark = ex.marks.get(r.oid) orelse 0;
                    if (mark == 0) {
                        // Left out by an exclusion: the ref goes, or with
                        // `reference_excluded_parents` names the commit.
                        if (!ex.options.reference_excluded_parents) {
                            try ex.w.print("reset {s}\nfrom {f}\n\n", .{ r.name, zero });
                        } else {
                            try ex.w.print("reset {s}\nfrom {f}\n\n", .{ r.name, r.oid });
                        }
                        continue;
                    }
                    try ex.w.print("reset {s}\nfrom :{d}\n\n", .{ r.name, mark });
                    try ex.showProgress();
                },
                else => {},
            }
        }
    }

    /// git's `handle_tag`.
    fn tag(ex: *Exporter, name_in: []const u8, oid: Oid) Error!void {
        // Trees have no marks, so a tag that ends at one is left out.
        var tagged_end = try ex.tagTarget(oid);
        while (try ex.typeOf(tagged_end) == .tag) tagged_end = try ex.tagTarget(tagged_end);
        if (try ex.typeOf(tagged_end) == .tree) return;

        const found = try ex.repo.objectDatabase().read(ex.io, oid);
        defer ex.gpa.free(found.bytes);
        const buf = found.bytes;
        var message: ?[]const u8 = null;
        const message_at = std.mem.find(u8, buf, "\n\n");
        if (message_at) |m| {
            var rest = buf[m + 2 ..];
            if (std.mem.findScalar(u8, rest, 0)) |nul| rest = rest[0..nul];
            message = rest;
        }
        const head = buf[0 .. message_at orelse buf.len];
        var tagger: []const u8 = "";
        if (std.mem.find(u8, head, "\ntagger ")) |t| {
            const start = t + 1;
            const end = std.mem.findScalarPos(u8, buf, start, '\n') orelse buf.len;
            tagger = buf[start..end];
        } else if (ex.options.fake_missing_tagger) {
            tagger = "tagger Unspecified Tagger <unspecified-tagger> 0 +0000";
        }
        var body = message orelse "";
        if (message) |m| {
            const sig_offset = fastimport.signedOffset(m);
            if (sig_offset < m.len) switch (ex.options.signed_tags) {
                .verbatim => {},
                .strip => body = m[0..sig_offset],
                .abort => return error.SignedObject,
            };
        }

        const tagged = try ex.tagTarget(oid);
        const tagged_type = try ex.typeOf(tagged);
        const tagged_mark = ex.marks.get(tagged) orelse 0;
        if (tagged_mark == 0) switch (ex.options.tag_of_filtered) {
            .abort => return error.TagOfFilteredObject,
            .drop => return,
            .rewrite => if (tagged_type == .tag and !ex.options.mark_tags) return error.NestedTag,
        };
        const zero = Oid.zero(ex.repo.objectFormat());
        if (tagged_type == .tag) try ex.w.print("reset {s}\nfrom {f}\n\n", .{ name_in, zero });
        const name = if (std.mem.startsWith(u8, name_in, "refs/tags/")) name_in["refs/tags/".len..] else name_in;
        try ex.w.print("tag {s}\n", .{name});
        if (ex.options.mark_tags) try ex.w.print("mark :{d}\n", .{try ex.markNext(oid)});
        if (tagged_mark != 0) try ex.w.print("from :{d}\n", .{tagged_mark}) else try ex.w.print("from {f}\n", .{tagged});
        if (ex.options.show_original_ids) try ex.w.print("original-oid {f}\n", .{oid});
        try ex.w.print("{s}{s}data {d}\n{s}\n", .{ tagger, if (tagger.len == 0) "" else "\n", body.len, body });
    }

    //=================================================================
    // Marks
    //=================================================================

    fn marksDir(ex: *Exporter) Io.Dir {
        return ex.options.cwd orelse Io.Dir.cwd();
    }

    /// git's `import_marks`: every commit marked is taken as written.
    fn importMarks(ex: *Exporter, path: []const u8) Error!void {
        const bytes = ex.marksDir().readFileAlloc(ex.io, path, ex.gpa, .unlimited) catch |err| switch (err) {
            error.FileNotFound => if (ex.options.import_marks_if_exists) return else return error.FileNotFound,
            else => |e| return e,
        };
        defer ex.gpa.free(bytes);
        var read: fastimport.Marks = .{};
        defer read.deinit(ex.gpa);
        read.parse(ex.gpa, ex.repo.objectFormat(), bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.CorruptMarks => return error.CorruptMarks,
        };
        var it = read.map.iterator();
        while (it.next()) |e| {
            const mark: u32 = std.math.cast(u32, e.key_ptr.*) orelse return error.CorruptMarks;
            if (ex.last_mark < mark) ex.last_mark = mark;
            const header = ex.repo.objectDatabase().readHeader(ex.io, e.value_ptr.*) catch |err| switch (err) {
                error.ObjectNotFound => return error.CorruptMarks,
                else => |x| return x,
            };
            if (header.type != .commit) continue;
            try ex.marks.put(ex.gpa, e.value_ptr.*, mark);
            try ex.imported.put(ex.gpa, e.value_ptr.*, {});
        }
    }

    /// git's `export_marks`: the commits' marks, lowest first.
    fn exportMarks(ex: *Exporter, path: []const u8) Error!void {
        var out: fastimport.Marks = .{};
        defer out.deinit(ex.gpa);
        var it = ex.marks.iterator();
        while (it.next()) |e| {
            if (try ex.typeOf(e.key_ptr.*) != .commit) continue;
            try out.put(ex.gpa, e.value_ptr.*, e.key_ptr.*);
        }
        const dir = ex.marksDir();
        if (std.Io.Dir.path.dirname(path)) |parent| try dir.createDirPath(ex.io, parent);
        var buffer: [4096]u8 = undefined;
        var lock = try fs.LockFile.open(ex.gpa, ex.io, dir, path, &buffer, .{});
        defer lock.deinit(ex.io);
        try out.write(ex.gpa, lock.writer());
        try lock.commit(ex.io);
    }

    //=================================================================
    // Objects
    //=================================================================

    fn typeOf(ex: *Exporter, oid: Oid) Error!object.Type {
        return (try ex.repo.objectDatabase().readHeader(ex.io, oid)).type;
    }

    fn tagTarget(ex: *Exporter, oid: Oid) Error!Oid {
        const found = try ex.repo.objectDatabase().read(ex.io, oid);
        defer ex.gpa.free(found.bytes);
        var t = try object.Tag.parse(ex.gpa, ex.repo.objectFormat(), found.bytes);
        defer t.deinit();
        return t.target;
    }

    fn commitTree(ex: *Exporter, oid: Oid) Error!Oid {
        const found = try ex.repo.objectDatabase().read(ex.io, oid);
        defer ex.gpa.free(found.bytes);
        return treeOf(ex.repo.objectFormat(), found.bytes);
    }

    fn peelToCommit(ex: *Exporter, start: Oid) Error!?Oid {
        var oid = start;
        while (true) switch (try ex.typeOf(oid)) {
            .commit => return oid,
            .tag => oid = try ex.tagTarget(oid),
            else => return null,
        };
    }
};

fn treeOf(kind: hash.Kind, buf: []const u8) Error!Oid {
    const hex_len = kind.hexLen();
    if (buf.len < 5 + hex_len or !std.mem.startsWith(u8, buf, "tree ")) return error.MalformedCommit;
    return Oid.parse(kind, buf[5..][0..hex_len]) catch error.MalformedCommit;
}

const Header = struct { start: usize, end: usize };

/// git's `find_commit_header`: the value of the first header `key` at or
/// after `from`, before the blank line.
fn findHeader(buf: []const u8, from: usize, key: []const u8) ?Header {
    var line = from;
    while (line < buf.len and buf[line] != '\n') {
        const eol = std.mem.findScalarPos(u8, buf, line, '\n') orelse buf.len;
        const text = buf[line..eol];
        if (text.len > key.len and std.mem.startsWith(u8, text, key) and text[key.len] == ' ') {
            return .{ .start = line + key.len + 1, .end = eol };
        }
        line = eol + 1;
    }
    return null;
}

/// git's `depth_first`: a directory's contents before the directory, and a
/// rename after what shares its path.
fn depthFirst(_: void, a: diff.Change, b: diff.Change) bool {
    const name_a = if (a.old) |o| o.path else a.new.?.path;
    const name_b = if (b.old) |o| o.path else b.new.?.path;
    const len = @min(name_a.len, name_b.len);
    const order = std.mem.order(u8, name_a[0..len], name_b[0..len]);
    if (order != .eq) return order == .lt;
    if (name_a.len != name_b.len) return name_a.len > name_b.len;
    return @intFromBool(a.status == .renamed) < @intFromBool(b.status == .renamed);
}

test "a commit's header is found by its name alone" {
    const buf = "tree 1\nauthor a\ncommitter c\nencoding ISO-8859-1\n\nmessage\nencoding no\n";
    const h = findHeader(buf, 0, "encoding").?;
    try std.testing.expectEqualStrings("ISO-8859-1", buf[h.start..h.end]);
    try std.testing.expect(findHeader(buf, 0, "gpgsig") == null);
}
