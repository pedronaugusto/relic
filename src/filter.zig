//! Clean and smudge filters: the programs a `filter` attribute names.
//!
//! `filter=<driver>` hands a path's content to `filter.<driver>.clean` on
//! the way into the repository and to `filter.<driver>.smudge` on the way
//! out, each a command line read the way git reads one: `%f` becomes the
//! path, quoted for the shell, and the line runs through `sh`. A driver may
//! name `filter.<driver>.process` instead, one program that stays up for a
//! whole operation and takes every file over the long-running process
//! protocol; when both are configured the process is used, as git uses it.
//!
//! A filter that fails is not an error unless `filter.<driver>.required`
//! says it is. git's reading of a filter is that it makes content more
//! convenient, so a missing or failing one leaves the content as it was; a
//! required one turns content that is unusable on its own into content that
//! is usable, and failing it is a failed operation. Both are here, and a
//! filter passed over is counted in `Report`, so a caller can say so.
//!
//! Running a filter means running a program, and nothing here starts one
//! without the caller's `program.Programs`. Without them a required driver is
//! a named refusal, which is what relic did before it ran anything, and any
//! other driver is passed over.
//!
//! One driver is not a program at all. `lfs` is handled in process by
//! `lfs.zig` when every command configured for it is one git-lfs itself
//! writes, or when none is configured: the bytes are the same bytes, and a
//! repository keeping its large files that way is then read and written with
//! no git-lfs installed and no `Programs` handed in. A command git-lfs did
//! not write is the person's own and runs like any other filter, and
//! `Drivers.Options.native_lfs` set to false makes `lfs` an ordinary driver
//! throughout.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const config_mod = @import("config.zig");
const program = @import("program.zig");
const pktline = @import("pktline.zig");
const lfs = @import("lfs.zig");

/// One `filter.<name>` section.
pub const Driver = struct {
    name: []const u8,
    /// `filter.<name>.clean`, or null when unset or empty.
    clean: ?[]const u8 = null,
    /// `filter.<name>.smudge`, or null when unset or empty.
    smudge: ?[]const u8 = null,
    /// `filter.<name>.process`, or null when unset or empty.
    process: ?[]const u8 = null,
    /// `filter.<name>.required`.
    required: bool = false,

    /// Whether every command this driver names is one git-lfs itself writes
    /// into a configuration: `git-lfs clean -- %f`, `git-lfs smudge -- %f`,
    /// `git-lfs filter-process`, or their `--skip` forms.
    pub fn isGitLfs(d: *const Driver) bool {
        if (d.clean) |line| if (!isGitLfsCommand(line, "clean")) return false;
        if (d.smudge) |line| if (!isGitLfsCommand(line, "smudge")) return false;
        if (d.process) |line| if (!isGitLfsCommand(line, "filter-process")) return false;
        return true;
    }

    /// Whether the smudge git-lfs was configured with is its `--skip` form,
    /// which leaves every pointer as it is.
    pub fn skipsSmudge(d: *const Driver) bool {
        for ([_]?[]const u8{ d.smudge, d.process }) |maybe| {
            const line = maybe orelse continue;
            var words = std.mem.tokenizeAny(u8, line, " \t");
            while (words.next()) |word| {
                if (std.mem.eql(u8, word, "--skip")) return true;
            }
        }
        return false;
    }
};

/// Whether `line` is git-lfs run with `subcommand` and nothing else but the
/// arguments git-lfs itself puts there.
pub fn isGitLfsCommand(line: []const u8, subcommand: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, line, " \t");
    const first = words.next() orelse return false;
    const base = std.fs.path.basenamePosix(first);
    if (std.mem.eql(u8, base, "git")) {
        const second = words.next() orelse return false;
        if (!std.mem.eql(u8, second, "lfs")) return false;
    } else if (!std.mem.eql(u8, base, "git-lfs") and !std.mem.eql(u8, base, "git-lfs.exe")) {
        return false;
    }
    const sub = words.next() orelse return false;
    if (!std.mem.eql(u8, sub, subcommand)) return false;
    while (words.next()) |word| {
        if (std.mem.eql(u8, word, "--") or std.mem.eql(u8, word, "%f") or std.mem.eql(u8, word, "--skip")) continue;
        return false;
    }
    return true;
}

