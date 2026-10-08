//! `git fast-import`: a stream in git's fast-import format read into a
//! repository, the objects and refs git's own makes from the same stream.
//!
//! Every command git reads is read: `blob`, `commit` with its `M`, `D`,
//! `C`, `R`, `deleteall` and `N` changes, `tag`, `reset`, `alias`,
//! `checkpoint`, `progress`, `done`, `get-mark`, `cat-blob`, `ls`,
//! `feature` and `option`. Paths are bare or C-quoted, data is counted or
//! delimited, dates are `raw`, `raw-permissive`, `rfc2822` or `now`, and
//! marks are read and written in git's marks files. Branches are kept as
//! git keeps them, in memory, each a tree changed in place and written out
//! at its next commit; a notes ref's fanout follows its count as git's
//! does. At the end — and at a `checkpoint` — the objects are one pack,
//! each branch is updated when the new tip contains the old one (or
//! `force` says to), every tag is written, and the marks are saved.
//!
//! The answers to `get-mark`, `cat-blob` and `ls` go to `Options.responses`,
//! git's `--cat-blob-fd`, or with none to `Options.output`, git's standard
//! output, where `progress` lines go. A commit signature in the stream is
//! kept, dropped or refused (`SignMode`); checking it, git's `*-if-invalid`
//! modes, is not offered. `rewrite-submodules-*` and `export-pack-edges`
//! are refused by name.

const ErrorNamespace = @This();
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Io = std.Io;

const hash = @import("hash/hash.zig");
const object = @import("object/object.zig");
const odb_mod = @import("odb/odb.zig");
const refs_mod = @import("refs/refs.zig");
const repo_mod = @import("repo/repo.zig");
const revwalk = @import("walk/walk.zig");
const revparse = @import("revwalk/revparse.zig");
const cquote = @import("text/cquote.zig");
const gitdate = @import("text/date.zig");
const signing = @import("object/signing.zig");
const safepath = @import("names/path.zig");
const ref_names = @import("names/ref.zig");
const fs = @import("fs/fs.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

/// Errors from an import. Each is where git's fast-import dies, by name.
pub const Error = error{
    /// A line naming no command git's fast-import has.
    UnsupportedCommand,
    /// A command whose arguments are not written as the format writes them:
    /// a missing space, something after a mark, a bad `data` count.
    MalformedCommand,
    /// A `commit` with no `committer`.
    MissingCommitter,
    /// A `data` command was expected and something else came.
    MissingData,
    /// A `tag` with no `from`, or an `alias` with no `mark` or `to`.
    MissingFrom,
    /// An identity line git's `parse_ident` refuses.
    InvalidIdent,
    /// A date the chosen `DateFormat` does not read.
    InvalidDate,
    /// A mode git does not store.
    InvalidMode,
    /// A path git's `verify_path` refuses, an empty component, or one
    /// holding a NUL.
    InvalidPath,
    /// A mark used before it was set.
    UnknownMark,
    /// A data reference that is neither a mark nor a whole object name.
    InvalidDataref,
    /// A named object this repository does not have.
    ObjectMissing,
    /// An object of the wrong kind: a mark that is not a commit for `from`,
    /// a blob that is a tree, a tree-ish that is not one.
    WrongObjectType,
    /// A `from`, `merge` or note target that names nothing: git's "invalid
    /// ref name or SHA1 expression".
    BadRevision,
    /// A branch or tag whose name is not a ref name.
    InvalidRefName,
    /// A branch started from itself without `^0`.
    BranchFromItself,
    /// A tag or a note on a branch with no commit yet.
    EmptyBranch,
    /// A copy or rename from a path the branch does not have.
    PathNotInBranch,
    /// The root replaced by something that is not a directory.
    RootNotDirectory,
    /// A gitlink or a directory given `inline`.
    InlineNotAllowed,
    /// A signed commit or tag where `SignMode.abort` says to stop.
    SignedObject,
    /// A `gpgsig` command naming no hash git has or no signature format.
    InvalidSignature,
    /// A `feature` this does not have, or one refused by name.
    UnsupportedFeature,
    /// An `option git` this does not have.
    UnsupportedOption,
    /// A `feature` or `option` after the first command that is neither.
    LateFeature,
    /// A marks file feature in a stream not trusted with the filesystem:
    /// see `Options.allow_unsafe_features`.
    UnsafeFeature,
    /// A second `feature import-marks` in one stream.
    DuplicateImportMarks,
    /// The stream ended inside a `data`.
    TruncatedData,
    /// The stream ended without the `done` that `feature done` promised.
    StreamEndsEarly,
    /// A marks file line that is not `:<mark> <name>`.
    CorruptMarks,
    /// A path, or a tree a copy or rename builds, nesting deeper than
    /// `object.max_tree_depth`. git's fast-import writes such a tree, which
    /// git's own walks then refuse; relic stops at the stream.
    TreeTooDeep,
} || Allocator.Error || odb_mod.Error || refs_mod.ReadError || refs_mod.TransactionError || revwalk.Error ||
    Io.Reader.Error || Io.Writer.Error || Io.Dir.ReadFileAllocError || Io.Dir.CreateDirPathError || fs.LockError || fs.CommitError;

/// How the dates in identities are written: git's `--date-format`.
pub const DateFormat = enum {
    /// `<seconds> <±hhmm>`, the zone no more than 14 hours.
    raw,
    /// `raw` with no check on the numbers.
    raw_permissive,
    /// What a mail header carries, read as `git am` reads it.
    rfc2822,
    /// The literal `now`: the time `Options.now` gives.
    now,

    /// The format git names `text`, or `null`.
    pub fn parse(text: []const u8) ?DateFormat {
        if (std.mem.eql(u8, text, "raw")) return .raw;
        if (std.mem.eql(u8, text, "raw-permissive")) return .raw_permissive;
        if (std.mem.eql(u8, text, "rfc2822")) return .rfc2822;
        if (std.mem.eql(u8, text, "now")) return .now;
        return null;
    }
};

/// What becomes of a signature in the stream: git's `--signed-commits`
/// and `--signed-tags`, less the warning modes, whose warning is the
/// caller's to print, and the `*-if-invalid` ones.
pub const SignMode = enum {
    /// Keep it.
    verbatim,
    /// Drop it.
    strip,
    /// Stop with `error.SignedObject`.
    abort,

    /// The mode git names `text`, the warning modes as theirs; `null` for
    /// one not offered.
    pub fn parse(text: []const u8) ?SignMode {
        if (std.mem.eql(u8, text, "verbatim") or std.mem.eql(u8, text, "warn-verbatim")) return .verbatim;
        if (std.mem.eql(u8, text, "strip") or std.mem.eql(u8, text, "warn-strip")) return .strip;
        if (std.mem.eql(u8, text, "abort")) return .abort;
        return null;
    }
};

/// The time `DateFormat.now` writes.
pub const Now = struct {
    secs: i64,
    offset_minutes: i16 = 0,
};

/// How a stream is imported. The settings a stream may give itself with
/// `feature` and `option` are optional here: set, they win over the
/// stream's, as git's command line does.
pub const Options = struct {
    /// Who the ref logs say updated the refs.
    who: object.Signature,
    /// `--force`: update a branch even where the new tip does not contain
    /// the old.
    force: bool = false,
    /// `--done`: the stream must end with `done`.
    require_done: bool = false,
    date_format: ?DateFormat = null,
    signed_commits: ?SignMode = null,
    signed_tags: ?SignMode = null,
    /// `--import-marks`: a marks file read before the first command.
    import_marks: ?[]const u8 = null,
    /// `--import-marks-if-exists`: `import_marks` may be missing.
    import_marks_if_exists: bool = false,
    /// `--export-marks`: where the marks are written at the end.
    export_marks: ?[]const u8 = null,
    /// `--relative-marks`: marks files named relative to
    /// `.git/info/fast-import` rather than to `cwd`.
    relative_marks: bool = false,
    /// What marks file paths are relative to, for both the options and the
    /// stream's features; `null` is the process's working directory.
    cwd: ?Io.Dir = null,
    /// `--allow-unsafe-features`: let the stream name marks files.
    allow_unsafe_features: bool = false,
    /// git's standard output: `progress` lines, and the answers to
    /// `get-mark`, `cat-blob` and `ls` when there is no `responses`.
    output: ?*Io.Writer = null,
    /// `--cat-blob-fd`: where the answers go. Each is flushed as it is
    /// written, since the frontend waits for it.
    responses: ?*Io.Writer = null,
    /// The time for `DateFormat.now`; `null` reads the `Io`'s clock, in UTC.
    now: ?Now = null,
};

/// A branch left as it was at the end.
pub const Rejected = struct {
    name: []const u8,
    new: Oid,
    old: Oid,
    reason: Reason,

    pub const Reason = enum {
        /// The new tip does not contain the old: git's "not updating".
        not_fast_forward,
        /// The old or the new value is not a commit: git's "is missing
        /// commits".
        missing_commits,
    };
};

/// What an import did.
pub const Report = struct {
    pub const Error = ErrorNamespace.Error;

    gpa: Allocator,
    arena: std.heap.ArenaAllocator.State,
    /// The branches not updated; git's exit status is 1 when there are any.
    rejected: []Rejected,
    /// Every mark, as the import left them.
    marks: Marks,

    /// Release everything.
    pub fn deinit(r: *Report) void {
        r.marks.deinit(r.gpa);
        var arena = r.arena.promote(r.gpa);
        arena.deinit();
        r.* = undefined;
    }
};

/// Marks: the numbers a stream names objects by, as git's marks files hold
/// them.
pub const Marks = struct {
    pub const Error = ErrorNamespace.Error;

    map: std.AutoHashMapUnmanaged(u64, Oid) = .empty,

    /// Release the table.
    pub fn deinit(m: *Marks, gpa: Allocator) void {
        m.map.deinit(gpa);
        m.* = undefined;
    }

    /// The object `mark` names, or `null`.
    pub fn get(m: *const Marks, mark: u64) ?Oid {
        return m.map.get(mark);
    }

    /// Name `oid` by `mark`, over whatever it named.
    pub fn put(m: *Marks, gpa: Allocator, mark: u64, oid: Oid) Allocator.Error!void {
        // Mark zero is no mark: `parse` refuses it, and a stream that names
        // none puts nothing.
        assert(mark != 0);
        try m.map.put(gpa, mark, oid);
    }

    /// Errors from `parse`.
    pub const ParseError = Allocator.Error || error{CorruptMarks};

    /// Read a marks file's lines, `:<mark> <name>`, into the table; a mark
    /// read again takes the later name.
    pub fn parse(m: *Marks, gpa: Allocator, kind: hash.Kind, bytes: []const u8) ParseError!void {
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 and lines.peek() == null) break;
            if (line.len < 2 or line[0] != ':') return error.CorruptMarks;
            const space = std.mem.findScalar(u8, line, ' ') orelse return error.CorruptMarks;
            const mark = std.fmt.parseInt(u64, line[1..space], 10) catch return error.CorruptMarks;
            if (mark == 0) return error.CorruptMarks;
            const oid = Oid.parse(kind, line[space + 1 ..]) catch return error.CorruptMarks;
            try m.map.put(gpa, mark, oid);
        }
    }

    /// Errors from `write`.
    pub const WriteError = Allocator.Error || Io.Writer.Error;

    /// Write the table as git writes a marks file, lowest mark first.
    pub fn write(m: *const Marks, gpa: Allocator, w: *Io.Writer) WriteError!void {
        const keys = try gpa.alloc(u64, m.map.count());
        defer gpa.free(keys);
        var it = m.map.keyIterator();
        var i: usize = 0;
        while (it.next()) |k| : (i += 1) keys[i] = k.*;
        std.mem.sort(u64, keys, {}, std.sort.asc(u64));
        for (keys) |k| {
            assert(k != 0);
            try w.print(":{d} {f}\n", .{ k, m.map.get(k).? });
        }
    }
};

