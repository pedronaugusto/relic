//! Bundle URIs, as git's `bundle-uri.c` fetches them: before a clone or a
//! fetch talks to the server, objects come from bundles somewhere else.
//!
//! A URI names a bundle or a bundle list. A list is a config file of
//! `bundle.*` keys: `bundle.version` (1), `bundle.mode` (`all` or `any`),
//! `bundle.heuristic` (`creationToken`), and per bundle `bundle.<id>.uri`
//! (relative to the list's own URI) and `bundle.<id>.creationToken`. A list
//! names bundles or more lists, four levels at most. Each is downloaded
//! into `objects/bundles/`: over http or https with git's transfer settings
//! (`transport.download`, as git-remote-https's `get`), from a path or a
//! `file://` URL by copying. The bundles are unbundled in whatever order
//! their prerequisites allow, and each ref a bundle carries under `refs/`
//! is written under `refs/bundles/`, which the fetch after it offers as
//! haves.
//!
//! Under the `creationToken` heuristic the newest bundles are taken first,
//! down to the first that unbundles, and the greatest token unbundled is
//! kept in `fetch.bundleCreationToken`; a list whose newest token is no
//! greater than it downloads nothing. A clone from such a list keeps the
//! URI in `fetch.bundleURI`, which every fetch after it reads again.
//!
//! A clone under `transfer.bundleURI=true` and no URI of its own takes the
//! list a server's protocol v2 `bundle-uri` command gives instead
//! (`List.parseLine` for each line, `fetchList`), its relative URIs taken
//! against the remote's URL. What git warns of on the way goes to the
//! transfer settings' `warnings`.
//!
//! git keeps a list's bundles in a hash map and walks them in its order;
//! relic walks them in the list's order. Where it matters, `mode = any`
//! with more than one bundle that works, another may be the one taken.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const bundle = @import("../bundle.zig");
const transport = @import("../transport.zig");
const repo_mod = @import("../../repo/repo.zig");
const object = @import("../../object/object.zig");
const config_mod = @import("../../config/config.zig");
const gitmodules = @import("../../config/gitmodules.zig");
const fsck = @import("../../object/fsck.zig");
const url_mod = @import("../../wire.zig").url;
const fs = @import("../../fs/fs.zig");
const decimal = @import("../../text.zig").decimal;
const warning = @import("../../report.zig").warning;

const Repository = repo_mod.Repository;

/// Errors that stop a bundle URI's fetch; anything else that goes wrong
/// fails the fetch quietly, as git warns and goes on.
pub const Error = Allocator.Error || Io.Cancelable;

/// `bundle.mode`.
pub const Mode = enum { all, any };

/// `bundle.heuristic`: how many of a list's bundles are needed.
pub const Heuristic = enum { none, creation_token };

/// One bundle of a list.
pub const Bundle = struct {
    id: []const u8,
    uri: ?[]const u8 = null,
    creation_token: u64 = 0,
    /// Where it was downloaded to, once it was tried.
    file: ?[]const u8 = null,
    unbundled: bool = false,
};