/// Every driver the configuration defines, and relic's own LFS.
pub const Drivers = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator.State,
    items: []const Driver,
    /// relic's own LFS, which stands in for the driver named `lfs`; null
    /// when `Options.native_lfs` turned it off or it was not loaded.
    lfs: ?lfs.Lfs = null,

    /// How the drivers are read.
    pub const Options = struct {
        /// Handle `filter=lfs` in process rather than through a program.
        native_lfs: bool = true,
        /// Leave every LFS pointer as it is on checkout, as
        /// `GIT_LFS_SKIP_SMUDGE` does.
        lfs_skip_smudge: bool = false,
        /// `.lfsconfig` from the index or `HEAD`, for a working tree that
        /// has none: `lfs.Lfs.Options.lfsconfig`.
        lfsconfig: ?[]const u8 = null,
    };

    /// Errors from reading the drivers.
    pub const LoadError = lfs.Lfs.LoadError || config_mod.ValueError;

    /// The drivers `config` defines, with no LFS of relic's own. Every
    /// string is copied, so the result does not borrow the configuration.
    pub fn fromConfig(gpa: Allocator, config: *const config_mod.Config) LoadError!Drivers {
        var arena_instance: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena_instance.deinit();
        const a = arena_instance.allocator();

        var list: std.ArrayList(Driver) = .empty;
        for (config.entries.items) |entry| {
            if (!std.ascii.eqlIgnoreCase(entry.section, "filter") or entry.subsection.len == 0) continue;
            const driver = for (list.items) |*d| {
                if (std.mem.eql(u8, d.name, entry.subsection)) break d;
            } else blk: {
                try list.append(a, .{ .name = try a.dupe(u8, entry.subsection) });
                break :blk &list.items[list.items.len - 1];
            };
            const raw = entry.value orelse "";
            // The last line that sets a key wins, as it does in git.
            if (std.ascii.eqlIgnoreCase(entry.name, "required")) {
                driver.required = if (entry.value == null) true else blk: {
                    const decoded = config_mod.unquote(a, raw) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return error.NotABoolean,
                    };
                    break :blk try config_mod.parseBool(decoded);
                };
                continue;
            }
            const slot = if (std.ascii.eqlIgnoreCase(entry.name, "clean"))
                &driver.clean
            else if (std.ascii.eqlIgnoreCase(entry.name, "smudge"))
                &driver.smudge
            else if (std.ascii.eqlIgnoreCase(entry.name, "process"))
                &driver.process
            else
                continue;
            const decoded = config_mod.unquote(a, raw) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.MalformedValue,
            };
            slot.* = if (decoded.len == 0) null else decoded;
        }
        return .{ .gpa = gpa, .arena = arena_instance.state, .items = list.items };
    }

    /// The drivers, and relic's own LFS unless `options` turns it off: its
    /// store under `common_dir`, which is borrowed for as long as the result
    /// lives, and its settings from the configuration and from `.lfsconfig`
    /// at the root of `work_dir`.
    pub fn load(
        gpa: Allocator,
        io: Io,
        config: *const config_mod.Config,
        common_dir: Io.Dir,
        work_dir: ?Io.Dir,
        options: Options,
    ) LoadError!Drivers {
        var drivers = try fromConfig(gpa, config);
        errdefer drivers.deinit();
        if (options.native_lfs) {
            const skip = options.lfs_skip_smudge or
                (if (drivers.find("lfs")) |d| d.isGitLfs() and d.skipsSmudge() else false);
            drivers.lfs = try lfs.Lfs.load(gpa, io, config, common_dir, work_dir, .{ .skip_smudge = skip, .lfsconfig = options.lfsconfig });
        }
        return drivers;
    }

    /// Release everything.
    pub fn deinit(d: *Drivers) void {
        if (d.lfs) |*l| l.deinit();
        var arena = d.arena.promote(d.gpa);
        arena.deinit();
        d.* = undefined;
    }

    /// The driver called `name`, or null.
    pub fn find(d: *const Drivers, name: []const u8) ?*const Driver {
        for (d.items) |*driver| {
            if (std.mem.eql(u8, driver.name, name)) return driver;
        }
        return null;
    }

    /// What a `filter=<name>` attribute comes to.
    pub fn resolve(d: *const Drivers, name: []const u8) Resolved {
        if (d.lfs != null and std.mem.eql(u8, name, "lfs")) {
            if (d.find(name)) |driver| {
                if (!driver.isGitLfs()) return .{ .program = driver };
            }
            return .native_lfs;
        }
        if (d.find(name)) |driver| return .{ .program = driver };
        // An attribute naming a driver the configuration does not define is
        // not an error in git and does nothing.
        return .none;
    }

    /// See `resolve`.
    pub const Resolved = union(enum) {
        none,
        /// relic's own LFS.
        native_lfs,
        program: *const Driver,
    };
};

