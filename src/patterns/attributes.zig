//! `.gitattributes`, and the line-ending conversion it drives.
//!
//! Only the attributes that change the bytes of a blob are interpreted here:
//! `text`, `eol`, the `crlf` that came before `text`, and the two that are
//! not line endings — `working-tree-encoding`, a named refusal, and
//! `filter`, which `convert.zig` runs. Every other
//! attribute is read, stored and handed back, so a caller may act on `diff`,
//! `merge` or one of its own without this package having an opinion.
//!
//! The conversion decision uses git's *check-in* binary rule and not the diff
//! one. They are different rules and using the diff rule here would normalise
//! a file git leaves alone, which produces a different blob and therefore a
//! different tree.

const ErrorNamespace = @This();
const cquote = @import("../text.zig").cquote;
const Self = @This();

const std = @import("std");
const shakedown_mod = @import("shakedown");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const sets = @import("set.zig");
const sweep = @import("sweep");
const encoding = @import("../text.zig").encoding;
const fs = @import("../fs.zig");

/// Errors from loading attributes.
pub const Error = Allocator.Error || Io.Dir.ReadFileAllocError;

/// What one attribute is set to.
pub const State = union(enum) {
    /// `attr` — set.
    set,
    /// `-attr` — unset.
    unset,
    /// `!attr` — explicitly unspecified, which stops a lower-precedence
    /// file from setting it.
    unspecified,
    /// `attr=value`.
    value: []const u8,

    /// Whether the attribute is set, either bare or to a value.
    pub fn isSet(s: State) bool {
        return switch (s) {
            .set, .value => true,
            .unset, .unspecified => false,
        };
    }
};

/// One `name=state` pair on one line.
pub const Assignment = struct {
    name: []const u8,
    state: State,
};

const builtin_binary = [_]Assignment{
    .{ .name = "diff", .state = .unset },
    .{ .name = "merge", .state = .unset },
    .{ .name = "text", .state = .unset },
};

/// One line of an attributes file.
pub const Rule = struct {
    /// The glob, with a leading `/` removed.
    glob: []const u8,
    /// The directory the rule is relative to, `/`-separated, empty at the
    /// root.
    base: []const u8,
    anchored: bool,
    dir_only: bool,
    assignments: []Assignment,
    source: []const u8,
    line: u32,
};

/// One file's rules, at one level of precedence.
pub const Level = struct {
    base: []const u8,
    rules: []Rule,
    /// Private compiled set, owned by the attributes.
    _matcher: *anyopaque,
    /// Higher wins. `info/attributes` is highest, then the deepest
    /// `.gitattributes`, down to the global file.
    precedence: u32,
    /// Loaded by `enter` rather than by the caller, so `leave` takes it
    /// away again.
    entered: bool = false,
};

/// The precedence `info/attributes` is given, above every `.gitattributes`.
///
/// git reads attributes in the opposite order from ignore rules:
/// `info/attributes` wins over a file in the working tree, where
/// `info/exclude` loses to one.
pub const info_precedence: u32 = 1_000_000;

/// The precedence the global and system files are given, below everything.
pub const global_precedence: u32 = 0;

/// The attributes that apply to one path.
pub const Attributes = struct {
    /// Every assignment that applied, most significant first. Borrowed from
    /// the `Attrs` that produced it.
    items: []const Assignment,

    /// The state of `name`, or `null` when nothing set it.
    pub fn get(a: Attributes, name: []const u8) ?State {
        for (a.items) |item| {
            if (std.mem.eql(u8, item.name, name)) return item.state;
        }
        return null;
    }

    /// Whether `name` is set.
    pub fn isSet(a: Attributes, name: []const u8) bool {
        const state = a.get(name) orelse return false;
        return state.isSet();
    }

    /// The value of `name`, or `null` when it is unset or has no value.
    pub fn value(a: Attributes, name: []const u8) ?[]const u8 {
        const state = a.get(name) orelse return null;
        return switch (state) {
            .value => |v| v,
            else => null,
        };
    }
};

