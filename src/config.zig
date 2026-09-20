//! git's configuration files, read losslessly and written back the same way.
//!
//! A file is kept as the lines it was made of, so setting one value rewrites
//! one line and leaves every comment, every blank line and every other value's
//! spelling exactly as it was. That is the difference between a configuration
//! writer a person can live with and one that reformats their file.
//!
//! `includeIf` is not optional. A caller that misses one reads the wrong
//! `core.autocrlf` and therefore writes a different blob than git would.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const fs = @import("fs.zig");

/// Errors from reading a configuration file.
pub const ParseError = error{
    /// A `[` with no `]`, or a section name holding a character git does not
    /// allow.
    MalformedSectionHeader,
    /// A name holding a character that is not a letter, a digit or `-`, or
    /// one that does not begin with a letter.
    InvalidVariableName,
    /// A quoted value with no closing quote, or an unknown escape.
    MalformedValue,
    /// A variable before any section header.
    VariableOutsideSection,
    /// `include.path` or an `includeIf` nested deeper than the cap.
    IncludeTooDeep,
} || Allocator.Error || Io.Dir.ReadFileAllocError;

/// Errors from asking for a value in a particular shape.
pub const ValueError = error{
    /// The value was not one of git's boolean spellings.
    NotABoolean,
    /// The value was not a number, with or without a `k`, `m` or `g`.
    NotAnInteger,
} || Allocator.Error;

/// One line of a configuration file, in the order the file holds them.
///
/// A `.section` line opens a section; a `.variable` line sets a value; a
/// `.other` line is a comment, a blank line, or anything else, and is copied
/// through untouched.
const Line = struct {
    kind: Kind,
    /// The whole line including its terminator, borrowed from the file's
    /// text or owned by the file after an edit.
    text: []const u8,
    owned: bool = false,
    /// For a `.section` line: the normalised section and subsection.
    section: []const u8 = "",
    subsection: []const u8 = "",
    has_subsection: bool = false,
    /// For a `.variable` line: the normalised name, and the span of the
    /// value inside `text`.
    name: []const u8 = "",
    value_start: usize = 0,
    value_end: usize = 0,
    /// Whether the variable had an `=` at all. A bare name means true.
    has_value: bool = false,

    const Kind = enum { section, variable, other };
};

/// Where a value came from, which is what decides precedence when two files
/// set the same name.
pub const Level = enum {
    /// `$(prefix)/etc/gitconfig`, or whatever the caller names.
    system,
    /// `~/.gitconfig` or `$XDG_CONFIG_HOME/git/config`.
    global,
    /// The repository's own `.git/config`.
    local,
    /// `.git/config.worktree`, when `extensions.worktreeConfig` is on.
    worktree,
    /// Values a caller supplied directly, which beat every file.
    command,
};

/// One configuration file, parsed into lines.
pub const SourceFile = struct {
    gpa: Allocator,
    level: Level,
    /// The path this was read from, for reporting. Owned.
    path: []const u8,
    /// The file's bytes. Owned.
    text: []const u8,
    lines: std.ArrayList(Line),
    /// Whether this file is one `set` may write to.
    writable: bool,

    /// Release the file.
    pub fn deinit(f: *SourceFile) void {
        for (f.lines.items) |line| {
            if (line.owned) f.gpa.free(line.text);
        }
        f.lines.deinit(f.gpa);
        f.gpa.free(f.text);
        f.gpa.free(f.path);
        f.* = undefined;
    }

    /// The file's current bytes, after any edits. The result is the caller's.
    pub fn render(f: *const SourceFile) Allocator.Error![]u8 {
        var out: std.Io.Writer.Allocating = .init(f.gpa);
        errdefer out.deinit();
        for (f.lines.items) |line| {
            out.writer.writeAll(line.text) catch return error.OutOfMemory;
        }
        return out.toOwnedSlice();
    }
};

/// One name and value, with where it came from.
pub const Entry = struct {
    /// Lower-case.
    section: []const u8,
    /// Case-sensitive, empty when there is none.
    subsection: []const u8,
    /// Lower-case.
    name: []const u8,
    /// `null` for a bare name, which git reads as true.
    value: ?[]const u8,
    level: Level,
    /// Which `SourceFile` it came from.
    file_index: u32,
    /// Which line of that file.
    line_index: u32,

    /// Whether this entry is the one `full_name` asks for.
    ///
    /// The section and the variable are compared without case; the
    /// subsection is compared exactly, which is git's rule and the reason
    /// `[remote "Origin"]` and `[remote "origin"]` are two remotes.
    pub fn matches(e: Entry, section: []const u8, subsection: ?[]const u8, name: []const u8) bool {
        if (!std.ascii.eqlIgnoreCase(e.section, section)) return false;
        if (!std.ascii.eqlIgnoreCase(e.name, name)) return false;
        if (subsection) |sub| return std.mem.eql(u8, e.subsection, sub);
        return e.subsection.len == 0;
    }
};

/// What `open` is asked to read, in git's own order.
pub const Sources = struct {
    /// The system file, if any.
    system: ?Path = null,
    /// The global file, if any.
    global: ?Path = null,
    /// The repository's `.git/config`.
    local: ?Path = null,
    /// `.git/config.worktree`, when `extensions.worktreeConfig` is on.
    worktree: ?Path = null,
    /// Values that beat every file, as `name=value` pairs with the name in
    /// full — `core.autocrlf=input`. Borrowed for the call.
    command: []const []const u8 = &.{},

    /// A file to read, named relative to a directory.
    pub const Path = struct {
        dir: Io.Dir,
        sub_path: []const u8,
    };
};

/// What an `includeIf` condition needs to know about the repository.
///
/// The caller supplies it, because this package reads no environment and has
/// no opinion about where a repository is.
pub const Context = struct {
    /// The absolute path of the `.git` directory, `/`-separated, for
    /// `gitdir:` and `gitdir/i:`.
    git_dir: ?[]const u8 = null,
    /// The branch `HEAD` points at, without `refs/heads/`, for `onbranch:`.
    branch: ?[]const u8 = null,
    /// The user's home directory, for a condition or an include path
    /// beginning `~/`.
    home: ?[]const u8 = null,
};

