//! What happens to a file's bytes between the working tree and the object
//! database, in git's order.
//!
//! On the way in: the clean filter, then line endings, then `ident`. On the
//! way out: `ident`, then line endings, then the smudge filter.
//! `working-tree-encoding` sits between the filter and the line endings both
//! ways, for UTF-16 and UTF-32; any other character set is a named refusal.
//! The order is the one git's
//! `convert.c` runs, which is not quite the one its documentation gives for
//! the way in; the suite holds it to what git does. It matters: a lone
//! carriage return inside a `$Id: … $` makes `text=auto` call a file binary
//! before `ident` removes it, and the `$Id$` a checkout writes names the
//! blob, not the blob with its line endings changed.
//!
//! A `Session` is one operation's worth of this: the filter processes it has
//! started, one per command and each kept up until the operation ends, the
//! files a filter or an LFS fetch has asked to hand over later, and where
//! failures are reported. `worktree.addAll`, `status`, `checkout` and
//! `applySparse` each run one.

const ErrorNamespace = @This();
const Self = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const attributes = @import("../patterns/attributes.zig");
const fs = @import("../fs/fs.zig");
const program = @import("../process/program.zig");
const filter = @import("filter.zig");
const native = @import("native.zig");
const index_mod = @import("../index/index.zig");
const odb_mod = @import("../odb/odb.zig");
const encoding = @import("../text/encoding.zig");

/// Errors from converting.
pub const Error = error{
    /// `working-tree-encoding` for a character set other than UTF-8,
    /// UTF-16 or UTF-32, or a required filter with no `Programs` to run
    /// it. `filter.Report.failure` names the path and the driver for the
    /// second.
    UnsupportedAttribute,
    /// `working-tree-encoding` set or unset with no value, which git
    /// refuses: it names no encoding.
    InvalidWorkingTreeEncoding,
    /// A file to be stored is not text in its `working-tree-encoding`: a
    /// UTF-16 or UTF-32 file without a byte order mark, a `UTF-16LE` or
    /// similar one with one, or bytes that do not decode. git refuses to
    /// store it; where nothing is stored, as for a status, the bytes are
    /// taken as they are, as git takes them.
    WorkingTreeEncodingFailed,
    /// A required filter failed, or a filter delayed a file and never handed
    /// it over. `filter.Report.failure` says which and why.
    FilterFailed,
    /// A process filter claimed a capability that was not offered.
    FilterCapability,
    /// A process filter wrote something that is not a pkt-line.
    FilterReply,
} || native.Error || odb_mod.Error;

/// What a conversion into the repository gave.
pub const ToGit = struct {
    /// The bytes to store, allocated from the allocator passed in or
    /// borrowed from the input.
    bytes: []const u8,
    /// The line-ending conversion would not round-trip, which
    /// `core.safecrlf` reports.
    irreversible: bool = false,
};

/// What a checkout knows about the file it is writing, for a process
/// filter's request.
pub const Meta = struct {
    blob: ?hash.Oid = null,
    treeish: ?hash.Oid = null,
    /// Whether the file may be handed over later. Only a checkout that asks
    /// `nextReady` afterwards may say so.
    can_delay: bool = false,
};