/// A bundle list, its values in `arena`.
pub const List = struct {
    arena: Allocator,
    version: i32 = 1,
    mode: Mode = .all,
    heuristic: Heuristic = .none,
    /// What a relative `uri` is resolved against: the list's own URI up to
    /// its last `/`, or the remote's URL for a server's list.
    base_uri: ?[]const u8 = null,
    bundles: std.ArrayList(Bundle) = .empty,
    /// Where a `creationToken` that does not parse is told of.
    warnings: ?*warning.Warnings = null,

    /// git's `bundle_list_update`: `key` (section and variable in lower
    /// case) set to `value`. `InvalidBundleList` for a key outside
    /// `bundle`, a version other than 1, an unknown mode, a second `uri`
    /// for one bundle; unknown keys and heuristics are hints for a later
    /// git and kept out.
    pub fn update(list: *List, key: []const u8, value: ?[]const u8) (Allocator.Error || error{InvalidBundleList})!void {
        if (!std.mem.startsWith(u8, key, "bundle.")) return error.InvalidBundleList;
        const rest = key["bundle.".len..];
        const dot = std.mem.findScalarLast(u8, rest, '.') orelse {
            const v = value orelse return error.InvalidBundleList;
            if (std.mem.eql(u8, rest, "version")) {
                const n = config_mod.parseInteger(v) catch return error.InvalidBundleList;
                if (n != 1) return error.InvalidBundleList;
                list.version = 1;
            } else if (std.mem.eql(u8, rest, "mode")) {
                list.mode = std.meta.stringToEnum(Mode, v) orelse return error.InvalidBundleList;
            } else if (std.mem.eql(u8, rest, "heuristic")) {
                if (std.mem.eql(u8, v, "creationToken")) list.heuristic = .creation_token;
            }
            return;
        };
        const id = rest[0..dot];
        const name = rest[dot + 1 ..];
        const entry = try list.find(id);
        if (std.mem.eql(u8, name, "uri")) {
            if (entry.uri != null) return error.InvalidBundleList;
            entry.uri = try list.resolve(value orelse return error.InvalidBundleList);
        } else if (std.mem.eql(u8, name, "creationtoken")) {
            // sscanf's `%PRIu64`: the digits at the start, and nothing
            // taken when there are none.
            const v = value orelse return error.InvalidBundleList;
            const text = std.mem.trimStart(u8, v, " \t\n\r\x0b\x0c");
            var end: usize = 0;
            while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
            if (decimal.digits(u64, text[0..end])) |n| {
                entry.creation_token = n;
            } else if (list.warnings) |w| {
                try w.add(.{ .bundle_uri = try list.arena.print("could not parse bundle list key creationToken with value '{s}'", .{v}) });
            }
        }
    }

    /// git's `bundle_uri_parse_line`: one `key=value` line of a server's
    /// `bundle-uri` answer.
    pub fn parseLine(list: *List, line: []const u8) (Allocator.Error || error{InvalidBundleList})!void {
        const equals = std.mem.findScalar(u8, line, '=') orelse return error.InvalidBundleList;
        if (equals == 0 or equals + 1 == line.len) return error.InvalidBundleList;
        try list.update(line[0..equals], line[equals + 1 ..]);
    }

    /// `text`, a list in git's config format read from `uri`. Any key
    /// `update` refuses, or a bundle without a `uri`, refuses it all.
    pub fn parseConfig(list: *List, uri: []const u8, text: []const u8) (Allocator.Error || error{InvalidBundleList})!void {
        // `strbuf_strip_file_from_path`: up to the last `/`.
        if (list.base_uri == null) list.base_uri = uri[0..if (std.mem.findScalarLast(u8, uri, '/')) |slash| slash + 1 else 0];
        var config = config_mod.Config.parseText(list.arena, text, .local) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidBundleList,
        };
        defer config.deinit();
        for (config.entries.items) |e| {
            const key = if (e.has_subsection)
                try std.mem.concat(list.arena, u8, &.{ e.section, ".", e.subsection, ".", e.name })
            else
                try std.mem.concat(list.arena, u8, &.{ e.section, ".", e.name });
            try list.update(key, e.value);
        }
        for (list.bundles.items) |b| if (b.uri == null) return error.InvalidBundleList;
    }

    fn find(list: *List, id: []const u8) Allocator.Error!*Bundle {
        for (list.bundles.items) |*b| if (std.mem.eql(u8, b.id, id)) return b;
        try list.bundles.append(list.arena, .{ .id = try list.arena.dupe(u8, id) });
        return &list.bundles.items[list.bundles.items.len - 1];
    }

    /// git's `relative_url` against the list's base: a URL or an absolute
    /// path as it is, anything else from the base.
    fn resolve(list: *List, value: []const u8) Allocator.Error![]const u8 {
        const base = list.base_uri orelse return list.arena.dupe(u8, value);
        if (!url_mod.isLocal(value) or std.Io.Dir.path.isAbsolute(value) or base.len == 0) return list.arena.dupe(u8, value);
        const relative = if (gitmodules.isRelativeUrl(value)) value else try std.mem.concat(list.arena, u8, &.{ "./", value });
        return gitmodules.resolveUrl(list.arena, base, relative, null) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => list.arena.dupe(u8, value),
        };
    }
};