/// The loaded attributes for a working tree.
pub const Attrs = struct {
    pub const Error = ErrorNamespace.Error;

    gpa: Allocator,
    arena: *std.heap.ArenaAllocator,
    levels: std.ArrayList(Level),
    macros: std.ArrayList(Macro),
    case_fold: bool,
    /// The directory `enter` last loaded the levels down to, and whether it
    /// has loaded any.
    entered_dir: std.ArrayList(u8) = .empty,
    entered_any: bool = false,

    /// An `[attr]name …` line: a name that expands to a list of
    /// assignments.
    pub const Macro = struct {
        name: []const u8,
        assignments: []const Assignment,
        /// The precedence of the file that defined it: of two definitions
        /// the higher file's holds, and within a file the later line's, as
        /// git's `determine_macros` picks.
        precedence: u32 = global_precedence,
    };

    /// Empty attributes, plus git's one built-in macro.
    ///
    /// `binary` is `-diff -merge -text`, which git defines itself; a
    /// repository that never writes a `[attr]binary` line still has it.
    pub const InitOptions = struct { case_fold: bool = false };

    pub fn init(gpa: Allocator, options: InitOptions) Allocator.Error!Attrs {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        arena.* = .init(gpa);
        errdefer {
            arena.deinit();
            gpa.destroy(arena);
        }
        var attrs: Attrs = .{
            .gpa = gpa,
            .arena = arena,
            .levels = .empty,
            .macros = .empty,
            .case_fold = options.case_fold,
        };
        const a = arena.allocator();
        try attrs.macros.append(a, .{ .name = "binary", .assignments = &builtin_binary });
        return attrs;
    }

    /// Release everything.
    pub fn deinit(attrs: *Attrs) void {
        for (attrs.levels.items) |level| levelMatcher(level).deinit();
        attrs.arena.deinit();
        attrs.gpa.destroy(attrs.arena);
        attrs.entered_dir.deinit(attrs.gpa);
        attrs.* = undefined;
    }

    /// Position before an operation adds transient tree attributes.
    pub const Checkpoint = struct { levels: usize, macros: usize };
    pub fn checkpoint(attrs: *const Attrs) Checkpoint {
        return .{ .levels = attrs.levels.items.len, .macros = attrs.macros.items.len };
    }
    /// Release matchers added since the checkpoint before dropping levels.
    pub fn restore(attrs: *Attrs, before: Checkpoint) void {
        std.debug.assert(before.levels <= attrs.levels.items.len);
        std.debug.assert(before.macros <= attrs.macros.items.len);
        for (attrs.levels.items[before.levels..]) |level| levelMatcher(level).deinit();
        attrs.levels.shrinkRetainingCapacity(before.levels);
        attrs.macros.shrinkRetainingCapacity(before.macros);
    }

    /// Load the `.gitattributes` of every directory from the root of the
    /// working tree down to the one holding `path`, so that a lookup of
    /// `path` sees every file git would consult. This is for a caller that
    /// is not walking the tree — a checkout goes path by path — and is
    /// cheapest over paths in sorted order: only the directories that
    /// differ from the last call's are read. A directory whose file the
    /// caller loaded itself is not read again. `leave` gives back what this
    /// loaded.
    pub fn enter(attrs: *Attrs, io: Io, wt: Io.Dir, path: []const u8) Self.Error!void {
        const dir = std.Io.Dir.path.dirnamePosix(path) orelse "";
        if (attrs.entered_any and std.mem.eql(u8, attrs.entered_dir.items, dir)) return;
        // How many leading directories this shares with the last one, and
        // how long they are.
        var common: u32 = 0;
        var kept_len: usize = 0;
        if (attrs.entered_any) {
            var a = std.mem.splitScalar(u8, attrs.entered_dir.items, '/');
            var b = std.mem.splitScalar(u8, dir, '/');
            while (true) {
                const x = a.next() orelse break;
                const y = b.next() orelse break;
                if (x.len == 0 or !std.mem.eql(u8, x, y)) break;
                kept_len += x.len + @intFromBool(common != 0);
                common += 1;
            }
            // The root is precedence one and the directory `d` deep is
            // `d + 1`; the shared ones stay.
            attrs.dropEntered(common + 2);
        } else {
            try attrs.enterOne(io, wt, "", 0);
        }
        var depth: u32 = common;
        var at: usize = kept_len;
        while (at < dir.len) {
            if (at != 0 and dir[at] == '/') at += 1;
            const end = std.mem.findScalarPos(u8, dir, at, '/') orelse dir.len;
            depth += 1;
            try attrs.enterOne(io, wt, dir[0..end], depth);
            at = end;
        }
        attrs.entered_dir.clearRetainingCapacity();
        try attrs.entered_dir.appendSlice(attrs.gpa, dir);
        attrs.entered_any = true;
    }

    /// Give back every level `enter` loaded, leaving what the caller loaded.
    pub fn leave(attrs: *Attrs) void {
        attrs.dropEntered(0);
        attrs.entered_dir.clearRetainingCapacity();
        attrs.entered_any = false;
    }

    /// Tell the attributes a file was just written at `path`. A
    /// `.gitattributes` there changes what `enter` loaded, so the next
    /// `enter` reads the directories again.
    pub fn written(attrs: *Attrs, path: []const u8) void {
        const name = if (std.mem.findScalarLast(u8, path, '/')) |slash| path[slash + 1 ..] else path;
        if (std.mem.eql(u8, name, ".gitattributes")) attrs.leave();
    }

    fn enterOne(attrs: *Attrs, io: Io, wt: Io.Dir, base: []const u8, depth: u32) ErrorNamespace.Error!void {
        for (attrs.levels.items) |level| {
            if (level.precedence == depth + 1 and std.mem.eql(u8, level.base, base)) return;
        }
        const before = attrs.levels.items.len;
        // The base must outlive the level, and `base` is the caller's.
        try attrs.addDirectory(io, wt, try attrs.arena.allocator().dupe(u8, base), depth);
        if (attrs.levels.items.len > before) attrs.levels.items[before].entered = true;
    }

    fn dropEntered(attrs: *Attrs, precedence: u32) void {
        var i: usize = 0;
        while (i < attrs.levels.items.len) {
            const level = attrs.levels.items[i];
            if (level.entered and level.precedence >= precedence) {
                levelMatcher(attrs.levels.orderedRemove(i)).deinit();
                continue;
            }
            i += 1;
        }
    }

    /// Load `info/attributes` from the common directory, at the highest
    /// precedence, and the global file at the lowest.
    pub fn loadGlobal(
        attrs: *Attrs,
        io: Io,
        common_dir: Io.Dir,
        attributes_file: ?[]const u8,
        attributes_dir: ?Io.Dir,
    ) Self.Error!void {
        if (attributes_file) |path| {
            if (attributes_dir) |dir| {
                try attrs.addFileIfPresent(io, dir, path, "", path, global_precedence, .follow);
            }
        }
        try attrs.addFileIfPresent(io, common_dir, "info/attributes", "", "info/attributes", info_precedence, .follow);
    }

    /// Load `<base>/.gitattributes`, if it is there.
    ///
    /// `depth` is how far `base` is below the root of the working tree;
    /// deeper wins, so the precedence rises with it.
    pub fn addDirectory(attrs: *Attrs, io: Io, wt: Io.Dir, base: []const u8, depth: u32) Self.Error!void {
        var path_buf: [4096]u8 = undefined;
        const path = if (base.len == 0)
            ".gitattributes"
        else
            std.mem.print(&path_buf, "{s}/.gitattributes", .{base}) catch return;
        try attrs.addFileIfPresent(io, wt, path, base, path, depth + 1, .no_follow);
    }

    /// git's `ATTR_MAX_FILE_SIZE`: a larger attributes file is passed over,
    /// as git passes it over with a warning.
    pub const max_file_size = 100 * 1024 * 1024;

    /// git's `ATTR_MAX_LINE_LENGTH`: a line this long or longer is passed
    /// over whole, as git passes it over with a warning, rather than read
    /// in part or broken in two.
    pub const max_line_length = 2048;

    fn addFileIfPresent(
        attrs: *Attrs,
        io: Io,
        dir: Io.Dir,
        path: []const u8,
        base: []const u8,
        source: []const u8,
        precedence: u32,
        links: enum { follow, no_follow },
    ) ErrorNamespace.Error!void {
        // A `.gitattributes` in the working tree is read only as a file,
        // never through a symbolic link, as git's `READ_ATTR_NOFOLLOW` reads
        // it: a link would have the tree's attributes come from anywhere.
        if (links == .no_follow) {
            const found = fs.statAt(io, dir, path) catch return orelse return;
            if (found.kind != .file) return;
        }
        const a = attrs.arena.allocator();
        const bytes = fs.readFileAlloc(a, io, dir, path, max_file_size) catch |err| switch (err) {
            error.StreamTooLong => return,
            else => |e| return e,
        } orelse return;
        try attrs.addText(bytes, base, source, precedence);
    }

    /// Add a level from text already in memory, which must outlive the
    /// attributes.
    pub fn addText(attrs: *Attrs, text: []const u8, base: []const u8, source: []const u8, precedence: u32) Self.Error!void {
        const a = attrs.arena.allocator();
        var rules: std.ArrayList(Rule) = .empty;
        var builder: sets.Builder = try .init(attrs.gpa);
        defer builder.deinit();
        var line_number: u32 = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw_line| {
            line_number += 1;
            var line = raw_line;
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            if (line.len >= max_line_length) continue;
            line = std.mem.trim(u8, line, " \t");
            if (line.len == 0 or line[0] == '#') continue;

            if (std.mem.startsWith(u8, line, "[attr]")) {
                // A macro is defined only at the top: the root's file, the
                // global one or `info/attributes`. git refuses one further
                // down with a warning, as `READ_ATTR_MACRO_OK` allows.
                if (base.len != 0) continue;
                const rest = std.mem.trim(u8, line["[attr]".len..], " \t");
                const space = std.mem.findAny(u8, rest, " \t") orelse continue;
                const name = rest[0..space];
                const assignments = try parseAssignments(a, rest[space + 1 ..]);
                try attrs.macros.append(a, .{ .name = name, .assignments = assignments, .precedence = precedence });
                continue;
            }

            const parsed = (try parsePattern(a, line)) orelse continue;
            const assignments = try parseAssignments(a, parsed.rest);
            if (assignments.len == 0) continue;
            if (!try sets.add(&builder, parsed.glob, parsed.anchored, parsed.dir_only, attrs.case_fold)) continue;
            try rules.append(a, .{
                .glob = parsed.glob,
                .base = base,
                .anchored = parsed.anchored,
                .dir_only = parsed.dir_only,
                .assignments = assignments,
                .source = source,
                .line = line_number,
            });
        }
        if (rules.items.len == 0) return;
        const compiled = try sets.Matcher.build(&builder);
        errdefer compiled.deinit();
        try attrs.levels.append(a, .{
            .base = base,
            .rules = rules.items,
            ._matcher = compiled,
            .precedence = precedence,
        });
    }

    /// Drop every level whose precedence is at or above `precedence` and
    /// below `info_precedence`, which is what a walk does on its way back
    /// out of a directory.
    pub fn popTo(attrs: *Attrs, precedence: u32) void {
        var i: usize = 0;
        while (i < attrs.levels.items.len) {
            const level = attrs.levels.items[i];
            if (level.precedence >= precedence and level.precedence != info_precedence) {
                // What `enter` loaded is no longer all there, so the next
                // `enter` starts again.
                if (level.entered) {
                    attrs.entered_any = false;
                    attrs.entered_dir.clearRetainingCapacity();
                }
                levelMatcher(attrs.levels.orderedRemove(i)).deinit();
                continue;
            }
            i += 1;
        }
    }

    /// The attributes that apply to `path`.
    ///
    /// The result borrows the allocator passed in, which is usually an arena
    /// the caller resets per path.
    pub fn lookup(attrs: *const Attrs, a: Allocator, path: []const u8, is_dir: bool) Allocator.Error!Attributes {
        var out: std.ArrayList(Assignment) = .empty;
        errdefer out.deinit(a);

        // Highest precedence first, and within a file the last line first:
        // the first assignment found for an attribute is the one that holds,
        // which is how git resolves it.
        var order_buffer: [16]*const Level = undefined;
        const order = if (attrs.levels.items.len <= order_buffer.len)
            order_buffer[0..attrs.levels.items.len]
        else
            try a.alloc(*const Level, attrs.levels.items.len);
        defer if (order.ptr != &order_buffer) a.free(order);
        for (attrs.levels.items, 0..) |*level, i| order[i] = level;
        std.mem.sort(*const Level, order, {}, higherPrecedenceFirst);

        for (order) |level| {
            const relative = relativeTo(level.base, path) orelse continue;
            var hit_buffer: [16]sweep.Set.Index = undefined;
            var hit_scratch: std.heap.BufferFirstAllocator = .init(std.mem.asBytes(&hit_buffer), a);
            const hit_allocator = hit_scratch.allocator();
            var hits: std.ArrayList(sweep.Set.Index) = .empty;
            defer hits.deinit(hit_allocator);
            try levelMatcher(level.*).all(hit_allocator, relative, is_dir, &hits);
            var i = hits.items.len;
            while (i > 0) {
                i -= 1;
                try attrs.fill(a, &out, level.rules[hits.items[i].raw()].assignments);
            }
        }
        return .{ .items = out.items };
    }

    /// git's `fill_one` and `macroexpand_one`: a line's assignments last
    /// first, each only where nothing decided the attribute already, and a
    /// macro just set -- to set, not to a value -- expanded into its own
    /// assignments the same way. An attribute is decided once, so each
    /// macro is expanded at most once per lookup however its definitions
    /// name each other; the expansion keeps its own stack, so a chain of
    /// macros as long as a file can hold runs no recursion off the stack.
    fn fill(attrs: *const Attrs, a: Allocator, out: *std.ArrayList(Assignment), assignments: []const Assignment) Allocator.Error!void {
        var pending: std.ArrayList([]const Assignment) = .empty;
        defer pending.deinit(a);
        var current = assignments;
        while (true) {
            if (current.len == 0) {
                current = pending.pop() orelse break;
                continue;
            }
            const assignment = current[current.len - 1];
            current = current[0 .. current.len - 1];
            if (decided(out.items, assignment.name)) continue;
            try out.append(a, assignment);
            if (assignment.state != .set) continue;
            if (attrs.macroNamed(assignment.name)) |macro| {
                if (current.len != 0) try pending.append(a, current);
                current = macro.assignments;
            }
        }
    }

    fn decided(out: []const Assignment, name: []const u8) bool {
        for (out) |existing| {
            if (std.mem.eql(u8, existing.name, name)) return true;
        }
        return false;
    }

    fn macroNamed(attrs: *const Attrs, name: []const u8) ?Macro {
        var best: ?Macro = null;
        for (attrs.macros.items) |macro| {
            if (!std.mem.eql(u8, macro.name, name)) continue;
            if (best == null or macro.precedence >= best.?.precedence) best = macro;
        }
        return best;
    }

    fn higherPrecedenceFirst(_: void, a: *const Level, b: *const Level) bool {
        return a.precedence > b.precedence;
    }
};

