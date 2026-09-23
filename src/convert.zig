//! What happens to a file's bytes between the working tree and the object
//! database, in git's order.
//!
//! On the way in: the clean filter, then line endings, then `ident`. On the
//! way out: `ident`, then line endings, then the smudge filter.
//! `working-tree-encoding` would sit between the filter and the line endings
//! both ways, and is a named refusal. The order is the one git's
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

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const attributes = @import("attributes.zig");
const fs = @import("fs.zig");
const program = @import("program.zig");
const filter = @import("filter.zig");
const lfs = @import("lfs.zig");
const index_mod = @import("index.zig");
const odb_mod = @import("odb.zig");

/// Errors from converting.
pub const Error = error{
    /// `working-tree-encoding`, or a required filter with no `Programs` to
    /// run it. `filter.Report.failure` names the path and the driver for
    /// the second.
    UnsupportedAttribute,
    /// A required filter failed, or a filter delayed a file and never handed
    /// it over. `filter.Report.failure` says which and why.
    FilterFailed,
    /// A process filter claimed a capability that was not offered.
    FilterCapability,
    /// A process filter wrote something that is not a pkt-line.
    FilterReply,
    /// An LFS pointer names an extension, or `lfs.extension.<name>` is
    /// configured: a program git-lfs would run around the content, which
    /// relic does not.
    LfsExtensionUnsupported,
} || Allocator.Error || Io.Cancelable || fs.ReadSizedError || Io.File.Reader.Error ||
    lfs.Store.InstallError || lfs.Store.OpenError || Io.File.Writer.Error || lfs.FetchError ||
    odb_mod.Error;

/// What a conversion into the repository gave.
pub const ToGit = struct {
    /// The bytes to store, allocated from the allocator passed in or
    /// borrowed from the input.
    bytes: []const u8,
    /// The line-ending conversion would not round-trip, which
    /// `core.safecrlf` reports.
    irreversible: bool = false,
};

/// Whether a native LFS clean puts the content in the store or only names
/// it: `status` asks what a file would be stored as, and stores nothing.
pub const Storing = enum { store, hash_only };