/// Why a filter did not produce content.
pub const Reason = enum {
    /// No `Programs` were handed in, so the program was not run.
    needs_program,
    /// The driver has no command for this direction.
    no_command,
    /// The program could not be started, or its handshake failed.
    not_started,
    /// A command line exited with a status other than zero, or was killed.
    exited,
    /// A process filter answered `status=error`.
    status_error,
    /// A process filter answered `status=abort`, and is not asked again for
    /// this direction.
    status_abort,
    /// A process filter went away, or answered with a status the protocol
    /// does not have; it is stopped and started again for the next file.
    broken,
    /// A process filter delayed a file and never handed it over.
    never_delivered,
};

/// A filter that did not produce content for one path.
pub const Failure = struct {
    path: []u8,
    driver: []u8,
    reason: Reason,
    /// What the program wrote to its standard error, up to four kilobytes,
    /// for a command line; empty otherwise.
    detail: []u8,
};

/// An LFS file a checkout left as a pointer.
pub const Missing = struct {
    path: []u8,
    pointer: lfs.Pointer,
    /// The settings said not to fetch it (`lfs.fetchexclude`,
    /// `lfs.fetchinclude`, a skipped smudge), as opposed to a fetch that was
    /// not possible or did not bring it.
    declined: bool,
};

/// What filtering did that is not in the bytes: files passed over and why,
/// and LFS files left as pointers. The caller owns it and hands it to an
/// operation through its options.
pub const Report = struct {
    gpa: Allocator,
    /// LFS files left as pointers, in the order they were met.
    lfs_missing: std.ArrayList(Missing) = .empty,
    /// Files a filter failed on whose content was then used unfiltered,
    /// because the driver is not required.
    passed_over: u32 = 0,
    /// The most recent failure. When an operation returns
    /// `error.FilterFailed` or `error.UnsupportedAttribute` for a filter,
    /// this is the one that stopped it.
    failure: ?Failure = null,

    /// An empty report whose lists are allocated from `gpa`.
    pub fn init(gpa: Allocator) Report {
        return .{ .gpa = gpa };
    }

    /// Release everything.
    pub fn deinit(r: *Report) void {
        for (r.lfs_missing.items) |m| r.gpa.free(m.path);
        r.lfs_missing.deinit(r.gpa);
        r.clearFailure();
        r.* = undefined;
    }

    fn clearFailure(r: *Report) void {
        if (r.failure) |f| {
            r.gpa.free(f.path);
            r.gpa.free(f.driver);
            r.gpa.free(f.detail);
        }
        r.failure = null;
    }

    /// Record a failure, replacing the one before.
    pub fn fail(r: *Report, path: []const u8, driver: []const u8, reason: Reason, detail: []const u8) Allocator.Error!void {
        const owned_path = try r.gpa.dupe(u8, path);
        errdefer r.gpa.free(owned_path);
        const owned_driver = try r.gpa.dupe(u8, driver);
        errdefer r.gpa.free(owned_driver);
        const owned_detail = try r.gpa.dupe(u8, detail[0..@min(detail.len, 4096)]);
        r.clearFailure();
        r.failure = .{ .path = owned_path, .driver = owned_driver, .reason = reason, .detail = owned_detail };
    }

    /// Record an LFS file left as a pointer.
    pub fn missing(r: *Report, path: []const u8, pointer: lfs.Pointer, declined: bool) Allocator.Error!void {
        const owned = try r.gpa.dupe(u8, path);
        errdefer r.gpa.free(owned);
        var kept = pointer;
        // A pointer with extensions is refused before it gets here; the
        // names would otherwise borrow bytes the report does not own.
        kept.extension_count = 0;
        try r.lfs_missing.append(r.gpa, .{ .path = owned, .pointer = kept, .declined = declined });
    }
};

/// A command line with `%f` replaced by the path quoted for `sh` and `%%`
/// by `%`, which is git's expansion; a `%` before anything else stays as it
/// is. The result is allocated from `a`.
pub fn expandCommand(a: Allocator, line: []const u8, path: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (c != '%' or i + 1 >= line.len) {
            try out.append(a, c);
            continue;
        }
        switch (line[i + 1]) {
            '%' => {
                try out.append(a, '%');
                i += 1;
            },
            'f' => {
                try appendShellQuoted(a, &out, path);
                i += 1;
            },
            else => try out.append(a, '%'),
        }
    }
    return out.toOwnedSlice(a);
}