/// How deep `include.path` may nest before it is refused.
pub const max_include_depth: u8 = 10;

/// A merged view of every configuration file that applies.
pub const Config = struct {
    gpa: Allocator,
    files: std.ArrayList(SourceFile) = .empty,
    entries: std.ArrayList(Entry) = .empty,
    context: Context = .{},

    /// An empty configuration, which answers `null` to everything.
    pub fn initEmpty(gpa: Allocator) Config {
        return .{ .gpa = gpa };
    }

    /// Read every source that is there, in git's order: system, then global,
    /// then local, then worktree, then the caller's own values.
    pub fn open(gpa: Allocator, io: Io, sources: Sources, context: Context) ParseError!Config {
        var config: Config = .{ .gpa = gpa, .context = context };
        errdefer config.deinit();

        if (sources.system) |p| try config.addFile(io, p, .system, false, 0);
        if (sources.global) |p| try config.addFile(io, p, .global, false, 0);
        if (sources.local) |p| try config.addFile(io, p, .local, true, 0);
        if (sources.worktree) |p| try config.addFile(io, p, .worktree, true, 0);
        if (sources.command.len != 0) try config.addCommandValues(sources.command);
        return config;
    }

    /// Read one file as the whole configuration. What a tool inspecting a
    /// single file wants.
    pub fn openFile(gpa: Allocator, io: Io, path: Sources.Path, level: Level, context: Context) ParseError!Config {
        var config: Config = .{ .gpa = gpa, .context = context };
        errdefer config.deinit();
        try config.addFile(io, path, level, true, 0);
        return config;
    }

    /// Parse configuration text with no file behind it.
    pub fn parseText(gpa: Allocator, text: []const u8, level: Level) ParseError!Config {
        var config: Config = .{ .gpa = gpa };
        errdefer config.deinit();
        const owned_text = try gpa.dupe(u8, text);
        const owned_path = gpa.dupe(u8, "<text>") catch |err| {
            gpa.free(owned_text);
            return err;
        };
        try config.addParsedFile(owned_path, owned_text, level, false);
        return config;
    }

    /// Release everything.
    pub fn deinit(config: *Config) void {
        for (config.files.items) |*f| f.deinit();
        config.files.deinit(config.gpa);
        config.entries.deinit(config.gpa);
        config.* = undefined;
    }

    fn addFile(config: *Config, io: Io, path: Sources.Path, level: Level, writable: bool, depth: u8) ParseError!void {
        if (depth > max_include_depth) return error.IncludeTooDeep;
        const text = (try fs.readFileAlloc(config.gpa, io, path.dir, path.sub_path, 1 << 24)) orelse return;
        const owned_path = config.gpa.dupe(u8, path.sub_path) catch |err| {
            config.gpa.free(text);
            return err;
        };
        // `addParsedFile` takes both, and its own errdefer frees them.
        const first_entry = config.entries.items.len;
        try config.addParsedFile(owned_path, text, level, writable);
        try config.followIncludes(io, path.dir, level, first_entry, depth);
    }

    fn addParsedFile(config: *Config, path: []const u8, text: []const u8, level: Level, writable: bool) ParseError!void {
        var file: SourceFile = .{
            .gpa = config.gpa,
            .level = level,
            .path = path,
            .text = text,
            .lines = .empty,
            .writable = writable,
        };
        errdefer file.deinit();
        try parseLines(config.gpa, text, &file.lines);

        const file_index: u32 = @intCast(config.files.items.len);
        var section: []const u8 = "";
        var subsection: []const u8 = "";
        for (file.lines.items, 0..) |line, i| {
            switch (line.kind) {
                .section => {
                    section = line.section;
                    subsection = line.subsection;
                },
                .variable => try config.entries.append(config.gpa, .{
                    .section = section,
                    .subsection = subsection,
                    .name = line.name,
                    .value = if (line.has_value) line.text[line.value_start..line.value_end] else null,
                    .level = level,
                    .file_index = file_index,
                    .line_index = @intCast(i),
                }),
                .other => {},
            }
        }
        try config.files.append(config.gpa, file);
    }

    fn addCommandValues(config: *Config, values: []const []const u8) ParseError!void {
        // A command-line value is `section.name=value` or
        // `section.sub.name=value`; it is turned into a one-line file so it
        // goes through exactly the same parser as everything else.
        var text: std.Io.Writer.Allocating = .init(config.gpa);
        errdefer text.deinit();
        for (values) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=');
            const full = if (eq) |at| pair[0..at] else pair;
            const value = if (eq) |at| pair[at + 1 ..] else null;
            const split = splitFullName(full) orelse continue;
            if (split.subsection) |sub| {
                text.writer.print("[{s} \"{s}\"]\n", .{ split.section, sub }) catch return error.OutOfMemory;
            } else {
                text.writer.print("[{s}]\n", .{split.section}) catch return error.OutOfMemory;
            }
            if (value) |v| {
                text.writer.print("\t{s} = {s}\n", .{ split.name, v }) catch return error.OutOfMemory;
            } else {
                text.writer.print("\t{s}\n", .{split.name}) catch return error.OutOfMemory;
            }
        }
        const owned_text = try text.toOwnedSlice();
        const owned_path = config.gpa.dupe(u8, "<command line>") catch |err| {
            config.gpa.free(owned_text);
            return err;
        };
        try config.addParsedFile(owned_path, owned_text, .command, false);
    }

    fn followIncludes(config: *Config, io: Io, dir: Io.Dir, level: Level, from: usize, depth: u8) ParseError!void {
        if (from == config.entries.items.len) return;
        const source_file_index = config.entries.items[from].file_index;
        var i = from;
        while (i < config.entries.items.len) : (i += 1) {
            const entry = config.entries.items[i];
            if (entry.file_index != source_file_index) break;
            const value = entry.value orelse continue;
            var include_path: ?[]const u8 = null;
            if (std.ascii.eqlIgnoreCase(entry.section, "include") and
                std.ascii.eqlIgnoreCase(entry.name, "path"))
            {
                include_path = value;
            } else if (std.ascii.eqlIgnoreCase(entry.section, "includeif") and
                std.ascii.eqlIgnoreCase(entry.name, "path"))
            {
                if (try config.conditionHolds(entry.subsection)) include_path = value;
            }
            const path = include_path orelse continue;

            var buf: [4096]u8 = undefined;
            const including_path = config.files.items[entry.file_index].path;
            const resolved = config.resolveIncludePath(path, including_path, &buf) orelse continue;
            config.addFile(io, .{ .dir = dir, .sub_path = resolved }, level, false, depth + 1) catch |err| switch (err) {
                error.IncludeTooDeep => return err,
                // git treats an unreadable or malformed include as absent.
                else => continue,
            };
        }
    }

    fn resolveIncludePath(config: *const Config, path: []const u8, including_path: []const u8, buf: []u8) ?[]const u8 {
        if (std.mem.startsWith(u8, path, "~/")) {
            const home = config.context.home orelse return null;
            return std.fmt.bufPrint(buf, "{s}/{s}", .{ home, path[2..] }) catch null;
        }
        if (std.fs.path.isAbsolute(path)) return path;
        if (std.fs.path.dirname(including_path)) |parent| {
            if (parent.len != 0) return std.fmt.bufPrint(buf, "{s}/{s}", .{ parent, path }) catch null;
        }
        return path;
    }

    /// Whether an `includeIf` condition holds.
    ///
    /// `gitdir:` and `gitdir/i:` match the `.git` directory against a glob,
    /// with git's own rules: a pattern ending `/` gains `**`, a pattern that
    /// is neither absolute nor `~/` nor `./` gains a leading `**/`.
    /// `onbranch:` matches the branch `HEAD` is on.
    pub fn conditionHolds(config: *const Config, condition: []const u8) ParseError!bool {
        const wildmatch = @import("wildmatch.zig");
        if (std.mem.startsWith(u8, condition, "gitdir:") or std.mem.startsWith(u8, condition, "gitdir/i:")) {
            const case_fold = std.mem.startsWith(u8, condition, "gitdir/i:");
            const pattern_raw = condition[if (case_fold) "gitdir/i:".len else "gitdir:".len..];
            const git_dir = config.context.git_dir orelse return false;
            var buf: [4096]u8 = undefined;
            const pattern = config.expandCondition(pattern_raw, &buf) orelse return false;
            return wildmatch.match(pattern, git_dir, .{ .pathname = true, .case_fold = case_fold }) catch false;
        }
        if (std.mem.startsWith(u8, condition, "onbranch:")) {
            const pattern_raw = condition["onbranch:".len..];
            const branch = config.context.branch orelse return false;
            var buf: [4096]u8 = undefined;
            const pattern = if (std.mem.endsWith(u8, pattern_raw, "/"))
                std.fmt.bufPrint(&buf, "{s}**", .{pattern_raw}) catch return false
            else
                pattern_raw;
            return wildmatch.match(pattern, branch, .{ .pathname = true }) catch false;
        }
        // `hasconfig:` and anything else this release does not implement
        // never holds, which is the safe direction: a condition that is
        // wrongly true reads settings that do not apply.
        return false;
    }

    fn expandCondition(config: *const Config, pattern: []const u8, buf: []u8) ?[]const u8 {
        var text = pattern;
        var scratch: [4096]u8 = undefined;
        if (std.mem.startsWith(u8, text, "~/")) {
            const home = config.context.home orelse return null;
            text = std.fmt.bufPrint(&scratch, "{s}/{s}", .{ home, text[2..] }) catch return null;
        } else if (!std.mem.startsWith(u8, text, "/") and !std.mem.startsWith(u8, text, "**") and
            !(text.len >= 2 and text[1] == ':'))
        {
            text = std.fmt.bufPrint(&scratch, "**/{s}", .{text}) catch return null;
        }
        if (std.mem.endsWith(u8, text, "/")) {
            return std.fmt.bufPrint(buf, "{s}**", .{text}) catch null;
        }
        return std.fmt.bufPrint(buf, "{s}", .{text}) catch null;
    }

    /// The value of `full_name`, or `null`.
    ///
    /// The last value in the last file that sets it wins, which is git's
    /// rule. A bare name — one written with no `=` — reads as the empty
    /// string here and as true from `getBool`.
    pub fn get(config: *const Config, full_name: []const u8) ?[]const u8 {
        const split = splitFullName(full_name) orelse return null;
        var found: ?[]const u8 = null;
        for (config.entries.items) |entry| {
            if (!entry.matches(split.section, split.subsection, split.name)) continue;
            found = entry.value orelse "";
        }
        return found;
    }

    /// The last entry setting `full_name`, or `null`.
    ///
    /// A caller that needs to tell a bare name from an empty value, or that
    /// wants to know which file and line decided, asks here.
    pub fn find(config: *const Config, full_name: []const u8) ?Entry {
        const split = splitFullName(full_name) orelse return null;
        var found: ?Entry = null;
        for (config.entries.items) |entry| {
            if (!entry.matches(split.section, split.subsection, split.name)) continue;
            found = entry;
        }
        return found;
    }

    /// Which file and line last set `full_name`, as a path and a one-based
    /// line number. `null` when it is not set.
    pub fn origin(config: *const Config, full_name: []const u8) ?struct { path: []const u8, line: u32, level: Level } {
        const entry = config.find(full_name) orelse return null;
        return .{
            .path = config.files.items[entry.file_index].path,
            .line = entry.line_index + 1,
            .level = entry.level,
        };
    }

    /// Every value of `full_name`, oldest first. The result is the caller's;
    /// the slices borrow the configuration.
    pub fn all(config: *const Config, full_name: []const u8) Allocator.Error![][]const u8 {
        const split = splitFullName(full_name) orelse return &.{};
        var out: std.ArrayList([]const u8) = .empty;
        errdefer out.deinit(config.gpa);
        for (config.entries.items) |entry| {
            if (!entry.matches(split.section, split.subsection, split.name)) continue;
            try out.append(config.gpa, entry.value orelse "");
        }
        return out.toOwnedSlice(config.gpa);
    }

    /// Whether `full_name` is set at all.
    pub fn has(config: *const Config, full_name: []const u8) bool {
        return config.get(full_name) != null;
    }

    /// The value of `full_name` as a boolean, or `fallback` when it is not
    /// set.
    ///
    /// git's spellings: `true`, `yes`, `on`, `1` and a bare name are true;
    /// `false`, `no`, `off`, `0` and the empty string are false.
    pub fn getBool(config: *const Config, full_name: []const u8, fallback: bool) ValueError!bool {
        const entry = config.find(full_name) orelse return fallback;
        // A name written with no `=` at all is true; a name written with an
        // `=` and nothing after it is false. git makes that distinction and
        // `core.bare` in a bare repository relies on it.
        const raw = entry.value orelse return true;
        const decoded = decodeValue(config.gpa, raw) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MalformedValue => return error.NotABoolean,
        };
        defer config.gpa.free(decoded);
        return parseBool(decoded);
    }

    /// The value of `full_name` as an integer, or `fallback`.
    ///
    /// A `k`, `m` or `g` suffix multiplies by 1024, 1024² or 1024³, which is
    /// what git accepts for a size.
    pub fn getInt(config: *const Config, full_name: []const u8, fallback: i64) ValueError!i64 {
        const raw = config.get(full_name) orelse return fallback;
        const decoded = decodeValue(config.gpa, raw) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MalformedValue => return error.NotAnInteger,
        };
        defer config.gpa.free(decoded);
        return parseInt(decoded);
    }

    /// The value of `full_name` as a path, with a leading `~/` expanded
    /// against `Context.home`. The result is the caller's.
    pub fn getPath(config: *const Config, gpa: Allocator, full_name: []const u8) (Allocator.Error || error{MalformedValue})!?[]u8 {
        const raw = config.get(full_name) orelse return null;
        const decoded = try decodeValue(gpa, raw);
        if (std.mem.startsWith(u8, decoded, "~/")) {
            const home = config.context.home orelse return decoded;
            defer gpa.free(decoded);
            return try std.fmt.allocPrint(gpa, "{s}/{s}", .{ home, decoded[2..] });
        }
        return decoded;
    }

    /// Every subsection name under `section`, in order and without
    /// duplicates. The result is the caller's; the slices borrow the
    /// configuration.
    ///
    /// This is how a caller lists the remotes, or the branches with an
    /// upstream, without knowing their names in advance.
    pub fn subsections(config: *const Config, gpa: Allocator, section: []const u8) Allocator.Error![][]const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        errdefer out.deinit(gpa);
        for (config.entries.items) |entry| {
            if (!std.ascii.eqlIgnoreCase(entry.section, section)) continue;
            if (entry.subsection.len == 0) continue;
            var already = false;
            for (out.items) |seen| {
                if (std.mem.eql(u8, seen, entry.subsection)) {
                    already = true;
                    break;
                }
            }
            if (!already) try out.append(gpa, entry.subsection);
        }
        return out.toOwnedSlice(gpa);
    }

    /// Errors from changing a value.
    pub const SetError = error{
        /// No source was opened that may be written to.
        NoWritableSource,
    } || Allocator.Error || fs.LockError || fs.CommitError;

    /// Set `full_name` to `value` in the writable file, keeping every
    /// comment and every other line exactly as it was.
    ///
    /// An existing value's line is rewritten in place. A new value is
    /// appended to the end of its section, or a new section is appended to
    /// the end of the file. Nothing else in the file moves.
    pub fn set(config: *Config, full_name: []const u8, value: []const u8) SetError!void {
        const split = splitFullName(full_name) orelse return error.NoWritableSource;
        const file_index = config.writableFileIndex() orelse return error.NoWritableSource;
        const file = &config.files.items[file_index];

        // The last matching line wins on read, so that is the one to change.
        var target: ?usize = null;
        var section_end: ?usize = null;
        var section: []const u8 = "";
        var subsection: []const u8 = "";
        for (file.lines.items, 0..) |line, i| {
            switch (line.kind) {
                .section => {
                    section = line.section;
                    subsection = line.subsection;
                },
                .variable => {
                    if (std.ascii.eqlIgnoreCase(section, split.section) and
                        std.mem.eql(u8, subsection, split.subsection orelse ""))
                    {
                        section_end = i + 1;
                        if (std.ascii.eqlIgnoreCase(line.name, split.name)) target = i;
                    }
                },
                // A comment or a blank line does not move the insertion
                // point: git appends a new variable after the section's last
                // *variable*, which keeps a trailing blank line where the
                // person who wrote it put it.
                .other => {},
            }
        }

        if (target) |i| {
            const line = &file.lines.items[i];
            const escaped = try escapeValue(config.gpa, value);
            defer config.gpa.free(escaped);
            const replacement = if (line.has_value)
                try std.fmt.allocPrint(config.gpa, "{s}{s}{s}", .{
                    line.text[0..line.value_start],
                    escaped,
                    line.text[line.value_end..],
                })
            else blk: {
                var name_start: usize = 0;
                while (name_start < line.text.len and (line.text[name_start] == ' ' or line.text[name_start] == '\t')) {
                    name_start += 1;
                }
                const name_end = name_start + line.name.len;
                break :blk try std.fmt.allocPrint(config.gpa, "{s} = {s}{s}", .{
                    line.text[0..name_end],
                    escaped,
                    line.text[name_end..],
                });
            };
            const parsed = parseVariableLine(replacement) catch unreachable;
            if (line.owned) config.gpa.free(line.text);
            line.text = replacement;
            line.owned = true;
            line.name = parsed.name;
            line.value_start = parsed.value_start;
            line.value_end = parsed.value_end;
            line.has_value = parsed.has_value;
        } else {
            const escaped = try escapeValue(config.gpa, value);
            defer config.gpa.free(escaped);
            const text = try std.fmt.allocPrint(config.gpa, "\t{s} = {s}\n", .{ split.name, escaped });
            errdefer config.gpa.free(text);
            const value_start = 1 + split.name.len + 3;
            const new_line: Line = .{
                .kind = .variable,
                .text = text,
                .owned = true,
                .name = text[1 .. 1 + split.name.len],
                .value_start = value_start,
                .value_end = text.len - 1,
                .has_value = true,
            };
            if (section_end) |at| {
                try file.lines.insert(config.gpa, at, new_line);
            } else {
                const header = if (split.subsection) |sub|
                    try std.fmt.allocPrint(config.gpa, "[{s} \"{s}\"]\n", .{ split.section, sub })
                else
                    try std.fmt.allocPrint(config.gpa, "[{s}]\n", .{split.section});
                errdefer config.gpa.free(header);
                try file.lines.append(config.gpa, .{
                    .kind = .section,
                    .text = header,
                    .owned = true,
                    .section = split.section,
                    .subsection = split.subsection orelse "",
                    .has_subsection = split.subsection != null,
                });
                try file.lines.append(config.gpa, new_line);
            }
        }
        try config.reindex();
    }

    /// Remove every setting of `full_name` from the writable file, keeping
    /// everything else exactly as it was.
    pub fn unset(config: *Config, full_name: []const u8) SetError!void {
        const split = splitFullName(full_name) orelse return error.NoWritableSource;
        const file_index = config.writableFileIndex() orelse return error.NoWritableSource;
        const file = &config.files.items[file_index];

        var section: []const u8 = "";
        var subsection: []const u8 = "";
        var i: usize = 0;
        while (i < file.lines.items.len) {
            const line = file.lines.items[i];
            switch (line.kind) {
                .section => {
                    section = line.section;
                    subsection = line.subsection;
                },
                .variable => {
                    if (std.ascii.eqlIgnoreCase(section, split.section) and
                        std.mem.eql(u8, subsection, split.subsection orelse "") and
                        std.ascii.eqlIgnoreCase(line.name, split.name))
                    {
                        if (line.owned) config.gpa.free(line.text);
                        _ = file.lines.orderedRemove(i);
                        continue;
                    }
                },
                .other => {},
            }
            i += 1;
        }
        try config.reindex();
    }

    fn writableFileIndex(config: *const Config) ?u32 {
        var found: ?u32 = null;
        for (config.files.items, 0..) |f, i| {
            if (f.writable) found = @intCast(i);
        }
        return found;
    }

    fn reindex(config: *Config) Allocator.Error!void {
        config.entries.clearRetainingCapacity();
        for (config.files.items, 0..) |*file, file_index| {
            var section: []const u8 = "";
            var subsection: []const u8 = "";
            for (file.lines.items, 0..) |line, i| {
                switch (line.kind) {
                    .section => {
                        section = line.section;
                        subsection = line.subsection;
                    },
                    .variable => try config.entries.append(config.gpa, .{
                        .section = section,
                        .subsection = subsection,
                        .name = line.name,
                        .value = if (line.has_value) line.text[line.value_start..line.value_end] else null,
                        .level = file.level,
                        .file_index = @intCast(file_index),
                        .line_index = @intCast(i),
                    }),
                    .other => {},
                }
            }
        }
    }

    /// Write the edited file back through `<path>.lock`.
    ///
    /// Nothing is written unless `set` or `unset` was called; the bytes are
    /// the original file with only the changed lines different.
    pub fn write(config: *Config, io: Io, dir: Io.Dir, sub_path: []const u8) SetError!void {
        const file_index = config.writableFileIndex() orelse return error.NoWritableSource;
        const file = &config.files.items[file_index];
        const bytes = try file.render();
        defer config.gpa.free(bytes);

        var buffer: [16 * 1024]u8 = undefined;
        var lock = try fs.LockFile.open(config.gpa, io, dir, sub_path, &buffer, .{});
        defer lock.deinit(io);
        lock.writer().writeAll(bytes) catch return error.WriteFailed;
        try lock.commit(io);
    }

    /// The bytes the writable file would be written as. The result is the
    /// caller's. What a test compares, and what a caller that wants to place
    /// the file itself asks for.
    pub fn renderWritable(config: *const Config) SetError![]u8 {
        const file_index = config.writableFileIndex() orelse return error.NoWritableSource;
        return config.files.items[file_index].render();
    }
};