fn levelMatcher(level: Level) *sets.Matcher {
    return @ptrCast(@alignCast(level._matcher)); // safe: a Level's matcher is allocated as a sets.Matcher and never changes type
}

fn relativeTo(base: []const u8, path: []const u8) ?[]const u8 {
    if (base.len == 0) return path;
    if (!std.mem.startsWith(u8, path, base)) return null;
    if (path.len <= base.len or path[base.len] != '/') return null;
    return path[base.len + 1 ..];
}

const ParsedPattern = struct {
    glob: []const u8,
    anchored: bool,
    dir_only: bool,
    rest: []const u8,
};

fn parsePattern(a: Allocator, line: []const u8) Allocator.Error!?ParsedPattern {
    var i: usize = 0;
    var glob: []const u8 = undefined;
    if (line[0] == '"') {
        const quoted = (try cquote.unquote(a, line)) orelse return null;
        glob = quoted.name;
        i = quoted.consumed;
    } else {
        const space = std.mem.findAny(u8, line, " \t") orelse return null;
        glob = line[0..space];
        i = space;
    }
    var anchored = false;
    var dir_only = false;
    if (glob.len > 0 and glob[glob.len - 1] == '/') {
        dir_only = true;
        glob = glob[0 .. glob.len - 1];
    }
    if (glob.len > 0 and glob[0] == '/') {
        anchored = true;
        glob = glob[1..];
    } else if (std.mem.findScalar(u8, glob, '/') != null) {
        anchored = true;
    }
    if (glob.len == 0) return null;
    return .{ .glob = glob, .anchored = anchored, .dir_only = dir_only, .rest = line[i..] };
}