/// Read the fast-import stream `input` into `repo`.
pub fn import(gpa: Allocator, io: Io, repo: *Repository, input: *Io.Reader, options: Options) Self.Error!Report {
    var imp: Importer = try .init(gpa, io, repo, input, options);
    defer imp.deinit();
    try imp.run();
    return imp.report();
}

const dir_mode: u32 = 0o040000;
const gitlink_mode: u32 = 0o160000;

fn isDir(mode: u32) bool {
    return mode & 0o170000 == dir_mode;
}

/// A tree as git's fast-import holds one: `oid` is its name while nothing
/// in it has changed since, and `entries` are read on first use.
const Node = struct {
    oid: ?Oid,
    entries: ?std.ArrayList(Entry),
};

/// One entry of a held tree. A directory's contents are its `sub`; a mode
/// of zero is an entry deleted since the tree was last written, kept until
/// then as git keeps it.
const Entry = struct {
    name: []const u8,
    mode: u32,
    oid: Oid,
    sub: ?*Node = null,
};

const Branch = struct {
    name: []const u8,
    /// The tip; `null` for a branch with no commit.
    oid: ?Oid = null,
    root: *Node,
    /// A `from` of the null object: the ref is to go.
    delete: bool = false,
    num_notes: u64 = 0,
};

const TagRef = struct { name: []const u8, oid: Oid };

const Pending = struct { type: object.Type, bytes: []u8 };

/// Objects held in memory while the pack they are going into is open, and
/// the size past which it is closed so they can be read back from it.
const pending_limit: usize = 64 << 20;

