//! A remote on this machine: a path, or a `file://` URL.
//!
//! git reaches a repository on the same machine by starting
//! `git-upload-pack` there and talking to it over a pipe. relic has the
//! repository's own reader and needs no second program: the other
//! repository is opened in process, its refs are read as they are, and the
//! objects a fetch needs are found with `objectwalk.missing` and written
//! straight into this repository's `objects/pack` as one pack, from the
//! other's object database. Nothing is spawned, and nothing goes through a
//! wire format that both ends of the same process would only have to parse.

const ErrorNamespace = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const refs_mod = @import("../refs/refs.zig");
const repo_mod = @import("../repo/repo.zig");
const odb_mod = @import("../odb/odb.zig");
const pack = @import("../odb/pack.zig");
const protocol = @import("../wire/protocol.zig");
const objectwalk = @import("../walk/objectwalk.zig");
const url_mod = @import("../wire/url.zig");
const object = @import("../object/object.zig");
const revwalk = @import("../walk/walk.zig");
const shallow_mod = @import("../walk/shallow.zig");
const ref_names = @import("../names/ref.zig");
const sendpack = @import("../wire/sendpack.zig");
const hidden_refs = @import("../wire/hidden.zig");
const builtin = @import("builtin");
const revindex = @import("../odb/revindex.zig");
const config_mod = @import("../config/config.zig");

const Oid = hash.Oid;

/// Errors from a repository on this machine used as a remote.
pub const Error = errors: {
    break :errors error{
        /// The path names no repository.
        NotARepository,
        /// The repository has hooks a push would run — `pre-receive`, `update`,
        /// `post-receive` and the rest — and relic runs no hook on another
        /// repository's behalf.
        RemoteHooksNotRun,
    } || repo_mod.Error || objectwalk.Error || refs_mod.ReadError || refs_mod.TransactionError;
};