fn parseAssignments(a: Allocator, text: []const u8) Allocator.Error![]Assignment {
    var count: usize = 0;
    var words = std.mem.tokenizeAny(u8, text, " \t");
    while (words.next() != null) count += 1;
    const out = try a.alloc(Assignment, count);
    words.reset();
    for (out) |*assignment| {
        const word = words.next().?;
        assignment.* = if (word[0] == '-')
            .{ .name = word[1..], .state = .unset }
        else if (word[0] == '!')
            .{ .name = word[1..], .state = .unspecified }
        else if (std.mem.findScalar(u8, word, '=')) |eq|
            .{ .name = word[0..eq], .state = .{ .value = word[eq + 1 ..] } }
        else
            .{ .name = word, .state = .set };
    }
    return out;
}

/// The settings from `core` that take part in line-ending conversion.
pub const CoreSettings = struct {
    /// `core.autocrlf`: `false`, `true` or `input`.
    autocrlf: AutoCrlf = .false,
    /// `core.eol`: what a checked-out text file ends its lines with when no
    /// `eol` attribute says.
    eol: Eol = .native,
    /// `core.safecrlf`: whether an irreversible conversion is reported.
    safecrlf: SafeCrlf = .false,

    /// What `core.autocrlf` may be: carriage returns removed on the way in
    /// and put back on the way out, removed on the way in only, or neither.
    pub const AutoCrlf = enum { false, true, input };
    /// What `core.eol` and the `eol` attribute may be: the line ending a
    /// text file is written with in the working tree.
    pub const Eol = enum { native, lf, crlf };
    /// What `core.safecrlf` may be: what happens when a conversion would not
    /// round-trip.
    pub const SafeCrlf = enum { false, true, warn };

    /// The native line ending, which is CRLF on Windows and LF elsewhere.
    pub const native_is_crlf = builtin.target.os.tag == .windows;
};

