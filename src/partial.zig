//! Partial clone: a repository that holds some of its objects and is
//! promised the rest.
//!
//! A clone with a filter — `blob:none`, `blob:limit=<size>`, `tree:<depth>`,
//! `object:type=<type>`, `sparse:oid=<blob>`, or several of them together
//! with `combine:` — asks the server to leave objects out of the pack, and
//! marks the
//! remote as the one that will give them later: `remote.<name>.promisor`
//! and `remote.<name>.partialclonefilter`, at repository format version 1.
//! Every pack from that remote is a promisor pack, with a `.promisor` file
//! beside it, and an object it names that the repository lacks is not
//! missing but promised. When something reads one — a checkout wants a
//! file's contents — the remote is asked for it, as git's lazy fetch asks:
//! the objects by name, `filter blob:none`, no negotiation, no tags. With
//! several promisor remotes each is asked in git's order until one gives
//! them (`promisorRemotes`).
//!
//! That fetch is a program's work for ssh and a credential helper's for
//! HTTP, so relic does it only when the caller installs a `Lazy` on the
//! repository, with the permission to run them. Without one a read of a
//! promised object is `error.ObjectNotFound`, as in any other repository.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const object = @import("object.zig");
const odb_mod = @import("odb.zig");
const pack = @import("pack.zig");
const program = @import("program.zig");
const config_mod = @import("config.zig");
const credential = @import("credential.zig");
const auth = @import("auth.zig");
const transport = @import("transport.zig");
const repo_mod = @import("repo.zig");
const revindex = @import("revindex.zig");
const filterspec = @import("filterspec.zig");

const Oid = hash.Oid;
const Repository = repo_mod.Repository;

/// Errors from reading a filter.
pub const FilterError = filterspec.Error;

/// The filter as git sends it, after reading it as git's
/// `list-objects-filter-options` reads it: `filterspec.sendForm`. The
/// result is `arena`'s, or `spec` itself.
pub fn normalize(arena: Allocator, spec: []const u8) FilterError![]const u8 {
    return filterspec.sendForm(arena, spec);
}

/// The remote a partial clone was promised its objects by: the first with
/// `remote.<name>.promisor` true, or the one `extensions.partialClone`
/// names, which is how git before 2.44 recorded it. `null` in a repository
/// that is not a partial clone. The name borrows `config`.
pub fn promisorRemote(config: *const config_mod.Config) ?[]const u8 {
    for (config.entries.items) |entry| {
        if (!std.ascii.eqlIgnoreCase(entry.section, "remote") or entry.subsection.len == 0) continue;
        if (!std.ascii.eqlIgnoreCase(entry.name, "promisor")) continue;
        if (entry.value == null or (config_mod.parseBool(entry.value.?) catch false)) return entry.subsection;
    }
    return config.get("extensions.partialclone");
}

/// Every promisor remote, in the order git's lazy fetch asks them: each
/// remote with `remote.<name>.promisor` true or a
/// `remote.<name>.partialclonefilter`, as the configuration first names it,
/// and the one `extensions.partialClone` names last. The names borrow
/// `config`; the list is `arena`'s.
pub fn promisorRemotes(arena: Allocator, config: *const config_mod.Config) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (config.entries.items) |entry| {
        if (!std.ascii.eqlIgnoreCase(entry.section, "remote") or !entry.has_subsection) continue;
        const promises = if (std.ascii.eqlIgnoreCase(entry.name, "promisor"))
            entry.value == null or (config_mod.parseBool(entry.value.?) catch false)
        else
            std.ascii.eqlIgnoreCase(entry.name, "partialclonefilter");
        if (!promises) continue;
        for (out.items) |name| {
            if (std.mem.eql(u8, name, entry.subsection)) break;
        } else try out.append(arena, entry.subsection);
    }
    if (config.get("extensions.partialclone")) |named| {
        for (out.items, 0..) |name, i| {
            if (std.mem.eql(u8, name, named)) {
                _ = out.orderedRemove(i);
                break;
            }
        }
        try out.append(arena, named);
    }
    return out.items;
}

/// Whether `name` is a promisor remote of `config`'s repository: one
/// `promisorRemotes` lists.
pub fn isPromisor(config: *const config_mod.Config, name: []const u8) bool {
    var buf: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "remote.{s}.promisor", .{name}) catch return false;
    if (config.getBool(key, false) catch false) return true;
    const filter_key = std.fmt.bufPrint(&buf, "remote.{s}.partialclonefilter", .{name}) catch return false;
    if (config.get(filter_key) != null) return true;
    const named = config.get("extensions.partialclone") orelse return false;
    return std.mem.eql(u8, named, name);
}

/// One line of a `.promisor` file: a ref the pack was fetched for.
pub const PromisorRef = struct {
    oid: Oid,
    name: []const u8,
};