/// One operation's conversions.
pub const Session = struct {
    pub const Error = ErrorNamespace.Error;

    gpa: Allocator,
    io: Io,
    options: Options,
    processes: std.ArrayList(*filter.Process) = .empty,
    /// Holds what outlives one file: the paths and pointers waiting to be
    /// handed over.
    arena: std.heap.ArenaAllocator,
    delayed: std.ArrayList(Delayed) = .empty,
    /// The filter commands that delayed a file, each asked what is
    /// available until it says nothing is.
    delaying: std.ArrayList(Delaying) = .empty,
    native_session: ?native.Session = null,
    /// Paths a filter has said are available, not yet asked for, as
    /// indexes into `delayed`.
    available: std.ArrayList(usize) = .empty,
    next_available: usize = 0,
    /// A delayed file went wrong somewhere; the operation fails once
    /// everything else is written, as git's does.
    delay_failed: bool = false,
    /// What a session is given.
    pub const Options = struct {
        /// The working tree, which a filter program runs in.
        wt: Io.Dir,
        kind: hash.Kind,
        core: attributes.CoreSettings = .{},
        /// What `worktree.Rules.required_filters` said, for a session with
        /// no `drivers`: the names that are refused.
        required_filters: []const []const u8 = &.{},
        /// The drivers and relic's own LFS. Null is what relic did before
        /// it ran filters: every driver passed over, the required ones
        /// refused.
        drivers: ?*const filter.Drivers = null,
        programs: ?program.Programs = null,
        report: ?*filter.Report = null,
        /// The index the working tree is compared with, and the objects it
        /// names. Where the content decides whether a file is text, a file
        /// whose indexed version already has CRLF endings keeps them, as it
        /// does in git; without these, every such file is normalised.
        index: ?*const index_mod.Index = null,
        db: ?*odb_mod.Odb = null,
    };

    const Delayed = struct {
        path: []const u8,
        driver: *const filter.Driver,
        blob: ?[]const u8,
        delivered: bool = false,
    };

    const Delaying = struct {
        command: []const u8,
        driver: *const filter.Driver,
        done: bool = false,
    };

    /// A session with nothing started. Nothing runs until a file needs it.
    pub fn open(gpa: Allocator, io: Io, options: Options) Session {
        return .{ .gpa = gpa, .io = io, .options = options, .arena = .init(gpa) };
    }

    /// Finish every filter process — close its input and wait for it, which
    /// is how git ends one — and release everything.
    pub fn deinit(s: *Session, io: Io) void {
        for (s.processes.items) |p| p.deinit(io);
        s.processes.deinit(s.gpa);
        s.delayed.deinit(s.gpa);
        s.delaying.deinit(s.gpa);
        if (s.native_session) |implementation| implementation.deinit(io);
        s.available.deinit(s.gpa);
        s.arena.deinit();
        s.* = undefined;
    }

    fn nativeOf(s: *Session) ErrorNamespace.Error!native.Session {
        if (s.native_session) |implementation| return implementation;
        const driver = s.options.drivers.?.native_driver.?;
        s.native_session = try driver.open(s.gpa, s.io, .{
            .wt = s.options.wt,
            .observer = if (s.options.report) |r| .{ .context = r, .missing_fn = observeMissing } else null,
        });
        return s.native_session.?;
    }
    fn observeMissing(context: *anyopaque, path: []const u8, object: native.Object, declined: bool) Allocator.Error!void {
        const r: *filter.Report = @ptrCast(@alignCast(context));
        return r.missing(path, object, declined);
    }
    pub fn fallbackCount(s: *const Session) u32 {
        return if (s.native_session) |implementation| implementation.fallbacks() else 0;
    }

    fn resolve(s: *Session, path: []const u8, applied: attributes.Attributes) ErrorNamespace.Error!filter.Drivers.Resolved {
        const name = applied.value("filter") orelse return .none;
        if (s.options.drivers) |drivers| return drivers.resolve(name);
        for (s.options.required_filters) |required| {
            if (!std.mem.eql(u8, required, name)) continue;
            if (s.options.report) |r| try r.fail(path, name, .needs_program, "");
            return error.UnsupportedAttribute;
        }
        return .none;
    }

    pub const FileInputs = struct { path: []const u8, size: u64, applied: attributes.Attributes };
    pub const GitInputs = struct { path: []const u8, bytes: []const u8, applied: attributes.Attributes };
    pub const WorktreeInputs = struct { path: []const u8, blob: []const u8, applied: attributes.Attributes };
    pub const ToGitOptions = struct { storing: native.Storing = .store };

    /// Read `path` from the working tree and convert it for storage. `size`
    /// is what a stat said, a hint for the read. A file relic's own LFS
    /// keeps is streamed into the store, or only hashed, and never held
    /// whole.
    pub fn toGitFile(s: *Session, a: Allocator, inputs: FileInputs, options: ToGitOptions) Self.Error!ToGit {
        const path = inputs.path;
        const size = inputs.size;
        const applied = inputs.applied;
        const storing = options.storing;
        if (attributes.unsupported(applied, &.{}) != null) return error.UnsupportedAttribute;
        const resolved = try s.resolve(path, applied);
        if (resolved == .native) {
            const pointer_bytes = try (try s.nativeOf()).cleanFile(a, s.io, .{ .path = path, .storing = storing });
            return s.afterFilter(a, path, pointer_bytes, applied, storing);
        }
        const bytes = try fs.readFileSized(a, s.io, s.options.wt, path, .{ .size = size, .max_bytes = 1 << 31 });
        return s.convertToGit(a, path, bytes, applied, resolved, storing);
    }

    /// Convert bytes already in memory for storage.
    pub fn toGit(s: *Session, a: Allocator, inputs: GitInputs, options: ToGitOptions) Self.Error!ToGit {
        const path = inputs.path;
        const bytes = inputs.bytes;
        const applied = inputs.applied;
        const storing = options.storing;
        if (attributes.unsupported(applied, &.{}) != null) return error.UnsupportedAttribute;
        const resolved = try s.resolve(path, applied);
        return s.convertToGit(a, path, bytes, applied, resolved, storing);
    }

    fn convertToGit(
        s: *Session,
        a: Allocator,
        path: []const u8,
        bytes: []const u8,
        applied: attributes.Attributes,
        resolved: filter.Drivers.Resolved,
        storing: native.Storing,
    ) ErrorNamespace.Error!ToGit {
        var cleaned = bytes;
        switch (resolved) {
            .none => {},
            .native => cleaned = try (try s.nativeOf()).clean(a, s.io, .{ .bytes = bytes, .storing = storing }),
            .program => |driver| {
                if (try s.clean(a, path, driver, bytes)) |out| cleaned = out;
            },
        }
        return s.afterFilter(a, path, cleaned, applied, storing);
    }

    fn afterFilter(s: *Session, a: Allocator, path: []const u8, filtered: []const u8, applied: attributes.Attributes, storing: native.Storing) ErrorNamespace.Error!ToGit {
        var bytes = filtered;
        if (try encodingOf(applied)) |e| {
            bytes = encoding.toUtf8(a, e, filtered) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                // git's `encode_to_git` dies only where it writes the
                // object, and otherwise goes on with the bytes as they are.
                else => if (storing == .store) return error.WorkingTreeEncodingFailed else filtered,
            };
        }
        var stored: attributes.Stored = .{};
        if (attributes.crlfAction(applied, s.options.core).isAuto() and std.mem.find(u8, bytes, "\r\n") != null) {
            stored.has_crlf = try s.storedHasCrlf(path);
        }
        const crlf = try attributes.toGitStored(a, bytes, applied, s.options.core, stored);
        const ident = if (identOn(applied)) try identToGit(a, crlf.bytes) else null;
        return .{ .bytes = ident orelse crlf.bytes, .irreversible = crlf.irreversible };
    }

    /// Whether the index's version of `path` is text with CRLF endings:
    /// stage 0, or in the middle of a merge the stage that is ours, as git
    /// reads it.
    fn storedHasCrlf(s: *Session, path: []const u8) ErrorNamespace.Error!bool {
        const index = s.options.index orelse return false;
        const db = s.options.db orelse return false;
        const entry = index.find(path) orelse index.findStage(path, 2) orelse return false;
        if (!entry.mode.isBlob()) return false;
        const found = try db.read(s.io, entry.oid);
        defer db.allocator().free(found.bytes);
        if (found.type != .blob) return false;
        return attributes.hasCrlfText(found.bytes);
    }

    /// Convert a blob for the working tree.
    pub fn toWorktree(s: *Session, a: Allocator, inputs: WorktreeInputs, meta: Meta) Self.Error!native.Content {
        const path = inputs.path;
        const blob = inputs.blob;
        const applied = inputs.applied;
        if (attributes.unsupported(applied, &.{}) != null) return error.UnsupportedAttribute;
        const resolved = try s.resolve(path, applied);
        const ident = if (identOn(applied)) try identToWorktree(a, s.options.kind, blob) else null;
        const crlf = try attributes.toWorktree(a, ident orelse blob, applied, s.options.core);
        const bytes = try encodeForWorktree(a, crlf.bytes, applied);
        switch (resolved) {
            .none => return .{ .bytes = bytes },
            .native => return (try s.nativeOf()).smudge(a, s.io, .{ .path = path, .bytes = bytes, .can_delay = meta.can_delay }),
            .program => |driver| return s.smudge(a, path, driver, bytes, meta),
        }
    }

    /// git's `renormalize_buffer`: `bytes`, as the repository holds them,
    /// taken out to the working tree and back in with the attributes
    /// `applied`, so that a blob stored before an attribute changed
    /// compares with one stored after. On the way out `ident` is expanded,
    /// and line endings are converted only when a filter will see them; on
    /// the way in the index is not asked whether the stored version kept
    /// its CRLF endings, which is what renormalizing means. A relic LFS
    /// pointer comes back as its canonical form, which is what the round
    /// trip through the object gives. Nothing is stored.
    pub fn renormalize(s: *Session, a: Allocator, path: []const u8, bytes: []const u8, applied: attributes.Attributes) Self.Error![]const u8 {
        if (attributes.unsupported(applied, &.{}) != null) return error.UnsupportedAttribute;
        const resolved = try s.resolve(path, applied);
        var out: []const u8 = bytes;
        if (identOn(applied)) {
            if (try identToWorktree(a, s.options.kind, out)) |expanded| out = expanded;
        }
        if (resolved == .program) out = (try attributes.toWorktree(a, out, applied, s.options.core)).bytes;
        if (resolved != .native) out = try encodeForWorktree(a, out, applied);
        switch (resolved) {
            .none => {},
            .native => {
                if (try (try s.nativeOf()).canonical(a, out)) |canonical_bytes| return canonical_bytes;
            },
            .program => |driver| {
                switch (try s.smudge(a, path, driver, out, .{})) {
                    .bytes => |smudged| out = smudged,
                    .file => |file| {
                        defer file.close(s.io);
                        var buf: [4096]u8 = undefined;
                        var reader = file.reader(s.io, &buf);
                        var all: std.ArrayList(u8) = .empty;
                        try reader.interface.appendRemainingUnlimited(a, &all);
                        out = all.items;
                    },
                    .delayed => unreachable,
                }
            },
        }
        const index = s.options.index;
        s.options.index = null;
        defer s.options.index = index;
        return (try s.convertToGit(a, path, out, applied, resolved, .hash_only)).bytes;
    }

    /// The encoding `working-tree-encoding` names, or `null` for none or
    /// UTF-8: git's `git_path_check_encoding`. A name this does not convert
    /// was refused before.
    fn encodingOf(applied: attributes.Attributes) ErrorNamespace.Error!?encoding.Encoding {
        const state = applied.get("working-tree-encoding") orelse return null;
        const name = switch (state) {
            .unspecified => return null,
            .set, .unset => return error.InvalidWorkingTreeEncoding,
            .value => |v| v,
        };
        if (name.len == 0 or encoding.isUtf8(name)) return null;
        return encoding.Encoding.fromName(name) orelse error.UnsupportedAttribute;
    }

    /// git's `encode_to_worktree`: UTF-8 out in the file's encoding, and
    /// left as it is where it is not UTF-8.
    fn encodeForWorktree(a: Allocator, bytes: []const u8, applied: attributes.Attributes) ErrorNamespace.Error![]const u8 {
        const e = (try encodingOf(applied)) orelse return bytes;
        return encoding.fromUtf8(a, e, bytes) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => bytes,
        };
    }

    fn identOn(applied: attributes.Attributes) bool {
        const state = applied.get("ident") orelse return false;
        return state == .set;
    }

    // ---------------------------------------------------------------
    // Program filters

    /// Record a filter that produced nothing for a path. A required driver
    /// fails the operation; any other is passed over, and null says so.
    fn passOver(
        s: *Session,
        path: []const u8,
        driver: *const filter.Driver,
        reason: filter.Reason,
        detail: []const u8,
    ) ErrorNamespace.Error!?[]const u8 {
        if (s.options.report) |r| try r.fail(path, driver.name, reason, detail);
        if (driver.required) {
            return if (reason == .needs_program) error.UnsupportedAttribute else error.FilterFailed;
        }
        if (s.options.report) |r| r.passed_over += 1;
        return null;
    }

    fn clean(s: *Session, a: Allocator, path: []const u8, driver: *const filter.Driver, bytes: []const u8) ErrorNamespace.Error!?[]const u8 {
        const programs = s.options.programs orelse return s.passOver(path, driver, .needs_program, "");
        if (driver.process) |command| {
            return switch (try s.processRequest(a, path, driver, command, .clean, bytes, .{})) {
                .content => |out| out,
                .passed_over => null,
                .delayed => unreachable,
            };
        }
        const line = driver.clean orelse {
            if (driver.required) return s.passOver(path, driver, .no_command, "");
            return null;
        };
        return s.runLine(a, programs, path, driver, line, bytes);
    }

    fn smudge(
        s: *Session,
        a: Allocator,
        path: []const u8,
        driver: *const filter.Driver,
        bytes: []const u8,
        meta: Meta,
    ) ErrorNamespace.Error!native.Content {
        const programs = s.options.programs orelse
            return .{ .bytes = (try s.passOver(path, driver, .needs_program, "")) orelse bytes };
        if (driver.process) |command| {
            return switch (try s.processRequest(a, path, driver, command, .smudge, bytes, meta)) {
                .content => |out| .{ .bytes = out },
                .passed_over => .{ .bytes = bytes },
                .delayed => .delayed,
            };
        }
        const line = driver.smudge orelse {
            if (driver.required) _ = try s.passOver(path, driver, .no_command, "");
            return .{ .bytes = bytes };
        };
        return .{ .bytes = (try s.runLine(a, programs, path, driver, line, bytes)) orelse bytes };
    }

    fn runLine(
        s: *Session,
        a: Allocator,
        programs: program.Programs,
        path: []const u8,
        driver: *const filter.Driver,
        line: []const u8,
        bytes: []const u8,
    ) ErrorNamespace.Error!?[]const u8 {
        return switch (try filter.runCommand(a, s.io, programs, line, .{ .cwd = s.options.wt, .path = path, .input = bytes })) {
            .output => |out| out,
            .failed => |stderr| s.passOver(path, driver, .exited, stderr),
            .not_started => s.passOver(path, driver, .not_started, ""),
        };
    }

    const ProcessOutcome = union(enum) {
        content: []const u8,
        passed_over,
        delayed,
    };

    fn processFor(s: *Session, command: []const u8) filter.Process.OpenError!*filter.Process {
        for (s.processes.items) |p| {
            if (std.mem.eql(u8, p.command, command)) return p;
        }
        try s.processes.ensureUnusedCapacity(s.gpa, 1);
        const p = try filter.Process.open(s.gpa, s.io, s.options.programs.?, command, s.options.wt);
        s.processes.appendAssumeCapacity(p);
        return p;
    }

    fn findProcess(s: *Session, command: []const u8) ?*filter.Process {
        for (s.processes.items) |p| {
            if (std.mem.eql(u8, p.command, command)) return p;
        }
        return null;
    }

    /// Stop a process that broke the protocol. The next file that needs the
    /// command starts it again, as git does.
    fn dropProcess(s: *Session, p: *filter.Process) void {
        for (s.processes.items, 0..) |q, i| {
            if (q == p) {
                _ = s.processes.swapRemove(i);
                break;
            }
        }
        p.kill(s.io);
        p.deinit(s.io);
    }

    fn processRequest(
        s: *Session,
        a: Allocator,
        path: []const u8,
        driver: *const filter.Driver,
        command: []const u8,
        which: filter.Protocol.Command,
        bytes: []const u8,
        meta: Meta,
    ) ErrorNamespace.Error!ProcessOutcome {
        const p = s.processFor(command) catch |err| switch (err) {
            error.FilterNotStarted => {
                _ = try s.passOver(path, driver, .not_started, "");
                return .passed_over;
            },
            error.FilterCapability => return error.FilterCapability,
            error.FilterReply => return error.FilterReply,
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
        };
        const caps = &p.protocol.capabilities;
        const able = switch (which) {
            .clean => caps.clean,
            .smudge => caps.smudge,
        };
        if (!able) {
            _ = try s.passOver(path, driver, .no_command, "");
            return .passed_over;
        }

        var blob_hex: [hash.max_hex_len]u8 = undefined;
        var tree_hex: [hash.max_hex_len]u8 = undefined;
        const can_delay = meta.can_delay and caps.delay;
        const reply = p.protocol.request(a, .{
            .command = which,
            .path = path,
            .content = bytes,
            .blob = if (meta.blob) |oid| oid.hex(&blob_hex) else null,
            .treeish = if (meta.treeish) |oid| oid.hex(&tree_hex) else null,
            .can_delay = can_delay,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.FilterReply => return error.FilterReply,
            error.FilterCapability => return error.FilterCapability,
            error.FilterGone, error.FilterPathTooLong, error.FilterHandshake => {
                const canceled = p.canceled();
                s.dropProcess(p);
                if (canceled) return error.Canceled;
                _ = try s.passOver(path, driver, .broken, "");
                return .passed_over;
            },
        };
        switch (reply) {
            .content => |out| return .{ .content = out },
            .delayed => {
                const arena = s.arena.allocator();
                for (s.delaying.items) |d| {
                    if (std.mem.eql(u8, d.command, command)) break;
                } else try s.delaying.append(s.gpa, .{ .command = try arena.dupe(u8, command), .driver = driver });
                try s.delayed.append(s.gpa, .{
                    .path = try arena.dupe(u8, path),
                    .driver = driver,
                    .blob = if (meta.blob) |oid| try arena.dupe(u8, oid.hex(&blob_hex)) else null,
                });
                return .delayed;
            },
            .failed => {
                _ = try s.passOver(path, driver, .status_error, "");
                return .passed_over;
            },
            .aborted => {
                switch (which) {
                    .clean => caps.clean = false,
                    .smudge => caps.smudge = false,
                }
                _ = try s.passOver(path, driver, .status_abort, "");
                return .passed_over;
            },
            .broken => {
                s.dropProcess(p);
                _ = try s.passOver(path, driver, .broken, "");
                return .passed_over;
            },
        }
    }

    // ---------------------------------------------------------------
    // Files handed over late

    /// The next file handed over late, or null when there are none left.
    ///
    /// LFS objects come first: the fetcher is called once with every one
    /// that was missing, and each is then written from the store, or as its
    /// pointer if it is still not there. Then each filter that delayed a
    /// file is asked what is available until it says nothing is, and each
    /// file it names is asked for again. A delayed file never handed over,
    /// or one handed over that was never delayed, is `error.FilterFailed`
    /// once every other file has been given back.
    pub fn nextReady(s: *Session, a: Allocator) Self.Error!?native.Ready {
        if (s.native_session) |implementation| {
            if (try implementation.nextReady(a, s.io)) |ready| return ready;
        }
        while (true) {
            assert(s.next_available <= s.available.items.len);
            if (s.next_available < s.available.items.len) {
                const d = &s.delayed.items[s.available.items[s.next_available]];
                // `askAvailable` lists a delayed file once, as it marks it.
                assert(d.delivered);
                s.next_available += 1;
                const redelivered = try s.redeliver(a, d);
                return redelivered;
            }
            if (!try s.askAvailable(a)) break;
        }
        for (s.delayed.items) |d| {
            if (d.delivered) continue;
            if (s.options.report) |r| try r.fail(d.path, d.driver.name, .never_delivered, "");
            return error.FilterFailed;
        }
        if (s.delay_failed) return error.FilterFailed;
        return null;
    }

    /// Ask every filter that delayed a file what is available, until each
    /// answers with nothing, as git does. False when none has anything more
    /// to say.
    fn askAvailable(s: *Session, a: Allocator) ErrorNamespace.Error!bool {
        var asked = false;
        for (s.delaying.items) |*delaying| {
            if (delaying.done) continue;
            const command = delaying.command;
            const p = s.findProcess(command) orelse {
                // It broke and was stopped with files still out.
                s.giveUp(command);
                continue;
            };
            const listed = p.protocol.listAvailable(a) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.FilterReply => return error.FilterReply,
                else => {
                    s.dropProcess(p);
                    s.giveUp(command);
                    continue;
                },
            };
            if (!listed.ok) {
                s.giveUp(command);
                continue;
            }
            if (listed.paths.len == 0) {
                s.giveUp(command);
                continue;
            }
            asked = true;
            for (listed.paths) |path| {
                for (s.delayed.items, 0..) |*d, i| {
                    if (d.delivered or !std.mem.eql(u8, d.path, path)) continue;
                    if (!std.mem.eql(u8, d.driver.process.?, command)) continue;
                    d.delivered = true;
                    try s.available.append(s.gpa, i);
                    break;
                } else {
                    // Named but never delayed: the filter is not asked
                    // again, and the operation fails at the end.
                    if (s.options.report) |r| try r.fail(path, delaying.driver.name, .never_delivered, "");
                    s.delay_failed = true;
                    s.giveUp(command);
                }
            }
        }
        return asked;
    }

    /// Stop asking a filter about its delayed files; any still out stay
    /// undelivered, and `nextReady` fails for them at the end.
    fn giveUp(s: *Session, command: []const u8) void {
        for (s.delaying.items) |*d| {
            if (std.mem.eql(u8, d.command, command)) d.done = true;
        }
    }

    /// Ask again for a file the filter says is ready. No content goes with
    /// the request, since the filter has it; a failure here writes an empty
    /// file for a driver that is not required, which is what git writes.
    fn redeliver(s: *Session, a: Allocator, d: *Delayed) ErrorNamespace.Error!native.Ready {
        const command = d.driver.process.?;
        const p = s.findProcess(command) orelse {
            _ = try s.passOver(d.path, d.driver, .broken, "");
            return .{ .path = d.path, .content = .{ .bytes = "" } };
        };
        const reply = p.protocol.request(a, .{
            .command = .smudge,
            .path = d.path,
            .content = "",
            .blob = d.blob,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.FilterReply => return error.FilterReply,
            error.FilterCapability => return error.FilterCapability,
            else => {
                const canceled = p.canceled();
                s.dropProcess(p);
                if (canceled) return error.Canceled;
                _ = try s.passOver(d.path, d.driver, .broken, "");
                return .{ .path = d.path, .content = .{ .bytes = "" } };
            },
        };
        switch (reply) {
            .content => |out| return .{ .path = d.path, .content = .{ .bytes = out } },
            .failed, .aborted, .delayed => _ = try s.passOver(d.path, d.driver, .status_error, ""),
            .broken => {
                s.dropProcess(p);
                _ = try s.passOver(d.path, d.driver, .broken, "");
            },
        }
        return .{ .path = d.path, .content = .{ .bytes = "" } };
    }
};