/// What a conversion out to the working tree gave.
pub const Smudged = union(enum) {
    /// The bytes to write, allocated from the allocator passed in or
    /// borrowed from the input.
    bytes: []const u8,
    /// An LFS object, opened, to be copied to the working tree. The caller
    /// closes it.
    file: Io.File,
    /// A filter will hand this file over later; `Session.nextReady` gives it
    /// back.
    delayed,
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

/// A file handed over late.
pub const Ready = struct {
    /// The path, as it was given to `toWorktree`.
    path: []const u8,
    /// `.bytes` or `.file`, never `.delayed`.
    content: Smudged,
};

/// One operation's conversions.
pub const Session = struct {
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
    deferred: std.ArrayList(Deferred) = .empty,
    fetched: bool = false,
    next_deferred: usize = 0,
    /// Paths a filter has said are available, not yet asked for, as
    /// indexes into `delayed`.
    available: std.ArrayList(usize) = .empty,
    next_available: usize = 0,
    /// A delayed file went wrong somewhere; the operation fails once
    /// everything else is written, as git's does.
    delay_failed: bool = false,
    /// LFS files given back as their pointer because the object is not in
    /// the store.
    lfs_pointers: u32 = 0,

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
        /// Where a checkout's missing LFS objects are fetched from.
        fetch: ?lfs.Fetcher = null,
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

    const Deferred = struct {
        path: []const u8,
        pointer: lfs.Pointer,
        /// What is written if the object still is not there: the pointer.
        pointer_bytes: []const u8,
    };

    /// A session with nothing started. Nothing runs until a file needs it.
    pub fn init(gpa: Allocator, io: Io, options: Options) Session {
        return .{ .gpa = gpa, .io = io, .options = options, .arena = .init(gpa) };
    }

    /// Finish every filter process — close its input and wait for it, which
    /// is how git ends one — and release everything.
    pub fn deinit(s: *Session) void {
        for (s.processes.items) |p| p.stop(s.io, .finish);
        s.processes.deinit(s.gpa);
        s.delayed.deinit(s.gpa);
        s.delaying.deinit(s.gpa);
        s.deferred.deinit(s.gpa);
        s.available.deinit(s.gpa);
        s.arena.deinit();
        s.* = undefined;
    }

    /// relic's own LFS, when the drivers carry it.
    fn lfsOf(s: *const Session) ?*const lfs.Lfs {
        const drivers = s.options.drivers orelse return null;
        return if (drivers.lfs) |*l| l else null;
    }

    fn resolve(s: *Session, path: []const u8, applied: attributes.Attributes) Error!filter.Drivers.Resolved {
        const name = applied.value("filter") orelse return .none;
        if (s.options.drivers) |drivers| return drivers.resolve(name);
        for (s.options.required_filters) |required| {
            if (!std.mem.eql(u8, required, name)) continue;
            if (s.options.report) |r| try r.fail(path, name, .needs_program, "");
            return error.UnsupportedAttribute;
        }
        return .none;
    }

    /// Read `path` from the working tree and convert it for storage. `size`
    /// is what a stat said, a hint for the read. A file relic's own LFS
    /// keeps is streamed into the store, or only hashed, and never held
    /// whole.
    pub fn toGitFile(
        s: *Session,
        a: Allocator,
        path: []const u8,
        size: u64,
        applied: attributes.Attributes,
        storing: Storing,
    ) Error!ToGit {
        if (attributes.unsupported(applied, &.{}) != null) return error.UnsupportedAttribute;
        const resolved = try s.resolve(path, applied);
        if (resolved == .native_lfs) {
            const pointer_bytes = try s.lfsCleanFile(a, path, storing);
            return s.afterFilter(a, path, pointer_bytes, applied);
        }
        const bytes = try fs.readFileSized(a, s.io, s.options.wt, path, size, 1 << 31);
        return s.convertToGit(a, path, bytes, applied, resolved, storing);
    }

    /// Convert bytes already in memory for storage.
    pub fn toGit(
        s: *Session,
        a: Allocator,
        path: []const u8,
        bytes: []const u8,
        applied: attributes.Attributes,
        storing: Storing,
    ) Error!ToGit {
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
        storing: Storing,
    ) Error!ToGit {
        var cleaned = bytes;
        switch (resolved) {
            .none => {},
            .native_lfs => cleaned = try s.lfsClean(a, bytes, storing),
            .program => |driver| {
                if (try s.clean(a, path, driver, bytes)) |out| cleaned = out;
            },
        }
        return s.afterFilter(a, path, cleaned, applied);
    }

    fn afterFilter(s: *Session, a: Allocator, path: []const u8, bytes: []const u8, applied: attributes.Attributes) Error!ToGit {
        var stored: attributes.Stored = .{};
        if (attributes.crlfAction(applied, s.options.core).isAuto() and std.mem.indexOf(u8, bytes, "\r\n") != null) {
            stored.has_crlf = try s.storedHasCrlf(path);
        }
        const crlf = try attributes.toGitStored(a, bytes, applied, s.options.core, stored);
        const ident = if (identOn(applied)) try identToGit(a, crlf.bytes) else null;
        return .{ .bytes = ident orelse crlf.bytes, .irreversible = crlf.irreversible };
    }

    /// Whether the index's version of `path` is text with CRLF endings:
    /// stage 0, or in the middle of a merge the stage that is ours, as git
    /// reads it.
    fn storedHasCrlf(s: *Session, path: []const u8) Error!bool {
        const index = s.options.index orelse return false;
        const db = s.options.db orelse return false;
        const entry = index.find(path) orelse index.findStage(path, 2) orelse return false;
        if (!entry.mode.isBlob()) return false;
        const found = try db.read(s.io, entry.oid);
        defer db.gpa.free(found.bytes);
        if (found.type != .blob) return false;
        return attributes.hasCrlfText(found.bytes);
    }

    /// Convert a blob for the working tree.
    pub fn toWorktree(
        s: *Session,
        a: Allocator,
        path: []const u8,
        blob: []const u8,
        applied: attributes.Attributes,
        meta: Meta,
    ) Error!Smudged {
        if (attributes.unsupported(applied, &.{}) != null) return error.UnsupportedAttribute;
        const resolved = try s.resolve(path, applied);
        const ident = if (identOn(applied)) try identToWorktree(a, s.options.kind, blob) else null;
        const crlf = try attributes.toWorktree(a, ident orelse blob, applied, s.options.core);
        const bytes = crlf.bytes;
        switch (resolved) {
            .none => return .{ .bytes = bytes },
            .native_lfs => return s.lfsSmudge(a, path, bytes, meta.can_delay),
            .program => |driver| return s.smudge(a, path, driver, bytes, meta),
        }
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
    ) Error!?[]const u8 {
        if (s.options.report) |r| try r.fail(path, driver.name, reason, detail);
        if (driver.required) {
            return if (reason == .needs_program) error.UnsupportedAttribute else error.FilterFailed;
        }
        if (s.options.report) |r| r.passed_over += 1;
        return null;
    }

    fn clean(s: *Session, a: Allocator, path: []const u8, driver: *const filter.Driver, bytes: []const u8) Error!?[]const u8 {
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
    ) Error!Smudged {
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
    ) Error!?[]const u8 {
        return switch (try filter.runCommand(programs, a, s.io, s.options.wt, line, path, bytes)) {
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

    fn processFor(s: *Session, command: []const u8) filter.Process.StartError!*filter.Process {
        for (s.processes.items) |p| {
            if (std.mem.eql(u8, p.command, command)) return p;
        }
        try s.processes.ensureUnusedCapacity(s.gpa, 1);
        const p = try filter.Process.start(s.options.programs.?, s.gpa, s.io, command, s.options.wt);
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
        p.stop(s.io, .kill);
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
    ) Error!ProcessOutcome {
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
    // relic's own LFS

    /// A file already a pointer is stored as it is, which is git-lfs's rule:
    /// cleaning twice changes nothing.
    fn lfsClean(s: *Session, a: Allocator, bytes: []const u8, storing: Storing) Error![]const u8 {
        if (lfs.Pointer.decode(bytes)) |_| return bytes else |_| {}
        const l = s.lfsOf().?;
        if (l.extensions) return error.LfsExtensionUnsupported;
        var source: Io.Reader = .fixed(bytes);
        const pointer = switch (storing) {
            .store => try l.store.install(s.io, &source, null),
            .hash_only => lfs.hashOnly(&source) catch unreachable,
        };
        return encodePointer(a, &pointer);
    }

    fn lfsCleanFile(s: *Session, a: Allocator, path: []const u8, storing: Storing) Error![]const u8 {
        const l = s.lfsOf().?;
        if (l.extensions) return error.LfsExtensionUnsupported;
        const file = try s.options.wt.openFile(s.io, path, .{});
        defer file.close(s.io);
        var head: [lfs.pointer_size_cutoff]u8 = undefined;
        const n = try file.readPositionalAll(s.io, &head, 0);
        if (lfs.Pointer.decode(head[0..n])) |_| {
            if (n < head.len) return a.dupe(u8, head[0..n]);
            return s.options.wt.readFileAlloc(s.io, path, a, .limited(1 << 31));
        } else |_| {}

        var buf: [64 * 1024]u8 = undefined;
        var reader = file.reader(s.io, &buf);
        const pointer = switch (storing) {
            .store => l.store.install(s.io, &reader.interface, null) catch |err| switch (err) {
                error.ReadFailed => return reader.err.?,
                else => |e| return e,
            },
            .hash_only => lfs.hashOnly(&reader.interface) catch return reader.err.?,
        };
        return encodePointer(a, &pointer);
    }

    fn encodePointer(a: Allocator, pointer: *const lfs.Pointer) Allocator.Error![]const u8 {
        var buf: [lfs.Pointer.max_encoded_len]u8 = undefined;
        return a.dupe(u8, pointer.encodeBuf(&buf));
    }

    /// Content that is not a pointer is passed through, and a pointer to
    /// nothing is the empty file. A pointer whose object is here is the
    /// object; one whose object is not is written as the canonical pointer,
    /// which is git-lfs's own fallback.
    fn lfsSmudge(s: *Session, a: Allocator, path: []const u8, bytes: []const u8, can_delay: bool) Error!Smudged {
        const pointer = lfs.Pointer.decode(bytes) catch return .{ .bytes = bytes };
        if (pointer.size == 0) return .{ .bytes = "" };
        if (pointer.extension_count != 0) return error.LfsExtensionUnsupported;
        const l = s.lfsOf().?;
        if (try l.store.open(s.io, &pointer)) |file| return .{ .file = file };

        const canonical = try encodePointer(a, &pointer);
        if (!l.settings.fetchAllowed(path)) {
            if (s.options.report) |r| try r.missing(path, pointer, true);
            s.lfs_pointers += 1;
            return .{ .bytes = canonical };
        }
        if (s.options.fetch != null and can_delay) {
            const arena = s.arena.allocator();
            try s.deferred.append(s.gpa, .{
                .path = try arena.dupe(u8, path),
                .pointer = pointer,
                .pointer_bytes = try arena.dupe(u8, canonical),
            });
            return .delayed;
        }
        if (s.options.report) |r| try r.missing(path, pointer, false);
        s.lfs_pointers += 1;
        return .{ .bytes = canonical };
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
    pub fn nextReady(s: *Session, a: Allocator) Error!?Ready {
        if (try s.nextDeferred()) |ready| return ready;
        while (true) {
            if (s.next_available < s.available.items.len) {
                const d = &s.delayed.items[s.available.items[s.next_available]];
                s.next_available += 1;
                return try s.redeliver(a, d);
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

    fn nextDeferred(s: *Session) Error!?Ready {
        if (s.deferred.items.len == 0) return null;
        const l = s.lfsOf().?;
        if (!s.fetched) {
            s.fetched = true;
            const wanted = try s.arena.allocator().alloc(lfs.Wanted, s.deferred.items.len);
            for (s.deferred.items, wanted) |d, *w| w.* = .{ .path = d.path, .pointer = d.pointer };
            try s.options.fetch.?.fetch(s.io, &l.store, &l.settings, wanted);
        }
        if (s.next_deferred == s.deferred.items.len) return null;
        const d = s.deferred.items[s.next_deferred];
        s.next_deferred += 1;
        if (try l.store.open(s.io, &d.pointer)) |file| return .{ .path = d.path, .content = .{ .file = file } };
        if (s.options.report) |r| try r.missing(d.path, d.pointer, false);
        s.lfs_pointers += 1;
        return .{ .path = d.path, .content = .{ .bytes = d.pointer_bytes } };
    }

    /// Ask every filter that delayed a file what is available, until each
    /// answers with nothing, as git does. False when none has anything more
    /// to say.
    fn askAvailable(s: *Session, a: Allocator) Error!bool {
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
    fn redeliver(s: *Session, a: Allocator, d: *Delayed) Error!Ready {
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
    while (std.mem.indexOfScalar(u8, rest, '$')) |dollar| {
        out.appendSliceAssumeCapacity(rest[0 .. dollar + 1]);
        rest = rest[dollar + 1 ..];
        if (rest.len > 3 and std.mem.startsWith(u8, rest, "Id:")) {
            const close = std.mem.indexOfScalarPos(u8, rest, 3, '$') orelse break;
            if (std.mem.indexOfScalar(u8, rest[3..close], '\n') != null) continue;
            out.appendSliceAssumeCapacity("Id$");
            rest = rest[close + 1 ..];
        }
    }
    out.appendSliceAssumeCapacity(rest);
    return try out.toOwnedSlice(a);
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
    while (std.mem.indexOfScalar(u8, rest, '$')) |dollar| {
        try out.appendSlice(a, rest[0 .. dollar + 1]);
        rest = rest[dollar + 1 ..];
        if (rest.len < 3 or !std.mem.startsWith(u8, rest, "Id")) continue;
        if (rest[2] == '$') {
            rest = rest[3..];
        } else if (rest[2] == ':') {
            const close = std.mem.indexOfScalarPos(u8, rest, 3, '$') orelse break;
            if (std.mem.indexOfScalar(u8, rest[3..close], '\n') != null) continue;
            // A space anywhere but just before the closing dollar is some
            // other system's keyword, and is kept.
            if (close > 4) {
                if (std.mem.indexOfScalar(u8, rest[4..close], ' ')) |at| {
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
    return try out.toOwnedSlice(a);
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
    const out = (try identToWorktree(a, .sha1, in)) orelse in;
    const back = (try identToGit(a, out)) orelse out;
    try testing.expectEqualStrings(in, back);
}