/// git's `sq_quote_buf`: single quotes around the whole, and a `'` or a `!`
/// inside closed out, escaped, and reopened.
fn appendShellQuoted(a: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    try out.append(a, '\'');
    for (text) |c| {
        if (c == '\'' or c == '!') {
            try out.appendSlice(a, "'\\");
            try out.append(a, c);
            try out.append(a, '\'');
        } else try out.append(a, c);
    }
    try out.append(a, '\'');
}

/// What running a command line gave.
pub const Ran = union(enum) {
    /// Its standard output, allocated from the allocator passed in.
    output: []u8,
    /// It exited with a status other than zero or was killed; its standard
    /// error is here, allocated from the same allocator.
    failed: []u8,
    /// It could not be started.
    not_started,
};

/// Run one `filter.<driver>.clean` or `.smudge` over `input`, from `cwd`,
/// with the repository's own variables removed from the environment so the
/// program finds the repository from where it stands.
pub fn runCommand(
    programs: program.Programs,
    a: Allocator,
    io: Io,
    cwd: Io.Dir,
    line: []const u8,
    path: []const u8,
    input: []const u8,
) (Allocator.Error || Io.Cancelable)!Ran {
    const expanded = try expandCommand(a, line, path);
    var outcome = program.run(programs, a, io, .{
        .argv = &.{expanded},
        .shell = true,
        .cwd = .{ .dir = cwd },
        .unset = &program.repository_variables,
        .stderr = .capture,
    }, input, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return .not_started,
    };
    if (outcome.succeeded()) {
        a.free(outcome.stderr);
        return .{ .output = outcome.stdout };
    }
    a.free(outcome.stdout);
    return .{ .failed = outcome.stderr };
}

/// What a process filter said it can do, and what it was asked to.
pub const Capabilities = struct {
    clean: bool = false,
    smudge: bool = false,
    delay: bool = false,
};

/// Errors from the long-running process protocol.
pub const ProtocolError = error{
    /// The filter did not answer the welcome with `git-filter-server`,
    /// `version=2` and a flush. git gives up on the filter and passes the
    /// file over.
    FilterHandshake,
    /// The filter claimed a capability that was not offered. git stops the
    /// whole command on this.
    FilterCapability,
    /// The filter wrote something that is not a pkt-line. git stops the
    /// whole command on this too.
    FilterReply,
    /// The filter went away: the pipe closed before a reply was whole, or
    /// would not take a request.
    FilterGone,
    /// A path longer than a pkt-line can carry.
    FilterPathTooLong,
} || Allocator.Error;