/// What a fetch from bundle URIs is made with.
pub const Options = struct {
    /// The transfer settings an http or https download is made with.
    transport: transport.Options = .{},
    /// Who `fetch.bundleCreationToken`'s and the refs' updates are written as.
    who: object.Signature,
};

/// git's `fetch_bundle_uri`: every bundle `uri` leads to, unbundled into
/// `repo`. False when it failed, which git warns of and goes on from;
/// `heuristic` says whether a list used one, which is when a clone keeps
/// the URI. An empty URI fetches nothing.
pub fn fetch(gpa: Allocator, io: Io, repo: *Repository, uri: []const u8, options: Options) Error!struct { ok: bool, heuristic: bool } {
    if (uri.len == 0) return .{ .ok = true, .heuristic = false };
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var run: Run = .{ .gpa = gpa, .arena = arena_state.allocator(), .io = io, .repo = repo, .options = options };
    defer run.removeFiles();
    var global: List = .{ .arena = run.arena };
    var top: Bundle = .{ .id = "", .uri = uri };
    const ok = try run.fetchInternal(&top, 0, &global) and try run.unbundleAll(&global);
    return .{ .ok = ok, .heuristic = global.heuristic != .none };
}

/// git's `fetch_bundle_list`: the bundles a server's list names.
pub fn fetchList(gpa: Allocator, io: Io, repo: *Repository, list: *List, options: Options) Error!bool {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var run: Run = .{ .gpa = gpa, .arena = arena_state.allocator(), .io = io, .repo = repo, .options = options };
    defer run.removeFiles();
    if (list.heuristic == .creation_token) return run.byToken(list);
    var global: List = .{ .arena = run.arena };
    if (!try run.downloadList(list, &global, 0)) return false;
    return run.unbundleAll(&global);
}

/// git's `max_bundle_uri_depth`.
const max_depth = 4;