/// A full name split into its parts: `remote.origin.url` is the section
/// `remote`, the subsection `origin` and the name `url`.
pub const FullName = struct {
    section: []const u8,
    subsection: ?[]const u8,
    name: []const u8,
};

/// Split `section.name` or `section.subsection.name`.
///
/// The subsection may itself hold dots — `url.https://example.com/.insteadOf`
/// is one — so the split is at the first dot and the last, not at every dot.
pub fn splitFullName(full: []const u8) ?FullName {
    const first = std.mem.indexOfScalar(u8, full, '.') orelse return null;
    const last = std.mem.lastIndexOfScalar(u8, full, '.').?;
    if (first == last) {
        return .{ .section = full[0..first], .subsection = null, .name = full[first + 1 ..] };
    }
    return .{
        .section = full[0..first],
        .subsection = full[first + 1 .. last],
        .name = full[last + 1 ..],
    };
}

/// git's boolean spellings.
pub fn parseBool(raw: []const u8) ValueError!bool {
    if (raw.len == 0) return false;
    const truthy = [_][]const u8{ "true", "yes", "on", "1" };
    const falsy = [_][]const u8{ "false", "no", "off", "0" };
    for (truthy) |t| {
        if (std.ascii.eqlIgnoreCase(raw, t)) return true;
    }
    for (falsy) |f| {
        if (std.ascii.eqlIgnoreCase(raw, f)) return false;
    }
    return error.NotABoolean;
}