/// Write `pack-<name>.promisor` beside the pack in `pack_dir`: the refs it
/// was fetched for, `<oid> <name>` to a line, as git writes them; empty for
/// a lazy fetch, which fetches objects rather than refs.
pub fn writePromisor(io: Io, pack_dir: Io.Dir, name: Oid, refs: []const PromisorRef) (Io.File.OpenError || Io.Writer.Error)!void {
    var hex: [hash.max_hex_len]u8 = undefined;
    var name_buf: [96]u8 = undefined;
    const file_name = std.fmt.bufPrint(&name_buf, "pack-{s}.promisor", .{name.hex(&hex)}) catch unreachable;
    const file = try pack_dir.createFile(io, file_name, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var w = file.writer(io, &buffer);
    for (refs) |ref| try w.interface.print("{f} {s}\n", .{ ref.oid, ref.name });
    try w.interface.flush();
}

/// A partial clone's lazy fetch: what a read of a promised object asks
/// the promisor remote through. Install it on the repository with
/// `install`; it must outlive the installation.
pub const Lazy = struct {
    gpa: Allocator,
    repo: *Repository,
    options: Options,
    /// The error behind the last `error.PromisorFetchFailed`.
    failure: ?anyerror = null,
    /// A refused credential, described.
    auth_failure: auth.Failure = .{},
    /// How many fetches it made, and for how many objects.
    fetches: u32 = 0,
    objects: u32 = 0,

    /// What the fetches are made with.
    pub const Options = struct {
        /// The permission to run `ssh` and credential helpers.
        programs: ?program.Programs = null,
        prompt: ?credential.Prompt = null,
        /// Check what arrives the way git's `fsck` does.
        check_objects: bool = true,
    };

    /// A lazy fetch for `repo`, a partial clone.
    pub fn init(gpa: Allocator, repo: *Repository, options: Options) Lazy {
        return .{ .gpa = gpa, .repo = repo, .options = options };
    }

    /// Stop asking, and release the failure's description.
    pub fn deinit(l: *Lazy) void {
        l.uninstall();
        l.auth_failure.deinit();
    }

    /// Have every read of a missing object in the repository ask.
    pub fn install(l: *Lazy) void {
        l.repo.odb.lazy = .{ .context = l, .fetch = fetchFn };
    }

    /// Stop asking.
    pub fn uninstall(l: *Lazy) void {
        if (l.repo.odb.lazy) |lazy| {
            if (lazy.context == @as(*anyopaque, l)) l.repo.odb.lazy = null;
        }
    }

    fn fetchFn(context: *anyopaque, io: Io, oids: []const Oid) (Allocator.Error || Io.Cancelable || error{PromisorFetchFailed})!void {
        const l: *Lazy = @ptrCast(@alignCast(context));
        l.fetch(io, oids) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => {
                l.failure = err;
                return error.PromisorFetchFailed;
            },
        };
    }

    /// Ask the promisor remotes for `oids`, all in one request to each, as
    /// git's lazy fetch asks them: in `promisorRemotes`' order, the next one
    /// asked only when a request fails, and then for what is still missing.
    /// The last failure is the one returned when none gives everything.
    pub fn fetch(l: *Lazy, io: Io, oids: []const Oid) !void {
        if (oids.len == 0) return;
        const repo = l.repo;
        // Nothing the fetch itself reads may ask again.
        const saved = repo.odb.lazy;
        repo.odb.lazy = null;
        defer repo.odb.lazy = saved;
        var arena_state: std.heap.ArenaAllocator = .init(l.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const names = try promisorRemotes(arena, &repo.config);
        if (names.len == 0) return error.NotAPartialClone;
        var remaining = try arena.dupe(Oid, oids);
        var last_error: anyerror = error.NotAPartialClone;
        for (names) |name| {
            if (l.fetchFrom(io, name, remaining)) |_| {
                l.fetches += 1;
                l.objects += @intCast(remaining.len);
                return;
            } else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                else => last_error = err,
            }
            // What came before the failure is not asked for again.
            try repo.odb.refresh(io);
            var kept: usize = 0;
            for (remaining) |oid| {
                if (!try repo.odb.exists(io, oid)) {
                    remaining[kept] = oid;
                    kept += 1;
                }
            }
            remaining = remaining[0..kept];
            if (remaining.len == 0) return;
        }
        return last_error;
    }

    /// One request to the promisor remote `name`. A promisor remote with no
    /// `partialclonefilter` is given `blob:none` first, in the repository's
    /// configuration, as git's lazy fetch registers it.
    fn fetchFrom(l: *Lazy, io: Io, name: []const u8, oids: []const Oid) !void {
        const repo = l.repo;
        {
            var buf: [256]u8 = undefined;
            const key = try std.fmt.bufPrint(&buf, "remote.{s}.partialclonefilter", .{name});
            if (repo.config.get(key) == null) {
                try repo.config.set(key, "blob:none");
                try repo.config.write(io, repo.common_dir, "config");
            }
        }
        var remote = try @import("remote.zig").Remote.get(l.gpa, &repo.config, name);
        defer remote.deinit();
        if (remote.urls.len == 0) return error.NotAPartialClone;
        var session = try transport.Session.open(l.gpa, io, remote.urls[0], .upload_pack, repo.kind, .{
            .programs = l.options.programs,
            .config = &repo.config,
            .service_program = remote.upload_pack,
            .prompt = l.options.prompt,
            .auth_failure = &l.auth_failure,
        });
        defer session.close(io);
        var pack_dir = try repo.common_dir.openDir(io, "objects/pack", .{});
        defer pack_dir.close(io);
        const fetched = try session.fetch(l.gpa, io, &repo.odb, pack_dir, .{
            .wants = oids,
            .tips = &.{},
            .include_tag = false,
            .filter = "blob:none",
        }, .{ .receive = .{ .check_objects = l.options.check_objects, .reverse_index = revindex.wanted(&repo.config) } });
        if (fetched.pack) |pack_name| try writePromisor(io, pack_dir, pack_name, &.{});
    }

    /// Fetch, in one request, every blob below `tree` that the repository
    /// lacks — what a checkout of `tree` will read — as git fetches them
    /// before it checks out rather than one at a time.
    pub fn prefetchTree(l: *Lazy, io: Io, tree: Oid) !void {
        var missing: std.ArrayList(Oid) = .empty;
        defer missing.deinit(l.gpa);
        var seen: Oid.Set = .empty;
        defer seen.deinit(l.gpa);
        var stack: std.ArrayList(Oid) = .empty;
        defer stack.deinit(l.gpa);
        try stack.append(l.gpa, tree);
        const db = &l.repo.odb;
        while (stack.pop()) |oid| {
            if ((try seen.getOrPut(l.gpa, oid)).found_existing) continue;
            if (!try db.exists(io, oid)) {
                // A tree the filter left out is fetched first; its blobs
                // are then looked at.
                try l.fetch(io, &.{oid});
                try db.refresh(io);
            }
            const found = try db.read(io, oid);
            defer db.gpa.free(found.bytes);
            var entries = object.Tree.parse(db.kind, found.bytes).iterate();
            while (try entries.next()) |entry| switch (entry.mode) {
                .tree => try stack.append(l.gpa, entry.oid),
                .gitlink => {},
                else => {
                    if ((try seen.getOrPut(l.gpa, entry.oid)).found_existing) continue;
                    if (!try db.exists(io, entry.oid)) try missing.append(l.gpa, entry.oid);
                },
            };
        }
        try l.fetch(io, missing.items);
        try db.refresh(io);
    }
};