/// The client side of git's long-running filter protocol, version 2, over
/// any reader and writer. The reader's buffer holds `pktline.max_line`
/// bytes.
pub const Protocol = struct {
    /// What the filter writes.
    in: *Io.Reader,
    /// What the filter reads.
    out: *Io.Writer,
    /// What the handshake settled on.
    capabilities: Capabilities = .{},

    /// One file's request.
    pub const Request = struct {
        command: Command,
        path: []const u8,
        /// Content, in full.
        content: []const u8,
        /// The tree a checkout is writing, in hexadecimal, for `treeish=`.
        treeish: ?[]const u8 = null,
        /// The blob being written, in hexadecimal, for `blob=`.
        blob: ?[]const u8 = null,
        /// Offer the filter the chance to hand the file over later.
        can_delay: bool = false,
    };

    /// The two things a filter is asked to do.
    pub const Command = enum { clean, smudge };

    /// A filter's answer to one request.
    pub const Reply = union(enum) {
        /// The filtered content, allocated from the allocator passed in.
        content: []u8,
        /// The filter will hand the file over when asked for what is
        /// available.
        delayed,
        /// `status=error`: this file failed and the filter carries on.
        failed,
        /// `status=abort`: the filter will do nothing more of this command.
        aborted,
        /// Any other status, or none: the protocol has broken down, and git
        /// stops the filter.
        broken,
    };

    /// The welcome, the version and the capabilities, as git sends them:
    /// `clean`, `smudge` and `delay` all offered.
    pub fn handshake(p: *Protocol) ProtocolError!void {
        try p.line("git-filter-client\n");
        try p.line("version=2\n");
        try p.end();
        const welcome = (try p.readLine()) orelse return error.FilterHandshake;
        if (!std.mem.eql(u8, welcome, "git-filter-server")) return error.FilterHandshake;
        const version_line = (try p.readLine()) orelse return error.FilterHandshake;
        if (!std.mem.startsWith(u8, version_line, "version=")) return error.FilterHandshake;
        const version_text = std.mem.trimStart(u8, version_line["version=".len..], " \t\n\r\x0b\x0c");
        const version = std.fmt.parseInt(i32, version_text, 10) catch return error.FilterHandshake;
        if (try p.readLine() != null) return error.FilterHandshake;
        if (version != 2) return error.FilterHandshake;

        try p.line("capability=clean\n");
        try p.line("capability=smudge\n");
        try p.line("capability=delay\n");
        try p.end();
        var caps: Capabilities = .{};
        while (try p.readLine()) |text| {
            if (!std.mem.startsWith(u8, text, "capability=")) continue;
            const name = text["capability=".len..];
            if (std.mem.eql(u8, name, "clean")) {
                caps.clean = true;
            } else if (std.mem.eql(u8, name, "smudge")) {
                caps.smudge = true;
            } else if (std.mem.eql(u8, name, "delay")) {
                caps.delay = true;
            } else return error.FilterCapability;
        }
        p.capabilities = caps;
    }

    /// Send one file and read the answer. The content of a reply is
    /// allocated from `a`.
    pub fn request(p: *Protocol, a: Allocator, req: Request) ProtocolError!Reply {
        if (req.path.len > pktline.max_data - "pathname=\n".len) return error.FilterPathTooLong;
        try p.print("command={s}\n", .{@tagName(req.command)});
        try p.print("pathname={s}\n", .{req.path});
        if (req.treeish) |t| try p.print("treeish={s}\n", .{t});
        if (req.blob) |b| try p.print("blob={s}\n", .{b});
        if (req.can_delay) try p.line("can-delay=1\n");
        try p.flushOnly();
        var rest = req.content;
        while (rest.len > 0) {
            const n = @min(rest.len, pktline.max_data);
            pktline.write(p.out, rest[0..n]) catch return error.FilterGone;
            rest = rest[n..];
        }
        try p.end();

        var status: Status = .none;
        try p.readStatus(&status);
        if (req.can_delay and status == .delayed) return .delayed;
        if (status != .success) return statusReply(status);

        var content: std.ArrayList(u8) = .empty;
        errdefer content.deinit(a);
        while (try p.readPacket()) |data| try content.appendSlice(a, data);
        try p.readStatus(&status);
        if (status != .success) {
            content.deinit(a);
            return statusReply(status);
        }
        return .{ .content = try content.toOwnedSlice(a) };
    }

    /// What `listAvailable` found.
    pub const Available = struct {
        /// Paths, allocated from the allocator passed in.
        paths: [][]u8,
        /// Whether the status after them was success.
        ok: bool,
    };

    /// `command=list_available_blobs`: the paths the filter delayed and can
    /// now hand over. An empty list says it has no more.
    pub fn listAvailable(p: *Protocol, a: Allocator) ProtocolError!Available {
        try p.line("command=list_available_blobs\n");
        try p.end();
        var paths: std.ArrayList([]u8) = .empty;
        errdefer {
            for (paths.items) |path| a.free(path);
            paths.deinit(a);
        }
        while (try p.readLine()) |text| {
            if (std.mem.startsWith(u8, text, "pathname=")) {
                try paths.append(a, try a.dupe(u8, text["pathname=".len..]));
            }
        }
        var status: Status = .none;
        try p.readStatus(&status);
        return .{ .paths = try paths.toOwnedSlice(a), .ok = status == .success };
    }

    const Status = enum { none, success, delayed, @"error", abort, other };

    fn statusReply(status: Status) Reply {
        return switch (status) {
            .@"error" => .failed,
            .abort => .aborted,
            else => .broken,
        };
    }

    /// A key=value list up to its end, keeping the last `status=`; a list
    /// with none leaves `status` as it was, which is how a filter says the
    /// status before the content still holds.
    fn readStatus(p: *Protocol, status: *Status) ProtocolError!void {
        while (try p.readLine()) |text| {
            if (!std.mem.startsWith(u8, text, "status=")) continue;
            const value = text["status=".len..];
            status.* = if (std.mem.eql(u8, value, "success"))
                .success
            else if (std.mem.eql(u8, value, "delayed"))
                .delayed
            else if (std.mem.eql(u8, value, "error"))
                .@"error"
            else if (std.mem.eql(u8, value, "abort"))
                .abort
            else
                .other;
        }
    }

    /// One packet's data, or null at the end of a list. git ends a list at
    /// a flush, a delimiter, a response end, and a packet with no data, and
    /// so does this.
    fn readPacket(p: *Protocol) ProtocolError!?[]const u8 {
        const packet = pktline.read(p.in) catch |err| switch (err) {
            error.BadPacket => return error.FilterReply,
            error.EndOfStream, error.ReadFailed => return error.FilterGone,
        };
        return switch (packet) {
            .data => |data| if (data.len == 0) null else data,
            else => null,
        };
    }

    /// A packet's data with one trailing newline removed, or null at the
    /// end of a list; a line that is empty once its newline is gone ends
    /// the list too, as it does in git.
    fn readLine(p: *Protocol) ProtocolError!?[]const u8 {
        const data = (try p.readPacket()) orelse return null;
        const text = if (data[data.len - 1] == '\n') data[0 .. data.len - 1] else data;
        return if (text.len == 0) null else text;
    }

    fn line(p: *Protocol, text: []const u8) ProtocolError!void {
        pktline.write(p.out, text) catch return error.FilterGone;
    }

    fn print(p: *Protocol, comptime fmt: []const u8, args: anytype) ProtocolError!void {
        pktline.print(p.out, fmt, args) catch return error.FilterGone;
    }

    fn flushOnly(p: *Protocol) ProtocolError!void {
        pktline.flush(p.out) catch return error.FilterGone;
    }

    /// A flush packet, and everything written so far sent.
    fn end(p: *Protocol) ProtocolError!void {
        try p.flushOnly();
        p.out.flush() catch return error.FilterGone;
    }
};