// -------------------------------------------------------------------
// ident

/// How many `$Id$` and `$Id: … $` there are, with git's own counting.
fn countIdent(src: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        i += 1;
        if (c != '$') continue;
        if (src.len - i < 3) break;
        if (!std.mem.eql(u8, src[i .. i + 2], "Id")) continue;
        const after = src[i + 2];
        i += 3;
        if (after == '$') count += 1;
        if (after != ':') continue;
        // `$Id: …`: up to the closing dollar, unless a line ends first.
        while (i < src.len) {
            const d = src[i];
            i += 1;
            if (d == '$') {
                count += 1;
                break;
            }
            if (d == '\n') break;
        }
    }
    return count;
}

/// `$Id: anything $` becomes `$Id$`, where the two dollars are on one line.
/// Null when there is nothing to change.
pub fn identToGit(a: Allocator, src: []const u8) Allocator.Error!?[]u8 {
    if (countIdent(src) == 0) return null;
    var out: std.ArrayList(u8) = try .initCapacity(a, src.len);
    var rest = src;
    while (std.mem.findScalar(u8, rest, '$')) |dollar| {
        out.appendSliceAssumeCapacity(rest[0 .. dollar + 1]);
        rest = rest[dollar + 1 ..];
        if (rest.len > 3 and std.mem.startsWith(u8, rest, "Id:")) {
            const close = std.mem.findScalarPos(u8, rest, 3, '$') orelse break;
            if (std.mem.findScalar(u8, rest[3..close], '\n') != null) continue;
            out.appendSliceAssumeCapacity("Id$");
            rest = rest[close + 1 ..];
        }
    }
    out.appendSliceAssumeCapacity(rest);
    const owned = try out.toOwnedSlice(a);
    return owned;
}