/// git's integer spellings, including the `k`, `m` and `g` size suffixes.
pub fn parseInt(raw: []const u8) ValueError!i64 {
    var text = std.mem.trim(u8, raw, " \t");
    if (text.len == 0) return error.NotAnInteger;
    var multiplier: i64 = 1;
    switch (text[text.len - 1]) {
        'k', 'K' => {
            multiplier = 1024;
            text = text[0 .. text.len - 1];
        },
        'm', 'M' => {
            multiplier = 1024 * 1024;
            text = text[0 .. text.len - 1];
        },
        'g', 'G' => {
            multiplier = 1024 * 1024 * 1024;
            text = text[0 .. text.len - 1];
        },
        else => {},
    }
    const base = std.fmt.parseInt(i64, text, 10) catch return error.NotAnInteger;
    return std.math.mul(i64, base, multiplier) catch error.NotAnInteger;
}

/// Quote a value if it needs quoting, the way git writes one. The result is
/// the caller's.
pub fn escapeValue(gpa: Allocator, value: []const u8) Allocator.Error![]u8 {
    var needs_quotes = false;
    for (value) |c| {
        switch (c) {
            '"', '\\', '\n', '\t', ';', '#' => needs_quotes = true,
            else => {},
        }
    }
    if (value.len != 0 and (value[0] == ' ' or value[value.len - 1] == ' ')) needs_quotes = true;
    if (!needs_quotes) return gpa.dupe(u8, value);

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    out.writer.writeByte('"') catch return error.OutOfMemory;
    for (value) |c| {
        switch (c) {
            '"' => out.writer.writeAll("\\\"") catch return error.OutOfMemory,
            '\\' => out.writer.writeAll("\\\\") catch return error.OutOfMemory,
            '\n' => out.writer.writeAll("\\n") catch return error.OutOfMemory,
            '\t' => out.writer.writeAll("\\t") catch return error.OutOfMemory,
            else => out.writer.writeByte(c) catch return error.OutOfMemory,
        }
    }
    out.writer.writeByte('"') catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn parseLines(gpa: Allocator, text: []const u8, out: *std.ArrayList(Line)) ParseError!void {
    var offset: usize = 0;
    var have_section = false;
    while (offset < text.len) {
        var end = std.mem.indexOfScalarPos(u8, text, offset, '\n') orelse text.len;
        // A trailing backslash continues the line, which git allows for a
        // value spread over several lines.
        while (end < text.len) {
            var body_end = end;
            if (body_end > offset and text[body_end - 1] == '\r') body_end -= 1;
            if (body_end > offset and text[body_end - 1] == '\\') {
                end = std.mem.indexOfScalarPos(u8, text, end + 1, '\n') orelse text.len;
            } else break;
        }
        const line_end = if (end < text.len) end + 1 else end;
        const raw = text[offset..line_end];
        offset = line_end;

        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == ';') {
            try out.append(gpa, .{ .kind = .other, .text = raw });
            continue;
        }
        if (trimmed[0] == '[') {
            const header = try parseSectionHeader(trimmed);
            try out.append(gpa, .{
                .kind = .section,
                .text = raw,
                .section = header.section,
                .subsection = header.subsection orelse "",
                .has_subsection = header.subsection != null,
            });
            have_section = true;
            continue;
        }
        if (!have_section) return error.VariableOutsideSection;

        const variable = try parseVariableLine(raw);
        try out.append(gpa, .{
            .kind = .variable,
            .text = raw,
            .name = variable.name,
            .value_start = variable.value_start,
            .value_end = variable.value_end,
            .has_value = variable.has_value,
        });
    }
}

