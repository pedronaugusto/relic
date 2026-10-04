//! Bundles: a repository's refs and the objects behind them in one file,
//! as `git bundle` writes and reads them, version 2 and version 3.
//!
//! A bundle is a header and a pack. The header is `# v2 git bundle` (or
//! `# v3 git bundle` with `@object-format=` and `@filter=` capability
//! lines), then a `-<name> <subject>` line for each prerequisite -- a commit
//! the receiving repository must already have -- then `<name> <ref>` for
//! each ref, then an empty line. The prerequisites are the boundary of the
//! revisions given, found and ordered as git's revision walk finds and
//! orders them; the refs are the names given that are refs, as git's
//! `dwim_ref` resolves them; the pack holds everything the refs reach and
//! the prerequisites do not. The header is git's byte for byte. The pack
//! holds git's objects; it is relic's own pack writer that writes them, and
//! its deltas are against objects in the pack, where git's thin pack may
//! delta against the prerequisites too.
//!
//! Reading checks the prerequisites are present and connected, as `git
//! bundle verify` does, and indexes the pack as `git bundle unbundle` does,
//! completing a thin one from the repository. A path or `file://` URL that
//! names a bundle is fetched and cloned from as git fetches from one.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash.zig");
const object = @import("../object.zig");
const odb_mod = @import("../odb.zig");
const repo_mod = @import("../repo.zig");
const refs_mod = @import("../refs.zig");
const revparse = @import("../revwalk/revparse.zig");
const revwalk = @import("../revwalk.zig");
const objectwalk = @import("objectwalk.zig");
const indexpack = @import("../odb/indexpack.zig");
const filterspec = @import("filterspec.zig");
const message = @import("../commit/message.zig");
const fs = @import("../repo/fs.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

const v2_signature = "# v2 git bundle\n";
const v3_signature = "# v3 git bundle\n";

/// A bundle format.
pub const Version = enum(u8) {
    v2 = 2,
    v3 = 3,
};

/// Errors from reading a bundle's header.
pub const ParseError = error{
    /// The first line is not a v2 or v3 bundle's signature.
    NotABundle,
    /// A header line git does not read: `unrecognized header`.
    MalformedBundleHeader,
    /// A v3 capability git does not know, or an object format it does not.
    UnknownBundleCapability,
    /// A `@filter=` git does not read.
    InvalidFilter,
} || Allocator.Error || Io.Reader.Error;

/// A prerequisite: a commit the receiving repository must have.
pub const Prerequisite = struct {
    oid: Oid,
};

/// A ref the bundle carries.
pub const Reference = struct {
    oid: Oid,
    /// As the header spells it.
    name: []const u8,
};

/// A bundle's header, read.
pub const Header = struct {
    arena: std.heap.ArenaAllocator,
    version: Version,
    object_format: hash.Kind,
    /// The `@filter=` capability's spec, for a filtered bundle.
    filter: ?[]const u8 = null,
    prerequisites: []const Prerequisite,
    references: []const Reference,

    /// Release everything.
    pub fn deinit(h: *Header) void {
        h.arena.deinit();
        h.* = undefined;
    }

    /// `read_bundle_header_fd`: the header from `r`, which is left at the
    /// first byte of the pack.
    pub fn read(gpa: Allocator, r: *Io.Reader) ParseError!Header {
        var h: Header = .{
            .arena = .init(gpa),
            .version = .v2,
            .object_format = .sha1,
            .prerequisites = &.{},
            .references = &.{},
        };
        errdefer h.arena.deinit();
        const a = h.arena.allocator();
        var line: std.ArrayList(u8) = .empty;

        if (!try readLine(a, r, &line)) return error.NotABundle;
        if (std.mem.eql(u8, line.items, v2_signature)) {
            h.version = .v2;
        } else if (std.mem.eql(u8, line.items, v3_signature)) {
            h.version = .v3;
        } else return error.NotABundle;

        var prerequisites: std.ArrayList(Prerequisite) = .empty;
        var references: std.ArrayList(Reference) = .empty;
        while (try readLine(a, r, &line)) {
            if (line.items.len == 0 or line.items[0] == '\n') break;
            // C reads the line up to its first NUL; `strbuf_rtrim` then
            // takes whitespace off the end of the whole line.
            var text = line.items;
            while (text.len > 0 and isSpace(text[text.len - 1])) text = text[0 .. text.len - 1];
            if (std.mem.indexOfScalar(u8, text, 0)) |nul| text = text[0..nul];

            if (h.version == .v3 and text.len > 0 and text[0] == '@') {
                const capability = text[1..];
                if (std.mem.startsWith(u8, capability, "object-format=")) {
                    const name = capability["object-format=".len..];
                    h.object_format = if (std.mem.eql(u8, name, "sha1"))
                        .sha1
                    else if (std.mem.eql(u8, name, "sha256"))
                        .sha256
                    else
                        return error.UnknownBundleCapability;
                } else if (std.mem.startsWith(u8, capability, "filter=")) {
                    const spec = capability["filter=".len..];
                    _ = filterspec.parse(a, spec) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.InvalidFilter => return error.InvalidFilter,
                    };
                    h.filter = try a.dupe(u8, spec);
                } else return error.UnknownBundleCapability;
                continue;
            }

            var is_prereq = false;
            if (text.len > 0 and text[0] == '-') {
                is_prereq = true;
                text = text[1..];
            }
            const hex_len = h.object_format.hexLen();
            if (text.len < hex_len) return error.MalformedBundleHeader;
            const oid = Oid.parse(h.object_format, text[0..hex_len]) catch blk: {
                // git reads upper-case digits too.
                var lower: [hash.max_hex_len]u8 = undefined;
                for (text[0..hex_len], 0..) |c, i| lower[i] = std.ascii.toLower(c);
                break :blk Oid.parse(h.object_format, lower[0..hex_len]) catch return error.MalformedBundleHeader;
            };
            const rest = text[hex_len..];
            if (rest.len != 0 and !isSpace(rest[0])) return error.MalformedBundleHeader;
            if (is_prereq) {
                try prerequisites.append(a, .{ .oid = oid });
            } else {
                if (rest.len == 0) return error.MalformedBundleHeader;
                try references.append(a, .{ .oid = oid, .name = try a.dupe(u8, rest[1..]) });
            }
        }
        h.prerequisites = prerequisites.items;
        h.references = references.items;
        return h;
    }

    /// `list_bundle_refs`: `<name> <ref>` for each ref, or only for those
    /// named in `only` when it is not empty.
    pub fn listHeads(h: *const Header, w: *Io.Writer, only: []const []const u8) Io.Writer.Error!void {
        for (h.references) |ref| {
            if (only.len != 0) {
                var wanted = false;
                for (only) |name| {
                    if (std.mem.eql(u8, name, ref.name)) wanted = true;
                }
                if (!wanted) continue;
            }
            try w.print("{f} {s}\n", .{ ref.oid, ref.name });
        }
    }

    /// What `git bundle verify` prints on its standard output for a bundle
    /// it found good.
    pub fn writeSummary(h: *const Header, w: *Io.Writer) Io.Writer.Error!void {
        if (h.references.len == 1) {
            try w.writeAll("The bundle contains this ref:\n");
        } else {
            try w.print("The bundle contains these {d} refs:\n", .{h.references.len});
        }
        try h.listHeads(w, &.{});
        if (h.prerequisites.len == 0) {
            try w.writeAll("The bundle records a complete history.\n");
        } else {
            if (h.prerequisites.len == 1) {
                try w.writeAll("The bundle requires this ref:\n");
            } else {
                try w.print("The bundle requires these {d} refs:\n", .{h.prerequisites.len});
            }
            // git keeps no name for a prerequisite, and prints the empty one.
            for (h.prerequisites) |p| try w.print("{f} \n", .{p.oid});
        }
        try w.print("The bundle uses this hash algorithm: {s}\n", .{@tagName(h.object_format)});
        if (h.filter) |f| try w.print("The bundle uses this filter: {s}\n", .{f});
    }
};

