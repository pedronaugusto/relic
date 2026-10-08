//! Native LFS filtering. Checkout knows only the native filter protocol;
//! this provider owns LFS commands, pointers, stores and batched fetches.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const assert = std.debug.assert;
const config = @import("../config/config.zig");
const native = @import("../checkout/native.zig");
const filter = @import("../checkout/filter.zig");
const repo = @import("../repo/repo.zig");
const lfs = @import("lfs.zig");
const testing = std.testing;
pub const Error = native.Error || repo.Repository.LoadFiltersError;
pub const Options = struct { fetch: ?lfs.Fetcher = null, skip_smudge: bool = false };

/// Load native LFS and configured program filters for one operation. The
/// fetcher and repository directories remain borrowed until driver deinit.
pub fn load(gpa: Allocator, io: Io, repository: *repo.Repository, options: Options) Error!filter.Drivers {
    const text = try repository.lfsconfigText(io);
    defer if (text) |bytes| repository.allocator().free(bytes);
    return filter.Drivers.load(gpa, io, repository.configuration(), .{ .common = repository.commonDirectory(), .work = repository.workDirectory() }, .{
        .native_provider = provider(&options),
        .skip_smudge = options.skip_smudge,
        .config_text = text,
    });
}

/// Context is borrowed only during loading. The returned driver copies it.
pub fn provider(options: *const Options) native.Provider {
    return .{ .context = options, .load_fn = loadDriver };
}

fn loadDriver(context: ?*const anyopaque, gpa: Allocator, io: Io, configuration: *const config.Config, options: native.LoadOptions) native.Error!native.Driver {
    const with: *const Options = @ptrCast(@alignCast(context.?));
    const backend = try gpa.create(Backend);
    errdefer gpa.destroy(backend);
    var commands: native.Commands = .{};
    commands.clean = configuration.get("filter.lfs.clean");
    commands.smudge = configuration.get("filter.lfs.smudge");
    commands.process = configuration.get("filter.lfs.process");
    backend.* = .{
        .gpa = gpa,
        .fetch = with.fetch,
        .lfs = try lfs.Lfs.load(gpa, io, configuration, .{
            .common_dir = options.common_dir,
            .work_dir = options.work_dir,
            .skip_smudge = options.skip_smudge or with.skip_smudge or (isGitLfs(commands) and skipsSmudge(commands)),
            .lfsconfig = options.config_text,
        }),
    };
    return .{ .name = "lfs", .context = backend, .vtable = &Backend.vtable };
}

const Backend = struct {
    gpa: Allocator,
    lfs: lfs.Lfs,
    fetch: ?lfs.Fetcher,
    const vtable: native.Driver.VTable = .{ .accepts = accepts, .open = open, .retarget = retarget, .deinit = deinit };
    fn accepts(_: *const anyopaque, commands: native.Commands) bool {
        return isGitLfs(commands);
    }
    fn open(context: *anyopaque, gpa: Allocator, _: Io, options: native.SessionOptions) native.Error!native.Session {
        const session = try gpa.create(Session);
        session.* = .{ .gpa = gpa, .backend = @ptrCast(@alignCast(context)), .options = options, .arena = .init(gpa) };
        return .{ .context = session, .vtable = &Session.vtable };
    }
    fn retarget(context: *anyopaque, dir: Io.Dir) void {
        const b: *Backend = @ptrCast(@alignCast(context));
        b.lfs.store = .{ .base = dir, .root = "lfs" };
    }
    fn deinit(context: *anyopaque, _: Io) void {
        const b: *Backend = @ptrCast(@alignCast(context));
        const gpa = b.gpa;
        b.lfs.deinit();
        gpa.destroy(b);
    }
};