/// A setting this release does not implement, named so the caller is refused
/// rather than handed a blob git would not write.
pub const Unsupported = union(enum) {
    /// `working-tree-encoding=<name>` for a character set other than
    /// UTF-8, UTF-16 and UTF-32, which this package does not convert.
    working_tree_encoding: []const u8,
    /// `filter=<name>` where `filter.<name>.required` is true. Running a
    /// filter means running a program, which this package never does.
    required_filter: []const u8,

    /// The name of the setting, for a message.
    pub fn settingName(u: Unsupported) []const u8 {
        return switch (u) {
            .working_tree_encoding => "working-tree-encoding",
            .required_filter => "filter",
        };
    }

    /// The value that was asked for.
    pub fn settingValue(u: Unsupported) []const u8 {
        return switch (u) {
            .working_tree_encoding => |name| name,
            .required_filter => |name| name,
        };
    }
};

/// Whether `attrs` name a setting this release cannot honour.
///
/// `required_filters` is the set of filter names whose `filter.<name>.required`
/// is true; a filter that is not required is not a refusal, because git
/// itself uses the bytes unfiltered when a non-required filter is missing.
pub fn unsupported(a: Attributes, required_filters: []const []const u8) ?Unsupported {
    if (a.value("working-tree-encoding")) |name| {
        if (name.len != 0 and !encoding.isUtf8(name) and encoding.Encoding.fromName(name) == null) {
            return .{ .working_tree_encoding = name };
        }
    }
    if (a.value("filter")) |name| {
        for (required_filters) |required| {
            if (std.mem.eql(u8, required, name)) return .{ .required_filter = name };
        }
    }
    return null;
}

/// git's *diff* binary rule: a NUL in the first 8000 bytes.
///
/// This decides whether a diff prints `Binary files differ`. It is not the
/// rule that decides whether a file is normalised on check-in.
pub fn isBinaryForDiff(bytes: []const u8) bool {
    const window = bytes[0..@min(bytes.len, first_few_bytes)];
    return std.mem.findScalar(u8, window, 0) != null;
}

/// How many bytes the diff rule looks at.
pub const first_few_bytes = 8000;

/// What `gatherStats` counted.
pub const TextStat = struct {
    crlf: usize = 0,
    lonecr: usize = 0,
    lonelf: usize = 0,
    printable: usize = 0,
    nonprintable: usize = 0,
    nul: bool = false,
};

/// Count the things git's check-in rule looks at, over the whole content:
/// unlike the diff rule, this one has no window, and a NUL or a lone
/// carriage return anywhere makes a file binary.
pub fn gatherStats(bytes: []const u8) TextStat {
    var stat: TextStat = .{};
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        const c = bytes[i];
        switch (c) {
            '\r' => {
                if (i + 1 < bytes.len and bytes[i + 1] == '\n') {
                    stat.crlf += 1;
                    i += 1;
                } else {
                    stat.lonecr += 1;
                }
            },
            '\n' => stat.lonelf += 1,
            127 => stat.nonprintable += 1,
            0 => {
                stat.nul = true;
                stat.nonprintable += 1;
            },
            // Backspace, tab, form feed and escape read as text; every
            // other control byte does not. Carriage return and line feed
            // are counted above and take part in neither total.
            8, '\t', 0o14, 0o33 => stat.printable += 1,
            1...7, 11, 14...26, 28...31 => stat.nonprintable += 1,
            else => stat.printable += 1,
        }
    }
    // A ^Z ending the file is the end-of-file mark some editors write, and
    // git does not count it against the file.
    if (bytes.len > 0 and bytes[bytes.len - 1] == 0x1a) stat.nonprintable -= 1;
    return stat;
}

/// git's *check-in* binary rule: a lone carriage return, or a NUL, or more
/// than one non-printable byte per 128 printable ones.
///
/// This is the rule `text=auto` and `core.autocrlf` consult. It is stricter
/// than the diff rule in one direction and looser in another, and using the
/// wrong one writes a blob git would not write.
pub fn isBinaryForCheckIn(bytes: []const u8) bool {
    return statsAreBinary(gatherStats(bytes));
}

fn statsAreBinary(stat: TextStat) bool {
    if (stat.lonecr != 0) return true;
    if (stat.nul) return true;
    if ((stat.printable >> 7) < stat.nonprintable) return true;
    return false;
}

/// What a conversion decided.
pub const Conversion = struct {
    pub const Error = ErrorNamespace.Error;

    /// The converted bytes, or the original slice when nothing changed.
    bytes: []const u8,
    /// Whether `bytes` was allocated and must be freed by the caller.
    owned: bool,
    /// Whether the conversion would not survive a round trip — a file with
    /// both CRLF and lone LF line endings, which `core.safecrlf` reports.
    irreversible: bool = false,

    /// Release the bytes if they were allocated.
    pub fn deinit(c: Conversion, gpa: Allocator) void {
        if (c.owned) gpa.free(c.bytes);
    }
};

/// What the attributes and `core` settings decide about a path's line
/// endings: git's `crlf_action`, worked out the way `convert_attrs` works
/// it out.
///
/// `text` is read first and the legacy `crlf` attribute only when `text`
/// says nothing, each as `text` is read: set, unset, `input` or `auto`,
/// any other value meaning nothing was said. An `eol` attribute makes a
/// path text, and says which ending it is written with. What is still
/// undecided after that is `core.autocrlf`'s.
pub const CrlfAction = enum {
    /// Left exactly as it is, both ways.
    binary,
    /// Text, stored with LF and written with LF.
    text_input,
    /// Text, stored with LF and written with CRLF.
    text_crlf,
    /// Text if it looks like text, written as `core.eol` and
    /// `core.autocrlf` say.
    auto,
    /// Text if it looks like text, written with LF.
    auto_input,
    /// Text if it looks like text, written with CRLF.
    auto_crlf,

    /// Whether the content decides: a file that looks binary is left alone.
    pub fn isAuto(action: CrlfAction) bool {
        return switch (action) {
            .auto, .auto_input, .auto_crlf => true,
            else => false,
        };
    }

    /// Whether a checkout writes CRLF endings.
    pub fn writesCrlf(action: CrlfAction, core: CoreSettings) bool {
        return switch (action) {
            .binary, .text_input, .auto_input => false,
            .text_crlf, .auto_crlf => true,
            .auto => textEolIsCrlf(core),
        };
    }
};

