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

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const refs_mod = @import("refs.zig");
const repo_mod = @import("repo.zig");
const odb_mod = @import("odb.zig");
const pack = @import("pack.zig");
const protocol = @import("protocol.zig");
const objectwalk = @import("objectwalk.zig");
const url_mod = @import("url.zig");
const object = @import("object.zig");
const revwalk = @import("revwalk.zig");
const safepath = @import("safepath.zig");
const sendpack = @import("sendpack.zig");
const builtin = @import("builtin");

const Oid = hash.Oid;

pub const Error = error{
    /// The path names no repository.
    NotARepository,
    /// The repository has hooks a push would run — `pre-receive`, `update`,
    /// `post-receive` and the rest — and relic runs no hook on another
    /// repository's behalf.
    RemoteHooksNotRun,
} || repo_mod.Error || objectwalk.Error || refs_mod.ReadError || refs_mod.TransactionError;

/// Another repository, open.
pub const Remote = struct {
    gpa: Allocator,
    repo: repo_mod.Repository,

    /// Open the repository at `location`: a path, relative to the current
    /// directory or absolute, or a `file://` URL. The path is the
    /// repository — its working tree, its `.git`, or a bare repository —
    /// and is not searched above, as git does not search above a remote's.
    pub fn open(gpa: Allocator, io: Io, location: []const u8) Error!Remote {
        const parsed = url_mod.Url.parse(location) catch return error.NotARepository;
        if (!parsed.isLocalRepository()) return error.NotARepository;
        var dir = Io.Dir.cwd().openDir(io, parsed.path, .{ .iterate = true }) catch return error.NotARepository;
        defer dir.close(io);
        const repo = repo_mod.Repository.open(gpa, io, dir, .{
            .discover = false,
            .odb = .{ .probe_timestamp_resolution = false },
        }) catch |err| switch (err) {
            error.NotARepository => return error.NotARepository,
            else => |e| return e,
        };
        return .{ .gpa = gpa, .repo = repo };
    }

    pub fn deinit(r: *Remote, io: Io) void {
        r.repo.deinit(io);
        r.* = undefined;
    }

    /// The refs the other repository has, as a server lists them: `HEAD`
    /// first, with its target, then every ref under `refs/` in name order,
    /// each annotated tag with what it peels to.
    pub fn listRefs(r: *Remote, gpa: Allocator, io: Io, prefixes: []const []const u8) Error!protocol.RefList {
        var list: protocol.RefList = .{ .arena = .init(gpa), .refs = &.{} };
        errdefer list.arena.deinit();
        const arena = list.arena.allocator();
        var out: std.ArrayList(protocol.RemoteRef) = .empty;
        const kind = r.repo.kind;

        if (matches("HEAD", prefixes)) {
            if (try r.repo.refs.read(gpa, io, "HEAD")) |head| switch (head) {
                .symbolic => |target| {
                    defer gpa.free(target);
                    const resolved = try r.repo.refs.resolve(gpa, io, "HEAD");
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

        var listing = try r.repo.refs.list(gpa, io, "refs/");
        defer listing.deinit();
        for (listing.entries) |entry| {
            if (!matches(entry.name, prefixes)) continue;
            var ref: protocol.RemoteRef = .{ .name = try arena.dupe(u8, entry.name), .oid = .zero(kind) };
            switch (entry.target) {
                .direct => |oid| ref.oid = oid,
                .symbolic => |target| {
                    const resolved = (try r.repo.refs.resolve(gpa, io, entry.name)) orelse continue;
                    defer gpa.free(resolved.name);
                    ref.oid = resolved.oid;
                    ref.symref_target = try arena.dupe(u8, target);
                },
            }
            if (entry.peeled) |peeled| {
                ref.peeled = peeled;
            } else if (try r.repo.odb.exists(io, ref.oid)) {
                const header = try r.repo.odb.readHeader(io, ref.oid);
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
    pub fn copyObjects(
        r: *Remote,
        io: Io,
        into: *odb_mod.Odb,
        pack_dir: Io.Dir,
        wants: []const Oid,
        haves: []const Oid,
        include_tags: bool,
        options: odb_mod.PackOptions,
    ) Error!?pack.WriteReport {
        var collected = try objectwalk.missing(r.gpa, io, &r.repo.odb, wants, haves);
        defer collected.deinit();
        if (collected.entries.len == 0) return null;

        if (include_tags) {
            var sending: Oid.Set = .empty;
            defer sending.deinit(r.gpa);
            for (collected.entries) |entry| try sending.put(r.gpa, entry.oid, {});
            var extra: std.ArrayList(odb_mod.PackEntry) = .empty;
            defer extra.deinit(r.gpa);
            var tags = try r.repo.refs.list(r.gpa, io, "refs/tags/");
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
                    if (!try r.repo.odb.exists(io, current)) break;
                    const header = try r.repo.odb.readHeader(io, current);
                    if (header.type != .tag) break;
                    try chain.append(r.gpa, current);
                    const found = try r.repo.odb.read(io, current);
                    defer r.gpa.free(found.bytes);
                    var tag = try @import("object.zig").Tag.parse(r.gpa, r.repo.kind, found.bytes);
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

        const report = try r.repo.odb.writePack(io, pack_dir, collected.entries, options);
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
    ) (Error || sendpack.Error)!sendpack.Report {
        try r.refuseHooks(io);

        var report: sendpack.Report = .{ .arena = .init(gpa), .unpack_ok = true, .unpack_message = null, .refs = &.{} };
        errdefer report.arena.deinit();
        const arena = report.arena.allocator();

        var needs_pack = false;
        for (commands) |command| {
            if (!command.new.isZero()) needs_pack = true;
        }
        if (needs_pack and objects.len != 0) {
            var pack_dir = try r.repo.common_dir.openDir(io, "objects/pack", .{ .iterate = true });
            defer pack_dir.close(io);
            _ = try from.writePack(io, pack_dir, objects, .{});
            try r.repo.odb.refresh(io);
        }

        const config = &r.repo.config;
        const bare = r.repo.isBare();
        const current = try r.repo.refs.currentBranch(gpa, io);
        defer if (current) |c| gpa.free(c);
        const deny_current = !bare and denies(config, "receive.denycurrentbranch", true);
        const deny_delete_current = !bare and denies(config, "receive.denydeletecurrent", true);
        const deny_deletes = config.getBool("receive.denydeletes", false) catch false;
        const deny_non_ff = config.getBool("receive.denynonfastforwards", false) catch false;

        var refs: std.ArrayList(sendpack.RefReport) = .empty;
        var refused = false;
        for (commands) |command| {
            const name = try arena.dupe(u8, command.name);
            const is_current = if (current) |c|
                std.mem.startsWith(u8, name, "refs/heads/") and std.mem.eql(u8, name["refs/heads/".len..], c)
            else
                false;
            var reason: ?[]const u8 = null;
            if (!std.mem.startsWith(u8, name, "refs/") or !safepath.isValidRefName(name)) {
                reason = "funny refname";
            } else if (command.new.isZero()) {
                if (deny_deletes) reason = "deletion prohibited";
                if (is_current and deny_delete_current) reason = "deletion of the current branch prohibited";
            } else {
                if (is_current and deny_current) reason = "branch is currently checked out";
                if (reason == null and !try r.repo.odb.exists(io, command.new)) reason = "missing necessary objects";
                if (reason == null and deny_non_ff and !command.old.isZero()) {
                    const ok = revwalk.isAncestor(gpa, io, &r.repo.odb, command.old, command.new) catch false;
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
                if (tx.commit(io, .{ .who = options.who, .message = "push", .policy = r.repo.reflogPolicy() })) |_| {} else |_| {
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
                tx.commit(io, .{ .who = options.who, .message = "push", .policy = r.repo.reflogPolicy() }) catch {
                    ref.ok = false;
                    ref.message = "failed to update ref";
                };
            }
        }
        report.refs = refs.items;
        return report;
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
    fn refuseHooks(r: *Remote, io: Io) Error!void {
        const hooks_path = r.repo.config.get("core.hookspath");
        var dir = (if (hooks_path) |path|
            Io.Dir.cwd().openDir(io, path, .{})
        else
            r.repo.common_dir.openDir(io, "hooks", .{})) catch return;
        defer dir.close(io);
        for ([_][]const u8{
            "pre-receive",  "update",           "post-receive",          "post-update",
            "proc-receive", "push-to-checkout", "reference-transaction",
        }) |name| {
            const stat = dir.statFile(io, name, .{}) catch continue;
            if (stat.kind != .file) continue;
            if (builtin.os.tag != .windows and stat.permissions.toMode() & 0o111 == 0) continue;
            return error.RemoteHooksNotRun;
        }
    }
};

/// Whether a `receive.deny*` setting denies: `refuse` and true do, and so
/// does an unset one whose default is to.
fn denies(config: *const @import("config.zig").Config, key: []const u8, default: bool) bool {
    const raw = config.get(key) orelse return default;
    if (std.ascii.eqlIgnoreCase(raw, "refuse")) return true;
    if (std.ascii.eqlIgnoreCase(raw, "warn") or std.ascii.eqlIgnoreCase(raw, "ignore")) return false;
    if (std.ascii.eqlIgnoreCase(raw, "updateinstead")) return true;
    return @import("config.zig").parseBool(raw) catch default;
}

fn matches(name: []const u8, prefixes: []const []const u8) bool {
    if (prefixes.len == 0) return true;
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) return true;
    }
    return false;
}