test "filters are read and sent as git reads and sends them, and the ones git does not have are refused by name" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("blob:none", try normalize(arena, "blob:none"));
    try std.testing.expectEqualStrings("blob:limit=1024", try normalize(arena, "blob:limit=1k"));
    try std.testing.expectEqualStrings("blob:limit=5", try normalize(arena, "blob:limit=5"));
    try std.testing.expectEqualStrings("tree:0", try normalize(arena, "tree:0"));
    try std.testing.expectError(error.InvalidFilter, normalize(arena, "blob:some"));
    try std.testing.expectError(error.InvalidFilter, normalize(arena, "tree:x"));
    try std.testing.expectEqualStrings("combine:blob:none+tree:3", try normalize(arena, "combine:blob:none+tree:3"));
    try std.testing.expectEqualStrings("combine:blob:limit=1k+tree:3", try normalize(arena, "combine:blob:limit=1k+tree:3"));
    try std.testing.expectEqualStrings("combine:blob:none+sparse:oid=main%3aspec", try normalize(arena, "combine:blob:none+sparse:oid=main%3aspec"));
    try std.testing.expectEqualStrings("object:type=tree", try normalize(arena, "object:type=tree"));
    try std.testing.expectEqualStrings("sparse:oid=main:spec", try normalize(arena, "sparse:oid=main:spec"));
    try std.testing.expectError(error.InvalidFilter, normalize(arena, "object:type=file"));
    try std.testing.expectEqualStrings("combine:blob:none+", try normalize(arena, "combine:blob:none+"));
    try std.testing.expectError(error.InvalidFilter, normalize(arena, "combine:"));
    try std.testing.expectError(error.InvalidFilter, normalize(arena, "combine:blob:none+tree:x"));
    try std.testing.expectError(error.InvalidFilter, normalize(arena, "combine:blob:none+sparse:oid=a~b"));
    try std.testing.expectError(error.InvalidFilter, normalize(arena, "sparse:path=x"));
}

test "fuzz: a filter is sent as git spells it or refused by name" {
    try std.testing.fuzz({}, fuzzFilter, .{});
}

fn fuzzFilter(_: void, smith: *std.testing.Smith) anyerror!void {
    var scratch: [128]u8 = undefined;
    const input = scratch[0..smith.slice(&scratch)];
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    _ = normalize(arena_state.allocator(), input) catch |err| switch (err) {
        error.InvalidFilter => return,
        else => |e| return e,
    };
}