/// The action for a path with these attributes, under these settings.
pub fn crlfAction(a: Attributes, core: CoreSettings) CrlfAction {
    var said = textSaid(a.get("text"));
    if (said == .nothing) said = textSaid(a.get("crlf"));
    if (said != .binary) {
        const eol = a.value("eol") orelse "";
        const lf = std.mem.eql(u8, eol, "lf");
        const crlf = std.mem.eql(u8, eol, "crlf");
        if (said == .auto and lf) {
            return .auto_input;
        } else if (said == .auto and crlf) {
            return .auto_crlf;
        } else if (lf) {
            return .text_input;
        } else if (crlf) {
            return .text_crlf;
        }
    }
    return switch (said) {
        .binary => .binary,
        .text => if (textEolIsCrlf(core)) .text_crlf else .text_input,
        .input => .text_input,
        .auto => .auto,
        .nothing => switch (core.autocrlf) {
            .false => .binary,
            .true => .auto_crlf,
            .input => .auto_input,
        },
    };
}

/// What one of `text` and `crlf` says.
const TextSaid = enum { nothing, text, binary, input, auto };

fn textSaid(state: ?State) TextSaid {
    return switch (state orelse return .nothing) {
        .set => .text,
        .unset => .binary,
        .unspecified => .nothing,
        .value => |v| if (std.mem.eql(u8, v, "input"))
            .input
        else if (std.mem.eql(u8, v, "auto"))
            .auto
        else
            .nothing,
    };
}

/// Whether a text file with nothing more specific to go by is written with
/// CRLF: `core.autocrlf` first, then `core.eol`, then the platform.
fn textEolIsCrlf(core: CoreSettings) bool {
    return switch (core.autocrlf) {
        .true => true,
        .input => false,
        .false => switch (core.eol) {
            .crlf => true,
            .lf => false,
            .native => CoreSettings.native_is_crlf,
        },
    };
}

/// What check-in knows about the version of a file the index already has.
pub const Stored = struct {
    /// The index's blob for the path is text with CRLF endings, which
    /// `hasCrlfText` says. Where the content decides whether a file is text,
    /// git leaves such a file's endings alone rather than change every line
    /// of it on the next commit.
    has_crlf: bool = false,
};

/// Whether a blob is text with at least one CRLF in it, by the check-in
/// rule: git's `has_crlf_in_index`, asked of the index's version of a path.
pub fn hasCrlfText(blob: []const u8) bool {
    if (std.mem.findScalar(u8, blob, '\r') == null) return false;
    return !isBinaryForCheckIn(blob) and gatherStats(blob).crlf != 0;
}

/// Normalise for storage: CRLF becomes LF where the attributes and the
/// configuration say the file is text.
///
/// This is the call that decides a blob's name. Getting it wrong produces a
/// tree git disagrees with, which is the one thing this package is for.
pub fn toGit(gpa: Allocator, bytes: []const u8, a: Attributes, core: CoreSettings) Allocator.Error!Conversion {
    return toGitStored(gpa, bytes, a, core, .{});
}

/// `toGit`, knowing what the index already holds for the path.
pub fn toGitStored(gpa: Allocator, bytes: []const u8, a: Attributes, core: CoreSettings, stored: Stored) Allocator.Error!Conversion {
    const action = crlfAction(a, core);
    if (action == .binary) return .{ .bytes = bytes, .owned = false };
    if (action.isAuto() and isBinaryForCheckIn(bytes)) return .{ .bytes = bytes, .owned = false };
    if (action.isAuto() and stored.has_crlf) return .{ .bytes = bytes, .owned = false };
    if (std.mem.findScalar(u8, bytes, '\r') == null) return .{ .bytes = bytes, .owned = false };

    var out = try std.ArrayList(u8).initCapacity(gpa, bytes.len);
    errdefer out.deinit(gpa);
    var had_lone_lf = false;
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        const c = bytes[i];
        if (c == '\r' and i + 1 < bytes.len and bytes[i + 1] == '\n') continue;
        if (c == '\n' and (i == 0 or bytes[i - 1] != '\r')) had_lone_lf = true;
        out.appendAssumeCapacity(c);
    }
    const converted = try out.toOwnedSlice(gpa);
    return .{
        .bytes = converted,
        .owned = true,
        // A file mixing CRLF and bare LF endings does not come back as it
        // went in, which is exactly what `core.safecrlf` exists to report.
        .irreversible = had_lone_lf,
    };
}

/// Convert for the working tree: LF becomes CRLF where the attributes and
/// the configuration ask for it.
pub fn toWorktree(gpa: Allocator, bytes: []const u8, a: Attributes, core: CoreSettings) Allocator.Error!Conversion {
    const action = crlfAction(a, core);
    if (!action.writesCrlf(core)) return .{ .bytes = bytes, .owned = false };
    if (action.isAuto()) {
        // A file that already has a carriage return in it is left as it
        // is, CRLF or not: the content deciding means not guessing twice.
        const stat = gatherStats(bytes);
        if (stat.lonecr != 0 or stat.crlf != 0 or statsAreBinary(stat)) return .{ .bytes = bytes, .owned = false };
    }
    if (std.mem.findScalar(u8, bytes, '\n') == null) return .{ .bytes = bytes, .owned = false };

    var out = try std.ArrayList(u8).initCapacity(gpa, bytes.len + bytes.len / 16 + 8);
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        const c = bytes[i];
        if (c == '\n' and (i == 0 or bytes[i - 1] != '\r')) {
            try out.append(gpa, '\r');
        }
        try out.append(gpa, c);
    }
    return .{ .bytes = try out.toOwnedSlice(gpa), .owned = true };
}