const Session = struct {
    gpa: Allocator,
    backend: *Backend,
    options: native.SessionOptions,
    arena: std.heap.ArenaAllocator,
    deferred: std.ArrayList(Deferred) = .empty,
    fetched: bool = false,
    next_deferred: usize = 0,
    lfs_pointers: u32 = 0,
    const Deferred = struct { path: []const u8, pointer: lfs.Pointer, pointer_bytes: []const u8 };
    const vtable: native.Session.VTable = .{ .clean = clean, .clean_file = cleanFile, .smudge = smudge, .canonical = canonical, .next_ready = nextReady, .fallbacks = fallbacks, .deinit = deinit };
    fn get(context: *anyopaque) *Session {
        const s: *Session = @ptrCast(@alignCast(context));
        return s;
    }
    fn clean(context: *anyopaque, a: Allocator, io: Io, input: native.CleanInput) native.Error![]const u8 {
        return get(context).lfsClean(a, io, input.bytes, input.storing);
    }
    fn cleanFile(context: *anyopaque, a: Allocator, io: Io, input: native.FileInput) native.Error![]const u8 {
        return get(context).lfsCleanFile(a, io, input.path, input.storing);
    }
    fn smudge(context: *anyopaque, a: Allocator, io: Io, input: native.SmudgeInput) native.Error!native.Content {
        return get(context).lfsSmudge(a, io, input.path, input.bytes, input.can_delay);
    }
    fn canonical(_: *anyopaque, a: Allocator, bytes: []const u8) native.Error!?[]const u8 {
        const pointer = lfs.Pointer.decode(bytes) catch return null;
        if (pointer.extension_count != 0) return error.NativeFilterExtensionUnsupported;
        return try encodePointer(a, &pointer);
    }
    fn nextReady(context: *anyopaque, _: Allocator, io: Io) native.Error!?native.Ready {
        return get(context).nextDeferred(io);
    }
    fn fallbacks(context: *const anyopaque) u32 {
        const s: *const Session = @ptrCast(@alignCast(context));
        return s.lfs_pointers;
    }
    fn deinit(context: *anyopaque, _: Io) void {
        const s: *Session = @ptrCast(@alignCast(context));
        const gpa = s.gpa;
        s.deferred.deinit(gpa);
        s.arena.deinit();
        gpa.destroy(s);
    }
    /// A file already a pointer is stored as it is, which is git-lfs's rule:
    /// cleaning twice changes nothing.
    fn lfsClean(s: *Session, a: Allocator, io: Io, bytes: []const u8, storing: native.Storing) native.Error![]const u8 {
        if (lfs.Pointer.decode(bytes)) |_| return bytes else |_| {}
        const l = &s.backend.lfs;
        if (l.extensions) return error.NativeFilterExtensionUnsupported;
        var source: Io.Reader = .fixed(bytes);
        const pointer = switch (storing) {
            .store => l.store.install(io, &source, null) catch |err| switch (err) {
                error.LfsObjectMismatch => return error.NativeFilterObjectMismatch,
                else => |e| return e,
            },
            // unreachable: a fixed reader over bytes in memory does not fail to read
            .hash_only => lfs.hashOnly(&source) catch unreachable,
        };
        return encodePointer(a, &pointer);
    }

    fn lfsCleanFile(s: *Session, a: Allocator, io: Io, path: []const u8, storing: native.Storing) native.Error![]const u8 {
        const l = &s.backend.lfs;
        if (l.extensions) return error.NativeFilterExtensionUnsupported;
        const file = try s.options.wt.openFile(io, path, .{});
        defer file.close(io);
        var head: [lfs.pointer_size_cutoff]u8 = undefined;
        const n = try file.readPositionalAll(io, &head, 0);
        if (lfs.Pointer.decode(head[0..n])) |_| {
            if (n < head.len) return a.dupe(u8, head[0..n]);
            return s.options.wt.readFileAlloc(io, path, a, .limited(1 << 31));
        } else |_| {}

        var buf: [64 * 1024]u8 = undefined;
        var reader = file.reader(io, &buf);
        const pointer = switch (storing) {
            .store => l.store.install(io, &reader.interface, null) catch |err| switch (err) {
                error.ReadFailed => return reader.err.?,
                error.LfsObjectMismatch => return error.NativeFilterObjectMismatch,
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
    fn lfsSmudge(s: *Session, a: Allocator, io: Io, path: []const u8, bytes: []const u8, can_delay: bool) native.Error!native.Content {
        const pointer = lfs.Pointer.decode(bytes) catch return .{ .bytes = bytes };
        if (pointer.size == 0) return .{ .bytes = "" };
        if (pointer.extension_count != 0) return error.NativeFilterExtensionUnsupported;
        const l = &s.backend.lfs;
        if (try l.store.open(io, &pointer)) |file| return .{ .file = file };

        const delayed = s.backend.fetch != null and can_delay and l.settings.fetchAllowed(path);
        const content_allocator = if (delayed) s.arena.allocator() else a;
        const canonical_bytes = try encodePointer(content_allocator, &pointer);
        errdefer content_allocator.free(canonical_bytes);
        if (!l.settings.fetchAllowed(path)) {
            if (s.options.observer) |r| try r.missing(path, .{ .id = &pointer.oid, .size = pointer.size }, true);
            s.lfs_pointers += 1;
            return .{ .bytes = canonical_bytes };
        }
        if (delayed) {
            const arena = s.arena.allocator();
            try s.deferred.append(s.gpa, .{
                .path = try arena.dupe(u8, path),
                .pointer = pointer,
                .pointer_bytes = canonical_bytes,
            });
            return .delayed;
        }
        if (s.options.observer) |r| try r.missing(path, .{ .id = &pointer.oid, .size = pointer.size }, false);
        s.lfs_pointers += 1;
        return .{ .bytes = canonical_bytes };
    }

    fn nextDeferred(s: *Session, io: Io) native.Error!?native.Ready {
        if (s.deferred.items.len == 0) return null;
        const l = &s.backend.lfs;
        if (!s.fetched) {
            s.fetched = true;
            const wanted = try s.arena.allocator().alloc(lfs.Wanted, s.deferred.items.len);
            for (s.deferred.items, wanted) |d, *w| w.* = .{ .path = d.path, .pointer = d.pointer };
            s.backend.fetch.?.fetch(io, &l.store, &l.settings, wanted) catch |err| switch (err) {
                error.LfsFetchFailed => return error.NativeFilterFetchFailed,
                else => |e| return e,
            };
        }
        assert(s.next_deferred <= s.deferred.items.len);
        if (s.next_deferred == s.deferred.items.len) return null;
        const d = s.deferred.items[s.next_deferred];
        s.next_deferred += 1;
        if (try l.store.open(io, &d.pointer)) |file| return .{ .path = d.path, .content = .{ .file = file } };
        if (s.options.observer) |r| try r.missing(d.path, .{ .id = &d.pointer.oid, .size = d.pointer.size }, false);
        s.lfs_pointers += 1;
        return .{ .path = d.path, .content = .{ .bytes = d.pointer_bytes } };
    }
};

/// Whether every command this driver names is one git-lfs itself writes
/// into a configuration: `git-lfs clean -- %f`, `git-lfs smudge -- %f`,
/// `git-lfs filter-process`, or their `--skip` forms.
pub fn isGitLfs(d: native.Commands) bool {
    if (d.clean) |line| if (!isGitLfsCommand(line, "clean")) return false;
    if (d.smudge) |line| if (!isGitLfsCommand(line, "smudge")) return false;
    if (d.process) |line| if (!isGitLfsCommand(line, "filter-process")) return false;
    return true;
}

/// Whether the smudge git-lfs was configured with is its `--skip` form,
/// which leaves every pointer as it is.
pub fn skipsSmudge(d: native.Commands) bool {
    for ([_]?[]const u8{ d.smudge, d.process }) |maybe| {
        const line = maybe orelse continue;
        var words = std.mem.tokenizeAny(u8, line, " \t");
        while (words.next()) |word| {
            if (std.mem.eql(u8, word, "--skip")) return true;
        }
    }
    return false;
}

/// Whether `line` is git-lfs run with `subcommand` and nothing else but the
/// arguments git-lfs itself puts there.
pub fn isGitLfsCommand(line: []const u8, subcommand: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, line, " \t");
    const first = words.next() orelse return false;
    const base = std.Io.Dir.path.basenamePosix(first);
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

test "git-lfs's own commands are recognised and a person's own are not" {
    try testing.expect(isGitLfsCommand("git-lfs clean -- %f", "clean"));
    try testing.expect(isGitLfsCommand("git-lfs smudge --skip -- %f", "smudge"));
    try testing.expect(isGitLfsCommand("git-lfs filter-process", "filter-process"));
    try testing.expect(isGitLfsCommand("/opt/bin/git-lfs filter-process --skip", "filter-process"));
    try testing.expect(isGitLfsCommand("git lfs clean -- %f", "clean"));
    try testing.expect(!isGitLfsCommand("git-lfs smudge -- %f", "clean"));
    try testing.expect(!isGitLfsCommand("git-lfs clean -- %f | tee log", "clean"));
    try testing.expect(!isGitLfsCommand("my-lfs clean %f", "clean"));
    const skipping: native.Commands = .{ .smudge = "git-lfs smudge --skip -- %f", .process = "git-lfs filter-process --skip" };
    try testing.expect(isGitLfs(skipping));
    try testing.expect(skipsSmudge(skipping));
}

/// Borrow the settings of a collection loaded by this provider.
pub fn settings(drivers: *const filter.Drivers) *const lfs.Settings {
    const driver = drivers.native_driver.?;
    assert(driver.vtable == &Backend.vtable);
    const b: *const Backend = @ptrCast(@alignCast(driver.context));
    return &b.lfs.settings;
}

test "phase2 native LFS selection owns settings, preserves custom commands and hash-only storage" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var cfg = try config.Config.parseText(gpa, "[filter \"lfs\"]\nprocess = git-lfs filter-process\n", .local);
    defer cfg.deinit();
    var ordinary = try filter.Drivers.load(gpa, io, &cfg, .{ .common = tmp.dir, .work = tmp.dir }, .{});
    defer ordinary.deinit(io);
    try testing.expect(ordinary.resolve("lfs") == .program);
    var options: Options = .{};
    var drivers = try filter.Drivers.load(gpa, io, &cfg, .{ .common = tmp.dir, .work = tmp.dir }, .{ .native_provider = provider(&options) });
    defer drivers.deinit(io);
    options.skip_smudge = true;
    try testing.expect(!settings(&drivers).skip_smudge);
    try testing.expect(drivers.resolve("lfs") == .native);
    const implementation = drivers.native_driver.?;
    try testing.expect(!implementation.accepts(.{ .clean = "my-lfs clean %f" }));
    const session = try implementation.open(gpa, io, .{ .wt = tmp.dir });
    defer session.deinit(io);
    const pointer_bytes = try session.clean(gpa, io, .{ .bytes = "large content", .storing = .hash_only });
    defer gpa.free(pointer_bytes);
    const pointer = try lfs.Pointer.decode(pointer_bytes);
    const store: lfs.Store = .{ .base = tmp.dir, .root = "lfs" };
    try testing.expect(!try store.contains(io, &pointer));
    const installed_bytes = try session.clean(gpa, io, .{ .bytes = "large content" });
    defer gpa.free(installed_bytes);
    try testing.expectEqualStrings(pointer_bytes, installed_bytes);
    try testing.expect(try store.contains(io, &pointer));
    const content = try session.smudge(gpa, io, .{ .path = "large.bin", .bytes = pointer_bytes });
    try testing.expect(content == .file);
    defer content.file.close(io);
    var buffer: [64]u8 = undefined;
    const n = try content.file.readPositionalAll(io, &buffer, 0);
    try testing.expectEqualStrings("large content", buffer[0..n]);
}

test "phase2 native LFS batches delayed files once and isolates session state" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var cfg = try config.Config.parseText(gpa, "", .local);
    defer cfg.deinit();
    const Fetch = struct {
        calls: usize = 0,
        fn fetch(io_: Io, context: *anyopaque, store: *const lfs.Store, _: *const lfs.Settings, wanted: []const lfs.Wanted) lfs.FetchError!void {
            const f: *@This() = @ptrCast(@alignCast(context));
            f.calls += 1;
            if (wanted.len != 2) return error.LfsFetchFailed;
            for (wanted) |w| {
                var source: Io.Reader = .fixed("payload");
                _ = store.install(io_, &source, &w.pointer) catch return error.LfsFetchFailed;
            }
        }
    };
    var fetch: Fetch = .{};
    const options: Options = .{ .fetch = .{ .context = &fetch, .fetchFn = Fetch.fetch } };
    var drivers = try filter.Drivers.load(gpa, io, &cfg, .{ .common = tmp.dir, .work = tmp.dir }, .{ .native_provider = provider(&options) });
    defer drivers.deinit(io);
    const session = try drivers.native_driver.?.open(gpa, io, .{ .wt = tmp.dir });
    defer session.deinit(io);
    var source: Io.Reader = .fixed("payload");
    const pointer = try lfs.hashOnly(&source);
    var buffer: [lfs.Pointer.max_encoded_len]u8 = undefined;
    const bytes = pointer.encodeBuf(&buffer);
    try testing.expect((try session.smudge(gpa, io, .{ .path = "one", .bytes = bytes, .can_delay = true })) == .delayed);
    try testing.expect((try session.smudge(gpa, io, .{ .path = "two", .bytes = bytes, .can_delay = true })) == .delayed);
    for ([_][]const u8{ "one", "two" }) |path| {
        const ready = (try session.nextReady(gpa, io)).?;
        try testing.expectEqualStrings(path, ready.path);
        try testing.expect(ready.content == .file);
        ready.content.file.close(io);
    }
    try testing.expect((try session.nextReady(gpa, io)) == null);
    try testing.expectEqual(@as(usize, 1), fetch.calls);
    const fresh = try drivers.native_driver.?.open(gpa, io, .{ .wt = tmp.dir });
    defer fresh.deinit(io);
    try testing.expect((try fresh.nextReady(gpa, io)) == null);
    try testing.expectEqual(@as(u32, 0), fresh.fallbacks());
}

test "phase2 native LFS propagates batched cancellation and releases pending state" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var cfg = try config.Config.parseText(gpa, "", .local);
    defer cfg.deinit();
    const Fetch = struct {
        calls: usize = 0,
        fn fetch(_: Io, context: *anyopaque, _: *const lfs.Store, _: *const lfs.Settings, _: []const lfs.Wanted) lfs.FetchError!void {
            const f: *@This() = @ptrCast(@alignCast(context));
            f.calls += 1;
            return error.Canceled;
        }
    };
    var fetch: Fetch = .{};
    const options: Options = .{ .fetch = .{ .context = &fetch, .fetchFn = Fetch.fetch } };
    var drivers = try filter.Drivers.load(gpa, io, &cfg, .{ .common = tmp.dir, .work = tmp.dir }, .{ .native_provider = provider(&options) });
    defer drivers.deinit(io);
    const session = try drivers.native_driver.?.open(gpa, io, .{ .wt = tmp.dir });
    var source: Io.Reader = .fixed("missing");
    const pointer = try lfs.hashOnly(&source);
    var buffer: [lfs.Pointer.max_encoded_len]u8 = undefined;
    try testing.expect((try session.smudge(gpa, io, .{ .path = "one", .bytes = pointer.encodeBuf(&buffer), .can_delay = true })) == .delayed);
    try testing.expectError(error.Canceled, session.nextReady(gpa, io));
    try testing.expectEqual(@as(usize, 1), fetch.calls);
    session.deinit(io);
    const fresh = try drivers.native_driver.?.open(gpa, io, .{ .wt = tmp.dir });
    defer fresh.deinit(io);
    try testing.expect((try fresh.nextReady(gpa, io)) == null);
}