/// Read one line, its newline kept, into `line`: `false` at the end of the
/// stream with nothing read.
fn readLine(a: Allocator, r: *Io.Reader, line: *std.ArrayList(u8)) (Allocator.Error || Io.Reader.Error)!bool {
    line.clearRetainingCapacity();
    while (true) {
        const byte = r.takeByte() catch |err| switch (err) {
            error.EndOfStream => return line.items.len != 0,
            else => |e| return e,
        };
        try line.append(a, byte);
        if (byte == '\n') return true;
    }
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// Errors from opening a bundle file.
pub const OpenError = ParseError || Io.File.OpenError;

/// A bundle file, open at its pack.
pub const File = struct {
    file: Io.File,
    buffer: [64 * 1024]u8 = undefined,
    reader: Io.File.Reader = undefined,
    header: Header,

    /// Open the bundle at `path` and read its header.
    pub fn open(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8) OpenError!*File {
        const f = try gpa.create(File);
        errdefer gpa.destroy(f);
        f.file = try dir.openFile(io, path, .{});
        errdefer f.file.close(io);
        f.reader = f.file.reader(io, &f.buffer);
        f.header = try Header.read(gpa, &f.reader.interface);
        return f;
    }

    /// Close it.
    pub fn close(f: *File, gpa: Allocator, io: Io) void {
        f.header.deinit();
        f.file.close(io);
        gpa.destroy(f);
    }

    /// The pack, from where the header ends.
    pub fn pack(f: *File) *Io.Reader {
        return &f.reader.interface;
    }
};

/// `is_bundle`: whether `path` is a file whose header reads as a bundle's.
pub fn isBundle(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8) bool {
    const f = File.open(gpa, io, dir, path) catch return false;
    f.close(gpa, io);
    return true;
}

/// Errors from verifying and unbundling.
pub const Error = error{
    /// A prerequisite the repository does not have. `Verification.missing`
    /// names each.
    MissingPrerequisites,
    /// The prerequisites are here, but what is below them is not:
    /// `some prerequisite commits exist in the object store, but are not
    /// connected to the repository's history`.
    PrerequisitesNotConnected,
    /// A bundle in another object format than the repository's.
    ObjectFormatMismatch,
} || Allocator.Error || odb_mod.Error || objectwalk.Error || indexpack.Error || OpenError || Io.File.Writer.Error || refs_mod.ReadError;

/// What `verify` found.
pub const Verification = struct {
    gpa: Allocator,
    /// The prerequisites the repository lacks, in the header's order.
    missing: []Oid,
    /// Whether what the prerequisites reach is all here.
    connected: bool,

    pub fn ok(v: *const Verification) bool {
        return v.missing.len == 0 and v.connected;
    }

    pub fn deinit(v: *Verification) void {
        v.gpa.free(v.missing);
        v.* = undefined;
    }
};

/// `verify_bundle`: whether the object database has every prerequisite,
/// and everything below them that its refs, `refs`, do not already reach --
/// git's `check_connected`, `rev-list --objects <prerequisites> --not
/// --all`. Pass the tip of every ref, `HEAD` included; `repositoryTips`
/// collects them.
pub fn verify(gpa: Allocator, io: Io, db: *odb_mod.Odb, header: *const Header, refs: []const Oid) Error!Verification {
    if (header.object_format != db.objectFormat()) return error.ObjectFormatMismatch;
    var missing: std.ArrayList(Oid) = .empty;
    errdefer missing.deinit(gpa);
    for (header.prerequisites) |p| {
        if (!try db.exists(io, p.oid)) try missing.append(gpa, p.oid);
    }
    var connected = missing.items.len == 0;
    if (connected and header.prerequisites.len != 0) {
        var tips: std.ArrayList(Oid) = .empty;
        defer tips.deinit(gpa);
        for (header.prerequisites) |p| try tips.append(gpa, p.oid);
        connected = try connectedBelow(gpa, io, db, tips.items, refs);
    }
    return .{ .gpa = gpa, .missing = try missing.toOwnedSlice(gpa), .connected = connected };
}

/// Whether every object `tips` reach and `refs` do not is in `db`.
fn connectedBelow(gpa: Allocator, io: Io, db: *odb_mod.Odb, tips: []const Oid, refs: []const Oid) Error!bool {
    var collected = objectwalk.missing(gpa, io, db, tips, refs) catch |err| switch (err) {
        error.MissingObject, error.ObjectNotFound => return false,
        else => |e| return e,
    };
    defer collected.deinit();
    for (collected.entries) |entry| {
        if (!try db.exists(io, entry.oid)) return false;
    }
    return true;
}

/// The tip of every ref of `repo`, and `HEAD`'s: what `--all` names. The
/// result is the caller's.
pub fn repositoryTips(gpa: Allocator, io: Io, repo: *Repository) (refs_mod.ReadError || Allocator.Error)![]Oid {
    var out: std.ArrayList(Oid) = .empty;
    errdefer out.deinit(gpa);
    var listing = try repo.refStore().list(gpa, io, "refs/");
    defer listing.deinit();
    for (listing.entries) |e| switch (e.target) {
        .direct => |o| try out.append(gpa, o),
        .symbolic => {},
    };
    if (try repo.head(io)) |h| {
        gpa.free(h.name);
        try out.append(gpa, h.oid);
    }
    return out.toOwnedSlice(gpa);
}

/// How `unbundle` indexes the pack.
pub const UnbundleOptions = struct {
    /// `--fsck-objects`: check every object as it arrives, which a fetch
    /// with `fetch.fsckObjects` asks for. Off, as `git bundle unbundle` is.
    check_objects: bool = false,
    progress: ?@import("progress.zig").Progress = null,
};

/// `unbundle`: verify the prerequisites and index the pack into the
/// repository, completing a thin pack from it; a filtered bundle's pack is
/// kept as a promisor pack, as git keeps it. Returns what was received.
pub fn unbundle(gpa: Allocator, io: Io, repo: *Repository, bundle: *File, options: UnbundleOptions) Error!indexpack.Result {
    var pack_dir = try repo.common_dir.openDir(io, "objects/pack", .{ .iterate = true });
    defer pack_dir.close(io);
    const tips = try repositoryTips(gpa, io, repo);
    defer gpa.free(tips);
    return receive(gpa, io, &repo.odb, pack_dir, bundle, tips, .{
        .fix_thin = true,
        .check_objects = options.check_objects,
        .progress = options.progress,
        .reverse_index = @import("../odb/revindex.zig").wanted(repo.configuration()),
        .threads = indexpack.configuredThreads(repo.configuration()),
    });
}

/// `unbundle` into `db`, whose `objects/pack` is `pack_dir` and whose refs
/// point at `refs`, with the pack received as `options` says: what a fetch
/// from a bundle does.
pub fn receive(gpa: Allocator, io: Io, db: *odb_mod.Odb, pack_dir: Io.Dir, bundle: *File, refs: []const Oid, options: indexpack.Options) Error!indexpack.Result {
    var v = try verify(gpa, io, db, &bundle.header, refs);
    defer v.deinit();
    if (v.missing.len != 0) return error.MissingPrerequisites;
    if (!v.connected) return error.PrerequisitesNotConnected;
    var receive_options = options;
    receive_options.fix_thin = true;
    const result = try indexpack.receive(gpa, io, db, pack_dir, bundle.pack(), receive_options);
    if (bundle.header.filter != null) if (result.name) |name| {
        var hex: [hash.max_hex_len]u8 = undefined;
        var name_buf: [96]u8 = undefined;
        const promisor = std.fmt.bufPrint(&name_buf, "pack-{s}.promisor", .{name.hex(&hex)}) catch unreachable;
        if (pack_dir.createFile(io, promisor, .{ .exclusive = true })) |file| {
            defer file.close(io);
            try file.writeStreamingAll(io, "from-bundle\n");
        } else |err| switch (err) {
            error.PathAlreadyExists => {},
            else => |e| return e,
        }
    };
    return result;
}

/// What `create` puts in a bundle: `git bundle create <file>
/// <git-rev-list-args>`, with the arguments split as git's revision
/// parser splits them.
pub const CreateRequest = struct {
    /// The revisions to include, each as given: those that name exactly
    /// one ref are the bundle's refs, by that ref's full name (or as given,
    /// for a symbolic ref such as `HEAD`); every one is included with its
    /// history.
    include: []const []const u8,
    /// `^<rev>`, or the left of `<a>..<b>`: left out, with its history.
    exclude: []const []const u8 = &.{},
    /// `--version`; `null` is the least the bundle needs: 3 for a SHA-256
    /// repository or a filter, 2 otherwise.
    version: ?Version = null,
    /// `--filter=<spec>`, which makes a version 3 bundle. `sparse:oid=` is
    /// refused by name.
    filter: ?[]const u8 = null,
    /// How the pack is written.
    pack: odb_mod.PackOptions = .{},
};

/// Errors from writing a bundle.
pub const CreateError = error{
    /// No ref would be written: `Refusing to create empty bundle.`
    EmptyBundle,
    /// `version` 2 for a SHA-256 repository or a filter.
    VersionTooLow,
    /// A `sparse:oid=` filter, which bundles here do not take.
    SparseFilterUnsupported,
    /// Not a filter git reads.
    InvalidFilter,
    NotACommit,
    WalkTooLong,
} || Allocator.Error || odb_mod.Error || objectwalk.Error || revparse.Error || refs_mod.ReadError ||
    object.ParseError || Io.Writer.Error || fs.LockError || fs.CommitError || repo_mod.Error;

/// Write the bundle `request` asks for to `<path>` in `dir`, through
/// `<path>.lock` as git writes it.
pub fn create(gpa: Allocator, io: Io, repo: *Repository, dir: Io.Dir, path: []const u8, request: CreateRequest) CreateError!void {
    var buffer: [64 * 1024]u8 = undefined;
    var lock = try fs.LockFile.open(gpa, io, dir, path, &buffer, .{ .sync = .none, .write_pid = false });
    defer lock.deinit(io);
    try write(gpa, io, repo, lock.writer(), request);
    try lock.commit(io);
}

/// Write the bundle `request` asks for to `w`: `git bundle create -`.
pub fn write(gpa: Allocator, io: Io, repo: *Repository, w: *Io.Writer, request: CreateRequest) CreateError!void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const kind = repo.objectFormat();

    var filter: objectwalk.Filter = .none;
    var filter_text: ?[]const u8 = null;
    if (request.filter) |text| {
        const spec = filterspec.parse(a, text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidFilter => return error.InvalidFilter,
        };
        filter = try walkFilter(a, spec);
        filter_text = try filterspec.sendForm(a, text);
    }
    const min: Version = if (kind != .sha1 or request.filter != null) .v3 else .v2;
    const version = request.version orelse min;
    if (@intFromEnum(version) < @intFromEnum(min)) return error.VersionTooLow;

    // The revisions, as the pending list git's revision parser makes.
    const Pending = struct { oid: Oid, name: []const u8, negative: bool, commit: ?Oid };
    var pending: std.ArrayList(Pending) = .empty;
    for (request.include) |name| {
        const oid = try revparse.resolve(gpa, io, repo, name);
        try pending.append(a, .{ .oid = oid, .name = name, .negative = false, .commit = commitOf(repo, io, oid) });
    }
    for (request.exclude) |name| {
        const oid = try revparse.resolve(gpa, io, repo, name);
        try pending.append(a, .{ .oid = oid, .name = name, .negative = true, .commit = commitOf(repo, io, oid) });
    }

    // The walk: what is shown, in order, and the boundary below it.
    var walk: revwalk.Walk = .init(gpa, &repo.odb);
    defer walk.deinit();
    for (pending.items) |p| {
        const c = p.commit orelse continue;
        if (p.negative) try walk.hide(c) else try walk.push(c);
    }
    var shown: Oid.Set = .empty;
    defer shown.deinit(gpa);
    var child_shown: Oid.Set = .empty;
    defer child_shown.deinit(gpa);
    var boundary: std.ArrayList(Oid) = .empty;
    defer boundary.deinit(gpa);
    while (try walk.next(io)) |c| {
        try shown.put(gpa, c.oid, {});
        for (c.parents) |p| {
            if (shown.contains(p) or child_shown.contains(p)) continue;
            try child_shown.put(gpa, p, {});
            try boundary.append(gpa, p);
        }
    }
    // `create_boundary_commit_list`: the ones never shown, newest found
    // first, then in topological order.
    var bounds: std.ArrayList(Oid) = .empty;
    var i = boundary.items.len;
    while (i > 0) {
        i -= 1;
        if (!shown.contains(boundary.items[i])) try bounds.append(a, boundary.items[i]);
    }
    const ordered = try topoOrder(a, io, repo, bounds.items);

    // The header.
    try w.writeAll(if (version == .v2) v2_signature else v3_signature);
    if (version == .v3) {
        try w.print("@object-format={s}\n", .{@tagName(kind)});
        if (filter_text) |f| try w.print("@filter={s}\n", .{f});
    }
    var haves: std.ArrayList(Oid) = .empty;
    var wants: std.ArrayList(Oid) = .empty;
    for (ordered) |b| {
        const found = try repo.odb.read(io, b);
        defer repo.odb.allocator().free(found.bytes);
        var commit = try object.Commit.parse(gpa, kind, found.bytes);
        defer commit.deinit();
        const subject = try message.onelineSubject(a, commit.message);
        try w.print("-{f} {s}\n", .{ b, std.mem.trim(u8, subject, " \t\n\r") });
        try haves.append(a, b);
    }

    // `write_bundle_refs`.
    var written: std.StringHashMapUnmanaged(void) = .empty;
    var ref_count: usize = 0;
    for (pending.items) |p| {
        // A commit the walk did not show is behind an exclusion, and git's
        // walk has marked it so.
        const uninteresting = p.negative or (p.commit != null and p.oid.eql(p.commit.?) and !shown.contains(p.oid));
        if (uninteresting) {
            try haves.append(a, p.oid);
            continue;
        }
        try wants.append(a, p.oid);
        const display = (try dwimRef(a, io, repo, p.name)) orelse continue;
        if ((try written.getOrPut(a, display)).found_existing) continue;
        ref_count += 1;
        try w.print("{f} {s}\n", .{ p.oid, display });
    }
    try w.writeByte('\n');
    if (ref_count == 0) return error.EmptyBundle;

    var collected = try objectwalk.missingWith(gpa, io, &repo.odb, wants.items, haves.items, .{ .filter = filter });
    defer collected.deinit();
    _ = try repo.odb.writePackTo(io, w, collected.entries, request.pack);
    try w.flush();
}