/// A running `filter.<driver>.process`, with its pipes and what it said it
/// can do.
pub const Process = struct {
    gpa: Allocator,
    /// The command line it was started from, which is what names it: two
    /// drivers with the same `process` share one.
    command: []u8,
    running: program.Running,
    in_buffer: []u8,
    out_buffer: []u8,
    reader: Io.File.Reader,
    writer: Io.File.Writer,
    protocol: Protocol,

    /// Errors from starting one.
    pub const StartError = error{
        /// The program would not start, or its handshake failed.
        FilterNotStarted,
        FilterCapability,
        FilterReply,
    } || Allocator.Error || Io.Cancelable;

    /// Start `command` from `cwd` and shake hands. Its diagnostics are not
    /// kept: a long-running program's standard error is not something a
    /// caller can be made to drain.
    pub fn start(programs: program.Programs, gpa: Allocator, io: Io, command: []const u8, cwd: Io.Dir) StartError!*Process {
        const p = try gpa.create(Process);
        errdefer gpa.destroy(p);
        p.gpa = gpa;
        p.command = try gpa.dupe(u8, command);
        errdefer gpa.free(p.command);
        p.in_buffer = try gpa.alloc(u8, pktline.max_line);
        errdefer gpa.free(p.in_buffer);
        p.out_buffer = try gpa.alloc(u8, pktline.max_line);
        errdefer gpa.free(p.out_buffer);

        p.running = program.start(programs, gpa, io, .{
            .argv = &.{command},
            .shell = true,
            .cwd = .{ .dir = cwd },
            .unset = &program.repository_variables,
            .stderr = .ignore,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => return error.FilterNotStarted,
        };
        errdefer p.running.deinit(io);
        p.reader = p.running.child.stdout.?.readerStreaming(io, p.in_buffer);
        p.writer = p.running.child.stdin.?.writerStreaming(io, p.out_buffer);
        p.protocol = .{ .in = &p.reader.interface, .out = &p.writer.interface };
        p.protocol.handshake() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.FilterCapability => return error.FilterCapability,
            error.FilterReply => return error.FilterReply,
            error.FilterHandshake, error.FilterGone, error.FilterPathTooLong => return error.FilterNotStarted,
        };
        return p;
    }

    /// Whether the last read or write was stopped by cancelation rather
    /// than by the program.
    pub fn canceled(p: *const Process) bool {
        if (p.reader.err) |err| if (err == error.Canceled) return true;
        if (p.writer.err) |err| if (err == error.Canceled) return true;
        return false;
    }

    /// How a process is stopped.
    pub const Stop = enum {
        /// Close its input, which tells it to finish, and wait for it.
        finish,
        /// End it now: it broke the protocol.
        kill,
    };

    /// Stop it and release everything.
    pub fn stop(p: *Process, io: Io, how: Stop) void {
        if (how == .finish) _ = p.running.wait(io) catch {};
        p.running.deinit(io);
        const gpa = p.gpa;
        gpa.free(p.command);
        gpa.free(p.in_buffer);
        gpa.free(p.out_buffer);
        gpa.destroy(p);
    }
};

