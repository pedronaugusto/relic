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

const config_state = @import("../config/state.zig");
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash.zig");
const object = @import("../object.zig");
const pack = @import("../odb/pack.zig");
const program = @import("../repo/program.zig");
const config_mod = @import("../config.zig");
const credential = @import("credential.zig");
const auth = @import("auth.zig");
const transport = @import("../transport.zig");
const repo_mod = @import("../repo.zig");
const fsck = @import("../object/fsck.zig");
const promisors = @import("promisors.zig");
const warning = @import("../repo/warning.zig");
const revindex = @import("../odb/revindex.zig");
const filterspec = @import("filterspec.zig");
const remote_mod = @import("remote.zig");

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
    return promisors.remotes(arena, config);
}

/// Write into `repo`'s configuration what a server's `promisor-remote`
/// was answered with storing (`promisor.storeFields`), saying each as git
/// says it.
pub fn storeAdvertised(io: Io, repo: *Repository, stores: []const promisors.Store, warnings: ?*warning.Warnings) (repo_mod.Error || config_mod.Config.SetError)!void {
    if (stores.len == 0) return;
    var arena_state: std.heap.ArenaAllocator = .init(repo.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (stores) |store| {
        try repo.editConfig(&.{.{ .set = .{ .level = .local, .name = try store.key(arena), .value = store.new } }}, null);
        try warning.note(warnings, .{ .promisor_stored = .{
            .field = switch (store.field) {
                .partial_clone_filter => "filter",
                .token => "token",
            },
            .remote = store.remote,
            .old = store.old,
            .new = store.new,
        } });
    }
    try config_state.writeLocal(repo._config, io);
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
    // unreachable: the longest hex name is 64 digits, 78 bytes with the words around it
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
        /// Whether what arrives is checked as a fetch checks it: `null`
        /// takes `fetch.fsckObjects` or `transfer.fsckObjects`; see
        /// `fetch.Options.check_objects`.
        check_objects: ?bool = null,
        /// The promisor remotes a server's `promisor-remote` was answered
        /// with taking, which are asked first, as git asks them.
        accepted: []const []const u8 = &.{},
    };

    /// A lazy fetch for `repo`, a partial clone.
    pub fn init(gpa: Allocator, repo: *Repository, options: Options) Lazy {
        return .{ .gpa = gpa, .repo = repo, .options = options };
    }

    /// Stop asking, and release the failure's description.
    pub fn deinit(l: *Lazy) void {
        l.uninstall();
        l.auth_failure.deinit();
        l.* = undefined;
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
        const l: *Lazy = @ptrCast(@alignCast(context)); // safe: the context handed out with this function is a Lazy
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
        const borrowed = try promisorRemotes(arena, repo.configuration());
        const names = try arena.alloc([]const u8, borrowed.len);
        // fetchFrom may publish configuration while registering a filter.
        // Keep every remote name under the request's owner across that edit.
        // The remotes a server's advertisement was answered with taking
        // come first, each half in the configuration's order.
        var at: usize = 0;
        for ([_]bool{ true, false }) |taken| {
            for (borrowed) |name| {
                const is_taken = for (l.options.accepted) |a| {
                    if (std.mem.eql(u8, a, name)) break true;
                } else false;
                if (is_taken != taken) continue;
                names[at] = try arena.dupe(u8, name);
                at += 1;
            }
        }
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
            if (repo.configuration().get(key) == null) {
                try repo.editConfig(&.{.{ .set = .{ .level = .local, .name = key, .value = "blob:none" } }}, null);
                try config_state.writeLocal(repo._config, io);
            }
        }
        var remote = try remote_mod.Remote.get(l.gpa, repo.configuration(), name);
        defer remote.deinit();
        if (remote.urls.len == 0) return error.NotAPartialClone;
        var session = try transport.Session.open(l.gpa, io, remote.urls[0], .upload_pack, repo.objectFormat(), .{
            .programs = l.options.programs,
            .config = repo.configuration(),
            .service_program = remote.upload_pack,
            .prompt = l.options.prompt,
            .auth_failure = &l.auth_failure,
            .remote_name = remote.name,
            .repository = repo,
        });
        defer session.close(io);
        var pack_dir = try repo.common_dir.openDir(io, "objects/pack", .{});
        defer pack_dir.close(io);
        var rules = try fsck.forTransfer(l.gpa, io, repo.configuration(), repo.objectFormat(), .fetch, l.options.check_objects, null);
        defer if (rules) |*r| r.deinit(l.gpa);
        const fetched = try session.fetch(l.gpa, io, &repo.odb, pack_dir, .{
            .wants = oids,
            .tips = &.{},
            .include_tag = false,
            .filter = "blob:none",
        }, .{ .receive = .{ .fsck = if (rules) |*r| r else null, .promised = true, .reverse_index = revindex.wanted(repo.configuration()) } });
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
            defer db.allocator().free(found.bytes);
            var entries = object.Tree.parse(db.objectFormat(), found.bytes).iterate();
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