/// `$Id$`, and a `$Id: … $` git itself would have written, become
/// `$Id: <the blob's name> $`. The name is the blob's as it is stored. Null
/// when there is nothing to change.
pub fn identToWorktree(a: Allocator, kind: hash.Kind, src: []const u8) Allocator.Error!?[]u8 {
    const count = countIdent(src);
    if (count == 0) return null;
    const oid = hash.Hasher.object(kind, "blob", src);
    var hex_buf: [hash.max_hex_len]u8 = undefined;
    const hex = oid.hex(&hex_buf);

    var out: std.ArrayList(u8) = try .initCapacity(a, src.len + count * (hex.len + 3));
    var rest = src;
    while (std.mem.findScalar(u8, rest, '$')) |dollar| {
        try out.appendSlice(a, rest[0 .. dollar + 1]);
        rest = rest[dollar + 1 ..];
        if (rest.len < 3 or !std.mem.startsWith(u8, rest, "Id")) continue;
        if (rest[2] == '$') {
            rest = rest[3..];
        } else if (rest[2] == ':') {
            const close = std.mem.findScalarPos(u8, rest, 3, '$') orelse break;
            if (std.mem.findScalar(u8, rest[3..close], '\n') != null) continue;
            // A space anywhere but just before the closing dollar is some
            // other system's keyword, and is kept.
            if (close > 4) {
                if (std.mem.findScalar(u8, rest[4..close], ' ')) |at| {
                    if (4 + at < close - 1) continue;
                }
            }
            rest = rest[close + 1 ..];
        } else continue;
        try out.appendSlice(a, "Id: ");
        try out.appendSlice(a, hex);
        try out.appendSlice(a, " $");
    }
    try out.appendSlice(a, rest);
    const owned = try out.toOwnedSlice(a);
    return owned;
}