const Run = struct {
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    repo: *Repository,
    options: Options,
    /// Every file downloaded, removed at the end.
    files: std.ArrayList([]const u8) = .empty,

    fn removeFiles(run: *Run) void {
        const objects = run.repo.objectDatabase().objectsDirectory();
        // glint-ignore: Z026 -- git's `unlink_or_warn` goes on too; a file left is a stale tmp_uri_ beside git's own
        for (run.files.items) |file| objects.deleteFile(run.io, file) catch {};
    }

    fn warnings(run: *Run) ?*warning.Warnings {
        return run.options.transport.warnings;
    }

    /// git's `warning` (or its `error` it goes on from), as text.
    fn warn(run: *Run, comptime format: []const u8, args: anytype) Allocator.Error!void {
        const w = run.warnings() orelse return;
        try w.add(.{ .bundle_uri = try run.arena.print(format, args) });
    }

    /// `fetch_bundle_uri_internal`: download `b`; a bundle goes into
    /// `global`, a list is followed.
    fn fetchInternal(run: *Run, b: *Bundle, depth: usize, global: *List) Error!bool {
        if (depth >= max_depth) {
            try run.warn("exceeded bundle URI recursion limit ({d})", .{max_depth});
            return false;
        }
        const uri = b.uri orelse {
            try run.warn("bundle '{s}' has no uri", .{b.id});
            return false;
        };
        if (b.file == null) b.file = try run.tempFile() orelse return false;
        if (!try run.copy(uri, b.file.?)) {
            try run.warn("failed to download bundle from URI '{s}'", .{uri});
            return false;
        }
        const objects = run.repo.objectDatabase().objectsDirectory();
        if (!bundle.isBundle(run.gpa, run.io, objects, b.file.?)) {
            if (try run.followList(b, depth, global)) return true;
            try run.warn("file at URI '{s}' is not a bundle or bundle list", .{uri});
            return false;
        }
        try global.bundles.append(run.arena, .{ .id = b.id, .file = b.file });
        return true;
    }

    /// `fetch_bundle_list_in_config_format`.
    fn followList(run: *Run, b: *Bundle, depth: usize, global: *List) Error!bool {
        const objects = run.repo.objectDatabase().objectsDirectory();
        const text = objects.readFileAlloc(run.io, b.file.?, run.arena, .limited(1 << 30)) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => return error.OutOfMemory,
            else => return false,
        };
        var list: List = .{ .arena = run.arena, .warnings = run.warnings() };
        list.parseConfig(b.uri.?, text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidBundleList => return false,
        };
        // A list under the heuristic names bundles, not lists.
        if (list.heuristic == .creation_token) {
            global.heuristic = .creation_token;
            return run.byToken(&list);
        }
        return run.downloadList(&list, global, depth);
    }

    /// Whether `file`, read from `uri`, is a bundle list.
    fn isList(run: *Run, uri: []const u8, file: []const u8) Error!bool {
        const objects = run.repo.objectDatabase().objectsDirectory();
        const text = objects.readFileAlloc(run.io, file, run.arena, .limited(1 << 30)) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => return error.OutOfMemory,
            else => return false,
        };
        var list: List = .{ .arena = run.arena, .warnings = run.warnings() };
        list.parseConfig(uri, text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidBundleList => return false,
        };
        return true;
    }

    /// `download_bundle_list`: as many of `list`'s bundles as download,
    /// or the first for `mode = any`. It fails only in a deeper list.
    fn downloadList(run: *Run, list: *List, global: *List, depth: usize) Error!bool {
        var count: usize = 0;
        for (list.bundles.items) |*b| {
            if (list.mode == .any and count != 0) break;
            if (try run.fetchInternal(b, depth + 2, global)) count += 1;
        }
        return true;
    }

    /// `unbundle_all_bundles`: again and again, while one more unbundles.
    fn unbundleAll(run: *Run, list: *List) Error!bool {
        var progressed = true;
        while (progressed) {
            progressed = false;
            for (list.bundles.items) |*b| {
                if (b.file == null or b.unbundled) continue;
                if (try run.unbundle(b.file.?)) {
                    b.unbundled = true;
                    progressed = true;
                    break;
                }
            }
        }
        return true;
    }

    /// `fetch_bundles_by_token`.
    fn byToken(run: *Run, list: *List) Error!bool {
        const items = list.bundles.items;
        if (items.len == 0) return true;
        std.mem.sort(Bundle, items, {}, struct {
            fn newer(_: void, a: Bundle, b: Bundle) bool {
                return a.creation_token > b.creation_token;
            }
        }.newer);
        var max_token: u64 = 0;
        if (run.repo.configuration().get("fetch.bundlecreationtoken")) |text| {
            const t = std.mem.trimStart(u8, text, " \t\n\r\x0b\x0c");
            var end: usize = 0;
            while (end < t.len and std.ascii.isDigit(t[end])) end += 1;
            max_token = decimal.digits(u64, t[0..end]) orelse 0;
            if (items[0].creation_token <= max_token) return true;
        }
        var new_max: u64 = 0;
        var cur: isize = 0;
        var direction: isize = 0;
        const objects = run.repo.objectDatabase().objectsDirectory();
        while (cur >= 0 and cur < items.len) {
            const b = &items[@intCast(cur)];
            if (b.creation_token <= max_token) break;
            if (b.file == null) {
                var fetched = false;
                if (b.uri) |uri| {
                    if (try run.tempFile()) |file| {
                        b.file = file;
                        fetched = try run.copy(uri, file);
                        if (!fetched) try run.warn("failed to download bundle from URI '{s}'", .{uri});
                    }
                } else try run.warn("bundle '{s}' has no uri", .{b.id});
                // What is neither a bundle nor a list fails to download,
                // to git; a list where a bundle is expected ends the walk.
                if (fetched and !bundle.isBundle(run.gpa, run.io, objects, b.file.?)) {
                    if (try run.isList(b.uri.?, b.file.?)) {
                        try run.warn("file downloaded from '{s}' is not a bundle", .{b.uri.?});
                        break;
                    }
                    try run.warn("file at URI '{s}' is not a bundle or bundle list", .{b.uri.?});
                    fetched = false;
                }
                if (!fetched) {
                    b.unbundled = true;
                    direction = 1;
                    cur += direction;
                    continue;
                }
            }
            if (!b.unbundled) {
                if (try run.unbundle(b.file.?)) {
                    direction = -1;
                    b.unbundled = true;
                    new_max = @max(new_max, b.creation_token);
                } else direction = 1;
            }
            cur += direction;
        }
        if (cur >= 0) return false;
        var buf: [20]u8 = undefined;
        const value = std.mem.print(&buf, "{d}", .{new_max}) catch unreachable; // unreachable: a u64 is at most twenty digits
        _ = run.repo.writeConfig(run.io, .local, &.{.{ .set = .{ .name = "fetch.bundleCreationToken", .value = value } }}, .{}) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => return error.OutOfMemory,
            else => try run.warn("failed to store maximum creation token", .{}),
        };
        return true;
    }

    /// `find_temp_filename`: a new name under `objects/bundles/`.
    fn tempFile(run: *Run) Error!?[]const u8 {
        const objects = run.repo.objectDatabase().objectsDirectory();
        objects.createDirPath(run.io, "bundles") catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                try run.warn("failed to create temporary file", .{});
                return null;
            },
        };
        var buf: [64]u8 = undefined;
        const name = try std.mem.concat(run.arena, u8, &.{ "bundles/", fs.tempName(run.io, &buf, "tmp_uri_") });
        try run.files.append(run.arena, name);
        return name;
    }

    /// `copy_uri_to_file`: an http or https URI downloaded, any other
    /// copied from the path it is (after `file://`).
    fn copy(run: *Run, uri: []const u8, file: []const u8) Error!bool {
        const objects = run.repo.objectDatabase().objectsDirectory();
        if (std.mem.startsWith(u8, uri, "https:") or std.mem.startsWith(u8, uri, "http:")) {
            // git-remote-https's `get` takes the URI and the file on one
            // line, split at a space.
            if (std.mem.findAny(u8, uri, " \n") != null) return false;
            const out = objects.createFile(run.io, file, .{}) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return false,
            };
            defer out.close(run.io);
            var buf: [64 * 1024]u8 = undefined;
            var w = out.writer(run.io, &buf);
            transport.download(run.gpa, run.io, uri, &w.interface, run.options.transport) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.OutOfMemory => return error.OutOfMemory,
                else => return false,
            };
            w.interface.flush() catch return false;
            return true;
        }
        const path = if (std.mem.startsWith(u8, uri, "file://")) uri["file://".len..] else uri;
        Io.Dir.cwd().copyFile(path, objects, file, run.io, .{}) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return false,
        };
        return true;
    }

    /// `unbundle_from_file`: the bundle's objects, and its refs under
    /// `refs/bundles/`. False when it does not unbundle.
    fn unbundle(run: *Run, file: []const u8) Error!bool {
        const io = run.io;
        const repo = run.repo;
        const objects = repo.objectDatabase().objectsDirectory();
        const opened = bundle.File.open(run.gpa, io, objects, file) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => return error.OutOfMemory,
            else => return false,
        };
        defer opened.deinit(io);
        const check = fsck.wanted(repo.configuration(), .fetch) catch null;
        var received = bundle.unbundle(run.gpa, io, repo, opened, .{ .check_objects = check orelse false }) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => return error.OutOfMemory,
            else => return false,
        };
        received.deinit(io);
        for (opened.header.references) |ref| {
            if (!std.mem.startsWith(u8, ref.name, "refs/")) continue;
            const name = try std.mem.concat(run.arena, u8, &.{ "refs/bundles/", ref.name["refs/".len..] });
            var tx = repo.refStore().begin(run.gpa);
            defer tx.deinit(io);
            tx.update(name, .{ .direct = ref.oid }, .any) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
            tx.commit(io, .{ .who = run.options.who, .message = "fetched bundle" }) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            };
        }
        return true;
    }
};
