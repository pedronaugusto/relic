//! git's wildmatch, the one dialect every glob relic reads is written in:
//! ignore and attribute lines, pathspecs, sparse patterns, config
//! conditions, ref and describe filters, LFS fetch patterns.
//!
//! sweep does the matching, in time linear in the subject. git takes a
//! pattern of any length, so this does too: a pattern too long for sweep's
//! one-shot match is compiled, and one too long for a compiled `Pattern` is
//! a set of one entry. A malformed pattern matches nothing, as git's matcher
//! answers for one.

const ErrorNamespace = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const sweep = @import("sweep");

/// git's matcher flags.
pub const Options = struct {
    /// `WM_PATHNAME`: `*`, `?` and brackets stop at `/`, and `**` spans
    /// whole components. Off, every wildcard crosses `/` (`fnmatch` with no
    /// flags).
    pathname: bool = true,
    /// `WM_CASEFOLD`, quirks included: an escaped letter and a bracket
    /// member compare unfolded, so `\A` and `[A]` match nothing while
    /// `[A-Z]` matches `q`.
    case_fold: bool = false,
    /// A pattern with no `/` matches the last component at any depth:
    /// gitignore's rule for such a line. No effect without `pathname`.
    anywhere: bool = false,

    fn sweepOptions(o: Options) sweep.Options {
        return .{
            .syntax = if (o.pathname) .git else .git_text,
            .case = if (o.case_fold) .ascii_git else .sensitive,
            .anywhere = o.anywhere,
        };
    }
};

/// Whether `pattern` matches all of `subject`. Allocates only for a pattern
/// longer than sweep's one-shot match takes (`sweep.inline_units`).
pub fn matches(gpa: Allocator, pattern: []const u8, subject: []const u8, options: Options) Allocator.Error!bool {
    if (sweep.match(pattern, subject, options.sweepOptions())) |hit| return hit else |err| switch (err) {
        error.InvalidPattern => return false,
        error.PatternTooLong => {},
    }
    var glob: Glob = try .compile(gpa, pattern, options);
    defer glob.deinit();
    return glob.matches(subject);
}

/// A pattern compiled once, for one asked about many subjects. Immutable
/// after `compile`; any number of threads may query it at once.
pub const Glob = struct {
    pub const Error = ErrorNamespace.Error;

    /// Private: what the pattern compiled to.
    compiled: Compiled,

    /// A glob that matches nothing, and needs no `deinit`.
    pub const never: Glob = .{ .compiled = .none };

    const Compiled = union(enum) {
        /// A malformed pattern, which matches nothing.
        none,
        pattern: sweep.Pattern,
        /// Longer than a `Pattern` takes.
        long: *Long,
    };

    /// A set of one entry and the cache its queries run in. A cache serves
    /// one query at a time, so queries take turns on it; matching never
    /// waits on anything else, so a turn is as short as one query.
    const Long = struct {
        gpa: Allocator,
        set: sweep.Set,
        cache: sweep.Set.Cache,
        turn: std.atomic.Mutex,

        fn take(l: *Long) void {
            while (!l.turn.tryLock()) std.atomic.spinLoopHint();
        }
    };

    /// Compiles `pattern`, which is copied: nothing stays borrowed.
    pub fn compile(gpa: Allocator, pattern: []const u8, options: Options) Allocator.Error!Glob {
        const o = options.sweepOptions();
        if (sweep.Pattern.compile(gpa, pattern, o)) |p| return .{ .compiled = .{ .pattern = p } } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidPattern => return .{ .compiled = .none },
            error.PatternTooLong => {},
        }
        var builder: sweep.Set.Builder = .init(gpa);
        defer builder.deinit();
        _ = builder.add(pattern, .{ .options = o }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidPattern => return .{ .compiled = .none },
            // unreachable: a builder holding no entry takes one of any length and separator
            error.PatternTooLong, error.SeparatorMismatch => unreachable,
        };
        const long = try gpa.create(Long);
        errdefer gpa.destroy(long);
        long.* = .{ .gpa = gpa, .set = try builder.build(), .cache = undefined, .turn = .unlocked };
        errdefer long.set.deinit();
        long.cache = try .init(gpa, &long.set, .{ .capacity = 1 << 16 });
        return .{ .compiled = .{ .long = long } };
    }

    pub fn deinit(g: *Glob) void {
        switch (g.compiled) {
            .none => {},
            .pattern => |*p| p.deinit(),
            .long => |l| {
                l.cache.deinit();
                l.set.deinit();
                l.gpa.destroy(l);
            },
        }
        g.* = undefined;
    }

    /// Whether the pattern matches all of `subject`. Allocates nothing.
    pub fn matches(g: *const Glob, subject: []const u8) bool {
        switch (g.compiled) {
            .none => return false,
            .pattern => |*p| return p.matches(subject),
            .long => |l| {
                l.take();
                defer l.turn.unlock();
                return l.set.any(&l.cache, subject, .file);
            },
        }
    }

    /// The end of the shortest prefix of `subject` that ends at a `/` or at
    /// the end and that the pattern matches, or null: whether the subject
    /// or a directory above it matches, in one pass. Allocates nothing.
    pub fn ancestor(g: *const Glob, subject: []const u8) ?usize {
        switch (g.compiled) {
            .none => return null,
            .pattern => |*p| return p.ancestor(subject),
            .long => |l| {
                l.take();
                defer l.turn.unlock();
                var steps = l.set.ancestors(&l.cache, subject, .file);
                while (steps.next()) |step| if (step.last != null) return step.end;
                return null;
            },
        }
    }
};

/// Whether `byte` has meaning outside brackets in git's dialect: git's
/// `is_glob_special`.
pub fn isSpecial(byte: u8) bool {
    return sweep.isSpecial(byte, .git);
}

/// The length of the leading run of `pattern` with no special byte: git's
/// `simple_length`.
pub fn literalPrefix(pattern: []const u8) usize {
    return sweep.literalPrefix(pattern, .git);
}

/// All errors reported by this namespace.
pub const Error = Allocator.Error;