fn walkFilter(a: Allocator, spec: filterspec.Spec) CreateError!objectwalk.Filter {
    return switch (spec) {
        .blob_none => .blob_none,
        .blob_limit => |v| .{ .blob_limit = v },
        .tree_depth => |v| .{ .tree_depth = v },
        .object_type => |v| .{ .object_type = v },
        .sparse_oid => error.SparseFilterUnsupported,
        .combine => |parts| blk: {
            const out = try a.alloc(objectwalk.Filter, parts.len);
            for (parts, out) |part, *f| f.* = try walkFilter(a, part);
            break :blk .{ .combine = out };
        },
    };
}

/// The commit `oid` is or peels to, or `null`.
fn commitOf(repo: *Repository, io: Io, oid: Oid) ?Oid {
    const peeled = repo.peel(io, oid) catch return null;
    const header = repo.odb.readHeader(io, peeled) catch return null;
    return if (header.type == .commit) peeled else null;
}

/// `sort_in_topological_order` in graph order over `list`.
fn topoOrder(a: Allocator, io: Io, repo: *Repository, list: []const Oid) CreateError![]Oid {
    var indegree: Oid.Map(u32) = .empty;
    var parents: Oid.Map([]const Oid) = .empty;
    for (list) |c| try indegree.put(a, c, 1);
    for (list) |c| {
        const found = try repo.odb.read(io, c);
        defer repo.odb.allocator().free(found.bytes);
        var commit = try object.Commit.parse(a, repo.objectFormat(), found.bytes);
        const ps = try a.dupe(Oid, revwalk.parentsOf(&repo.odb, c, commit.parents));
        commit.deinit();
        try parents.put(a, c, ps);
        for (ps) |p| if (indegree.getPtr(p)) |d| {
            if (d.* != 0) d.* += 1;
        };
    }
    var stack: std.ArrayList(Oid) = .empty;
    for (list) |c| if (indegree.get(c).? == 1) try stack.append(a, c);
    std.mem.reverse(Oid, stack.items);
    var out: std.ArrayList(Oid) = .empty;
    while (stack.pop()) |c| {
        for (parents.get(c).?) |p| {
            const d = indegree.getPtr(p) orelse continue;
            if (d.* == 0) continue;
            d.* -= 1;
            if (d.* == 1) try stack.append(a, p);
        }
        indegree.getPtr(c).?.* = 0;
        try out.append(a, c);
    }
    return out.items;
}