test "phase2 native LFS allocator failures release driver and pending delivery" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var cfg = try config.Config.parseText(testing.allocator, "", .local);
    defer cfg.deinit();
    var no_resize = @import("shakedown").alloc.NoResize.init(testing.allocator);
    try testing.checkAllAllocationFailures(no_resize.allocator(), struct {
        fn exercise(gpa: Allocator, dir: Io.Dir, configuration: *const config.Config) !void {
            const fetch = struct {
                fn run(_: Io, _: *anyopaque, _: *const lfs.Store, _: *const lfs.Settings, _: []const lfs.Wanted) lfs.FetchError!void {}
            };
            var context: u8 = 0;
            const options: Options = .{ .fetch = .{ .context = &context, .fetchFn = fetch.run } };
            var drivers = try filter.Drivers.load(gpa, testing.io, configuration, .{ .common = dir, .work = dir }, .{ .native_provider = provider(&options) });
            defer drivers.deinit(testing.io);
            const session = try drivers.native_driver.?.open(gpa, testing.io, .{ .wt = dir });
            defer session.deinit(testing.io);
            const bytes = try session.clean(gpa, testing.io, .{ .bytes = "unavailable", .storing = .hash_only });
            defer gpa.free(bytes);
            try testing.expect((try session.smudge(gpa, testing.io, .{ .path = "one", .bytes = bytes, .can_delay = true })) == .delayed);
            const ready = (try session.nextReady(gpa, testing.io)).?;
            try testing.expectEqualStrings(bytes, ready.content.bytes);
        }
    }.exercise, .{ tmp.dir, &cfg });
}