const Importer = struct {
    gpa: Allocator,
    io: Io,
    repo: *Repository,
    kind: hash.Kind,
    input: *Io.Reader,
    options: Options,
    arena_state: std.heap.ArenaAllocator,
    line: Io.Writer.Allocating,
    unread: bool = false,
    eof: bool = false,
    seen_data_command: bool = false,

    marks: Marks = .{},
    types: Oid.Map(object.Type) = .empty,
    pending: Oid.Map(Pending) = .empty,
    pending_bytes: usize = 0,
    pack: ?odb_mod.Odb.OpenPack = null,
    branches: std.array_hash_map.String(*Branch) = .empty,
    tags: std.ArrayList(TagRef) = .empty,
    rejected: std.ArrayList(Rejected) = .empty,
    next_mark: u64 = 0,

    date_format: DateFormat,
    signed_commits: SignMode,
    signed_tags: SignMode,
    force: bool,
    require_done: bool,
    relative_marks: bool,
    import_marks: ?[]const u8,
    import_marks_if_exists: bool,
    import_marks_from_stream: bool = false,
    import_marks_done: bool = false,
    export_marks: ?[]const u8,
    ignore_case: bool,
    quote_path: bool,
    empty_tree: Oid,

    fn init(gpa: Allocator, io: Io, repo: *Repository, input: *Io.Reader, options: Options) Error!Importer {
        const config = repo.configuration();
        const kind = repo.objectFormat();
        return .{
            .gpa = gpa,
            .io = io,
            .repo = repo,
            .kind = kind,
            .input = input,
            .options = options,
            .arena_state = .init(gpa),
            .line = .init(gpa),
            .date_format = options.date_format orelse .raw,
            .signed_commits = options.signed_commits orelse .verbatim,
            .signed_tags = options.signed_tags orelse .verbatim,
            .force = options.force,
            .require_done = options.require_done,
            .relative_marks = options.relative_marks,
            .import_marks = options.import_marks,
            .import_marks_if_exists = options.import_marks_if_exists,
            .export_marks = options.export_marks,
            .ignore_case = config.getBool("core.ignorecase", false) catch false,
            .quote_path = config.getBool("core.quotepath", true) catch true,
            .empty_tree = hash.Hasher.object(kind, "tree", ""),
        };
    }

    fn deinit(imp: *Importer) void {
        if (imp.pack) |p| imp.repo.objectDatabase().abortPack(imp.io, p);
        var it = imp.pending.valueIterator();
        while (it.next()) |p| imp.gpa.free(p.bytes);
        imp.pending.deinit(imp.gpa);
        imp.types.deinit(imp.gpa);
        imp.marks.deinit(imp.gpa);
        imp.branches.deinit(imp.gpa);
        imp.tags.deinit(imp.gpa);
        imp.rejected.deinit(imp.gpa);
        imp.line.deinit();
        imp.arena_state.deinit();
        imp.* = undefined;
    }

    fn arena(imp: *Importer) Allocator {
        return imp.arena_state.allocator();
    }

    fn report(imp: *Importer) Error!Report {
        var out_arena: std.heap.ArenaAllocator = .init(imp.gpa);
        errdefer out_arena.deinit();
        const a = out_arena.allocator();
        const rejected = try a.alloc(Rejected, imp.rejected.items.len);
        for (imp.rejected.items, rejected) |r, *out| {
            out.* = r;
            out.name = try a.dupe(u8, r.name);
        }
        const marks = imp.marks;
        imp.marks = .{};
        return .{ .gpa = imp.gpa, .arena = out_arena.state, .rejected = rejected, .marks = marks };
    }

    //=================================================================
    // Reading the stream
    //=================================================================

    /// The next command line, comments skipped, or `null` at the end: git's
    /// `read_next_command`.
    fn next(imp: *Importer) Error!?[]const u8 {
        if (imp.eof) {
            imp.unread = false;
            return null;
        }
        while (true) {
            if (imp.unread) {
                imp.unread = false;
            } else {
                if (!try imp.readLine()) {
                    imp.eof = true;
                    return null;
                }
                const text = imp.line.written();
                if (!imp.seen_data_command and !std.mem.startsWith(u8, text, "feature ") and !std.mem.startsWith(u8, text, "option ")) {
                    try imp.startData();
                }
            }
            const text = imp.line.written();
            if (text.len > 0 and text[0] == '#') continue;
            return text;
        }
    }

    /// The current line, which `next` returned last.
    fn current(imp: *Importer) []const u8 {
        return imp.line.written();
    }

    fn readLine(imp: *Importer) Error!bool {
        imp.line.clearRetainingCapacity();
        _ = imp.input.streamDelimiterEnding(&imp.line.writer, '\n') catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            error.ReadFailed => return error.ReadFailed,
        };
        if (imp.input.bufferedLen() > 0) {
            imp.input.toss(1);
            return true;
        }
        return imp.line.written().len > 0;
    }

    fn skipOptionalLf(imp: *Importer) Error!void {
        const c = imp.input.peekByte() catch |err| switch (err) {
            error.EndOfStream => return,
            else => |e| return e,
        };
        if (c == '\n') imp.input.toss(1);
    }

    /// `data <n>` or `data <<<delim>`, at the current line; the bytes are
    /// the caller's.
    fn readData(imp: *Importer) Error![]u8 {
        const text = imp.current();
        if (!std.mem.startsWith(u8, text, "data ")) return error.MissingData;
        const arg = text["data ".len..];
        if (std.mem.startsWith(u8, arg, "<<")) {
            const term = try imp.gpa.dupe(u8, arg[2..]);
            defer imp.gpa.free(term);
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(imp.gpa);
            while (true) {
                if (!try imp.readLine()) return error.TruncatedData;
                const l = imp.line.written();
                if (std.mem.eql(u8, l, term)) break;
                try out.appendSlice(imp.gpa, l);
                try out.append(imp.gpa, '\n');
            }
            try imp.skipOptionalLf();
            return out.toOwnedSlice(imp.gpa);
        }
        const len = leadingNumber(arg) orelse 0;
        const bytes = try imp.gpa.alloc(u8, std.math.cast(usize, len) orelse return error.MalformedCommand);
        errdefer imp.gpa.free(bytes);
        imp.input.readSliceAll(bytes) catch |err| switch (err) {
            error.EndOfStream => return error.TruncatedData,
            else => |e| return e,
        };
        try imp.skipOptionalLf();
        return bytes;
    }

    /// git's `parse_argv`: the settings take effect and the marks are read
    /// once the first command that is not a `feature` or an `option` comes.
    fn startData(imp: *Importer) Error!void {
        const o = imp.options;
        if (o.date_format) |f| imp.date_format = f;
        if (o.signed_commits) |m| imp.signed_commits = m;
        if (o.signed_tags) |m| imp.signed_tags = m;
        if (o.force) imp.force = true;
        if (o.require_done) imp.require_done = true;
        if (o.export_marks) |p| imp.export_marks = try imp.marksPath(p);
        if (o.import_marks) |p| {
            imp.import_marks = try imp.marksPath(p);
            imp.import_marks_if_exists = o.import_marks_if_exists;
        }
        imp.seen_data_command = true;
        if (imp.import_marks != null) try imp.readMarks();
    }

    fn marksPath(imp: *Importer, path: []const u8) Error![]const u8 {
        if (!imp.relative_marks or std.Io.Dir.path.isAbsolute(path)) return imp.arena().dupe(u8, path);
        return imp.arena().print("info/fast-import/{s}", .{path});
    }

    /// The directory a marks path is relative to.
    fn marksDir(imp: *Importer, path: []const u8) Io.Dir {
        if (std.mem.startsWith(u8, path, "info/fast-import/") and imp.relative_marks) return imp.repo.commonDirectory();
        return imp.options.cwd orelse Io.Dir.cwd();
    }

    fn readMarks(imp: *Importer) Error!void {
        const path = imp.import_marks.?;
        const bytes = imp.marksDir(path).readFileAlloc(imp.io, path, imp.gpa, .unlimited) catch |err| switch (err) {
            error.FileNotFound => {
                if (!imp.import_marks_if_exists) return error.FileNotFound;
                imp.import_marks_done = true;
                return;
            },
            else => |e| return e,
        };
        defer imp.gpa.free(bytes);
        var read: Marks = .{};
        defer read.deinit(imp.gpa);
        try read.parse(imp.gpa, imp.kind, bytes);
        var it = read.map.iterator();
        while (it.next()) |e| {
            // git's `insert_object_entry`: a marked object must be here.
            _ = try imp.typeOf(e.value_ptr.*) orelse return error.ObjectMissing;
            try imp.marks.put(imp.gpa, e.key_ptr.*, e.value_ptr.*);
        }
        imp.import_marks_done = true;
    }

    fn dumpMarks(imp: *Importer) Error!void {
        const path = imp.export_marks orelse return;
        if (imp.import_marks != null and !imp.import_marks_done) return;
        const dir = imp.marksDir(path);
        if (std.Io.Dir.path.dirname(path)) |parent| try dir.createDirPath(imp.io, parent);
        var buffer: [4096]u8 = undefined;
        var lock = try fs.LockFile.open(imp.gpa, imp.io, dir, path, &buffer, .{});
        defer lock.deinit(imp.io);
        try imp.marks.write(imp.gpa, lock.writer());
        try lock.commit(imp.io);
    }

    //=================================================================
    // The commands
    //=================================================================

    fn run(imp: *Importer) Error!void {
        var done = false;
        while (try imp.next()) |text| {
            if (std.mem.eql(u8, text, "blob")) {
                try imp.blob();
            } else if (std.mem.startsWith(u8, text, "commit ")) {
                try imp.commit(try imp.arena().dupe(u8, text["commit ".len..]));
            } else if (std.mem.startsWith(u8, text, "tag ")) {
                try imp.tag(try imp.arena().dupe(u8, text["tag ".len..]));
            } else if (std.mem.startsWith(u8, text, "reset ")) {
                try imp.reset(try imp.arena().dupe(u8, text["reset ".len..]));
            } else if (std.mem.startsWith(u8, text, "ls ")) {
                try imp.ls(text["ls ".len..], null);
            } else if (std.mem.startsWith(u8, text, "cat-blob ")) {
                try imp.catBlob(text["cat-blob ".len..]);
            } else if (std.mem.startsWith(u8, text, "get-mark ")) {
                try imp.getMark(text["get-mark ".len..]);
            } else if (std.mem.eql(u8, text, "checkpoint")) {
                try imp.skipOptionalLf();
                try imp.checkpoint();
            } else if (std.mem.eql(u8, text, "done")) {
                done = true;
                break;
            } else if (std.mem.eql(u8, text, "alias")) {
                try imp.alias();
            } else if (std.mem.startsWith(u8, text, "progress ")) {
                if (imp.options.output) |w| {
                    try w.writeAll(text);
                    try w.writeByte('\n');
                    try w.flush();
                }
                try imp.skipOptionalLf();
            } else if (std.mem.startsWith(u8, text, "feature ")) {
                if (imp.seen_data_command) return error.LateFeature;
                try imp.feature(text["feature ".len..]);
            } else if (std.mem.startsWith(u8, text, "option git ")) {
                if (imp.seen_data_command) return error.LateFeature;
                try imp.option(text["option git ".len..]);
            } else if (std.mem.startsWith(u8, text, "option ")) {
                // another program's option
            } else return error.UnsupportedCommand;
        }
        if (!imp.seen_data_command) try imp.startData();
        if (imp.require_done and !done) return error.StreamEndsEarly;
        try imp.closePack();
        try imp.dumpBranches();
        try imp.dumpTags();
        try imp.dumpMarks();
    }

    fn checkpoint(imp: *Importer) Error!void {
        try imp.closePack();
        try imp.dumpBranches();
        try imp.dumpTags();
        try imp.dumpMarks();
    }

    fn feature(imp: *Importer, text: []const u8) Error!void {
        if (afterPrefix(text, "date-format=")) |arg| {
            imp.date_format = DateFormat.parse(arg) orelse return error.UnsupportedFeature;
        } else if (afterPrefix(text, "import-marks=")) |arg| {
            try imp.importMarksFeature(arg, false);
        } else if (afterPrefix(text, "import-marks-if-exists=")) |arg| {
            try imp.importMarksFeature(arg, true);
        } else if (afterPrefix(text, "export-marks=")) |arg| {
            if (!imp.options.allow_unsafe_features) return error.UnsafeFeature;
            imp.export_marks = try imp.marksPath(arg);
        } else if (std.mem.eql(u8, text, "relative-marks")) {
            imp.relative_marks = true;
        } else if (std.mem.eql(u8, text, "no-relative-marks")) {
            imp.relative_marks = false;
        } else if (std.mem.eql(u8, text, "done")) {
            imp.require_done = true;
        } else if (std.mem.eql(u8, text, "force")) {
            imp.force = true;
        } else if (std.mem.eql(u8, text, "alias") or std.mem.eql(u8, text, "get-mark") or
            std.mem.eql(u8, text, "cat-blob") or std.mem.eql(u8, text, "notes") or std.mem.eql(u8, text, "ls"))
        {
            // had
        } else return error.UnsupportedFeature;
    }

    fn importMarksFeature(imp: *Importer, path: []const u8, if_exists: bool) Error!void {
        if (!imp.options.allow_unsafe_features) return error.UnsafeFeature;
        if (imp.import_marks != null and imp.import_marks_from_stream) return error.DuplicateImportMarks;
        imp.import_marks = try imp.marksPath(path);
        imp.import_marks_if_exists = if_exists;
        imp.import_marks_from_stream = true;
    }

    fn option(imp: *Importer, text: []const u8) Error!void {
        if (afterPrefix(text, "signed-commits=")) |arg| {
            imp.signed_commits = SignMode.parse(arg) orelse return error.UnsupportedOption;
        } else if (afterPrefix(text, "signed-tags=")) |arg| {
            imp.signed_tags = SignMode.parse(arg) orelse return error.UnsupportedOption;
        } else if (afterPrefix(text, "max-pack-size=") != null or afterPrefix(text, "big-file-threshold=") != null or
            afterPrefix(text, "depth=") != null or afterPrefix(text, "active-branches=") != null or
            std.mem.eql(u8, text, "quiet") or std.mem.eql(u8, text, "stats") or std.mem.eql(u8, text, "allow-unsafe-features"))
        {
            // how git packs and reports, which says nothing of what is imported
        } else return error.UnsupportedOption;
    }

    /// `mark :<n>`, if the current line is one: git's `parse_mark`.
    fn parseMark(imp: *Importer) Error!void {
        if (afterPrefix(imp.current(), "mark :")) |arg| {
            imp.next_mark = leadingNumber(arg) orelse 0;
            _ = try imp.next();
        } else imp.next_mark = 0;
    }

    fn skipOriginalOid(imp: *Importer) Error!void {
        if (std.mem.startsWith(u8, imp.current(), "original-oid ")) _ = try imp.next();
    }

    fn blob(imp: *Importer) Error!void {
        _ = try imp.next();
        try imp.parseMark();
        try imp.skipOriginalOid();
        _ = try imp.storeData(imp.next_mark);
    }

    /// The `data` at the current line, stored as a blob.
    fn storeData(imp: *Importer, mark: u64) Error!Oid {
        const bytes = try imp.readData();
        defer imp.gpa.free(bytes);
        return imp.store(.blob, bytes, mark);
    }

    fn commit(imp: *Importer, name: []const u8) Error!void {
        const b = imp.branches.get(name) orelse try imp.newBranch(name);
        _ = try imp.next();
        try imp.parseMark();
        const mark = imp.next_mark;
        try imp.skipOriginalOid();
        var author: ?[]const u8 = null;
        var committer: ?[]const u8 = null;
        if (afterPrefix(imp.current(), "author ")) |v| {
            author = try imp.ident(v);
            _ = try imp.next();
        }
        if (afterPrefix(imp.current(), "committer ")) |v| {
            committer = try imp.ident(v);
            _ = try imp.next();
        }
        const who = committer orelse return error.MissingCommitter;

        var sig_sha1: ?[]const u8 = null;
        var sig_sha256: ?[]const u8 = null;
        while (afterPrefix(imp.current(), "gpgsig ")) |v| {
            if (imp.signed_commits == .abort) return error.SignedObject;
            const space = std.mem.findScalar(u8, v, ' ') orelse return error.InvalidSignature;
            const algo = v[0..space];
            const format = v[space + 1 ..];
            if (!std.mem.eql(u8, algo, "sha1") and !std.mem.eql(u8, algo, "sha256")) return error.InvalidSignature;
            if (!validSignatureFormat(format)) return error.InvalidSignature;
            const is_sha1 = std.mem.eql(u8, algo, "sha1");
            _ = try imp.next();
            const data = try imp.readData();
            const slot = if (is_sha1) &sig_sha1 else &sig_sha256;
            // A second signature for one hash is ignored, as git ignores it.
            if (imp.signed_commits == .verbatim and slot.* == null) {
                slot.* = try imp.arena().dupe(u8, data);
            }
            imp.gpa.free(data);
            _ = try imp.next();
        }
        var encoding: ?[]const u8 = null;
        if (afterPrefix(imp.current(), "encoding ")) |v| {
            encoding = try imp.arena().dupe(u8, v);
            _ = try imp.next();
        }
        const message = try imp.readData();
        defer imp.gpa.free(message);
        _ = try imp.next();
        if (afterPrefix(imp.current(), "from ")) |from| {
            try imp.parseObjectish(b, try imp.gpa.dupe(u8, from));
        }
        var merges: std.ArrayList(Oid) = .empty;
        defer merges.deinit(imp.gpa);
        while (afterPrefix(imp.current(), "merge ")) |from| {
            try merges.append(imp.gpa, try imp.mergeParent(from));
            _ = try imp.next();
        }

        var prev_fanout = fanoutFor(b.num_notes);
        while (imp.current().len > 0 and !imp.eof) {
            const text = imp.current();
            if (afterPrefix(text, "M ")) |v| {
                try imp.fileModify(b, try imp.gpa.dupe(u8, v));
            } else if (afterPrefix(text, "D ")) |v| {
                const path = try imp.parsePathEol(v);
                defer imp.gpa.free(path);
                _ = try imp.removePath(&b.root, path, null, true);
            } else if (afterPrefix(text, "R ")) |v| {
                try imp.copyOrRename(b, v, true);
            } else if (afterPrefix(text, "C ")) |v| {
                try imp.copyOrRename(b, v, false);
            } else if (afterPrefix(text, "N ")) |v| {
                try imp.noteModify(b, try imp.gpa.dupe(u8, v), &prev_fanout);
            } else if (std.mem.eql(u8, text, "deleteall")) {
                b.root = try imp.newNode(null);
                b.num_notes = 0;
            } else if (afterPrefix(text, "ls ")) |v| {
                try imp.ls(v, b);
            } else if (afterPrefix(text, "cat-blob ")) |v| {
                try imp.catBlob(v);
            } else {
                imp.unread = true;
                break;
            }
            if (try imp.next() == null) break;
        }
        const new_fanout = fanoutFor(b.num_notes);
        if (new_fanout != prev_fanout) b.num_notes = try imp.changeFanout(b.root, new_fanout);

        const tree = try imp.storeTree(b.root);
        var out: Io.Writer.Allocating = .init(imp.gpa);
        defer out.deinit();
        const w = &out.writer;
        w.print("tree {f}\n", .{tree}) catch return error.OutOfMemory;
        if (b.oid) |p| w.print("parent {f}\n", .{p}) catch return error.OutOfMemory;
        for (merges.items) |p| w.print("parent {f}\n", .{p}) catch return error.OutOfMemory;
        w.print("author {s}\ncommitter {s}\n", .{ author orelse who, who }) catch return error.OutOfMemory;
        if (encoding) |e| w.print("encoding {s}\n", .{e}) catch return error.OutOfMemory;
        if (sig_sha1) |s| writeSignatureHeader(w, "gpgsig ", s) catch return error.OutOfMemory;
        if (sig_sha256) |s| writeSignatureHeader(w, "gpgsig-sha256 ", s) catch return error.OutOfMemory;
        w.writeByte('\n') catch return error.OutOfMemory;
        w.writeAll(message) catch return error.OutOfMemory;
        b.oid = try imp.store(.commit, out.written(), mark);
    }

    fn tag(imp: *Importer, name: []const u8) Error!void {
        _ = try imp.next();
        try imp.parseMark();
        const mark = imp.next_mark;
        const from = afterPrefix(imp.current(), "from ") orelse return error.MissingFrom;
        var target: Oid = undefined;
        var target_type: object.Type = undefined;
        if (imp.branches.get(from)) |s| {
            target = s.oid orelse return error.EmptyBranch;
            target_type = .commit;
        } else if (from.len > 0 and from[0] == ':') {
            target = try imp.markRefEol(from);
            target_type = try imp.typeOf(target) orelse return error.ObjectMissing;
        } else {
            target = try imp.resolve(from);
            target_type = try imp.typeOf(target) orelse return error.ObjectMissing;
        }
        _ = try imp.next();
        try imp.skipOriginalOid();
        var tagger: ?[]const u8 = null;
        if (afterPrefix(imp.current(), "tagger ")) |v| {
            tagger = try imp.ident(v);
            _ = try imp.next();
        }
        const message = try imp.readData();
        defer imp.gpa.free(message);
        var body: []const u8 = message;
        const sig_offset = signedOffset(message);
        if (sig_offset < message.len) switch (imp.signed_tags) {
            .verbatim => {},
            .strip => body = message[0..sig_offset],
            .abort => return error.SignedObject,
        };
        var out: Io.Writer.Allocating = .init(imp.gpa);
        defer out.deinit();
        const w = &out.writer;
        w.print("object {f}\ntype {s}\ntag {s}\n", .{ target, target_type.name(), name }) catch return error.OutOfMemory;
        if (tagger) |t| w.print("tagger {s}\n", .{t}) catch return error.OutOfMemory;
        w.writeByte('\n') catch return error.OutOfMemory;
        w.writeAll(body) catch return error.OutOfMemory;
        const oid = try imp.store(.tag, out.written(), mark);
        try imp.tags.append(imp.gpa, .{ .name = name, .oid = oid });
    }

    fn reset(imp: *Importer, name: []const u8) Error!void {
        const b = if (imp.branches.get(name)) |b| blk: {
            b.oid = null;
            b.root = try imp.newNode(null);
            break :blk b;
        } else try imp.newBranch(name);
        _ = try imp.next();
        if (afterPrefix(imp.current(), "from ")) |from| try imp.parseObjectish(b, try imp.gpa.dupe(u8, from));
        if (b.delete) if (afterPrefix(b.name, "refs/tags/")) |tag_name| {
            // The tag list is written after the branches, so a deleted tag
            // leaves it, as git takes it out.
            for (imp.tags.items, 0..) |t, i| if (std.mem.eql(u8, t.name, tag_name)) {
                _ = imp.tags.orderedRemove(i);
                break;
            };
        };
        if (imp.current().len > 0 and !imp.eof) imp.unread = true;
    }

    fn alias(imp: *Importer) Error!void {
        try imp.skipOptionalLf();
        _ = try imp.next();
        try imp.parseMark();
        if (imp.next_mark == 0) return error.MissingFrom;
        const mark = imp.next_mark;
        const to = afterPrefix(imp.current(), "to ") orelse return error.MissingFrom;
        var scratch: Branch = .{ .name = "", .root = try imp.newNode(null) };
        try imp.parseObjectish(&scratch, try imp.gpa.dupe(u8, to));
        try imp.marks.put(imp.gpa, mark, scratch.oid orelse Oid.zero(imp.kind));
    }

    fn newBranch(imp: *Importer, name: []const u8) Error!*Branch {
        if (!ref_names.checkFormat(name, .{ .allow_onelevel = true })) return error.InvalidRefName;
        const b = try imp.arena().create(Branch);
        const owned = try imp.arena().dupe(u8, name);
        b.* = .{ .name = owned, .root = try imp.newNode(null) };
        try imp.branches.put(imp.gpa, owned, b);
        return b;
    }

    /// `from` for `b`: git's `parse_objectish`. Takes `text`, which is the
    /// importer's to free; the next line is read.
    fn parseObjectish(imp: *Importer, b: *Branch, text: []u8) Error!void {
        defer imp.gpa.free(text);
        const prev_tree = b.root.oid;
        if (imp.branches.get(text)) |s| {
            if (s == b) return error.BranchFromItself;
            b.oid = s.oid;
            b.root = try imp.newNode(s.root.oid);
        } else if (text.len > 0 and text[0] == ':') {
            const oid = try imp.markRefEol(text);
            if (try imp.typeOf(oid) != .commit) return error.WrongObjectType;
            if (b.oid == null or !b.oid.?.eql(oid)) {
                b.oid = oid;
                b.root = try imp.newNode(try imp.commitTree(oid));
            }
        } else {
            const oid = try imp.resolve(text);
            if (oid.isZero()) {
                b.oid = null;
                b.root = try imp.newNode(null);
                b.delete = true;
            } else {
                const peeled = try imp.peelToCommit(oid);
                b.oid = peeled;
                b.root = try imp.newNode(try imp.commitTree(peeled));
            }
        }
        if (prev_tree != null and b.root.oid != null and prev_tree.?.eql(b.root.oid.?)) {
            // the same tree: git keeps what it held
        }
        _ = try imp.next();
    }

    fn mergeParent(imp: *Importer, text: []const u8) Error!Oid {
        if (imp.branches.get(text)) |s| return s.oid orelse Oid.zero(imp.kind);
        if (text.len > 0 and text[0] == ':') {
            const oid = try imp.markRefEol(text);
            if (try imp.typeOf(oid) != .commit) return error.WrongObjectType;
            return oid;
        }
        return imp.peelToCommit(try imp.resolve(text));
    }

    /// A commit-ish that is not a branch or a mark: git's `get_oid`.
    fn resolve(imp: *Importer, text: []const u8) Error!Oid {
        if (text.len == imp.kind.hexLen()) {
            if (Oid.parse(imp.kind, text)) |oid| return oid else |_| {}
        }
        return revparse.resolve(imp.gpa, imp.io, imp.repo, text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.BadRevision,
        };
    }

    //=================================================================
    // File changes
    //=================================================================

    fn fileModify(imp: *Importer, b: *Branch, text: []u8) Error!void {
        defer imp.gpa.free(text);
        const space = std.mem.findScalar(u8, text, ' ') orelse return error.InvalidMode;
        var mode = parseOctal(text[0..space]) orelse return error.InvalidMode;
        switch (mode) {
            0o644, 0o755 => mode |= 0o100000,
            0o100644, 0o100755, 0o120000, dir_mode, gitlink_mode => {},
            else => return error.InvalidMode,
        }
        var p: []const u8 = text[space + 1 ..];
        var oid: Oid = undefined;
        var inline_data = false;
        var known: ?object.Type = null;
        if (p.len > 0 and p[0] == ':') {
            const r = try imp.markRefSpace(p);
            oid = r.oid;
            p = r.rest;
            known = try imp.typeOf(oid);
        } else if (afterPrefix(p, "inline ")) |rest| {
            inline_data = true;
            p = rest;
        } else {
            const hex_len = imp.kind.hexLen();
            if (p.len < hex_len) return error.InvalidDataref;
            oid = Oid.parse(imp.kind, p[0..hex_len]) catch return error.InvalidDataref;
            if (p.len == hex_len or p[hex_len] != ' ') return error.MalformedCommand;
            p = p[hex_len + 1 ..];
        }
        const path = try imp.parsePathEol(p);
        defer imp.gpa.free(path);

        // Git does not track empty directories below the top.
        if (isDir(mode) and !inline_data and oid.eql(imp.empty_tree) and path.len > 0) {
            _ = try imp.removePath(&b.root, path, null, false);
            return;
        }
        if (mode == gitlink_mode) {
            if (inline_data) return error.InlineNotAllowed;
            if (known) |t| if (t != .commit) return error.WrongObjectType;
        } else if (inline_data) {
            if (isDir(mode)) return error.InlineNotAllowed;
            while (try imp.next()) |line| {
                if (afterPrefix(line, "cat-blob ")) |v| {
                    try imp.catBlob(v);
                } else {
                    oid = try imp.storeData(0);
                    break;
                }
            }
        } else {
            const expected: object.Type = if (isDir(mode)) .tree else .blob;
            const t = try imp.typeOf(oid) orelse return error.ObjectMissing;
            if (t != expected) return error.WrongObjectType;
        }
        if (path.len == 0) {
            if (!isDir(mode)) return error.RootNotDirectory;
            b.root = try imp.newNode(oid);
            return;
        }
        if (!validPath(path, mode)) return error.InvalidPath;
        _ = try imp.setPath(b.root, path, oid, mode, null);
    }

    fn copyOrRename(imp: *Importer, b: *Branch, text: []const u8, rename: bool) Error!void {
        const source = try imp.parsePath(text, false);
        defer imp.gpa.free(source.path);
        if (source.rest.len == 0 or source.rest[0] != ' ') return error.MalformedCommand;
        const dest = try imp.parsePathEol(source.rest[1..]);
        defer imp.gpa.free(dest);
        var leaf: Entry = .{ .name = "", .mode = 0, .oid = Oid.zero(imp.kind) };
        if (rename) {
            _ = try imp.removePath(&b.root, source.path, &leaf, true);
        } else {
            _ = try imp.getPath(b.root, source.path, &leaf, true);
        }
        if (leaf.mode == 0) return error.PathNotInBranch;
        if (dest.len == 0) {
            if (!isDir(leaf.mode)) return error.RootNotDirectory;
            b.root = leaf.sub orelse try imp.newNode(leaf.oid);
            return;
        }
        if (!validPath(dest, leaf.mode)) return error.InvalidPath;
        _ = try imp.setPath(b.root, dest, leaf.oid, leaf.mode, leaf.sub);
    }

    fn noteModify(imp: *Importer, b: *Branch, text: []u8, old_fanout: *u8) Error!void {
        defer imp.gpa.free(text);
        // A notes ref read in has an uncounted tree; count it the first
        // time, as git does.
        if (b.num_notes == 0 and old_fanout.* == 0) {
            b.num_notes = try imp.changeFanout(b.root, 0xff);
            old_fanout.* = fanoutFor(b.num_notes);
        }
        var p: []const u8 = text;
        var oid: Oid = undefined;
        var inline_data = false;
        var known: ?object.Type = null;
        if (p.len > 0 and p[0] == ':') {
            const r = try imp.markRefSpace(p);
            oid = r.oid;
            p = r.rest;
            known = try imp.typeOf(oid);
        } else if (afterPrefix(p, "inline ")) |rest| {
            inline_data = true;
            p = rest;
        } else {
            const hex_len = imp.kind.hexLen();
            if (p.len < hex_len) return error.InvalidDataref;
            oid = Oid.parse(imp.kind, p[0..hex_len]) catch return error.InvalidDataref;
            if (p.len == hex_len or p[hex_len] != ' ') return error.MalformedCommand;
            p = p[hex_len + 1 ..];
            if (!oid.isZero()) known = try imp.typeOf(oid) orelse return error.ObjectMissing;
        }
        var commit_oid: Oid = undefined;
        if (imp.branches.get(p)) |s| {
            commit_oid = s.oid orelse return error.EmptyBranch;
        } else if (p.len > 0 and p[0] == ':') {
            commit_oid = try imp.markRefEol(p);
            if (try imp.typeOf(commit_oid) != .commit) return error.WrongObjectType;
        } else {
            commit_oid = try imp.peelToCommit(try imp.resolve(p));
        }
        if (inline_data) {
            _ = try imp.next();
            oid = try imp.storeData(0);
        } else if (known) |t| {
            if (t != .blob) return error.WrongObjectType;
        }

        var hex_buf: [hash.max_hex_len]u8 = undefined;
        const hex = commit_oid.hex(&hex_buf);
        var path_buf: [hash.max_hex_len * 3 / 2]u8 = undefined;
        if (try imp.removePath(&b.root, fanoutPath(hex, old_fanout.*, &path_buf), null, false)) b.num_notes -%= 1;
        if (oid.isZero()) return;
        b.num_notes += 1;
        _ = try imp.setPath(b.root, fanoutPath(hex, fanoutFor(b.num_notes), &path_buf), oid, 0o100644, null);
    }

    /// Move every note in `root` to where `fanout` puts it, and count them;
    /// a fanout of 0xff only counts. git's `change_note_fanout`.
    fn changeFanout(imp: *Importer, root: *Node, fanout: u8) Error!u64 {
        var hex: [hash.max_hex_len]u8 = undefined;
        var full: [hash.max_hex_len * 3 / 2]u8 = undefined;
        return imp.changeFanoutIn(root, root, &hex, 0, &full, 0, fanout);
    }

    fn changeFanoutIn(
        imp: *Importer,
        orig_root: *Node,
        node: *Node,
        hex: *[hash.max_hex_len]u8,
        hex_len: usize,
        full: *[hash.max_hex_len * 3 / 2]u8,
        full_len: usize,
        fanout: u8,
    ) Error!u64 {
        const hexsz = imp.kind.hexLen();
        try imp.load(node);
        var count: u64 = 0;
        var i: usize = 0;
        while (i < node.entries.?.items.len) : (i += 1) {
            const e = node.entries.?.items[i];
            const tmp_hex_len = hex_len + e.name.len;
            if (e.mode == 0 or tmp_hex_len > hexsz or e.name.len % 2 != 0) continue;
            @memcpy(hex[hex_len..tmp_hex_len], e.name);
            var tmp_full_len = full_len;
            if (tmp_full_len > 0) {
                full[tmp_full_len] = '/';
                tmp_full_len += 1;
            }
            @memcpy(full[tmp_full_len..][0..e.name.len], e.name);
            tmp_full_len += e.name.len;
            if (tmp_hex_len == hexsz and isHex(hex[0..hexsz])) {
                if (fanout == 0xff) {
                    count += 1;
                    continue;
                }
                var real_buf: [hash.max_hex_len * 3 / 2]u8 = undefined;
                const real = fanoutPath(hex[0..hexsz], fanout, &real_buf);
                if (std.mem.eql(u8, full[0..tmp_full_len], real)) {
                    count += 1;
                    continue;
                }
                const from = try imp.gpa.dupe(u8, full[0..tmp_full_len]);
                defer imp.gpa.free(from);
                var leaf: Entry = .{ .name = "", .mode = 0, .oid = Oid.zero(imp.kind) };
                var root_slot = orig_root;
                if (!try imp.removePath(&root_slot, from, &leaf, false)) return error.PathNotInBranch;
                _ = try imp.setPath(orig_root, real, leaf.oid, leaf.mode, leaf.sub);
            } else if (isDir(e.mode)) {
                count += try imp.changeFanoutIn(orig_root, e.sub.?, hex, tmp_hex_len, full, tmp_full_len, fanout);
            }
        }
        return count;
    }

    //=================================================================
    // Queries
    //=================================================================

    fn responder(imp: *Importer) ?*Io.Writer {
        return imp.options.responses orelse imp.options.output;
    }

    fn getMark(imp: *Importer, text: []const u8) Error!void {
        if (text.len == 0 or text[0] != ':') return error.InvalidDataref;
        const oid = try imp.markRefEol(text);
        const w = imp.responder() orelse return;
        try w.print("{f}\n", .{oid});
        try w.flush();
    }

    fn catBlob(imp: *Importer, text: []const u8) Error!void {
        const oid = if (text.len > 0 and text[0] == ':')
            try imp.markRefEol(text)
        else blk: {
            if (text.len != imp.kind.hexLen()) return error.InvalidDataref;
            break :blk Oid.parse(imp.kind, text) catch return error.InvalidDataref;
        };
        const w = imp.responder() orelse return;
        const found = imp.readObject(oid) catch |err| switch (err) {
            error.ObjectNotFound => {
                try w.print("{f} missing\n", .{oid});
                try w.flush();
                return;
            },
            else => |e| return e,
        };
        defer imp.gpa.free(found.bytes);
        if (found.type != .blob) return error.WrongObjectType;
        try w.print("{f} blob {d}\n", .{ oid, found.bytes.len });
        try w.writeAll(found.bytes);
        try w.writeByte('\n');
        try w.flush();
    }

    fn ls(imp: *Importer, text: []const u8, b: ?*Branch) Error!void {
        var root: *Node = undefined;
        var p = text;
        if (p.len > 0 and p[0] == '"') {
            root = (b orelse return error.MalformedCommand).root;
        } else {
            var oid: Oid = undefined;
            if (p.len > 0 and p[0] == ':') {
                const r = try imp.markRefSpace(p);
                oid = r.oid;
                p = r.rest;
            } else {
                const hex_len = imp.kind.hexLen();
                if (p.len < hex_len) return error.InvalidDataref;
                oid = Oid.parse(imp.kind, p[0..hex_len]) catch return error.InvalidDataref;
                if (p.len == hex_len or p[hex_len] != ' ') return error.MalformedCommand;
                p = p[hex_len + 1 ..];
            }
            root = try imp.newNode(try imp.peelToTree(oid));
        }
        const path = try imp.parsePathEol(p);
        defer imp.gpa.free(path);
        var leaf: Entry = .{ .name = "", .mode = 0, .oid = Oid.zero(imp.kind) };
        _ = try imp.getPath(root, path, &leaf, true);
        if (isDir(leaf.mode)) leaf.oid = try imp.storeTree(leaf.sub orelse try imp.newNode(leaf.oid));
        const w = imp.responder() orelse return;
        if (leaf.mode == 0) {
            try w.writeAll("missing ");
        } else {
            const type_name = if (leaf.mode == gitlink_mode) "commit" else if (isDir(leaf.mode)) "tree" else "blob";
            try w.print("{o:0>6} {s} {f}\t", .{ leaf.mode, type_name, leaf.oid });
        }
        try cquote.write(w, path, imp.quote_path);
        try w.writeByte('\n');
        try w.flush();
    }

    //=================================================================
    // Paths, marks and identities
    //=================================================================

    const Parsed = struct { path: []u8, rest: []const u8 };

    /// A path at the start of `text`: quoted, or bare up to a space (or to
    /// the end when it is the last field). The path is the importer's.
    fn parsePath(imp: *Importer, text: []const u8, last: bool) Error!Parsed {
        if (text.len > 0 and text[0] == '"') {
            const unquoted = try cquote.unquote(imp.gpa, text) orelse return error.InvalidPath;
            if (std.mem.findScalar(u8, unquoted.name, 0) != null) {
                imp.gpa.free(unquoted.name);
                return error.InvalidPath;
            }
            return .{ .path = unquoted.name, .rest = text[unquoted.consumed..] };
        }
        const end = if (last) text.len else std.mem.findScalar(u8, text, ' ') orelse text.len;
        return .{ .path = try imp.gpa.dupe(u8, text[0..end]), .rest = text[end..] };
    }

    fn parsePathEol(imp: *Importer, text: []const u8) Error![]u8 {
        const parsed = try imp.parsePath(text, true);
        if (parsed.rest.len != 0) {
            imp.gpa.free(parsed.path);
            return error.MalformedCommand;
        }
        return parsed.path;
    }

    fn markNumber(text: []const u8) Error!struct { mark: u64, len: usize } {
        assert(text[0] == ':');
        var i: usize = 1;
        while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {}
        if (i == 1) return error.MalformedCommand;
        const mark = std.fmt.parseInt(u64, text[1..i], 10) catch return error.MalformedCommand;
        return .{ .mark = mark, .len = i };
    }

    fn markRefEol(imp: *Importer, text: []const u8) Error!Oid {
        const n = try markNumber(text);
        if (n.len != text.len) return error.MalformedCommand;
        return imp.marks.get(n.mark) orelse error.UnknownMark;
    }

    fn markRefSpace(imp: *Importer, text: []const u8) Error!struct { oid: Oid, rest: []const u8 } {
        const n = try markNumber(text);
        if (n.len >= text.len or text[n.len] != ' ') return error.MalformedCommand;
        return .{ .oid = imp.marks.get(n.mark) orelse return error.UnknownMark, .rest = text[n.len + 1 ..] };
    }

    /// An identity as git's `parse_ident` keeps it: the name and address as
    /// written, the date as the format makes it. The text is the arena's.
    fn ident(imp: *Importer, text_in: []const u8) Error![]const u8 {
        // A missing name keeps the space before the `<`.
        var owned: std.ArrayList(u8) = .empty;
        if (text_in.len > 0 and text_in[0] == '<') try owned.append(imp.arena(), ' ');
        try owned.appendSlice(imp.arena(), text_in);
        const text = owned.items;
        const lt = std.mem.findAny(u8, text, "<>") orelse return error.InvalidIdent;
        if (text[lt] != '<') return error.InvalidIdent;
        if (lt != 0 and text[lt - 1] != ' ') return error.InvalidIdent;
        const gt = std.mem.findAnyPos(u8, text, lt + 1, "<>") orelse return error.InvalidIdent;
        if (text[gt] != '>') return error.InvalidIdent;
        if (gt + 1 >= text.len or text[gt + 1] != ' ') return error.InvalidIdent;
        const head = text[0 .. gt + 2];
        const when = text[gt + 2 ..];
        switch (imp.date_format) {
            .raw, .raw_permissive => {
                if (!validRawDate(when, imp.date_format == .raw)) return error.InvalidDate;
                return text;
            },
            .rfc2822 => {
                const parsed = gitdate.parse(when, .{ .now = 0 }) orelse return error.InvalidDate;
                return imp.withDate(head, parsed.secs, parsed.offset_minutes);
            },
            .now => {
                if (!std.mem.eql(u8, when, "now")) return error.InvalidDate;
                const now = imp.options.now orelse Now{ .secs = Io.Clock.real.now(imp.io).toSeconds() };
                return imp.withDate(head, now.secs, now.offset_minutes);
            },
        }
    }

    fn withDate(imp: *Importer, head: []const u8, secs: i64, offset_minutes: i32) Error![]const u8 {
        const sign: u8 = if (offset_minutes < 0) '-' else '+';
        const abs: u32 = @abs(offset_minutes);
        return imp.arena().print("{s}{d} {c}{d:0>2}{d:0>2}", .{ head, secs, sign, abs / 60, abs % 60 });
    }

    //=================================================================
    // Trees held in memory
    //=================================================================

    fn newNode(imp: *Importer, oid: ?Oid) Error!*Node {
        const n = try imp.arena().create(Node);
        n.* = .{ .oid = oid, .entries = if (oid == null) .empty else null };
        return n;
    }

    /// Read a held tree's entries on first use: git's `load_tree`.
    fn load(imp: *Importer, node: *Node) Error!void {
        if (node.entries != null) return;
        node.entries = .empty;
        const oid = node.oid orelse return;
        if (oid.eql(imp.empty_tree)) return;
        const found = try imp.readObject(oid);
        defer imp.gpa.free(found.bytes);
        if (found.type != .tree) return error.WrongObjectType;
        var it = object.Tree.parse(imp.kind, found.bytes).iterate();
        while (try it.next()) |e| {
            const mode = e.mode.raw();
            try node.entries.?.append(imp.arena(), .{
                .name = try imp.arena().dupe(u8, e.name),
                .mode = mode,
                .oid = e.oid,
                .sub = if (isDir(mode)) try imp.newNode(e.oid) else null,
            });
        }
    }

    fn nameEql(imp: *const Importer, a: []const u8, b: []const u8) bool {
        if (imp.ignore_case) return std.ascii.eqlIgnoreCase(a, b);
        return std.mem.eql(u8, a, b);
    }

    /// git's `tree_content_set`: whether anything changed.
    fn setPath(imp: *Importer, node: *Node, path: []const u8, oid: Oid, mode: u32, subtree: ?*Node) Error!bool {
        try checkDepth(path);
        return imp.setPathIn(node, path, oid, mode, subtree);
    }

    fn setPathIn(imp: *Importer, node: *Node, path: []const u8, oid: Oid, mode: u32, subtree: ?*Node) Error!bool {
        const slash = std.mem.findScalar(u8, path, '/');
        const name = path[0 .. slash orelse path.len];
        if (name.len == 0) return error.InvalidPath;
        try imp.load(node);
        for (node.entries.?.items) |*e| {
            if (!imp.nameEql(e.name, name)) continue;
            if (slash == null) {
                if (!isDir(mode) and e.mode == mode and e.oid.eql(oid)) return false;
                e.mode = mode;
                e.oid = oid;
                e.sub = if (isDir(mode)) subtree orelse try imp.newNode(oid) else null;
                node.oid = null;
                return true;
            }
            if (!isDir(e.mode)) {
                e.sub = try imp.newNode(null);
                e.mode = dir_mode;
            }
            if (try imp.setPathIn(e.sub.?, path[slash.? + 1 ..], oid, mode, subtree)) {
                node.oid = null;
                return true;
            }
            return false;
        }
        var e: Entry = .{ .name = try imp.arena().dupe(u8, name), .mode = mode, .oid = oid };
        if (slash) |s| {
            e.mode = dir_mode;
            e.sub = try imp.newNode(null);
            _ = try imp.setPathIn(e.sub.?, path[s + 1 ..], oid, mode, subtree);
        } else if (isDir(mode)) {
            e.sub = subtree orelse try imp.newNode(oid);
        }
        try node.entries.?.append(imp.arena(), e);
        node.oid = null;
        return true;
    }

    /// git's `tree_content_remove`: whether the path is gone. `backup`
    /// takes the entry removed, its held tree with it. The root itself goes
    /// when `allow_root` and the path is empty.
    fn removePath(imp: *Importer, slot: **Node, path: []const u8, backup: ?*Entry, allow_root: bool) Error!bool {
        const node = slot.*;
        try imp.load(node);
        if (path.len == 0 and allow_root) {
            if (backup) |out| out.* = .{ .name = "", .mode = dir_mode, .oid = node.oid orelse Oid.zero(imp.kind), .sub = node };
            slot.* = try imp.newNode(null);
            return true;
        }
        try checkDepth(path);
        return imp.removeIn(node, path, backup);
    }

    fn removeIn(imp: *Importer, node: *Node, path: []const u8, backup_in: ?*Entry) Error!bool {
        var backup = backup_in;
        try imp.load(node);
        const slash = std.mem.findScalar(u8, path, '/');
        const name = path[0 .. slash orelse path.len];
        for (node.entries.?.items) |*e| {
            if (!imp.nameEql(e.name, name)) continue;
            // A file standing where a directory of the path would be: the
            // path cannot exist, and need not be deleted.
            if (slash != null and !isDir(e.mode)) return true;
            if (slash != null) {
                if (try imp.removeIn(e.sub.?, path[slash.? + 1 ..], backup)) {
                    for (e.sub.?.entries.?.items) |child| if (child.mode != 0) {
                        node.oid = null;
                        return true;
                    };
                    backup = null;
                } else return false;
            }
            if (backup) |out| out.* = e.*;
            e.mode = 0;
            e.sub = null;
            node.oid = null;
            return true;
        }
        return false;
    }

    /// git's `tree_content_get`: the entry at `path`, a held tree copied so
    /// changes to one do not reach the other.
    fn getPath(imp: *Importer, node: *Node, path: []const u8, leaf: *Entry, allow_root: bool) Error!bool {
        try checkDepth(path);
        return imp.getPathIn(node, path, leaf, allow_root);
    }

    fn getPathIn(imp: *Importer, node: *Node, path: []const u8, leaf: *Entry, allow_root: bool) Error!bool {
        const slash = std.mem.findScalar(u8, path, '/');
        const name = path[0 .. slash orelse path.len];
        if (name.len == 0 and !allow_root) return error.InvalidPath;
        try imp.load(node);
        if (name.len == 0) {
            leaf.* = .{ .name = "", .mode = dir_mode, .oid = node.oid orelse Oid.zero(imp.kind), .sub = try imp.copyNode(node) };
            return true;
        }
        for (node.entries.?.items) |e| {
            if (!imp.nameEql(e.name, name)) continue;
            if (slash == null) {
                leaf.* = e;
                if (e.sub) |sub| leaf.sub = try imp.copyNode(sub);
                return true;
            }
            if (!isDir(e.mode)) return false;
            return imp.getPathIn(e.sub.?, path[slash.? + 1 ..], leaf, false);
        }
        return false;
    }

    fn copyNode(imp: *Importer, node: *Node) Error!*Node {
        return imp.copyNodeAt(node, 0);
    }

    fn copyNodeAt(imp: *Importer, node: *Node, depth: u32) Error!*Node {
        if (node.oid) |oid| return imp.newNode(oid);
        if (depth > object.max_tree_depth) return error.TreeTooDeep;
        const copy = try imp.newNode(null);
        for (node.entries.?.items) |e| {
            var c = e;
            if (e.sub) |sub| c.sub = try imp.copyNodeAt(sub, depth + 1);
            try copy.entries.?.append(imp.arena(), c);
        }
        return copy;
    }

    /// Write a held tree and everything changed under it: git's
    /// `store_tree`.
    fn storeTree(imp: *Importer, node: *Node) Error!Oid {
        return imp.storeTreeAt(node, 0);
    }

    /// `storeTree` for a node `depth` trees down. Copies and renames can
    /// stack held trees deeper than any one path reaches, so the depth is
    /// counted here too.
    fn storeTreeAt(imp: *Importer, node: *Node, depth: u32) Error!Oid {
        if (node.oid) |oid| return oid;
        if (depth > object.max_tree_depth) return error.TreeTooDeep;
        try imp.load(node);
        const entries = &node.entries.?;
        var kept: usize = 0;
        for (entries.items) |e| {
            if (e.mode == 0) continue;
            var c = e;
            if (e.sub) |sub| c.oid = try imp.storeTreeAt(sub, depth + 1);
            entries.items[kept] = c;
            kept += 1;
        }
        entries.shrinkRetainingCapacity(kept);
        std.mem.sort(Entry, entries.items, {}, entryLessThan);
        var out: Io.Writer.Allocating = .init(imp.gpa);
        defer out.deinit();
        for (entries.items) |e| {
            out.writer.print("{o} {s}\x00", .{ e.mode, e.name }) catch return error.OutOfMemory;
            out.writer.writeAll(e.oid.raw()) catch return error.OutOfMemory;
        }
        const oid = try imp.store(.tree, out.written(), 0);
        node.oid = oid;
        return oid;
    }

    //=================================================================
    // Objects
    //=================================================================

    /// Write an object, into the pack this import is filling, and name it
    /// by `mark` when that is not zero.
    fn store(imp: *Importer, t: object.Type, bytes: []const u8, mark: u64) Error!Oid {
        const oid = hash.Hasher.object(imp.kind, t.name(), bytes);
        if (mark != 0) try imp.marks.put(imp.gpa, mark, oid);
        try imp.types.put(imp.gpa, oid, t);
        if (imp.pending.contains(oid)) return oid;
        if (try imp.repo.objectDatabase().exists(imp.io, oid)) return oid;
        if (imp.pack == null) imp.pack = try imp.repo.objectDatabase().beginPack(imp.io, .{});
        _ = try imp.repo.objectDatabase().writeInto(imp.io, imp.pack.?, t, bytes);
        try imp.pending.put(imp.gpa, oid, .{ .type = t, .bytes = try imp.gpa.dupe(u8, bytes) });
        imp.pending_bytes += bytes.len;
        if (imp.pending_bytes > pending_limit) try imp.closePack();
        return oid;
    }

    /// Finish the pack being filled, so what is in it reads from the
    /// repository: git's `end_packfile`.
    fn closePack(imp: *Importer) Error!void {
        const p = imp.pack orelse return;
        imp.pack = null;
        _ = try imp.repo.objectDatabase().finishPack(imp.io, p);
        var it = imp.pending.valueIterator();
        while (it.next()) |v| imp.gpa.free(v.bytes);
        imp.pending.clearRetainingCapacity();
        imp.pending_bytes = 0;
    }

    /// An object's type and bytes, from the open pack or the repository.
    /// The bytes are the caller's.
    fn readObject(imp: *Importer, oid: Oid) Error!odb_mod.Odb.Read {
        if (imp.pending.get(oid)) |p| return .{ .type = p.type, .bytes = try imp.gpa.dupe(u8, p.bytes) };
        return imp.repo.objectDatabase().read(imp.io, oid);
    }

    fn typeOf(imp: *Importer, oid: Oid) Error!?object.Type {
        if (imp.types.get(oid)) |t| return t;
        const header = imp.repo.objectDatabase().readHeader(imp.io, oid) catch |err| switch (err) {
            error.ObjectNotFound => return null,
            else => |e| return e,
        };
        try imp.types.put(imp.gpa, oid, header.type);
        return header.type;
    }

    fn commitTree(imp: *Importer, oid: Oid) Error!Oid {
        const found = try imp.readObject(oid);
        defer imp.gpa.free(found.bytes);
        if (found.type != .commit) return error.WrongObjectType;
        const hex_len = imp.kind.hexLen();
        if (found.bytes.len < 5 + hex_len or !std.mem.startsWith(u8, found.bytes, "tree ")) return error.WrongObjectType;
        return Oid.parse(imp.kind, found.bytes[5..][0..hex_len]) catch error.WrongObjectType;
    }

    fn peelToCommit(imp: *Importer, start: Oid) Error!Oid {
        var oid = start;
        var depth: usize = 0;
        while (depth < 64) : (depth += 1) {
            const t = try imp.typeOf(oid) orelse return error.ObjectMissing;
            switch (t) {
                .commit => return oid,
                .tag => oid = try imp.tagTarget(oid),
                else => return error.WrongObjectType,
            }
        }
        return error.WrongObjectType;
    }

    fn peelToTree(imp: *Importer, start: Oid) Error!Oid {
        var oid = start;
        var depth: usize = 0;
        while (depth < 64) : (depth += 1) {
            const t = try imp.typeOf(oid) orelse return error.ObjectMissing;
            switch (t) {
                .tree => return oid,
                .commit => oid = try imp.commitTree(oid),
                .tag => oid = try imp.tagTarget(oid),
                else => return error.WrongObjectType,
            }
        }
        return error.WrongObjectType;
    }

    fn tagTarget(imp: *Importer, oid: Oid) Error!Oid {
        const found = try imp.readObject(oid);
        defer imp.gpa.free(found.bytes);
        const hex_len = imp.kind.hexLen();
        if (found.bytes.len < 7 + hex_len or !std.mem.startsWith(u8, found.bytes, "object ")) return error.WrongObjectType;
        return Oid.parse(imp.kind, found.bytes[7..][0..hex_len]) catch error.WrongObjectType;
    }

    //=================================================================
    // Refs
    //=================================================================

    /// Update every branch: git's `dump_branches` and `update_branch`.
    fn dumpBranches(imp: *Importer) Error!void {
        const db = imp.repo.objectDatabase();
        for (imp.branches.values()) |b| {
            const store_refs = imp.repo.refStore();
            if (afterPrefix(b.name, "refs/replace/")) |rest| if (b.oid) |oid| {
                var hex_buf: [hash.max_hex_len]u8 = undefined;
                if (std.mem.eql(u8, rest, oid.hex(&hex_buf))) {
                    // A replacement of itself is dropped.
                    try imp.deleteRef(b.name);
                    continue;
                }
            };
            const new = b.oid orelse {
                if (b.delete) try imp.deleteRef(b.name);
                continue;
            };
            const old: ?Oid = if (try store_refs.resolve(imp.gpa, imp.io, b.name)) |r| blk: {
                imp.gpa.free(r.name);
                break :blk r.oid;
            } else null;
            if (!imp.force) if (old) |o| {
                const old_commit = imp.peelToCommit(o) catch null;
                const new_commit = imp.peelToCommit(new) catch null;
                if (old_commit == null or new_commit == null) {
                    try imp.rejected.append(imp.gpa, .{ .name = b.name, .new = new, .old = o, .reason = .missing_commits });
                    continue;
                }
                if (!try revwalk.isAncestor(imp.gpa, imp.io, db, .{ .ancestor = old_commit.?, .descendant = new_commit.? }, .{})) {
                    try imp.rejected.append(imp.gpa, .{ .name = b.name, .new = new, .old = o, .reason = .not_fast_forward });
                    continue;
                }
            };
            var tx = imp.repo.beginRefs();
            defer tx.deinit(imp.io);
            try tx.update(b.name, .{ .direct = new }, if (old) |o| .{ .matches = o } else .must_not_exist);
            try tx.commit(imp.io, imp.logMessage());
        }
    }

    fn dumpTags(imp: *Importer) Error!void {
        if (imp.tags.items.len == 0) return;
        var tx = imp.repo.beginRefs();
        defer tx.deinit(imp.io);
        // A tag made twice is the later one.
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(imp.gpa);
        var i = imp.tags.items.len;
        while (i > 0) {
            i -= 1;
            const t = imp.tags.items[i];
            if ((try seen.getOrPut(imp.gpa, t.name)).found_existing) continue;
            const name = try imp.gpa.print("refs/tags/{s}", .{t.name});
            defer imp.gpa.free(name);
            try tx.update(name, .{ .direct = t.oid }, .any);
        }
        try tx.commit(imp.io, imp.logMessage());
    }

    fn deleteRef(imp: *Importer, name: []const u8) Error!void {
        const found = try imp.repo.refStore().read(imp.gpa, imp.io, name) orelse return;
        switch (found) {
            .symbolic => |target| imp.gpa.free(target),
            .direct => {},
        }
        var tx = imp.repo.beginRefs();
        defer tx.deinit(imp.io);
        try tx.delete(name, .any);
        try tx.commit(imp.io, imp.logMessage());
    }

    fn logMessage(imp: *Importer) refs_mod.LogMessage {
        return .{ .who = imp.options.who, .message = "fast-import", .policy = imp.repo.reflogPolicy() };
    }
};