const SectionHeader = struct { section: []const u8, subsection: ?[]const u8 };

fn parseSectionHeader(trimmed: []const u8) ParseError!SectionHeader {
    if (trimmed[trimmed.len - 1] != ']') return error.MalformedSectionHeader;
    const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t");
    if (inner.len == 0) return error.MalformedSectionHeader;
    if (std.mem.indexOfScalar(u8, inner, '"')) |quote| {
        const section = std.mem.trim(u8, inner[0..quote], " \t");
        if (inner[inner.len - 1] != '"') return error.MalformedSectionHeader;
        const subsection = inner[quote + 1 .. inner.len - 1];
        try checkSectionName(section);
        return .{ .section = section, .subsection = subsection };
    }
    // The dotted form `[section.sub]` is git's older spelling; the part
    // after the first dot is the subsection and is case-sensitive.
    if (std.mem.indexOfScalar(u8, inner, '.')) |dot| {
        try checkSectionName(inner[0..dot]);
        return .{ .section = inner[0..dot], .subsection = inner[dot + 1 ..] };
    }
    try checkSectionName(inner);
    return .{ .section = inner, .subsection = null };
}

fn checkSectionName(name: []const u8) ParseError!void {
    if (name.len == 0) return error.MalformedSectionHeader;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '.') return error.MalformedSectionHeader;
    }
}