const testing = std.testing;

test "ident collapses on the way in and names the blob on the way out" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expect(try identToGit(a, "no keyword here\n") == null);
    try testing.expectEqualStrings("a $Id$ b\n", (try identToGit(a, "a $Id: 1234 $ b\n")).?);
    try testing.expectEqualStrings("$Id$\n$Id: x\ny $\n", (try identToGit(a, "$Id: q $\n$Id: x\ny $\n")).?);

    const blob = "$Id$\nx\n";
    const out = (try identToWorktree(a, .sha1, blob)).?;
    try testing.expectEqualStrings("$Id: 093cd7cf40884a9ffe9014d667e7edf3593ec7fb $\nx\n", out);
    try testing.expectEqualStrings(blob, (try identToGit(a, out)).?);
    // Another system's keyword, with a space inside, is left alone.
    try testing.expectEqualStrings(
        "$Id: foo.c,v 1.2 bar $",
        (try identToWorktree(a, .sha1, "$Id: foo.c,v 1.2 bar $")) orelse "$Id: foo.c,v 1.2 bar $",
    );
}

test "fuzz: ident on the way in never grows a file, and undoes the way out" {
    try testing.fuzz({}, fuzzIdent, .{});
}

fn fuzzIdent(_: void, smith: *testing.Smith) anyerror!void {
    var scratch: [512]u8 = undefined;
    const n = smith.slice(&scratch);
    const src = scratch[0..n];
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const in = (try identToGit(a, src)) orelse src;
    try testing.expect(in.len <= src.len);
    // The way in is git's, and git's is not idempotent: a collapse can leave
    // a `$Id:` the scan stepped past, which the next one takes. What the way
    // out undoes is a file the way in leaves as it is.
    const settled = (try identToGit(a, in)) orelse in;
    if (!std.mem.eql(u8, settled, in)) return;
    const out = (try identToWorktree(a, .sha1, in)) orelse in;
    const back = (try identToGit(a, out)) orelse out;
    try testing.expectEqualStrings(in, back);
}