fn entryLessThan(_: void, a: Entry, b: Entry) bool {
    return baseNameCompare(a.name, a.mode, b.name, b.mode) == .lt;
}

/// git's `base_name_compare`: a directory sorts as its name and a `/`.
fn baseNameCompare(a: []const u8, a_mode: u32, b: []const u8, b_mode: u32) std.math.Order {
    const len = @min(a.len, b.len);
    const order = std.mem.order(u8, a[0..len], b[0..len]);
    if (order != .eq) return order;
    const c1: u8 = if (len < a.len) a[len] else if (isDir(a_mode)) '/' else 0;
    const c2: u8 = if (len < b.len) b[len] else if (isDir(b_mode)) '/' else 0;
    return std.math.order(c1, c2);
}

fn afterPrefix(text: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, text, prefix)) return null;
    return text[prefix.len..];
}

/// The decimal number `text` begins with, as `strtoumax` reads it.
fn leadingNumber(text: []const u8) ?u64 {
    var i: usize = 0;
    while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {}
    if (i == 0) return null;
    return std.fmt.parseInt(u64, text[0..i], 10) catch null;
}

fn parseOctal(text: []const u8) ?u32 {
    if (text.len == 0 or text.len > 6) return null;
    var value: u32 = 0;
    for (text) |c| {
        if (c < '0' or c > '7') return null;
        value = value * 8 + (c - '0');
    }
    return value;
}