const VariableLine = struct {
    name: []const u8,
    value_start: usize,
    value_end: usize,
    has_value: bool,
};

fn parseVariableLine(raw: []const u8) ParseError!VariableLine {
    var i: usize = 0;
    while (i < raw.len and (raw[i] == ' ' or raw[i] == '\t')) i += 1;
    const name_start = i;
    while (i < raw.len and (std.ascii.isAlphanumeric(raw[i]) or raw[i] == '-')) i += 1;
    const name = raw[name_start..i];
    if (name.len == 0 or !std.ascii.isAlphabetic(name[0])) return error.InvalidVariableName;

    while (i < raw.len and (raw[i] == ' ' or raw[i] == '\t')) i += 1;
    if (i >= raw.len or raw[i] == '\n' or raw[i] == '\r' or raw[i] == '#' or raw[i] == ';') {
        return .{ .name = name, .value_start = i, .value_end = i, .has_value = false };
    }
    if (raw[i] != '=') return error.InvalidVariableName;
    i += 1;
    while (i < raw.len and (raw[i] == ' ' or raw[i] == '\t')) i += 1;
    const value_start = i;

    // Walk to the end of the value, honouring quotes so that a `#` inside
    // one is not a comment.
    var in_quotes = false;
    var end = i;
    var last_significant = i;
    while (end < raw.len) : (end += 1) {
        const c = raw[end];
        if (c == '\\') {
            if (end + 1 < raw.len) {
                end += 1;
                last_significant = end + 1;
            }
            continue;
        }
        if (c == '"') {
            in_quotes = !in_quotes;
            last_significant = end + 1;
            continue;
        }
        if (!in_quotes) {
            if (c == '\n' or c == '\r') break;
            if (c == '#' or c == ';') break;
            if (c != ' ' and c != '\t') last_significant = end + 1;
        } else {
            last_significant = end + 1;
        }
    }
    if (in_quotes) return error.MalformedValue;
    return .{
        .name = name,
        .value_start = value_start,
        .value_end = last_significant,
        .has_value = true,
    };
}

