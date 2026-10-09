//! Private storage for one compiled pattern set per precedence level.
const std = @import("std");
const sweep = @import("sweep");
const Allocator = std.mem.Allocator;
pub const Error = Allocator.Error;

pub const Builder = struct {
    pub const Error = Allocator.Error;
    gpa: Allocator,
    arena: *std.heap.ArenaAllocator,
    owner: *Matcher,
    inner: sweep.Set.Builder,
    transferred: bool = false,

    pub const InitOptions = struct { arena: ?Allocator = null };

    pub fn init(gpa: Allocator, options: InitOptions) Allocator.Error!Builder {
        const owner = try gpa.create(Matcher);
        owner.* = .{ .gpa = gpa, .arena = .init(gpa), .set = undefined, .cache = null };
        const arena = &owner.arena;
        const compilation = options.arena orelse arena.allocator();
        return .{ .gpa = gpa, .arena = arena, .owner = owner, .inner = .init(compilation) };
    }

    pub fn deinit(b: *Builder) void {
        if (!b.transferred) {
            b.inner.deinit();
            b.arena.deinit();
            b.gpa.destroy(b.owner);
        }
        b.* = undefined;
    }
};

pub fn add(builder: *Builder, pattern: []const u8, anchored: bool, dir_only: bool, fold: bool) Allocator.Error!bool {
    _ = builder.inner.add(pattern, .{
        .options = .{ .syntax = .git, .anywhere = !anchored, .case = if (fold) .ascii_git else .sensitive },
        .dir_only = dir_only,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidPattern, error.PatternTooLong => return false,
        error.SeparatorMismatch => unreachable, // Every entry above uses git's slash separator.
    };
    return true;
}

pub const Matcher = struct {
    pub const Error = Allocator.Error;
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    set: sweep.Set,
    cache: ?sweep.Set.Cache,
    turn: std.atomic.Mutex = .unlocked,
    walking: ?sweep.Set.Ancestors = null,

    pub const BuildOptions = struct { cache: enum { retained, temporary } = .retained };

    pub fn build(builder: *Builder, options: BuildOptions) Allocator.Error!*Matcher {
        const m = builder.owner;
        var compiled = try builder.inner.build();
        errdefer compiled.deinit();
        m.set = compiled;
        if (options.cache == .retained) m.cache = try .init(m.gpa, &m.set, .{ .capacity = 1 << 16 });
        builder.inner.deinit();
        builder.transferred = true;
        return m;
    }

    pub fn deinit(m: *Matcher) void {
        const gpa = m.gpa;
        if (m.cache) |*cache| cache.deinit();
        // Compiled storage belongs to this arena or the construction owner.
        m.arena.deinit();
        gpa.destroy(m);
    }

    pub fn lock(m: *Matcher) void {
        while (!m.turn.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn unlock(m: *Matcher) void {
        m.turn.unlock();
    }

    pub fn last(m: *Matcher, path: []const u8, is_dir: bool) ?u32 {
        m.lock();
        defer m.unlock();
        return m.set.last(&m.cache.?, path, if (is_dir) .dir else .file);
    }

    pub fn all(m: *Matcher, a: Allocator, path: []const u8, is_dir: bool, out: *std.ArrayList(u32)) Allocator.Error!void {
        if (m.cache) |*cache| {
            m.lock();
            defer m.unlock();
            try m.set.all(a, cache, path, if (is_dir) .dir else .file, out);
        } else {
            // One query owns its scratch. Typical git sets fit on the stack;
            // larger automata use the caller's allocator. The set is immutable.
            var buffer: [80 * 1024]u8 = undefined;
            var scratch: std.heap.BufferFirstAllocator = .init(&buffer, a);
            var cache = try sweep.Set.Cache.init(scratch.allocator(), &m.set, .{ .capacity = 1 << 16 });
            defer cache.deinit();
            try m.set.all(a, &cache, path, if (is_dir) .dir else .file, out);
        }
    }

    pub fn begin(m: *Matcher, path: []const u8, is_dir: bool) void {
        m.walking = m.set.ancestors(&m.cache.?, path, if (is_dir) .dir else .file);
    }
};