/// Another repository, open.
pub const Remote = struct {
    pub const Error = ErrorNamespace.Error;

    gpa: Allocator,
    repo: repo_mod.Repository,
    /// The refs not shown: `uploadpack.hideRefs` and `transfer.hideRefs`
    /// from the repository's configuration, or `receive.hideRefs` once
    /// `serve` says a push is coming.
    hidden: hidden_refs.Refs,

    /// Open the repository at `location`: a path, relative to the current
    /// directory or absolute, or a `file://` URL. The path is the
    /// repository — its working tree, its `.git`, or a bare repository —
    /// and is not searched above, as git does not search above a remote's.
    pub fn open(gpa: Allocator, io: Io, location: []const u8, options: repo_mod.Repository.OpenOptions) ErrorNamespace.Error!Remote {
        var identity = url_mod.Identity.parse(gpa, location) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NotARepository,
        };
        defer identity.deinit();
        const parsed = identity.url;
        if (!parsed.isLocalRepository()) return error.NotARepository;
        var dir = Io.Dir.cwd().openDir(io, parsed.path, .{ .iterate = true }) catch return error.NotARepository;
        defer dir.close(io);
        var open_options = options;
        open_options.discover = false;
        open_options.odb.probe_timestamp_resolution = false;
        const repo = repo_mod.Repository.open(gpa, io, dir, open_options) catch |err| switch (err) {
            error.NotARepository => return error.NotARepository,
            else => |e| return e,
        };
        var opened = repo;
        errdefer opened.deinit(io);
        const hidden = try hidden_refs.Refs.load(gpa, opened.configuration(), .upload_pack);
        return .{ .gpa = gpa, .repo = opened, .hidden = hidden };
    }

    /// Close the repository.
    pub fn deinit(r: *Remote, io: Io) void {
        r.hidden.deinit();
        r.repo.deinit(io);
        r.* = undefined;
    }

    /// Hide what the repository hides from `service`: a push is shown
    /// what `receive.hideRefs` leaves.
    pub fn serve(r: *Remote, service: hidden_refs.Service) ErrorNamespace.Error!void {
        const hidden = try hidden_refs.Refs.load(r.gpa, r.repo.configuration(), service);
        r.hidden.deinit();
        r.hidden = hidden;
    }

    /// Whether `name` is a ref the repository does not show.
    pub fn isHidden(r: *const Remote, name: []const u8) bool {
        return r.hidden.isHidden(name, name);
    }

    /// The refs the other repository shows, as a server lists them: `HEAD`
    /// first, with its target, then every ref under `refs/` in name order,
    /// each annotated tag with what it peels to. A hidden ref is left out.
    pub fn listRefs(r: *Remote, gpa: Allocator, io: Io, prefixes: []const []const u8) ErrorNamespace.Error!protocol.RefList {
        return r.listWith(gpa, io, prefixes, false);
    }

    /// `listRefs`, the hidden refs included: what a server asks of itself
    /// when it decides whether a want is a ref's tip.
    pub fn listAllRefs(r: *Remote, gpa: Allocator, io: Io, prefixes: []const []const u8) ErrorNamespace.Error!protocol.RefList {
        return r.listWith(gpa, io, prefixes, true);
    }

    fn listWith(r: *Remote, gpa: Allocator, io: Io, prefixes: []const []const u8, include_hidden: bool) ErrorNamespace.Error!protocol.RefList {
        var list: protocol.RefList = .{ .arena = .init(gpa), .refs = &.{} };
        errdefer list.arena.deinit();
        const arena = list.arena.allocator();
        var out: std.ArrayList(protocol.RemoteRef) = .empty;
        const kind = r.repo.objectFormat();

        if (matches("HEAD", prefixes) and (include_hidden or !r.isHidden("HEAD"))) {
            if (try r.repo.refStore().read(gpa, io, "HEAD")) |head| switch (head) {
                .symbolic => |target| {
                    defer gpa.free(target);
                    const resolved = try r.repo.refStore().resolve(gpa, io, "HEAD");
                    if (resolved) |res| {
                        defer gpa.free(res.name);
                        try out.append(arena, .{
                            .name = "HEAD",
                            .oid = res.oid,
                            .symref_target = try arena.dupe(u8, target),
                        });
                    } else {
                        try out.append(arena, .{
                            .name = "HEAD",
                            .oid = .zero(kind),
                            .symref_target = try arena.dupe(u8, target),
                            .unborn = true,
                        });
                    }
                },
                .direct => |oid| try out.append(arena, .{ .name = "HEAD", .oid = oid }),
            };
        }

        var listing = try r.repo.refStore().list(gpa, io, "refs/");
        defer listing.deinit();
        for (listing.entries) |entry| {
            if (!matches(entry.name, prefixes)) continue;
            if (!include_hidden and r.isHidden(entry.name)) continue;
            var ref: protocol.RemoteRef = .{ .name = try arena.dupe(u8, entry.name), .oid = .zero(kind) };
            switch (entry.target) {
                .direct => |oid| ref.oid = oid,
                .symbolic => |target| {
                    const resolved = (try r.repo.refStore().resolve(gpa, io, entry.name)) orelse continue;
                    defer gpa.free(resolved.name);
                    ref.oid = resolved.oid;
                    ref.symref_target = try arena.dupe(u8, target);
                },
            }
            if (entry.peeled) |peeled| {
                ref.peeled = peeled;
            } else if (try r.repo.objectDatabase().exists(io, ref.oid)) {
                const header = try r.repo.objectDatabase().readHeader(io, ref.oid);
                if (header.type == .tag) ref.peeled = try r.repo.peel(io, ref.oid);
            }
            try out.append(arena, ref);
        }
        list.refs = out.items;
        return list;
    }

    /// Put in `into` — whose `objects/pack` is `pack_dir` — every object
    /// reachable from `wants` that is not reachable from `haves`, as one
    /// pack written from this repository's objects. With `include_tags`,
    /// every annotated tag that points at something in the pack comes too,
    /// as a server's `include-tag` sends it. `null` when there is nothing to
    /// copy. `into` is refreshed to read the new pack.
    pub const CopyOptions = struct { pack_dir: Io.Dir, haves: []const Oid = &.{}, include_tags: bool = false, pack: odb_mod.PackOptions = .{} };
    pub fn copyObjects(
        r: *Remote,
        io: Io,
        into: *odb_mod.Odb,
        wants: []const Oid,
        with: CopyOptions,
    ) ErrorNamespace.Error!?pack.WriteReport {
        const pack_dir = with.pack_dir;
        const haves = with.haves;
        const include_tags = with.include_tags;
        const options = with.pack;
        var collected = try objectwalk.missing(r.gpa, io, r.repo.objectDatabase(), wants, .{ .exclude = haves });
        defer collected.deinit();
        if (collected.entries.len == 0) return null;

        if (include_tags) {
            var sending: Oid.Set = .empty;
            defer sending.deinit(r.gpa);
            for (collected.entries) |entry| try sending.put(r.gpa, entry.oid, {});
            var extra: std.ArrayList(odb_mod.PackEntry) = .empty;
            defer extra.deinit(r.gpa);
            var tags = try r.repo.refStore().list(r.gpa, io, "refs/tags/");
            defer tags.deinit();
            for (tags.entries) |entry| {
                const start = switch (entry.target) {
                    .direct => |oid| oid,
                    .symbolic => continue,
                };
                // A chain of tags: every tag object on it, if it ends at
                // something being sent.
                var chain: std.ArrayList(Oid) = .empty;
                defer chain.deinit(r.gpa);
                var current = start;
                var depth: u8 = 0;
                while (depth < 16) : (depth += 1) {
                    if (!try r.repo.objectDatabase().exists(io, current)) break;
                    const header = try r.repo.objectDatabase().readHeader(io, current);
                    if (header.type != .tag) break;
                    try chain.append(r.gpa, current);
                    const found = try r.repo.objectDatabase().read(io, current);
                    defer r.gpa.free(found.bytes);
                    var tag = try object.Tag.parse(r.gpa, r.repo.objectFormat(), found.bytes);
                    defer tag.deinit();
                    current = tag.target;
                }
                if (chain.items.len == 0 or !sending.contains(current)) continue;
                for (chain.items) |tag_oid| {
                    if (sending.contains(tag_oid) or try into.exists(io, tag_oid)) continue;
                    try sending.put(r.gpa, tag_oid, {});
                    try extra.append(r.gpa, .{ .oid = tag_oid });
                }
            }
            if (extra.items.len != 0) {
                const arena = collected.arena.allocator();
                collected.entries = try std.mem.concat(arena, odb_mod.PackEntry, &.{ collected.entries, extra.items });
            }
        }

        var report = try r.repo.objectDatabase().writePack(io, pack_dir, collected.entries, options);
        errdefer if (report.keep) |*token| token.deinit(io);
        try into.refresh(io);
        return report;
    }

    /// How a push to this repository is applied.
    pub const ReceiveOptions = struct {
        /// Who the reflog entries are written as, and when.
        who: object.Signature,
        /// Apply every command or none.
        atomic: bool = false,
    };

    /// Errors from `receivePush`.
    pub const ReceivePushError = ErrorNamespace.Error || sendpack.Error;

    /// Apply a push to this repository as `git-receive-pack` applies one:
    /// the objects copied from `from` as one pack, then each command under
    /// receive-pack's own rules — `receive.denyCurrentBranch`,
    /// `receive.denyDeleteCurrent`, `receive.denyDeletes`,
    /// `receive.denyNonFastForwards` — and the value the pusher saw, each
    /// ref written with `push` in its log. The answer is the report a
    /// receive-pack would send.
    ///
    /// A repository with hooks that a push runs is refused whole: those
    /// hooks are its owner's, and applying the push without them would skip
    /// whatever they check.
    pub fn receivePush(
        r: *Remote,
        gpa: Allocator,
        io: Io,
        from: *odb_mod.Odb,
        commands: []const sendpack.Command,
        objects: []const odb_mod.PackEntry,
        options: ReceiveOptions,
    ) ReceivePushError!sendpack.Report {
        try r.refuseHooks(io);

        var report: sendpack.Report = .{ .arena = .init(gpa), .unpack_ok = true, .unpack_message = null, .refs = &.{} };
        errdefer report.arena.deinit();
        const arena = report.arena.allocator();

        var needs_pack = false;
        for (commands) |command| {
            if (!command.new.isZero()) needs_pack = true;
        }
        var retained: ?pack.WriteReport = null;
        defer if (retained) |*written| {
            if (written.keep) |*token| token.deinit(io);
        };
        if (needs_pack and objects.len != 0) {
            var pack_dir = try r.repo.commonDirectory().openDir(io, "objects/pack", .{ .iterate = true });
            defer pack_dir.close(io);
            retained = try from.writePack(io, pack_dir, objects, .{ .keep = true, .reverse_index = revindex.wanted(r.repo.configuration()) });
            try r.repo.objectDatabase().refresh(io);
        }

        const config = r.repo.configuration();
        const bare = r.repo.isBare();
        const current = try r.repo.refStore().currentBranch(gpa, io);
        defer if (current) |c| gpa.free(c);
        const deny_current = !bare and denies(config, "receive.denycurrentbranch", true);
        const deny_delete_current = !bare and denies(config, "receive.denydeletecurrent", true);
        const deny_deletes = config.getBool("receive.denydeletes", false) catch false;
        const deny_non_ff = config.getBool("receive.denynonfastforwards", false) catch false;

        var pushed: hash.Oid.Set = .empty;
        for (objects) |entry| try pushed.put(arena, entry.oid, {});
        var new_roots: hash.Oid.Set = .empty;
        var refs: std.ArrayList(sendpack.RefReport) = .empty;
        var refused = false;
        for (commands) |command| {
            const name = try arena.dupe(u8, command.name);
            const is_current = if (current) |c|
                std.mem.startsWith(u8, name, "refs/heads/") and std.mem.eql(u8, name["refs/heads/".len..], c)
            else
                false;
            var reason: ?[]const u8 = null;
            if (r.isHidden(name)) {
                reason = try r.hiddenPushReason(io, command);
            } else if (!std.mem.startsWith(u8, name, "refs/") or !ref_names.checkFormat(name["refs/".len..], .{})) {
                reason = "funny refname";
            } else if (command.new.isZero()) {
                if (deny_deletes) reason = "deletion prohibited";
                if (is_current and deny_delete_current) reason = "deletion of the current branch prohibited";
            } else {
                if (is_current and deny_current) reason = "branch is currently checked out";
                if (reason == null and !try r.repo.objectDatabase().exists(io, command.new)) reason = "missing necessary objects";
                // A shallow pusher's history ends at its boundary; taking a
                // ref whose history does moves this repository's, which git
                // allows only with `receive.shallowUpdate`.
                if (reason == null and from.shallow.count() != 0) {
                    const roots = try shallowRootsReached(arena, io, from, command.new, &pushed);
                    if (roots.len != 0) {
                        if (config.getBool("receive.shallowupdate", false) catch false) {
                            for (roots) |root| try new_roots.put(arena, root, {});
                        } else reason = "shallow update not allowed";
                    }
                }
                if (reason == null and deny_non_ff and !command.old.isZero()) {
                    const ok = revwalk.isAncestor(gpa, io, r.repo.objectDatabase(), .{ .ancestor = command.old, .descendant = command.new }, .{}) catch false;
                    if (!ok) reason = "non-fast-forward";
                }
            }
            if (reason != null) refused = true;
            try refs.append(arena, .{ .name = name, .ok = reason == null, .message = reason });
        }

        if (options.atomic) {
            if (refused) {
                for (refs.items) |*ref| {
                    if (ref.ok) {
                        ref.ok = false;
                        ref.message = "atomic transaction failed";
                    }
                }
            } else {
                var tx = r.repo.beginRefs();
                defer tx.deinit(io);
                for (commands) |command| try stage(&tx, command);
                if (tx.commit(io, .{ .who = options.who, .message = "push", .policy = r.repo.reflogPolicy() })) |_| {} else |err| {
                    if (err == error.Canceled) return error.Canceled;
                    for (refs.items) |*ref| {
                        ref.ok = false;
                        ref.message = "failed to update ref";
                    }
                }
            }
        } else {
            for (commands, refs.items) |command, *ref| {
                if (!ref.ok) continue;
                var tx = r.repo.beginRefs();
                defer tx.deinit(io);
                try stage(&tx, command);
                tx.commit(io, .{ .who = options.who, .message = "push", .policy = r.repo.reflogPolicy() }) catch |err| {
                    if (err == error.Canceled) return error.Canceled;
                    ref.ok = false;
                    ref.message = "failed to update ref";
                };
            }
        }
        if (new_roots.count() != 0) {
            var it = new_roots.keyIterator();
            while (it.next()) |root| try r.repo.objectDatabase().shallow.put(r.repo.allocator(), root.*, {});
            try shallow_mod.write(gpa, io, r.repo.commonDirectory(), &r.repo.objectDatabase().shallow);
        }
        report.refs = refs.items;
        return report;
    }

    fn hiddenPushReason(r: *Remote, io: Io, command: sendpack.Command) ErrorNamespace.Error![]const u8 {
        // After the objects are found to be there, before any of
        // receive-pack's own rules, as git rejects it.
        return if (command.new.isZero())
            "deny deleting a hidden ref"
        else if (!try r.repo.objectDatabase().exists(io, command.new))
            "missing necessary objects"
        else
            "deny updating a hidden ref";
    }

    /// The pusher's boundary commits `tip`'s pushed history reaches.
    fn shallowRootsReached(arena: Allocator, io: Io, from: *odb_mod.Odb, tip: hash.Oid, pushed: *const hash.Oid.Set) (ErrorNamespace.Error || sendpack.Error)![]const hash.Oid {
        var out: std.ArrayList(hash.Oid) = .empty;
        var seen: hash.Oid.Set = .empty;
        var stack: std.ArrayList(hash.Oid) = .empty;
        try stack.append(arena, tip);
        while (stack.pop()) |oid| {
            if ((try seen.getOrPut(arena, oid)).found_existing) continue;
            if (!pushed.contains(oid)) continue;
            if (from.shallow.contains(oid)) {
                try out.append(arena, oid);
                continue;
            }
            const found = from.read(io, oid) catch continue;
            defer from.allocator().free(found.bytes);
            if (found.type != .commit) continue;
            var commit = try object.Commit.parse(arena, from.objectFormat(), found.bytes);
            defer commit.deinit();
            for (commit.parents) |p| try stack.append(arena, p);
        }
        return out.items;
    }

    fn stage(tx: *refs_mod.Transaction, command: sendpack.Command) refs_mod.TransactionError!void {
        const expected: refs_mod.Expected = if (command.old.isZero()) .must_not_exist else .{ .matches = command.old };
        if (command.new.isZero()) {
            try tx.delete(command.name, expected);
        } else {
            try tx.update(command.name, .{ .direct = command.new }, expected);
        }
    }

    /// Refuse a repository whose push would run hooks.
    fn refuseHooks(r: *Remote, io: Io) ErrorNamespace.Error!void {
        const hooks_path = r.repo.configuration().get("core.hookspath");
        var dir = (if (hooks_path) |path|
            Io.Dir.cwd().openDir(io, path, .{})
        else
            r.repo.commonDirectory().openDir(io, "hooks", .{})) catch return;
        defer dir.close(io);
        for ([_][]const u8{
            "pre-receive",  "update",           "post-receive",          "post-update",
            "proc-receive", "push-to-checkout", "reference-transaction",
        }) |name| {
            if (dir.statFile(io, name, .{})) |stat| {
                if (stat.kind == .file and (builtin.target.os.tag == .windows or stat.permissions.toMode() & 0o111 != 0))
                    return error.RemoteHooksNotRun;
            } else |_| {}
            if (builtin.target.os.tag != .windows) continue;
            var name_buf: [64]u8 = undefined;
            // unreachable: the longest hook name above, reference-transaction, is 21 bytes, 25 with .exe
            const executable = std.mem.print(&name_buf, "{s}.exe", .{name}) catch unreachable;
            const stat = dir.statFile(io, executable, .{}) catch continue;
            if (stat.kind != .file) continue;
            return error.RemoteHooksNotRun;
        }
    }
};

/// Whether a `receive.deny*` setting denies: `refuse` and true do, and so
/// does an unset one whose default is to.
fn denies(config: *const config_mod.Config, key: []const u8, default: bool) bool {
    const raw = config.get(key) orelse return default;
    if (std.ascii.eqlIgnoreCase(raw, "refuse")) return true;
    if (std.ascii.eqlIgnoreCase(raw, "warn") or std.ascii.eqlIgnoreCase(raw, "ignore")) return false;
    if (std.ascii.eqlIgnoreCase(raw, "updateinstead")) return true;
    return config_mod.parseBool(raw) catch default;
}

fn matches(name: []const u8, prefixes: []const []const u8) bool {
    if (prefixes.len == 0) return true;
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) return true;
    }
    return false;
}