/// A value with its quotes removed and its escapes applied. The result is the
/// caller's.
///
/// `get` hands back the raw text as the file spells it; this is what turns
/// `"a\tb"` into a tab. A caller comparing a value against a literal wants
/// this, and `getBool`, `getInt` and `getPath` apply it themselves.
fn decodeValue(gpa: Allocator, raw: []const u8) (Allocator.Error || error{MalformedValue})![]u8 {
    return unquote(gpa, raw) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.MalformedValue => error.MalformedValue,
        else => unreachable,
    };
}

pub fn unquote(gpa: Allocator, raw: []const u8) (Allocator.Error || ParseError)![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var i: usize = 0;
    var in_quotes = false;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (c == '"') {
            in_quotes = !in_quotes;
            continue;
        }
        if (c == '\\') {
            i += 1;
            if (i >= raw.len) return error.MalformedValue;
            const escaped: u8 = switch (raw[i]) {
                'n' => '\n',
                't' => '\t',
                'b' => 8,
                '\\' => '\\',
                '"' => '"',
                '\n' => continue,
                '\r' => {
                    if (i + 1 < raw.len and raw[i + 1] == '\n') i += 1;
                    continue;
                },
                else => return error.MalformedValue,
            };
            out.writer.writeByte(escaped) catch return error.OutOfMemory;
            continue;
        }
        out.writer.writeByte(c) catch return error.OutOfMemory;
    }
    if (in_quotes) return error.MalformedValue;
    return out.toOwnedSlice();
}

test "values read with the last one winning" {
    const gpa = std.testing.allocator;
    var config = try Config.parseText(gpa, "# a comment\n" ++
        "[core]\n" ++
        "\tautocrlf = input\n" ++
        "\tbare = false\n" ++
        "[core]\n" ++
        "\tautocrlf = true\n" ++
        "[remote \"origin\"]\n" ++
        "\turl = https://example.com/x.git\n" ++
        "\tfetch = +refs/heads/*:refs/remotes/origin/*\n" ++
        "\n", .local);
    defer config.deinit();

    try std.testing.expectEqualStrings("true", config.get("core.autocrlf").?);
    try std.testing.expectEqualStrings("false", config.get("core.bare").?);
    try std.testing.expectEqualStrings("https://example.com/x.git", config.get("remote.origin.url").?);
    try std.testing.expect(config.get("core.missing") == null);
    try std.testing.expect(try config.getBool("core.autocrlf", false) == true);
    try std.testing.expect(try config.getBool("core.bare", true) == false);

    const values = try config.all("core.autocrlf");
    defer gpa.free(values);
    try std.testing.expectEqual(@as(usize, 2), values.len);
    try std.testing.expectEqualStrings("input", values[0]);

    const subs = try config.subsections(gpa, "remote");
    defer gpa.free(subs);
    try std.testing.expectEqual(@as(usize, 1), subs.len);
    try std.testing.expectEqualStrings("origin", subs[0]);
}

test "a bare name is true and an empty value is false" {
    const gpa = std.testing.allocator;
    var config = try Config.parseText(gpa, "[core]\n" ++
        "\tbare\n" ++
        "\tsparse =\n" ++
        "\n", .local);
    defer config.deinit();
    try std.testing.expect(try config.getBool("core.bare", false));
    try std.testing.expect(!try config.getBool("core.sparse", true));
}

test "quotes, escapes and inline comments" {
    const gpa = std.testing.allocator;
    var config = try Config.parseText(gpa, "[user]\n" ++
        "\tname = \"Ada  Lovelace\" # not a comment inside quotes\n" ++
        "\temail = ada@example.com ; trailing comment\n" ++
        "\tsig = \"a\\tb\"\n" ++
        "\n", .local);
    defer config.deinit();
    const name = try unquote(gpa, config.get("user.name").?);
    defer gpa.free(name);
    try std.testing.expectEqualStrings("Ada  Lovelace", name);
    try std.testing.expectEqualStrings("ada@example.com", config.get("user.email").?);
    const sig = try unquote(gpa, config.get("user.sig").?);
    defer gpa.free(sig);
    try std.testing.expectEqualStrings("a\tb", sig);
}

