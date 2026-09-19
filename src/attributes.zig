//! `.gitattributes`, and the line-ending conversion it drives.
//!
//! Only the attributes that change the bytes of a blob are interpreted here:
//! `text`, `eol`, and the two that mean this release cannot produce the blob
//! git would — `working-tree-encoding` and a named `filter`. Every other
//! attribute is read, stored and handed back, so a caller may act on `diff`,
//! `merge` or one of its own without this package having an opinion.
//!
//! The conversion decision uses git's *check-in* binary rule and not the diff
//! one. They are different rules and using the diff rule here would normalise
//! a file git leaves alone, which produces a different blob and therefore a
//! different tree.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const wildmatch = @import("wildmatch.zig");
const fs = @import("fs.zig");

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
    /// Higher wins. `info/attributes` is highest, then the deepest
    /// `.gitattributes`, down to the global file.
    precedence: u32,
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
    gpa: Allocator,
    arena: *std.heap.ArenaAllocator,
    levels: std.ArrayList(Level),
    macros: std.ArrayList(Macro),
    case_fold: bool,

    /// An `[attr]name …` line: a name that expands to a list of
    /// assignments.
    pub const Macro = struct {
        name: []const u8,
        assignments: []Assignment,
    };

    /// Empty attributes, plus git's one built-in macro.
    ///
    /// `binary` is `-diff -merge -text`, which git defines itself; a
    /// repository that never writes a `[attr]binary` line still has it.
    pub fn init(gpa: Allocator, case_fold: bool) Allocator.Error!Attrs {
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
            .case_fold = case_fold,
        };
        const a = arena.allocator();
        const builtin_binary = try a.alloc(Assignment, 3);
        builtin_binary[0] = .{ .name = "diff", .state = .unset };
        builtin_binary[1] = .{ .name = "merge", .state = .unset };
        builtin_binary[2] = .{ .name = "text", .state = .unset };
        try attrs.macros.append(gpa, .{ .name = "binary", .assignments = builtin_binary });
        return attrs;
    }

    /// Release everything.
    pub fn deinit(attrs: *Attrs) void {
        attrs.arena.deinit();
        attrs.gpa.destroy(attrs.arena);
        attrs.levels.deinit(attrs.gpa);
        attrs.macros.deinit(attrs.gpa);
        attrs.* = undefined;
    }

    /// Load `info/attributes` from the common directory, at the highest
    /// precedence, and the global file at the lowest.
    pub fn loadGlobal(
        attrs: *Attrs,
        io: Io,
        common_dir: Io.Dir,
        attributes_file: ?[]const u8,
        attributes_dir: ?Io.Dir,
    ) Error!void {
        if (attributes_file) |path| {
            if (attributes_dir) |dir| {
                try attrs.addFileIfPresent(io, dir, path, "", path, global_precedence);
            }
        }
        try attrs.addFileIfPresent(io, common_dir, "info/attributes", "", "info/attributes", info_precedence);
    }

    /// Load `<base>/.gitattributes`, if it is there.
    ///
    /// `depth` is how far `base` is below the root of the working tree;
    /// deeper wins, so the precedence rises with it.
    pub fn addDirectory(attrs: *Attrs, io: Io, wt: Io.Dir, base: []const u8, depth: u32) Error!void {
        var path_buf: [4096]u8 = undefined;
        const path = if (base.len == 0)
            ".gitattributes"
        else
            std.fmt.bufPrint(&path_buf, "{s}/.gitattributes", .{base}) catch return;
        try attrs.addFileIfPresent(io, wt, path, base, path, depth + 1);
    }

    fn addFileIfPresent(
        attrs: *Attrs,
        io: Io,
        dir: Io.Dir,
        path: []const u8,
        base: []const u8,
        source: []const u8,
        precedence: u32,
    ) Error!void {
        const a = attrs.arena.allocator();
        const bytes = (try fs.readFileAlloc(a, io, dir, path, 1 << 24)) orelse return;
        try attrs.addText(bytes, base, source, precedence);
    }

    /// Add a level from text already in memory, which must outlive the
    /// attributes.
    pub fn addText(attrs: *Attrs, text: []const u8, base: []const u8, source: []const u8, precedence: u32) Error!void {
        const a = attrs.arena.allocator();
        var rules: std.ArrayList(Rule) = .empty;
        var line_number: u32 = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw_line| {
            line_number += 1;
            var line = raw_line;
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            line = std.mem.trim(u8, line, " \t");
            if (line.len == 0 or line[0] == '#') continue;

            if (std.mem.startsWith(u8, line, "[attr]")) {
                const rest = std.mem.trim(u8, line["[attr]".len..], " \t");
                const space = std.mem.indexOfAny(u8, rest, " \t") orelse continue;
                const name = rest[0..space];
                const assignments = try parseAssignments(a, rest[space + 1 ..]);
                try attrs.macros.append(attrs.gpa, .{ .name = name, .assignments = assignments });
                continue;
            }

            const parsed = parsePattern(line) orelse continue;
            const assignments = try parseAssignments(a, parsed.rest);
            if (assignments.len == 0) continue;
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
        try attrs.levels.append(attrs.gpa, .{
            .base = base,
            .rules = rules.items,
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
                _ = attrs.levels.orderedRemove(i);
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
        var order = try a.alloc(*const Level, attrs.levels.items.len);
        defer a.free(order);
        for (attrs.levels.items, 0..) |*level, i| order[i] = level;
        std.mem.sort(*const Level, order, {}, higherPrecedenceFirst);

        for (order) |level| {
            const relative = relativeTo(level.base, path) orelse continue;
            const name = basename(relative);
            var i = level.rules.len;
            while (i > 0) {
                i -= 1;
                const rule = level.rules[i];
                if (rule.dir_only and !is_dir) continue;
                const subject = if (rule.anchored) relative else name;
                const matched = wildmatch.match(rule.glob, subject, .{
                    .pathname = rule.anchored,
                    .case_fold = attrs.case_fold,
                }) catch false;
                if (!matched) continue;
                try attrs.applyAssignments(a, &out, rule.assignments, 0);
            }
        }
        return .{ .items = out.items };
    }

    fn applyAssignments(
        attrs: *const Attrs,
        a: Allocator,
        out: *std.ArrayList(Assignment),
        assignments: []const Assignment,
        depth: u8,
    ) Allocator.Error!void {
        // A macro may name another macro; the depth cap is what stops two
        // macros naming each other.
        if (depth > 8) return;
        for (assignments) |assignment| {
            if (attrs.macroNamed(assignment.name)) |macro| {
                if (assignment.state.isSet()) {
                    try attrs.applyAssignments(a, out, macro.assignments, depth + 1);
                }
            }
            var already = false;
            for (out.items) |existing| {
                if (std.mem.eql(u8, existing.name, assignment.name)) {
                    already = true;
                    break;
                }
            }
            if (!already) try out.append(a, assignment);
        }
    }

    fn macroNamed(attrs: *const Attrs, name: []const u8) ?Macro {
        for (attrs.macros.items) |macro| {
            if (std.mem.eql(u8, macro.name, name)) return macro;
        }
        return null;
    }

    fn higherPrecedenceFirst(_: void, a: *const Level, b: *const Level) bool {
        return a.precedence > b.precedence;
    }
};

fn basename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| return path[slash + 1 ..];
    return path;
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

fn parsePattern(line: []const u8) ?ParsedPattern {
    var i: usize = 0;
    var glob: []const u8 = undefined;
    if (line[0] == '"') {
        // A quoted pattern carries spaces. The quotes are dropped and the
        // escapes inside are left as they are, which is what the matcher
        // handles anyway.
        const end = std.mem.indexOfScalarPos(u8, line, 1, '"') orelse return null;
        glob = line[1..end];
        i = end + 1;
    } else {
        const space = std.mem.indexOfAny(u8, line, " \t") orelse return null;
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
    } else if (std.mem.indexOfScalar(u8, glob, '/') != null) {
        anchored = true;
    }
    if (glob.len == 0) return null;
    return .{ .glob = glob, .anchored = anchored, .dir_only = dir_only, .rest = line[i..] };
}

fn parseAssignments(a: Allocator, text: []const u8) Allocator.Error![]Assignment {
    var out: std.ArrayList(Assignment) = .empty;
    errdefer out.deinit(a);
    var it = std.mem.tokenizeAny(u8, text, " \t");
    while (it.next()) |word| {
        if (word.len == 0) continue;
        if (word[0] == '-') {
            try out.append(a, .{ .name = word[1..], .state = .unset });
        } else if (word[0] == '!') {
            try out.append(a, .{ .name = word[1..], .state = .unspecified });
        } else if (std.mem.indexOfScalar(u8, word, '=')) |eq| {
            try out.append(a, .{ .name = word[0..eq], .state = .{ .value = word[eq + 1 ..] } });
        } else {
            try out.append(a, .{ .name = word, .state = .set });
        }
    }
    return out.toOwnedSlice(a);
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

    pub const AutoCrlf = enum { false, true, input };
    pub const Eol = enum { native, lf, crlf };
    pub const SafeCrlf = enum { false, true, warn };

    /// The native line ending, which is CRLF on Windows and LF elsewhere.
    pub const native_is_crlf = @import("builtin").os.tag == .windows;
};

/// A setting this release does not implement, named so the caller is refused
/// rather than handed a blob git would not write.
pub const Unsupported = union(enum) {
    /// `working-tree-encoding=<name>`. Converting to and from it is a
    /// character-set conversion this package does not do.
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
    if (a.value("working-tree-encoding")) |encoding| {
        return .{ .working_tree_encoding = encoding };
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
    return std.mem.indexOfScalar(u8, window, 0) != null;
}

/// How many bytes either binary rule looks at.
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

/// Count the things git's check-in rule looks at, over the first 8000 bytes.
pub fn gatherStats(bytes: []const u8) TextStat {
    var stat: TextStat = .{};
    const window = bytes[0..@min(bytes.len, first_few_bytes)];
    var i: usize = 0;
    while (i < window.len) : (i += 1) {
        const c = window[i];
        switch (c) {
            '\r' => {
                if (i + 1 < window.len and window[i + 1] == '\n') {
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
    return stat;
}

/// git's *check-in* binary rule: a lone carriage return, or a NUL, or more
/// than one non-printable byte per 128 printable ones.
///
/// This is the rule `text=auto` and `core.autocrlf` consult. It is stricter
/// than the diff rule in one direction and looser in another, and using the
/// wrong one writes a blob git would not write.
pub fn isBinaryForCheckIn(bytes: []const u8) bool {
    const stat = gatherStats(bytes);
    if (stat.lonecr != 0) return true;
    if (stat.nul) return true;
    if ((stat.printable >> 7) < stat.nonprintable) return true;
    return false;
}

/// What a conversion decided.
pub const Conversion = struct {
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

/// Whether the bytes are normalised on the way into the object database.
fn convertsOnCheckIn(a: Attributes, core: CoreSettings, bytes: []const u8) bool {
    if (a.get("text")) |state| {
        switch (state) {
            .unset, .unspecified => return false,
            .set => return true,
            .value => |v| {
                if (std.mem.eql(u8, v, "auto")) return !isBinaryForCheckIn(bytes);
                return true;
            },
        }
    }
    return switch (core.autocrlf) {
        .false => false,
        .true, .input => !isBinaryForCheckIn(bytes),
    };
}

/// Normalise for storage: CRLF becomes LF where the attributes and the
/// configuration say the file is text.
///
/// This is the call that decides a blob's name. Getting it wrong produces a
/// tree git disagrees with, which is the one thing this package is for.
pub fn toGit(gpa: Allocator, bytes: []const u8, a: Attributes, core: CoreSettings) Allocator.Error!Conversion {
    if (!convertsOnCheckIn(a, core, bytes)) return .{ .bytes = bytes, .owned = false };
    if (std.mem.indexOfScalar(u8, bytes, '\r') == null) return .{ .bytes = bytes, .owned = false };

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

/// Whether the bytes get CRLF endings on the way out to the working tree.
fn convertsOnCheckout(a: Attributes, core: CoreSettings, bytes: []const u8) bool {
    if (a.get("eol")) |state| {
        switch (state) {
            .value => |v| {
                if (std.mem.eql(u8, v, "crlf")) return true;
                if (std.mem.eql(u8, v, "lf")) return false;
            },
            else => {},
        }
    }
    const text_state = a.get("text");
    if (text_state) |state| {
        switch (state) {
            .unset, .unspecified => return false,
            .set => {},
            .value => |v| {
                if (std.mem.eql(u8, v, "auto") and isBinaryForCheckIn(bytes)) return false;
            },
        }
        // The file is text; `core.eol` decides the ending.
        return switch (core.eol) {
            .lf => false,
            .crlf => true,
            .native => CoreSettings.native_is_crlf,
        };
    }
    // No `text` attribute: only `core.autocrlf = true` converts, and only
    // for a file the check-in rule calls text.
    if (core.autocrlf != .true) return false;
    return !isBinaryForCheckIn(bytes);
}

/// Convert for the working tree: LF becomes CRLF where the attributes and
/// the configuration ask for it.
pub fn toWorktree(gpa: Allocator, bytes: []const u8, a: Attributes, core: CoreSettings) Allocator.Error!Conversion {
    if (!convertsOnCheckout(a, core, bytes)) return .{ .bytes = bytes, .owned = false };
    if (std.mem.indexOfScalar(u8, bytes, '\n') == null) return .{ .bytes = bytes, .owned = false };

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
    var attrs: Attrs = try .init(gpa, false);
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
    var attrs: Attrs = try .init(gpa, false);
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
    var attrs: Attrs = try .init(gpa, false);
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
    var attrs: Attrs = try .init(gpa, false);
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
    var attrs: Attrs = try .init(gpa, false);
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

test "a deeper file wins, and info/attributes wins over both" {
    const gpa = std.testing.allocator;
    var attrs: Attrs = try .init(gpa, false);
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
    var attrs: Attrs = try .init(gpa, false);
    defer attrs.deinit();
    try attrs.addText("*.po working-tree-encoding=UTF-16\n*.lfs filter=lfs\n", "", ".gitattributes", 1);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const po = try attrs.lookup(arena.allocator(), "a.po", false);
    const refused = unsupported(po, &.{}).?;
    try std.testing.expectEqualStrings("working-tree-encoding", refused.settingName());
    try std.testing.expectEqualStrings("UTF-16", refused.settingValue());

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
    var attrs: Attrs = try .init(gpa, false);
    defer attrs.deinit();
    attrs.addText(text, "", "fuzz", 1) catch return;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = attrs.lookup(arena.allocator(), path, false) catch return;
    _ = unsupported(a, &.{"lfs"});
    const converted = toGit(gpa, text, a, .{ .autocrlf = .true }) catch return;
    converted.deinit(gpa);
}