/// `repo_dwim_ref` as `write_bundle_refs` uses it: the name a revision is
/// written under, or `null` when it names no ref or more than one.
fn dwimRef(a: Allocator, io: Io, repo: *Repository, name: []const u8) CreateError!?[]const u8 {
    const store = repo.refStore();
    const rules = [_][2][]const u8{
        .{ "", "" },
        .{ "refs/", "" },
        .{ "refs/tags/", "" },
        .{ "refs/heads/", "" },
        .{ "refs/remotes/", "" },
        .{ "refs/remotes/", "/HEAD" },
    };
    var found: ?[]const u8 = null;
    var count: usize = 0;
    for (rules) |rule| {
        const full = try std.mem.concat(a, u8, &.{ rule[0], name, rule[1] });
        if (!@import("../worktree/safepath.zig").isValidRefName(full) and !std.mem.eql(u8, full, "HEAD")) continue;
        const resolved = (store.resolve(a, io, full) catch continue) orelse continue;
        count += 1;
        if (found == null) found = resolved.name;
    }
    if (count != 1) return null;
    // A symbolic ref asked for by its own name is written by that name.
    if (store.read(a, io, name) catch null) |direct| switch (direct) {
        .symbolic => return name,
        .direct => {},
    };
    return found;
}

test "fuzz: any bytes are a bundle header or a named error" {
    try std.testing.fuzz({}, fuzzHeader, .{});
}

fn fuzzHeader(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [512]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    for ([_][]const u8{ "", v2_signature, v3_signature }) |prefix| {
        var joined: [600]u8 = undefined;
        @memcpy(joined[0..prefix.len], prefix);
        @memcpy(joined[prefix.len..][0..input.len], input);
        var r: Io.Reader = .fixed(joined[0 .. prefix.len + input.len]);
        var h = Header.read(std.testing.allocator, &r) catch |err| switch (err) {
            error.NotABundle, error.MalformedBundleHeader, error.UnknownBundleCapability, error.InvalidFilter => continue,
            else => |e| return e,
        };
        defer h.deinit();
        var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try h.writeSummary(&out.writer);
    }
}