test "integers take git's size suffixes" {
    try std.testing.expectEqual(@as(i64, 1024), try parseInt("1k"));
    try std.testing.expectEqual(@as(i64, 5 * 1024 * 1024), try parseInt("5M"));
    try std.testing.expectEqual(@as(i64, -7), try parseInt("-7"));
    try std.testing.expectError(error.NotAnInteger, parseInt("x"));
}

test "typed getters unquote values before parsing them" {
    const gpa = std.testing.allocator;
    var config = try Config.parseText(gpa, "[typed]\n" ++
        "\tflag = \"true\"\n" ++
        "\tsize = \"5k\"\n" ++
        "\tpath = \"~/a b\"\n", .local);
    defer config.deinit();
    config.context.home = "/home/ada";

    try std.testing.expect(try config.getBool("typed.flag", false));
    try std.testing.expectEqual(@as(i64, 5 * 1024), try config.getInt("typed.size", 0));
    const path = (try config.getPath(gpa, "typed.path")).?;
    defer gpa.free(path);
    try std.testing.expectEqualStrings("/home/ada/a b", path);
}

test "relative includes start beside the including file" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "cfg", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "cfg/main", .data = "[include]\n\tpath = child\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "cfg/child", .data = "[fixture]\n\tvalue = nested\n" });

    var config = try Config.openFile(gpa, io, .{ .dir = tmp.dir, .sub_path = "cfg/main" }, .local, .{});
    defer config.deinit();
    try std.testing.expectEqualStrings("nested", config.get("fixture.value").?);
    try std.testing.expectEqualStrings("cfg/child", config.origin("fixture.value").?.path);
}

test "a full name splits at the first dot and the last" {
    const a = splitFullName("core.autocrlf").?;
    try std.testing.expectEqualStrings("core", a.section);
    try std.testing.expect(a.subsection == null);
    try std.testing.expectEqualStrings("autocrlf", a.name);

    const b = splitFullName("url.https://example.com/.insteadOf").?;
    try std.testing.expectEqualStrings("url", b.section);
    try std.testing.expectEqualStrings("https://example.com/", b.subsection.?);
    try std.testing.expectEqualStrings("insteadOf", b.name);
}

test "setting a value rewrites one line and leaves the rest alone" {
    const gpa = std.testing.allocator;
    const original =
        "# keep me\n" ++
        "[core]\n" ++
        "\t; and me\n" ++
        "\tautocrlf = input\n" ++
        "\tbare = false\n" ++
        "\n" ++
        "[user]\n" ++
        "\tname = Ada\n" ++
        "\n";
    var config = try Config.parseText(gpa, original, .local);
    defer config.deinit();
    config.files.items[0].writable = true;

    try config.set("core.autocrlf", "true");
    const after = try config.renderWritable();
    defer gpa.free(after);
    try std.testing.expectEqualStrings("# keep me\n" ++
        "[core]\n" ++
        "\t; and me\n" ++
        "\tautocrlf = true\n" ++
        "\tbare = false\n" ++
        "\n" ++
        "[user]\n" ++
        "\tname = Ada\n" ++
        "\n", after);
    try std.testing.expectEqualStrings("true", config.get("core.autocrlf").?);
}

test "setting a bare variable inserts an equals sign" {
    const gpa = std.testing.allocator;
    var config = try Config.parseText(gpa, "[core]\n\tbare  # repository kind\n", .local);
    defer config.deinit();
    config.files.items[0].writable = true;

    try config.set("core.bare", "false");
    try config.set("core.bare", "true");
    const after = try config.renderWritable();
    defer gpa.free(after);
    try std.testing.expectEqualStrings("[core]\n\tbare = true  # repository kind\n", after);
    try std.testing.expectEqualStrings("true", config.get("core.bare").?);
}

test "a new value joins its section and a new section is appended" {
    const gpa = std.testing.allocator;
    var config = try Config.parseText(gpa, "[core]\n" ++
        "\tbare = false\n", .local);
    defer config.deinit();
    config.files.items[0].writable = true;

    try config.set("core.autocrlf", "input");
    try config.set("user.name", "Ada Lovelace");
    const after = try config.renderWritable();
    defer gpa.free(after);
    try std.testing.expectEqualStrings("[core]\n" ++
        "\tbare = false\n" ++
        "\tautocrlf = input\n" ++
        "[user]\n" ++
        "\tname = Ada Lovelace\n", after);
    try std.testing.expectEqualStrings("input", config.get("core.autocrlf").?);
    try std.testing.expectEqualStrings("Ada Lovelace", config.get("user.name").?);
}

test "unsetting removes only the matching lines" {
    const gpa = std.testing.allocator;
    var config = try Config.parseText(gpa, "[core]\n" ++
        "\tbare = false\n" ++
        "\tautocrlf = input\n" ++
        "# a comment\n" ++
        "[user]\n" ++
        "\tname = Ada\n" ++
        "\n", .local);
    defer config.deinit();
    config.files.items[0].writable = true;
    try config.unset("core.autocrlf");
    const after = try config.renderWritable();
    defer gpa.free(after);
    try std.testing.expectEqualStrings("[core]\n" ++
        "\tbare = false\n" ++
        "# a comment\n" ++
        "[user]\n" ++
        "\tname = Ada\n" ++
        "\n", after);
    try std.testing.expect(config.get("core.autocrlf") == null);
}

test "a variable before any section is a named error" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.VariableOutsideSection, Config.parseText(gpa, "x = 1\n", .local));
}

test "fuzz: any bytes are a configuration or a named error" {
    try std.testing.fuzz({}, fuzzConfig, .{});
}

fn fuzzConfig(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;
    var scratch: [2048]u8 = undefined;
    const input = scratch[0..smith.slice(&scratch)];
    var config = Config.parseText(gpa, input, .local) catch return;
    defer config.deinit();
    _ = config.get("core.autocrlf");
    _ = config.getBool("core.bare", false) catch {};
    _ = config.getInt("core.bigfilethreshold", 0) catch {};
    const values = config.all("core.autocrlf") catch return;
    gpa.free(values);
}