const testing = std.testing;

test "the path in a command line is quoted for sh, and %% is a percent sign" {
    const a = testing.allocator;
    const cases = [_][3][]const u8{
        .{ "tr a-z A-Z", "a.txt", "tr a-z A-Z" },
        .{ "f --clean %f", "a b.txt", "f --clean 'a b.txt'" },
        .{ "f %f", "it's!", "f 'it'\\''s'\\!''" },
        .{ "printf '%s %% %d' %f", "x", "printf '%s % %d' 'x'" },
        .{ "tail%", "x", "tail%" },
    };
    for (cases) |case| {
        const got = try expandCommand(a, case[0], case[1]);
        defer a.free(got);
        try testing.expectEqualStrings(case[2], got);
    }
}

test "git-lfs's own commands are recognised and a person's own are not" {
    try testing.expect(isGitLfsCommand("git-lfs clean -- %f", "clean"));
    try testing.expect(isGitLfsCommand("git-lfs smudge --skip -- %f", "smudge"));
    try testing.expect(isGitLfsCommand("git-lfs filter-process", "filter-process"));
    try testing.expect(isGitLfsCommand("/opt/bin/git-lfs filter-process --skip", "filter-process"));
    try testing.expect(isGitLfsCommand("git lfs clean -- %f", "clean"));
    try testing.expect(!isGitLfsCommand("git-lfs smudge -- %f", "clean"));
    try testing.expect(!isGitLfsCommand("git-lfs clean -- %f | tee log", "clean"));
    try testing.expect(!isGitLfsCommand("my-lfs clean %f", "clean"));
    const skipping: Driver = .{ .name = "lfs", .smudge = "git-lfs smudge --skip -- %f", .process = "git-lfs filter-process --skip" };
    try testing.expect(skipping.isGitLfs());
    try testing.expect(skipping.skipsSmudge());
}

test "drivers are read from the configuration, the last value winning" {
    const gpa = testing.allocator;
    var config = try config_mod.Config.parseText(gpa,
        \\[filter "a"]
        \\    clean = "sed -e \"s/x/y/\""
        \\    smudge = cat
        \\    smudge = cat -u
        \\    required
        \\[filter "lfs"]
        \\    process = git-lfs filter-process
        \\    clean =
        \\[filter "mine"]
        \\    process = my-filter
        \\
    , .local);
    defer config.deinit();
    var drivers = try Drivers.fromConfig(gpa, &config);
    defer drivers.deinit();
    const a = drivers.find("a").?;
    try testing.expectEqualStrings("sed -e \"s/x/y/\"", a.clean.?);
    try testing.expectEqualStrings("cat -u", a.smudge.?);
    try testing.expect(a.required);
    try testing.expect(drivers.find("lfs").?.clean == null);
    try testing.expectEqual(Drivers.Resolved.none, drivers.resolve("absent"));
    // Without an LFS of relic's own, `lfs` is an ordinary driver.
    try testing.expect(drivers.resolve("lfs") == .program);
}

/// A scripted filter: its replies, and the requests written to it.
const Scripted = struct {
    buffer: [pktline.max_line]u8 = undefined,
    fixed: Io.Reader,
    limited: Io.Reader.Limited = undefined,
    sent: Io.Writer.Allocating,
    protocol: Protocol = undefined,

    fn init(s: *Scripted, replies: []const u8) void {
        s.fixed = .fixed(replies);
        s.limited = s.fixed.limited(.unlimited, &s.buffer);
        s.sent = .init(testing.allocator);
        s.protocol = .{ .in = &s.limited.interface, .out = &s.sent.writer };
    }

    fn deinit(s: *Scripted) void {
        s.sent.deinit();
    }
};

const handshake_reply = "0016git-filter-server\n000eversion=2\n0000" ++
    "0015capability=clean\n0016capability=smudge\n0000";