test "the way in is git's, a collapse that leaves a keyword for the next one included" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // git's ident_to_git steps past the dollar that closes a collapsed
    // keyword, so the `Id:` right after it waits for the next pass.
    const once = (try identToGit(a, "$Id: a $Id: b $Id: c $")).?;
    try testing.expectEqualStrings("$Id$Id: b $Id$", once);
    try testing.expectEqualStrings("$Id$Id$Id$", (try identToGit(a, once)).?);
}

test "phase2 conversion cleanup passes its supplied Io to the native owner once" {
    const Probe = struct {
        calls: usize = 0,
        received: ?Io = null,
        fn clean(_: *anyopaque, _: Allocator, _: Io, _: native.CleanInput) native.Error![]const u8 {
            unreachable;
        }
        fn cleanFile(_: *anyopaque, _: Allocator, _: Io, _: native.FileInput) native.Error![]const u8 {
            unreachable;
        }
        fn smudge(_: *anyopaque, _: Allocator, _: Io, _: native.SmudgeInput) native.Error!native.Content {
            unreachable;
        }
        fn canonical(_: *anyopaque, _: Allocator, _: []const u8) native.Error!?[]const u8 {
            unreachable;
        }
        fn nextReady(_: *anyopaque, _: Allocator, _: Io) native.Error!?native.Ready {
            unreachable;
        }
        fn fallbacks(_: *const anyopaque) u32 {
            return 0;
        }
        fn deinit(context: *anyopaque, io: Io) void {
            const p: *@This() = @ptrCast(@alignCast(context));
            p.calls += 1;
            p.received = io;
        }
        const vtable: native.Session.VTable = .{ .clean = clean, .clean_file = cleanFile, .smudge = smudge, .canonical = canonical, .next_ready = nextReady, .fallbacks = fallbacks, .deinit = deinit };
    };
    const io = std.testing.io;
    var cleanup_vtable = io.vtable.*;
    const cleanup_io: Io = .{ .userdata = io.userdata, .vtable = &cleanup_vtable };
    var probe: Probe = .{};
    var session: Session = .open(std.testing.allocator, io, .{ .wt = Io.Dir.cwd(), .kind = .sha1 });
    session.native_session = .{ .context = &probe, .vtable = &Probe.vtable };
    session.deinit(cleanup_io);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expect(probe.received.?.vtable == cleanup_io.vtable);
    try std.testing.expect(probe.received.?.userdata == cleanup_io.userdata);
    try std.testing.expect(probe.received.?.vtable != io.vtable);
}