test "text=auto normalises a text file and leaves a binary one" {
    const gpa = std.testing.allocator;
    var attrs: Attrs = try .init(gpa, .{ .case_fold = false });
    defer attrs.deinit();
    try attrs.addText("* text=auto\n", "", ".gitattributes", 1);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = try attrs.lookup(arena.allocator(), "a.txt", false);

    const text = try toGit(gpa, "one\r\ntwo\r\n", a, .{});
    defer text.deinit(gpa);
    try std.testing.expectEqualStrings("one\ntwo\n", text.bytes);
    try std.testing.expect(text.owned);

    // A lone carriage return makes the check-in rule call it binary, so it
    // is stored exactly as it is.
    const binary = try toGit(gpa, "one\rtwo\r\n", a, .{});
    defer binary.deinit(gpa);
    try std.testing.expectEqualStrings("one\rtwo\r\n", binary.bytes);
    try std.testing.expect(!binary.owned);
}

test "the two binary rules disagree, and each is used where it belongs" {
    // A lone carriage return: text to the diff rule, binary to check-in.
    try std.testing.expect(!isBinaryForDiff("a\rb"));
    try std.testing.expect(isBinaryForCheckIn("a\rb"));
    // A NUL: binary to both.
    try std.testing.expect(isBinaryForDiff("a\x00b"));
    try std.testing.expect(isBinaryForCheckIn("a\x00b"));
    // Plain text: neither.
    try std.testing.expect(!isBinaryForDiff("hello\n"));
    try std.testing.expect(!isBinaryForCheckIn("hello\n"));
    // Mostly control bytes with no NUL: text to the diff rule, binary to
    // check-in.
    const noisy = "\x01\x02\x03\x04\x05\x06\x07\x0e\x0f\x10abc";
    try std.testing.expect(!isBinaryForDiff(noisy));
    try std.testing.expect(isBinaryForCheckIn(noisy));
}

test "core.autocrlf without an attribute" {
    const gpa = std.testing.allocator;
    var attrs: Attrs = try .init(gpa, .{ .case_fold = false });
    defer attrs.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = try attrs.lookup(arena.allocator(), "a.txt", false);

    const off = try toGit(gpa, "one\r\n", a, .{ .autocrlf = .false });
    defer off.deinit(gpa);
    try std.testing.expectEqualStrings("one\r\n", off.bytes);

    const input = try toGit(gpa, "one\r\n", a, .{ .autocrlf = .input });
    defer input.deinit(gpa);
    try std.testing.expectEqualStrings("one\n", input.bytes);

    const out = try toWorktree(gpa, "one\n", a, .{ .autocrlf = .true });
    defer out.deinit(gpa);
    try std.testing.expectEqualStrings("one\r\n", out.bytes);

    const not_out = try toWorktree(gpa, "one\n", a, .{ .autocrlf = .input });
    defer not_out.deinit(gpa);
    try std.testing.expectEqualStrings("one\n", not_out.bytes);
}

test "-text turns conversion off whatever the configuration says" {
    const gpa = std.testing.allocator;
    var attrs: Attrs = try .init(gpa, .{ .case_fold = false });
    defer attrs.deinit();
    try attrs.addText("*.bin -text\n", "", ".gitattributes", 1);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = try attrs.lookup(arena.allocator(), "x.bin", false);
    const kept = try toGit(gpa, "one\r\n", a, .{ .autocrlf = .true });
    defer kept.deinit(gpa);
    try std.testing.expectEqualStrings("one\r\n", kept.bytes);
}

test "the eol attribute beats core.eol" {
    const gpa = std.testing.allocator;
    var attrs: Attrs = try .init(gpa, .{ .case_fold = false });
    defer attrs.deinit();
    try attrs.addText("*.txt text eol=crlf\n*.sh text eol=lf\n", "", ".gitattributes", 1);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const txt = try attrs.lookup(arena.allocator(), "a.txt", false);
    const crlf = try toWorktree(gpa, "one\n", txt, .{ .eol = .lf });
    defer crlf.deinit(gpa);
    try std.testing.expectEqualStrings("one\r\n", crlf.bytes);

    const sh = try attrs.lookup(arena.allocator(), "a.sh", false);
    const lf = try toWorktree(gpa, "one\n", sh, .{ .eol = .crlf });
    defer lf.deinit(gpa);
    try std.testing.expectEqualStrings("one\n", lf.bytes);
}

test "a macro expands, and the built-in binary macro is there" {
    const gpa = std.testing.allocator;
    var attrs: Attrs = try .init(gpa, .{ .case_fold = false });
    defer attrs.deinit();
    try attrs.addText("[attr]mine -text diff=zig\n*.zz mine\n*.png binary\n", "", ".gitattributes", 1);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const zz = try attrs.lookup(arena.allocator(), "a.zz", false);
    try std.testing.expectEqual(State.unset, zz.get("text").?);
    try std.testing.expectEqualStrings("zig", zz.value("diff").?);

    const png = try attrs.lookup(arena.allocator(), "a.png", false);
    try std.testing.expectEqual(State.unset, png.get("text").?);
    try std.testing.expectEqual(State.unset, png.get("diff").?);
}