fn isHex(text: []const u8) bool {
    for (text) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// git's `validate_raw_date`: `<seconds> <±zone>`, the zone no more than
/// 1400 when `strict`.
fn validRawDate(text: []const u8, strict: bool) bool {
    const space = std.mem.findScalar(u8, text, ' ') orelse return false;
    if (space == 0) return false;
    _ = std.fmt.parseInt(u64, text[0..space], 10) catch return false;
    const zone = text[space + 1 ..];
    if (zone.len < 2 or (zone[0] != '+' and zone[0] != '-')) return false;
    const value = std.fmt.parseInt(u64, zone[1..], 10) catch return false;
    if (!std.ascii.isDigit(zone[1])) return false;
    return !(strict and value > 1400);
}

/// A path deeper than `object.max_tree_depth` is refused before a walk
/// along it recurses once per component.
fn checkDepth(path: []const u8) Error!void {
    if (std.mem.countScalar(u8, path, '/') >= object.max_tree_depth) return error.TreeTooDeep;
}

/// git's `verify_path`, with `core.protectNTFS` and `core.protectHFS` on:
/// no empty, `.` or `..` component, no spelling of `.git` NTFS or HFS+
/// opens as it, nor of `.gitmodules` for a symlink.
fn validPath(path: []const u8, mode: u32) bool {
    return safepath.checkEntry(path, .stored, mode == 0o120000) == null;
}

fn validSignatureFormat(text: []const u8) bool {
    for ([_][]const u8{ "openpgp", "x509", "ssh", "unknown" }) |f| if (std.mem.eql(u8, text, f)) return true;
    return false;
}

/// Where a tag message's signature starts — the last line that opens
/// one — or its length: git's `parse_signed_buffer`.
pub fn signedOffset(message: []const u8) usize {
    var match = message.len;
    var at: usize = 0;
    while (at < message.len) {
        if (signing.Format.of(message[at..]) != null) match = at;
        const nl = std.mem.findScalarPos(u8, message, at, '\n');
        at = if (nl) |n| n + 1 else message.len;
    }
    return match;
}

/// A signature as a commit header: its lines joined by a newline and a
/// space, as git's `add_gpgsig_to_commit` writes them.
fn writeSignatureHeader(w: *Io.Writer, header: []const u8, signature: []const u8) Io.Writer.Error!void {
    try w.writeAll(header);
    var it = std.mem.splitScalar(u8, signature, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try w.writeAll("\n ");
        try w.writeAll(line);
        first = false;
    }
    try w.writeByte('\n');
}

/// git's `convert_num_notes_to_fanout`: one level per byte of the count.
fn fanoutFor(num_notes: u64) u8 {
    var n = num_notes;
    var fanout: u8 = 0;
    while (true) {
        n >>= 8;
        if (n == 0) break;
        fanout += 1;
    }
    return fanout;
}

/// git's `construct_path_with_fanout`.
fn fanoutPath(hex: []const u8, fanout: u8, buf: []u8) []const u8 {
    var i: usize = 0;
    var j: usize = 0;
    var f = fanout;
    while (f > 0) : (f -= 1) {
        buf[i] = hex[j];
        buf[i + 1] = hex[j + 1];
        buf[i + 2] = '/';
        i += 3;
        j += 2;
    }
    @memcpy(buf[i..][0 .. hex.len - j], hex[j..]);
    return buf[0 .. i + hex.len - j];
}

test "a tree's entries sort as git sorts them, a directory as its name and a slash" {
    try std.testing.expectEqual(std.math.Order.lt, baseNameCompare("a.c", 0o100644, "a", dir_mode));
    try std.testing.expectEqual(std.math.Order.gt, baseNameCompare("a0", 0o100644, "a", dir_mode));
    try std.testing.expectEqual(std.math.Order.lt, baseNameCompare("a", 0o100644, "a.c", 0o100644));
}

test "a note's path splits a byte off per level of fanout" {
    var buf: [hash.max_hex_len * 3 / 2]u8 = undefined;
    const hex = "0123456789abcdef0123456789abcdef01234567";
    try std.testing.expectEqualStrings(hex, fanoutPath(hex, 0, &buf));
    try std.testing.expectEqualStrings("01/23456789abcdef0123456789abcdef01234567", fanoutPath(hex, 1, &buf));
    try std.testing.expectEqualStrings("01/23/456789abcdef0123456789abcdef01234567", fanoutPath(hex, 2, &buf));
    try std.testing.expectEqual(@as(u8, 0), fanoutFor(255));
    try std.testing.expectEqual(@as(u8, 1), fanoutFor(256));
    try std.testing.expectEqual(@as(u8, 2), fanoutFor(65536));
}

test "a raw date is seconds and a zone, the zone no more than fourteen hours unless permissive" {
    try std.testing.expect(validRawDate("1700000000 +0100", true));
    try std.testing.expect(validRawDate("0 -0000", true));
    try std.testing.expect(!validRawDate("1700000000 +1500", true));
    try std.testing.expect(validRawDate("1700000000 +1500", false));
    try std.testing.expect(!validRawDate("1700000000 0100", true));
    try std.testing.expect(!validRawDate("1700000000", true));
}