test "a handshake offers what git offers and keeps what the filter accepts" {
    var s: Scripted = undefined;
    s.init(handshake_reply);
    defer s.deinit();
    try s.protocol.handshake();
    try testing.expectEqualStrings("0016git-filter-client\n000eversion=2\n0000" ++
        "0015capability=clean\n0016capability=smudge\n0015capability=delay\n0000", s.sent.written());
    try testing.expect(s.protocol.capabilities.clean and s.protocol.capabilities.smudge);
    try testing.expect(!s.protocol.capabilities.delay);
}

test "a request carries the content in packets and reads the content back" {
    var s: Scripted = undefined;
    s.init("0013status=success\n0000" ++ "0009HELLO0000" ++ "0000");
    defer s.deinit();
    const reply = try s.protocol.request(testing.allocator, .{ .command = .clean, .path = "a.txt", .content = "hello" });
    defer testing.allocator.free(reply.content);
    try testing.expectEqualStrings("HELLO", reply.content);
    try testing.expectEqualStrings("0012command=clean\n0013pathname=a.txt\n0000" ++ "0009hello0000", s.sent.written());
}

test "a status after the content overrides the one before it" {
    var s: Scripted = undefined;
    s.init("0013status=success\n0000" ++ "0009HELLO0000" ++ "0011status=abort\n0000");
    defer s.deinit();
    const reply = try s.protocol.request(testing.allocator, .{ .command = .smudge, .path = "a", .content = "" });
    try testing.expectEqual(Protocol.Reply.aborted, reply);
}

test "a delayed file is a reply of its own only where delay was offered" {
    var s: Scripted = undefined;
    s.init("0013status=delayed\n0000" ++ "0013status=delayed\n0000");
    defer s.deinit();
    try testing.expectEqual(Protocol.Reply.delayed, try s.protocol.request(testing.allocator, .{
        .command = .smudge,
        .path = "a",
        .content = "x",
        .can_delay = true,
    }));
    try testing.expectEqual(Protocol.Reply.broken, try s.protocol.request(testing.allocator, .{
        .command = .smudge,
        .path = "a",
        .content = "x",
    }));
}

test "a malformed or truncated reply is a named error" {
    const cases = [_]struct { []const u8, ProtocolError }{
        .{ "zzzz", error.FilterReply },
        .{ "0013status=success\n", error.FilterGone },
        .{ "0013status=success\n00000009HEL", error.FilterGone },
        .{ "", error.FilterGone },
    };
    for (cases) |case| {
        var s: Scripted = undefined;
        s.init(case[0]);
        defer s.deinit();
        try testing.expectError(case[1], s.protocol.request(testing.allocator, .{ .command = .clean, .path = "a", .content = "x" }));
    }
    const handshakes = [_]struct { []const u8, ProtocolError }{
        .{ "0015git-filter-hello\n000eversion=2\n0000", error.FilterHandshake },
        .{ "0016git-filter-server\n000eversion=3\n0000", error.FilterHandshake },
        .{ "0016git-filter-server\n000eversion=2\n0000" ++ "0015capability=fetch\n0000", error.FilterCapability },
    };
    for (handshakes) |case| {
        var s: Scripted = undefined;
        s.init(case[0]);
        defer s.deinit();
        try testing.expectError(case[1], s.protocol.handshake());
    }
}

test "fuzz: any reply is an answer or a named error" {
    try testing.fuzz({}, fuzzProtocol, .{});
}

fn fuzzProtocol(_: void, smith: *testing.Smith) anyerror!void {
    var scratch: [4096]u8 = undefined;
    const n = smith.slice(&scratch);
    var s: Scripted = undefined;
    s.init(scratch[0..n]);
    defer s.deinit();
    s.protocol.handshake() catch |err| switch (err) {
        error.FilterHandshake, error.FilterCapability, error.FilterReply, error.FilterGone => {},
        else => return err,
    };
    var round: usize = 0;
    while (round < 8) : (round += 1) {
        const reply = s.protocol.request(testing.allocator, .{
            .command = .smudge,
            .path = "a",
            .content = "x",
            .can_delay = round % 2 == 0,
        }) catch |err| switch (err) {
            error.FilterReply, error.FilterGone => break,
            else => return err,
        };
        if (reply == .content) testing.allocator.free(reply.content);
        const available = s.protocol.listAvailable(testing.allocator) catch |err| switch (err) {
            error.FilterReply, error.FilterGone => break,
            else => return err,
        };
        for (available.paths) |path| testing.allocator.free(path);
        testing.allocator.free(available.paths);
    }
}