test "macros naming each other many times over expand once each, where each expansion used to repeat" {
    const gpa = std.testing.allocator;
    var attrs: Attrs = try .init(gpa, .{ .case_fold = false });
    defer attrs.deinit();
    // Nine macros, each naming the next twelve times: expanded again at
    // every mention that is twelve to the eighth expansions per lookup.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (0..8) |i| {
        try text.print(gpa, "[attr]m{d}", .{i});
        for (0..12) |_| try text.print(gpa, " m{d}", .{i + 1});
        try text.append(gpa, '\n');
    }
    try text.appendSlice(gpa, "[attr]m8 leaf\n* m0\n");
    try attrs.addText(text.items, "", ".gitattributes", 1);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const found = try attrs.lookup(arena.allocator(), "f", false);
    try std.testing.expect(found.isSet("leaf"));
    try std.testing.expectEqual(@as(usize, 10), found.items.len);
}

test "a deeper file wins, and info/attributes wins over both" {
    const gpa = std.testing.allocator;
    var attrs: Attrs = try .init(gpa, .{ .case_fold = false });
    defer attrs.deinit();
    try attrs.addText("* text\n", "", ".gitattributes", 1);
    try attrs.addText("* -text\n", "sub", "sub/.gitattributes", 2);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const deep = try attrs.lookup(arena.allocator(), "sub/a.txt", false);
    try std.testing.expectEqual(State.unset, deep.get("text").?);

    try attrs.addText("* text=auto\n", "", "info/attributes", info_precedence);
    const highest = try attrs.lookup(arena.allocator(), "sub/a.txt", false);
    try std.testing.expectEqualStrings("auto", highest.value("text").?);
}

test "an unimplemented setting is named" {
    const gpa = std.testing.allocator;
    var attrs: Attrs = try .init(gpa, .{ .case_fold = false });
    defer attrs.deinit();
    try attrs.addText("*.po working-tree-encoding=SHIFT-JIS\n*.txt working-tree-encoding=UTF-16\n*.lfs filter=lfs\n", "", ".gitattributes", 1);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const po = try attrs.lookup(arena.allocator(), "a.po", false);
    const refused = unsupported(po, &.{}).?;
    try std.testing.expectEqualStrings("working-tree-encoding", refused.settingName());
    try std.testing.expectEqualStrings("SHIFT-JIS", refused.settingValue());
    try std.testing.expect(unsupported(try attrs.lookup(arena.allocator(), "a.txt", false), &.{}) == null);

    const lfs = try attrs.lookup(arena.allocator(), "a.lfs", false);
    try std.testing.expect(unsupported(lfs, &.{}) == null);
    const required = unsupported(lfs, &.{"lfs"}).?;
    try std.testing.expectEqualStrings("filter", required.settingName());
    try std.testing.expectEqualStrings("lfs", required.settingValue());
}

test "fuzz: any attributes file answers without a crash" {
    try std.testing.fuzz({}, fuzzAttrs, .{});
}

fn fuzzAttrs(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;
    var text_buf: [1024]u8 = undefined;
    var path_buf: [128]u8 = undefined;
    const text = text_buf[0..smith.slice(&text_buf)];
    const path = path_buf[0..smith.slice(&path_buf)];
    var attrs: Attrs = try .init(gpa, .{ .case_fold = false });
    defer attrs.deinit();
    attrs.addText(text, "", "fuzz", 1) catch return;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = attrs.lookup(arena.allocator(), path, false) catch return;
    _ = unsupported(a, &.{"lfs"});
    const converted = toGit(gpa, text, a, .{ .autocrlf = .true }) catch return;
    converted.deinit(gpa);
}

test "quoted attributes decode C escapes once" {
    const gpa = std.testing.allocator;
    var attrs = try Attrs.init(gpa, .{ .case_fold = false });
    defer attrs.deinit();
    try attrs.addText("\"tab\\tname\" diff=tab\n\"quote\\\"name\" diff=quote\n\"octal\\040name\" diff=octal\n", "", ".gitattributes", 1);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cases = .{ .{ "tab\tname", "tab" }, .{ "quote\"name", "quote" }, .{ "octal name", "octal" } };
    inline for (cases) |case| {
        const found = try attrs.lookup(arena.allocator(), case[0], false);
        try std.testing.expectEqualStrings(case[1], found.value("diff") orelse "missing");
    }
}

test "attribute sets survive every allocation failure and keep precedence" {
    var no_resize = shakedown_mod.alloc.NoResize.init(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(no_resize.allocator(), struct {
        fn exercise(gpa: Allocator) !void {
            var attrs = try Attrs.init(gpa, .{ .case_fold = true });
            defer attrs.deinit();
            try attrs.addText("[attr]source text diff=zig\n*.zig source\n*.bin binary\n", "", ".gitattributes", 1);
            try attrs.addText("*.ZIG diff=deep\n", "src", "src/.gitattributes", 2);
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            const found = try attrs.lookup(arena.allocator(), "src/main.Zig", false);
            try std.testing.expectEqualStrings("deep", found.value("diff").?);
            try std.testing.expect(found.isSet("text"));
            const binary = try attrs.lookup(arena.allocator(), "src/data.BIN", false);
            try std.testing.expectEqual(State.unset, binary.get("diff").?);
        }
    }.exercise, .{});
}

test "attribute queries release their scratch on every allocation failure" {
    const gpa = std.testing.allocator;
    var attrs = try Attrs.init(gpa, .{});
    defer attrs.deinit();
    const pattern = &@as([1800]u8, @splat('?'));
    try attrs.addText(pattern ++ " text\n" ++ pattern ++ " diff=long\n", "", ".gitattributes", 1);
    var no_resize = shakedown_mod.alloc.NoResize.init(gpa);
    try std.testing.checkAllAllocationFailures(no_resize.allocator(), struct {
        fn query(a: Allocator, loaded: *const Attrs) !void {
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            const result = try loaded.lookup(arena.allocator(), &@as([1800]u8, @splat('a')), false);
            try std.testing.expect(result.isSet("text"));
            try std.testing.expectEqualStrings("long", result.value("diff").?);
        }
    }.query, .{&attrs});
}
