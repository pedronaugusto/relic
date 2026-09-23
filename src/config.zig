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
    /// A section header git refuses: a `[` with no `]`, a name holding a
    /// character other than a letter, a digit, `-` or `.`, a space that is
    /// not followed by a quoted subsection, anything but `]` after the
    /// closing quote, or a line break inside the quotes.
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
    /// A value given as `Sources.command` under a name git refuses; see
    /// `checkKey`.
    InvalidKey,
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
    /// For a `.section` line: the section, lower-cased, and the subsection
    /// as git reads it — a quoted one with its escapes undone, a dotted one
    /// lower-cased. Borrowed from the text or from the file's `names`.
    section: []const u8 = "",
    subsection: []const u8 = "",
    has_subsection: bool = false,
    /// For a `.section` line: the name as spelled before any space, and
    /// whether a quoted subsection followed it. `[Section.Sub]` is spelled
    /// `Section.Sub` and is not quoted; `[remote "origin"]` is spelled
    /// `remote` and is.
    spelled: []const u8 = "",
    quoted: bool = false,
    /// For a `.variable` line: the normalised name, and the span of the
    /// value inside `text`.
    name: []const u8 = "",
    value_start: usize = 0,
    value_end: usize = 0,
    /// Whether the variable had an `=` at all. A bare name means true.
    has_value: bool = false,

    const Kind = enum { section, variable, other };

    /// Whether this header is `[section.sub]`, git's older spelling, whose
    /// subsection git lower-cases on reading and matches without case when
    /// it looks for the section to add a value to.
    fn legacy(line: Line) bool {
        return line.has_subsection and !line.quoted;
    }

    /// Whether a new value of `split` belongs in the section this header
    /// opens: git's rule when it looks for where to add one.
    fn opensSectionOf(line: Line, split: FullName) bool {
        if (!std.ascii.eqlIgnoreCase(line.section, split.section)) return false;
        const sub = split.subsection orelse return !line.has_subsection;
        if (!line.has_subsection) return false;
        if (line.legacy()) return std.ascii.eqlIgnoreCase(line.subsection, sub);
        return std.mem.eql(u8, line.subsection, sub);
    }

    /// Whether this header is the one `git config --remove-section` names
    /// with `full`: the header as spelled, compared byte for byte, with a
    /// quoted subsection's escapes undone. Neither the section's case nor
    /// the dotted spelling's is folded, which is git's own comparison.
    fn spelledAs(line: Line, full: []const u8) bool {
        if (!line.quoted) return std.mem.eql(u8, line.spelled, full);
        if (!std.mem.startsWith(u8, full, line.spelled)) return false;
        const rest = full[line.spelled.len..];
        if (rest.len == 0 or rest[0] != '.') return false;
        // A dotted name before the quotes, `[a.b "c"]`, reads as the
        // subsection `b.c`: the quoted part is what follows the dotted one.
        const quoted_part = if (std.mem.indexOfScalar(u8, line.spelled, '.')) |dot|
            line.subsection[line.spelled.len - dot ..]
        else
            line.subsection;
        return std.mem.eql(u8, rest[1..], quoted_part);
    }
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
    /// Section and subsection names that are not a slice of a line as
    /// written: a lower-cased section, a subsection with its escapes undone.
    names: std.heap.ArenaAllocator.State = .{},

    /// Release the file.
    pub fn deinit(f: *SourceFile) void {
        for (f.lines.items) |line| {
            if (line.owned) f.gpa.free(line.text);
        }
        f.lines.deinit(f.gpa);
        var names = f.names.promote(f.gpa);
        names.deinit();
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
    /// Case-sensitive, with a quoted subsection's escapes undone. Empty when
    /// there is none, and also for `[section ""]`, which `has_subsection`
    /// tells apart.
    subsection: []const u8,
    /// Whether the header named a subsection at all. git reads
    /// `[section ""]` as a subsection that is empty, and `section..name`
    /// is the only full name that reaches it.
    has_subsection: bool,
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
        if (subsection) |sub| return e.has_subsection and std.mem.eql(u8, e.subsection, sub);
        return !e.has_subsection;
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
///
/// It holds what the files held when they were read. Nothing reads them
/// again on its own: `isStale` says whether any has changed since, and
/// `Repository.refreshConfig` is what reads them again.
pub const Config = struct {
    gpa: Allocator,
    files: std.ArrayList(SourceFile) = .empty,
    entries: std.ArrayList(Entry) = .empty,
    context: Context = .{},
    /// What `open` was asked to read, kept so the same files can be read
    /// again. The paths and the command-line values are owned; the
    /// directories are the caller's, and stay open while the configuration
    /// may be read again.
    sources: Sources = .{},
    /// Every file a read tried, includes among them and the ones that were
    /// not there, with the bytes each held.
    read: std.ArrayList(Read) = .empty,

    /// One file a read tried.
    pub const Read = struct {
        dir: Io.Dir,
        /// Owned.
        sub_path: []const u8,
        /// What it held, owned; `null` when it was not there.
        bytes: ?[]const u8,
    };

    /// An empty configuration, which answers `null` to everything.
    pub fn initEmpty(gpa: Allocator) Config {
        return .{ .gpa = gpa };
    }

    /// Read every source that is there, in git's order: system, then global,
    /// then local, then worktree, then the caller's own values.
    pub fn open(gpa: Allocator, io: Io, sources: Sources, context: Context) ParseError!Config {
        var config: Config = .{ .gpa = gpa, .context = context };
        errdefer config.deinit();
        try config.keepSources(sources);

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
        for (config.read.items) |r| {
            config.gpa.free(r.sub_path);
            if (r.bytes) |b| config.gpa.free(b);
        }
        config.read.deinit(config.gpa);
        const paths = [_]?Sources.Path{ config.sources.system, config.sources.global, config.sources.local, config.sources.worktree };
        for (paths) |maybe| {
            if (maybe) |path| config.gpa.free(path.sub_path);
        }
        for (config.sources.command) |value| config.gpa.free(value);
        config.gpa.free(config.sources.command);
        config.* = undefined;
    }

    fn keepSources(config: *Config, sources: Sources) Allocator.Error!void {
        const gpa = config.gpa;
        const fields = [_][]const u8{ "system", "global", "local", "worktree" };
        inline for (fields) |field| {
            if (@field(sources, field)) |path| {
                @field(config.sources, field) = .{ .dir = path.dir, .sub_path = try gpa.dupe(u8, path.sub_path) };
            }
        }
        const command = try gpa.alloc([]const u8, sources.command.len);
        var kept: usize = 0;
        errdefer {
            for (command[0..kept]) |value| gpa.free(value);
            gpa.free(command);
        }
        for (sources.command) |value| {
            command[kept] = try gpa.dupe(u8, value);
            kept += 1;
        }
        config.sources.command = command;
    }

    /// Whether a file this configuration was read from now holds other
    /// bytes than it did, or is there when it was not, or is gone. Includes
    /// count, and so does an include that was not there when it was read.
    ///
    /// The files are read and compared, which is exact: a stat cannot see a
    /// rewrite of the same size inside the file system's timestamp
    /// resolution, and a configuration is small enough that reading it is
    /// the cheap part. Nothing is parsed and nothing is kept.
    pub fn isStale(config: *const Config, io: Io) (Allocator.Error || Io.Dir.ReadFileAllocError)!bool {
        for (config.read.items) |r| {
            const now = try fs.readFileAlloc(config.gpa, io, r.dir, r.sub_path, 1 << 24);
            defer if (now) |b| config.gpa.free(b);
            const was = r.bytes orelse {
                if (now != null) return true;
                continue;
            };
            const is = now orelse return true;
            if (!std.mem.eql(u8, was, is)) return true;
        }
        return false;
    }

    fn addFile(config: *Config, io: Io, path: Sources.Path, level: Level, writable: bool, depth: u8) ParseError!void {
        if (depth > max_include_depth) return error.IncludeTooDeep;
        const read = try fs.readFileAlloc(config.gpa, io, path.dir, path.sub_path, 1 << 24);
        try config.remember(path, read);
        const text = read orelse return;
        const owned_path = config.gpa.dupe(u8, path.sub_path) catch |err| {
            config.gpa.free(text);
            return err;
        };
        // `addParsedFile` takes both, and its own errdefer frees them.
        const first_entry = config.entries.items.len;
        try config.addParsedFile(owned_path, text, level, writable);
        try config.followIncludes(io, path.dir, level, first_entry, depth);
    }

    /// Keep what a read found, so `isStale` can ask again.
    fn remember(config: *Config, path: Sources.Path, read: ?[]const u8) Allocator.Error!void {
        errdefer if (read) |b| config.gpa.free(b);
        const sub_path = try config.gpa.dupe(u8, path.sub_path);
        errdefer config.gpa.free(sub_path);
        const bytes = if (read) |b| try config.gpa.dupe(u8, b) else null;
        errdefer if (bytes) |b| config.gpa.free(b);
        try config.read.append(config.gpa, .{ .dir = path.dir, .sub_path = sub_path, .bytes = bytes });
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
        {
            var names = file.names.promote(config.gpa);
            defer file.names = names.state;
            try parseLines(config.gpa, names.allocator(), text, &file.lines);
        }
        try config.files.append(config.gpa, file);
        errdefer _ = config.files.pop();
        try config.indexFile(@intCast(config.files.items.len - 1));
    }

    fn indexFile(config: *Config, file_index: u32) Allocator.Error!void {
        const file = &config.files.items[file_index];
        var section: []const u8 = "";
        var subsection: []const u8 = "";
        var has_subsection = false;
        for (file.lines.items, 0..) |line, i| {
            switch (line.kind) {
                .section => {
                    section = line.section;
                    subsection = line.subsection;
                    has_subsection = line.has_subsection;
                },
                .variable => try config.entries.append(config.gpa, .{
                    .section = section,
                    .subsection = subsection,
                    .has_subsection = has_subsection,
                    .name = line.name,
                    .value = if (line.has_value) line.text[line.value_start..line.value_end] else null,
                    .level = file.level,
                    .file_index = file_index,
                    .line_index = @intCast(i),
                }),
                .other => {},
            }
        }
    }

    fn addCommandValues(config: *Config, values: []const []const u8) ParseError!void {
        // A command-line value is `section.name=value` or
        // `section.sub.name=value`; it is turned into a one-line file so it
        // goes through exactly the same parser as everything else. The value
        // is taken as it is, the way `git -c` takes it, so it is written
        // with the quoting a file would need to hold it.
        var text: std.Io.Writer.Allocating = .init(config.gpa);
        errdefer text.deinit();
        for (values) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=');
            const full = if (eq) |at| pair[0..at] else pair;
            const value = if (eq) |at| pair[at + 1 ..] else null;
            const split = try checkKey(full);
            writeSectionHeader(&text.writer, split) catch return error.OutOfMemory;
            if (value) |v| {
                text.writer.print("\t{s} = ", .{split.name}) catch return error.OutOfMemory;
                writeValue(&text.writer, v) catch return error.OutOfMemory;
                text.writer.writeByte('\n') catch return error.OutOfMemory;
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
        /// A name git refuses to write; see `checkKey`.
        InvalidKey,
    } || Allocator.Error || fs.LockError || fs.CommitError;

    /// Set `full_name` to `value` in the writable file, keeping every
    /// comment and every other line exactly as it was.
    ///
    /// An existing value's line is rewritten in place. A new value is
    /// appended to the end of its section, or a new section is appended to
    /// the end of the file. Nothing else in the file moves.
    pub fn set(config: *Config, full_name: []const u8, value: []const u8) SetError!void {
        const file_index = config.writableFileIndex() orelse return error.NoWritableSource;
        return config.setInFile(file_index, full_name, value);
    }

    /// `set`, in the first writable file read at `level` rather than the
    /// last writable one.
    ///
    /// A repository with `extensions.worktreeConfig` on has two writable
    /// files, and a value git keeps in `.git/config` — a submodule's url,
    /// say — belongs in the first of them whichever is last.
    pub fn setIn(config: *Config, level: Level, full_name: []const u8, value: []const u8) SetError!void {
        const file_index = config.writableFileAt(level) orelse return error.NoWritableSource;
        return config.setInFile(file_index, full_name, value);
    }

    fn setInFile(config: *Config, file_index: u32, full_name: []const u8, value: []const u8) SetError!void {
        const split = try checkKey(full_name);
        const file = &config.files.items[file_index];

        // The last matching line wins on read, so that is the one to change.
        // A new value goes where git puts one: after the last variable of
        // the last section it belongs in, or straight after that section's
        // header when it has none. A comment or a blank line does not move
        // that point, which keeps a trailing blank line where the person who
        // wrote it put it.
        var target: ?usize = null;
        var insert_at: ?usize = null;
        var in_section = false;
        var same_key_section = false;
        for (file.lines.items, 0..) |line, i| {
            switch (line.kind) {
                .section => {
                    in_section = line.opensSectionOf(split);
                    if (in_section) insert_at = i + 1;
                    same_key_section = in_section and
                        std.mem.eql(u8, line.subsection, split.subsection orelse "");
                },
                .variable => {
                    if (!in_section) continue;
                    insert_at = i + 1;
                    // `[a.b]` takes a new `a.B.x` as git does, but only an
                    // exact subsection is the same key.
                    if (same_key_section and std.ascii.eqlIgnoreCase(line.name, split.name)) target = i;
                },
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
                while (name_start < line.text.len and isSpace(line.text[name_start])) name_start += 1;
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
            return config.reindex();
        }

        var text: std.Io.Writer.Allocating = .init(config.gpa);
        errdefer text.deinit();
        text.writer.print("\t{s} = ", .{split.name}) catch return error.OutOfMemory;
        writeValue(&text.writer, value) catch return error.OutOfMemory;
        text.writer.writeByte('\n') catch return error.OutOfMemory;
        const new_text = try text.toOwnedSlice();
        const parsed = parseVariableLine(new_text) catch unreachable;
        const new_line: Line = .{
            .kind = .variable,
            .text = new_text,
            .owned = true,
            .name = parsed.name,
            .value_start = parsed.value_start,
            .value_end = parsed.value_end,
            .has_value = true,
        };
        {
            errdefer config.gpa.free(new_text);
            try file.lines.ensureUnusedCapacity(config.gpa, 3);
        }
        const at = insert_at orelse file.lines.items.len;
        // git ends the line before with a newline when it has none, which a
        // header followed by a comment, or a file's last line, may lack.
        if (at > 0 and !std.mem.endsWith(u8, file.lines.items[at - 1].text, "\n")) {
            file.lines.insertAssumeCapacity(at, .{ .kind = .other, .text = "\n" });
            return config.insertNew(file, at + 1, split, insert_at != null, new_line);
        }
        return config.insertNew(file, at, split, insert_at != null, new_line);
    }

    /// Put a new variable line at `at`, under a new header when no section
    /// it belongs in exists. Capacity for both is reserved.
    fn insertNew(config: *Config, file: *SourceFile, at: usize, split: FullName, section_exists: bool, new_line: Line) SetError!void {
        if (section_exists) {
            file.lines.insertAssumeCapacity(at, new_line);
            return config.reindex();
        }
        var header_text: std.Io.Writer.Allocating = .init(config.gpa);
        defer header_text.deinit();
        writeSectionHeader(&header_text.writer, split) catch {
            config.gpa.free(new_line.text);
            return error.OutOfMemory;
        };
        const header = header_text.toOwnedSlice() catch {
            config.gpa.free(new_line.text);
            return error.OutOfMemory;
        };
        var names = file.names.promote(config.gpa);
        defer file.names = names.state;
        const parsed = parseSectionHeader(names.allocator(), header, 0) catch |err| {
            config.gpa.free(header);
            config.gpa.free(new_line.text);
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                // `checkKey` let through only what writes as a header.
                else => unreachable,
            };
        };
        file.lines.appendAssumeCapacity(.{
            .kind = .section,
            .text = header,
            .owned = true,
            .section = parsed.section,
            .subsection = parsed.subsection,
            .has_subsection = parsed.has_subsection,
            .spelled = parsed.spelled,
            .quoted = parsed.quoted,
        });
        file.lines.appendAssumeCapacity(new_line);
        return config.reindex();
    }

    /// Remove every setting of `full_name` from the writable file, keeping
    /// everything else exactly as it was.
    pub fn unset(config: *Config, full_name: []const u8) SetError!void {
        const file_index = config.writableFileIndex() orelse return error.NoWritableSource;
        return config.unsetInFile(file_index, full_name);
    }

    /// `unset`, in the first writable file read at `level`.
    pub fn unsetIn(config: *Config, level: Level, full_name: []const u8) SetError!void {
        const file_index = config.writableFileAt(level) orelse return error.NoWritableSource;
        return config.unsetInFile(file_index, full_name);
    }

    fn unsetInFile(config: *Config, file_index: u32, full_name: []const u8) SetError!void {
        const split = try checkKey(full_name);
        const file = &config.files.items[file_index];

        var section: Line = .{ .kind = .other, .text = "" };
        var i: usize = 0;
        while (i < file.lines.items.len) {
            const line = file.lines.items[i];
            switch (line.kind) {
                .section => section = line,
                .variable => {
                    const entry: Entry = .{
                        .section = section.section,
                        .subsection = section.subsection,
                        .has_subsection = section.has_subsection,
                        .name = line.name,
                        .value = null,
                        .level = file.level,
                        .file_index = file_index,
                        .line_index = @intCast(i),
                    };
                    if (section.kind == .section and entry.matches(split.section, split.subsection, split.name)) {
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

    /// Remove every `[section "subsection"]` from the first writable file
    /// read at `level`, with every line up to the next section header —
    /// comments included, which is what `git config --remove-section`
    /// takes. Returns whether there was one.
    ///
    /// The header is matched as git matches it: as spelled, so `Submodule`
    /// is not `submodule` here although it is when a value is read, and
    /// `[a.b]` answers to the section `a` with the subsection `b`.
    pub fn removeSectionIn(config: *Config, level: Level, section: []const u8, subsection: ?[]const u8) SetError!bool {
        const file_index = config.writableFileAt(level) orelse return error.NoWritableSource;
        const file = &config.files.items[file_index];
        const full = if (subsection) |sub|
            try std.fmt.allocPrint(config.gpa, "{s}.{s}", .{ section, sub })
        else
            try config.gpa.dupe(u8, section);
        defer config.gpa.free(full);
        var removing = false;
        var removed = false;
        var i: usize = 0;
        while (i < file.lines.items.len) {
            const line = file.lines.items[i];
            if (line.kind == .section) removing = line.spelledAs(full);
            if (removing) {
                if (line.owned) config.gpa.free(line.text);
                _ = file.lines.orderedRemove(i);
                removed = true;
                continue;
            }
            i += 1;
        }
        try config.reindex();
        return removed;
    }

    fn writableFileAt(config: *const Config, level: Level) ?u32 {
        for (config.files.items, 0..) |f, i| {
            if (f.writable and f.level == level) return @intCast(i);
        }
        return null;
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
        for (0..config.files.items.len) |file_index| try config.indexFile(@intCast(file_index));
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

/// Check `full` the way git checks a name before it writes one, and split
/// it.
///
/// git's `git_config_parse_key`: the variable is what follows the last dot
/// and must begin with a letter; it and the section hold only letters,
/// digits and `-`; the subsection between them may hold anything but a line
/// break, which no header can carry. A section may be empty only when a
/// subsection follows it, as in `.sub.name`.
pub fn checkKey(full: []const u8) error{InvalidKey}!FullName {
    const last = std.mem.lastIndexOfScalar(u8, full, '.') orelse return error.InvalidKey;
    if (last == 0 or last == full.len - 1) return error.InvalidKey;
    const split = splitFullName(full).?;
    for (split.section) |c| {
        if (!isKeyChar(c)) return error.InvalidKey;
    }
    if (!std.ascii.isAlphabetic(split.name[0])) return error.InvalidKey;
    for (split.name) |c| {
        if (!isKeyChar(c)) return error.InvalidKey;
    }
    if (split.subsection) |sub| {
        if (std.mem.indexOfScalar(u8, sub, '\n') != null) return error.InvalidKey;
    }
    return split;
}

/// The header git writes for a new section, with its line ending:
/// `[section]`, or `[section "subsection"]` with every `"` and `\` in the
/// subsection escaped by a backslash. The section keeps the case it was
/// given, as git's does.
fn writeSectionHeader(w: *std.Io.Writer, split: FullName) std.Io.Writer.Error!void {
    const sub = split.subsection orelse return w.print("[{s}]\n", .{split.section});
    try w.print("[{s} \"", .{split.section});
    for (sub) |c| {
        if (c == '"' or c == '\\') try w.writeByte('\\');
        try w.writeByte(c);
    }
    try w.writeAll("\"]\n");
}

/// A value spelled the way git writes one. A line break, a tab, a quote and
/// a backslash are escaped; the whole value is quoted only when it begins
/// or ends with a space, or holds a `;`, a `#` or a carriage return, which
/// reading would otherwise drop.
fn writeValue(w: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    var quote = value.len != 0 and (value[0] == ' ' or value[value.len - 1] == ' ');
    for (value) |c| {
        if (c == ';' or c == '#' or c == '\r') quote = true;
    }
    if (quote) try w.writeByte('"');
    for (value) |c| {
        switch (c) {
            '\n' => try w.writeAll("\\n"),
            '\t' => try w.writeAll("\\t"),
            '"', '\\' => {
                try w.writeByte('\\');
                try w.writeByte(c);
            },
            else => try w.writeByte(c),
        }
    }
    if (quote) try w.writeByte('"');
}

/// A value spelled the way git writes one: escaped where it must be, and
/// quoted only where a leading or trailing space, a `;`, a `#` or a
/// carriage return would otherwise be lost. The result is the caller's.
pub fn escapeValue(gpa: Allocator, value: []const u8) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    writeValue(&out.writer, value) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// git's `isspace`, which is these four and not the vertical tab or the form
/// feed.
fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// What git drops at either end of an unquoted value: its `isspace` short of
/// the line break, which ends the value instead.
fn isValueSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r';
}

/// git's `iskeychar`: what a section or a variable name may hold.
fn isKeyChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-';
}

/// Split `text` into lines the way git's parser walks it.
///
/// A physical line may hold more than one: git reads `[core] bare = true`
/// as a header and a variable, and `[a][b]` as two headers, so each becomes
/// its own `Line` and rendering them back to back gives the bytes again. A
/// comment ends at its line break whatever precedes it; only a value
/// continues onto the next line after a backslash.
fn parseLines(gpa: Allocator, names: Allocator, text: []const u8, out: *std.ArrayList(Line)) ParseError!void {
    var offset: usize = 0;
    // git skips a UTF-8 byte-order mark at the start of the file.
    const bom = "\xEF\xBB\xBF";
    if (std.mem.startsWith(u8, text, bom)) {
        try out.append(gpa, .{ .kind = .other, .text = text[0..bom.len] });
        offset = bom.len;
    }
    var have_section = false;
    var start = offset;
    while (offset < text.len) {
        const c = text[offset];
        if (c == '\n') {
            offset += 1;
            try out.append(gpa, .{ .kind = .other, .text = text[start..offset] });
            start = offset;
            continue;
        }
        if (isSpace(c)) {
            offset += 1;
            continue;
        }
        if (c == '#' or c == ';') {
            offset = if (std.mem.indexOfScalarPos(u8, text, offset, '\n')) |nl| nl + 1 else text.len;
            try out.append(gpa, .{ .kind = .other, .text = text[start..offset] });
            start = offset;
            continue;
        }
        if (c == '[') {
            const header = try parseSectionHeader(names, text, offset);
            offset = header.end;
            // A line break straight after the `]` belongs to the header:
            // git adds a new value after it, and after anything else on
            // the line it adds one of its own first.
            if (std.mem.startsWith(u8, text[offset..], "\n")) {
                offset += 1;
            } else if (std.mem.startsWith(u8, text[offset..], "\r\n")) {
                offset += 2;
            }
            try out.append(gpa, .{
                .kind = .section,
                .text = text[start..offset],
                .section = header.section,
                .subsection = header.subsection,
                .has_subsection = header.has_subsection,
                .spelled = header.spelled,
                .quoted = header.quoted,
            });
            start = offset;
            have_section = true;
            continue;
        }
        if (!have_section) return error.VariableOutsideSection;
        offset = try variableEnd(text, offset);
        const raw = text[start..offset];
        const variable = try parseVariableLine(raw);
        try out.append(gpa, .{
            .kind = .variable,
            .text = raw,
            .name = variable.name,
            .value_start = variable.value_start,
            .value_end = variable.value_end,
            .has_value = variable.has_value,
        });
        start = offset;
    }
    if (start < text.len) try out.append(gpa, .{ .kind = .other, .text = text[start..] });
}

/// Where the variable beginning at `start` ends: just past the line break
/// that is not escaped, inside quotes, or inside a trailing comment's line.
fn variableEnd(text: []const u8, start: usize) ParseError!usize {
    var in_quotes = false;
    var i = start;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '\n') {
            if (in_quotes) return error.MalformedValue;
            return i + 1;
        }
        if (c == '\\') {
            // A backslash takes the next byte with it, a line break
            // included: that is how a value continues.
            if (i + 2 < text.len and text[i + 1] == '\r' and text[i + 2] == '\n') {
                i += 2;
            } else if (i + 1 < text.len) {
                i += 1;
            }
            continue;
        }
        if (c == '"') {
            in_quotes = !in_quotes;
            continue;
        }
        if (!in_quotes and (c == '#' or c == ';')) {
            return if (std.mem.indexOfScalarPos(u8, text, i, '\n')) |nl| nl + 1 else text.len;
        }
    }
    return text.len;
}

const SectionHeader = struct {
    /// Just past the `]`.
    end: usize,
    section: []const u8,
    subsection: []const u8,
    has_subsection: bool,
    spelled: []const u8,
    quoted: bool,
};

/// Read the header whose `[` is at `text[at]`, as git's `get_base_var` and
/// `get_extended_base_var` read one.
///
/// The name runs from the `[` to a `]` or a space, and holds letters,
/// digits, `-` and `.`; it is lower-cased, all of it, so the older
/// `[Section.Sub]` spelling reads as `section.sub`. A space begins a quoted
/// subsection: any further spaces, a `"`, bytes in which a backslash takes
/// the next byte as it is, a `"`, and the `]` at once. A line break
/// anywhere before the `]` is refused, which is why a subsection can never
/// hold one.
fn parseSectionHeader(names: Allocator, text: []const u8, at: usize) ParseError!SectionHeader {
    var i = at + 1;
    while (true) : (i += 1) {
        if (i >= text.len) return error.MalformedSectionHeader;
        const c = text[i];
        if (c == ']' or isSpace(c)) break;
        if (!isKeyChar(c) and c != '.') return error.MalformedSectionHeader;
    }
    const spelled = text[at + 1 .. i];
    const name = try lowered(names, spelled);
    const dot = std.mem.indexOfScalar(u8, name, '.');
    const section = name[0 .. dot orelse name.len];

    if (text[i] == ']') {
        if (spelled.len == 0) return error.MalformedSectionHeader;
        return .{
            .end = i + 1,
            .section = section,
            .subsection = if (dot) |d| name[d + 1 ..] else "",
            .has_subsection = dot != null,
            .spelled = spelled,
            .quoted = false,
        };
    }

    while (i < text.len and isSpace(text[i])) : (i += 1) {
        if (text[i] == '\n') return error.MalformedSectionHeader;
    }
    if (i >= text.len or text[i] != '"') return error.MalformedSectionHeader;
    i += 1;
    const quoted_start = i;
    var escapes = false;
    while (true) : (i += 1) {
        if (i >= text.len or text[i] == '\n') return error.MalformedSectionHeader;
        if (text[i] == '"') break;
        if (text[i] == '\\') {
            escapes = true;
            i += 1;
            if (i >= text.len or text[i] == '\n') return error.MalformedSectionHeader;
        }
        // A carriage return before a line break is the line break's.
        if (text[i] == '\r' and i + 1 < text.len and text[i + 1] == '\n') return error.MalformedSectionHeader;
    }
    const quoted_raw = text[quoted_start..i];
    if (i + 1 >= text.len or text[i + 1] != ']') return error.MalformedSectionHeader;

    const quoted = if (escapes) try unescapeSubsection(names, quoted_raw) else quoted_raw;
    // `[a.b "c"]` is the section `a` with the subsection `b.c`: git
    // appends the quoted part to the name read so far.
    const subsection = if (dot) |d|
        try std.fmt.allocPrint(names, "{s}.{s}", .{ name[d + 1 ..], quoted })
    else
        quoted;
    return .{
        .end = i + 2,
        .section = section,
        .subsection = subsection,
        .has_subsection = true,
        .spelled = spelled,
        .quoted = true,
    };
}

/// `name`, lower-cased, sliced when it already is.
fn lowered(names: Allocator, name: []const u8) Allocator.Error![]const u8 {
    for (name) |c| {
        if (std.ascii.isUpper(c)) return std.ascii.allocLowerString(names, name);
    }
    return name;
}

/// A quoted subsection's escapes undone: a backslash takes the next byte as
/// it is, whatever it is.
fn unescapeSubsection(names: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    var out = try names.alloc(u8, raw.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\\') i += 1;
        out[n] = raw[i];
        n += 1;
    }
    return out[0..n];
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
    while (i < raw.len and isValueSpace(raw[i])) i += 1;
    const value_start = i;

    // Walk to the end of the value, honouring quotes so that a `#` inside
    // one is not a comment. Only a line break ends it: a carriage return
    // that is not part of one is a byte of the value, as a tab is, and like
    // a tab it is dropped only at either end.
    var in_quotes = false;
    var end = i;
    var last_significant = i;
    while (end < raw.len) : (end += 1) {
        const c = raw[end];
        if (c == '\\') {
            // A backslash before a line break continues the value, and a
            // carriage return and a line feed are one line break.
            if (end + 2 < raw.len and raw[end + 1] == '\r' and raw[end + 2] == '\n') {
                end += 2;
                last_significant = end + 1;
            } else if (end + 1 < raw.len) {
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
            if (c == '\n') break;
            if (c == '#' or c == ';') break;
            if (!isValueSpace(c)) last_significant = end + 1;
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

const testgit = @import("testgit.zig");

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

test "a new section owns its parsed name" {
    const gpa = std.testing.allocator;
    var config = try Config.parseText(gpa, "[core]\n\tbare = false\n", .local);
    defer config.deinit();
    config.files.items[0].writable = true;
    const full_name = try gpa.dupe(u8, "fresh.value");
    try config.set(full_name, "kept");
    @memset(full_name, 'x');
    gpa.free(full_name);

    try std.testing.expectEqualStrings("kept", config.get("fresh.value").?);
    const rendered = try config.renderWritable();
    defer gpa.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[fresh]\n\tvalue = kept\n") != null);
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

test "a value set at one level lands in that level's file, not the last writable one" {
    const gpa = std.testing.allocator;
    var config = try Config.parseText(gpa, "[core]\n\tbare = false\n", .local);
    defer config.deinit();
    config.files.items[0].writable = true;
    var worktree = try Config.parseText(gpa, "[core]\n\tsparseCheckout = true\n", .worktree);
    defer worktree.deinit();
    // The second file joins the first, as `Repository.open` reads them.
    const text = try gpa.dupe(u8, worktree.files.items[0].text);
    const path = gpa.dupe(u8, "config.worktree") catch |err| {
        gpa.free(text);
        return err;
    };
    try config.addParsedFile(path, text, .worktree, true);

    try config.setIn(.local, "submodule.lib.url", "../lib");
    const local = try config.files.items[0].render();
    defer gpa.free(local);
    try std.testing.expectEqualStrings("[core]\n\tbare = false\n[submodule \"lib\"]\n\turl = ../lib\n", local);
    try std.testing.expectEqualStrings("../lib", config.get("submodule.lib.url").?);

    try config.unsetIn(.local, "submodule.lib.url");
    try std.testing.expect(config.get("submodule.lib.url") == null);
    try std.testing.expectError(error.NoWritableSource, config.setIn(.global, "user.name", "x"));
}

test "removing a section takes its header and every line up to the next one, as git does" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const text = "[core]\n\tbare = false\n" ++
        "[submodule \"lib\"]\n\tactive = true\n# kept by nobody\n\turl = ../lib\n" ++
        "[submodule \"other\"]\n\turl = ../other\n" ++
        "[submodule \"lib\"]\n\tupdate = none\n\n" ++
        "[user]\n\tname = Ada\n";
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    try git.writeFile(io, "probe.config", text);
    try git.exec(io, &.{ "config", "-f", "probe.config", "--remove-section", "submodule.lib" });
    const theirs = try git.readFile(io, "probe.config");
    defer gpa.free(theirs);

    var config = try Config.parseText(gpa, text, .local);
    defer config.deinit();
    config.files.items[0].writable = true;
    try std.testing.expect(try config.removeSectionIn(.local, "submodule", "lib"));
    try std.testing.expect(!try config.removeSectionIn(.local, "submodule", "lib"));
    const ours = try config.renderWritable();
    defer gpa.free(ours);
    try std.testing.expectEqualStrings(theirs, ours);
    try std.testing.expectEqualStrings("../other", config.get("submodule.other.url").?);
}

test "a header reads as git reads it, and a header git refuses is refused" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    const headers = [_][]const u8{
        "[s \"a\\\"b\"]",      "[s \"a\\\\b\"]",   "[s \"a\\qb\"]",  "[S.Sub]",
        "[S.Sub.Deep]",        "[ core]",          "[core ]",        "[ \"x\"]",
        "[core.]",             "[.a]",             "[.]",            "[]",
        "[s  \t \"a\"]",       "[s \"a\" ]",       "[s\"a\"]",       "[s \"a\\\nb\"]",
        "[s \"a\nb\"]",        "[s \"a\rb\"]",     "[s \"a\r\nb\"]", "[core] bare = true",
        "[core] # c",          "[core]]",          "[core][user]",   "[Core_x]",
        "[s \"a]b\"]",         "[s \"a\"b\"]",     "[s \"\" ]",      "[s \"\"]",
        "[s.]",                "[s \"a\"\n]",      "[s \"a\\\"]",    "[a.B \"C\"]",
        "[Remote \"Origin\"]", "[s \"a;b#c\"]",    "[s \"t\tb\"]",   "[s \"\xc3\xa9\"]",
        "\xEF\xBB\xBF[core]",  "[core]\r",         "# c \\\n[core]", "[s \"a b\"]",
        "[s \"a\\",            "[core",            "[s \"a",         "[a-b.C-d]",
        "; x\n[core]\t; y",    "[s \"a\\\r\nb\"]", "[s\t\"a\"]",     "[s \"x\"]]",
    };
    for (headers) |header| {
        const text = try std.fmt.allocPrint(gpa, "{s}\n\tx = 1\n", .{header});
        defer gpa.free(text);
        try git.writeFile(io, "probe.config", text);
        git.report_failures = false;
        const listed: ?[]u8 = git.run(io, &.{ "config", "-f", "probe.config", "--list", "-z" }) catch |err| switch (err) {
            error.GitFailed => null,
            else => return err,
        };
        defer if (listed) |l| gpa.free(l);

        var config = Config.parseText(gpa, text, .local) catch |err| {
            if (listed == null) continue;
            std.debug.print("{any}: git reads it, this says {t}\n", .{ header, err });
            return error.TestExpectedEqual;
        };
        defer config.deinit();
        const theirs = listed orelse {
            std.debug.print("{any}: git refuses it, this reads it\n", .{header});
            return error.TestExpectedEqual;
        };
        var ours: std.Io.Writer.Allocating = .init(gpa);
        defer ours.deinit();
        for (config.entries.items) |entry| {
            try ours.writer.writeAll(entry.section);
            if (entry.has_subsection) try ours.writer.print(".{s}", .{entry.subsection});
            const value = try unquote(gpa, entry.value orelse "");
            defer gpa.free(value);
            try ours.writer.print(".{s}\n{s}\x00", .{ entry.name, value });
        }
        std.testing.expectEqualStrings(theirs, ours.written()) catch |err| {
            std.debug.print("header {any}\n", .{header});
            return err;
        };
    }
}

test "a value reads as git reads it, carriage returns and all" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    const lines = [_][]const u8{
        "\ty = p\rq\n",      "\ty = p\r",           "\ty = p\r \n",       "\ty = \rp\n",
        "\ty = p\r\r\n",     "\ty = p \r q\n",      "\ty = p\t\n",        "\ty = p\rq # c\n",
        "\ty = p\tq  r\n",   "\ty = \"q\r\" x\r\n", "\ty = a\\\r\nb\r\n", "\ty = a\\\nb\n",
        "\ty = \" p \"\t\n", "\ty = p;q\n",         "\ty = \"p;q\"\n",    "\ty =\r\n",
    };
    for (lines) |line| {
        const text = try std.fmt.allocPrint(gpa, "[a]\n{s}", .{line});
        defer gpa.free(text);
        try git.writeFile(io, "probe.config", text);
        const theirs = try git.run(io, &.{ "config", "-f", "probe.config", "-z", "--get", "a.y" });
        defer gpa.free(theirs);

        var config = try Config.parseText(gpa, text, .local);
        defer config.deinit();
        const ours = try unquote(gpa, config.get("a.y").?);
        defer gpa.free(ours);
        const ours_z = try std.fmt.allocPrint(gpa, "{s}\x00", .{ours});
        defer gpa.free(ours_z);
        std.testing.expectEqualStrings(theirs, ours_z) catch |err| {
            std.debug.print("line {any}\n", .{line});
            return err;
        };
    }
}

test "a name git refuses to write is refused here, and every other one is written" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    const keys = [_][]const u8{
        "s.a\nb.x", ".a.x",    "s_x.y",  "s.a.1y", "s.a.",    "sx",       "s.a.y_z",  ".x",
        "a..x",     "a.b c.x", "a b.x",  "a.x-y",  "a.-x",    "A.B.C.D",  "a.\"\\.x", "a.b\r.x",
        "a.b.x.",   "a.x",     "1a.b.x", "a.1x",   "a-b.c-d", "a.b\tc.x",
    };
    for (keys) |key| {
        git.report_failures = false;
        const git_ok = if (git.run(io, &.{ "config", "-f", "probe.config", key, "1" })) |out| blk: {
            gpa.free(out);
            break :blk true;
        } else |err| switch (err) {
            error.GitFailed => false,
            else => return err,
        };
        const ours_ok = if (checkKey(key)) |_| true else |_| false;
        if (git_ok != ours_ok) {
            std.debug.print("key {any}: git says {}, this says {}\n", .{ key, git_ok, ours_ok });
            return error.TestExpectedEqual;
        }
    }
}

/// Run each `git config -f probe.config <key> <value>` in `git`, and the
/// same `set` here over the same starting text; the two files must be the
/// same bytes, and git must read back every value set here.
fn expectSetsAgree(git: *testgit.Repo, start: []const u8, sets: []const [2][]const u8) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try git.writeFile(io, "probe.config", start);
    var config = try Config.parseText(gpa, start, .local);
    defer config.deinit();
    config.files.items[0].writable = true;
    for (sets) |pair| {
        try git.exec(io, &.{ "config", "-f", "probe.config", pair[0], pair[1] });
        try config.set(pair[0], pair[1]);
    }
    const theirs = try git.readFile(io, "probe.config");
    defer gpa.free(theirs);
    const ours = try config.renderWritable();
    defer gpa.free(ours);
    try std.testing.expectEqualStrings(theirs, ours);

    // The other direction: git reads what this wrote.
    try git.writeFile(io, "ours.config", ours);
    for (sets) |pair| {
        // git adds `a.B.x` to `[a.b]`, where it reads as `a.b.x`: a name
        // git cannot read back after setting it is one this cannot either.
        git.report_failures = false;
        const read = git.run(io, &.{ "config", "-f", "ours.config", "--get-all", pair[0] }) catch |err| switch (err) {
            error.GitFailed => {
                try std.testing.expect(config.get(pair[0]) == null);
                continue;
            },
            else => return err,
        };
        defer gpa.free(read);
        const want = try std.fmt.allocPrint(gpa, "{s}\n", .{pair[1]});
        defer gpa.free(want);
        // A name git adds a line for rather than replaces reads back as more
        // than one value; the last is the one set.
        try std.testing.expect(std.mem.endsWith(u8, read, want));
        const value = try unquote(gpa, config.get(pair[0]).?);
        defer gpa.free(value);
        try std.testing.expectEqualStrings(pair[1], value);
    }
}

test "setting values writes the bytes git config writes, headers and escapes included" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();

    try expectSetsAgree(&git, "", &.{
        .{ "Core.AutoCRLF", "true" },
        .{ "s.a\"b\\c.X", "1" },
        .{ "S.Sub.x", "2" },
        .{ "v.q.v1", "a\"b\\c" },
        .{ "v.q.v2", " lead" },
        .{ "v.q.v3", "tab\tx" },
        .{ "v.q.v4", "semi;x" },
        .{ "v.q.v5", "cr\rx" },
        .{ "v.q.v6", "nl\nx" },
        .{ "v.q.v7", "" },
        .{ "v.q.v8", "trail " },
        .{ "v.q.v9", "hash#x" },
        .{ "s..y", "3" },
        .{ ".a.x", "4" },
        .{ "a.b c.x", "5" },
        .{ "url.https://example.com/a\"b.insteadOf", "x" },
        .{ "s.a\rb.x", "6" },
        .{ "Section.x", "7" },
        .{ "core.x", "8" },
    });
    // Into sections that are there: the older dotted spelling takes a new
    // name without regard to case, a quoted one only exactly; an empty
    // section takes it straight after its header; a header followed by a
    // comment, and a last line with no line break, gain one first.
    try expectSetsAgree(&git, "[a.b]\n\tx = 1\n[c \"D\"]\n\tx = 1\n", &.{
        .{ "a.B.y", "2" },
        .{ "a.B.x", "3" },
        .{ "c.d.x", "4" },
        .{ "A.b.z", "5" },
        .{ "C.D.z", "6" },
    });
    try expectSetsAgree(&git, "[core]\n\ta=1\n[user]\n[core]\n[x]\n", &.{.{ "core.c", "1" }});
    try expectSetsAgree(&git, "[core]\n\ta=1\n[user]\n[core]\n\tb=1\n[x]\n", &.{.{ "core.c", "1" }});
    try expectSetsAgree(&git, "[core] # c\n[user]\n", &.{.{ "core.x", "1" }});
    try expectSetsAgree(&git, "[core][user]\n", &.{.{ "core.x", "1" }});
    try expectSetsAgree(&git, "[core]", &.{.{ "core.x", "1" }});
    try expectSetsAgree(&git, "[a]\n\tx = 1", &.{ .{ "a.y", "1" }, .{ "b.y", "2" } });
    try expectSetsAgree(&git, "[s \"a\\\"b\"]\n\tx = 1\n[s \"a\\\\b\"]\n\tx = 1\n", &.{
        .{ "s.a\"b.x", "2" },
        .{ "s.a\\b.y", "3" },
        .{ "s.a\\\"b.z", "4" },
    });
    try expectSetsAgree(&git, "[s]\n\tx = 1\n[s \"\"]\n\tx = 1\n", &.{
        .{ "s..x", "2" },
        .{ "s.x", "3" },
    });
    try expectSetsAgree(&git, "\xEF\xBB\xBF[core]\r\n\tx = 1\r\n", &.{.{ "core.y", "2" }});
    try expectSetsAgree(&git, "\xEF\xBB\xBF[core]\r\n", &.{.{ "core.y", "2" }});
}

test "a section is removed and a value unset as git config matches them" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var git = try testgit.Repo.init(gpa, io, &.{});
    defer git.deinit();
    const start = "[Sub \"x\"]\n\ty=1\n[sub \"X\"]\n\ty=2\n[a.b]\n\tz=1\n[A.B]\n\tz=2\n[a \"b\"]\n\tz=3\n" ++
        "[s \"a\\\"b\"]\n\ty=1\n[a.b \"c\"]\n\tx=1\n[s \"\"]\n\tq=1\n[s]\n\tq=1\n";
    const Removal = struct { section: []const u8, subsection: ?[]const u8, full: []const u8 };
    const removals = [_]Removal{
        .{ .section = "Sub", .subsection = "x", .full = "Sub.x" },
        .{ .section = "sub", .subsection = "X", .full = "sub.X" },
        .{ .section = "sub", .subsection = "x", .full = "sub.x" },
        .{ .section = "a", .subsection = "b", .full = "a.b" },
        .{ .section = "s", .subsection = "a\"b", .full = "s.a\"b" },
        .{ .section = "a", .subsection = "b.c", .full = "a.b.c" },
        .{ .section = "s", .subsection = "", .full = "s." },
        .{ .section = "s", .subsection = null, .full = "s" },
    };
    for (removals) |removal| {
        try git.writeFile(io, "probe.config", start);
        git.report_failures = false;
        const git_removed = if (git.run(io, &.{ "config", "-f", "probe.config", "--remove-section", removal.full })) |out| blk: {
            gpa.free(out);
            break :blk true;
        } else |err| switch (err) {
            error.GitFailed => false,
            else => return err,
        };
        const theirs = try git.readFile(io, "probe.config");
        defer gpa.free(theirs);

        var config = try Config.parseText(gpa, start, .local);
        defer config.deinit();
        config.files.items[0].writable = true;
        const removed = try config.removeSectionIn(.local, removal.section, removal.subsection);
        const ours = try config.renderWritable();
        defer gpa.free(ours);
        std.testing.expectEqual(git_removed, removed) catch |err| {
            std.debug.print("--remove-section {s}\n", .{removal.full});
            return err;
        };
        try std.testing.expectEqualStrings(theirs, ours);
    }

    // `--unset` matches the subsection exactly, even under the dotted
    // spelling that takes a new value without regard to case.
    const unset_start = "[a.b]\n\tx = 1\n\ty = 1\n[s \"a\\\"b\"]\n\tx = 1\n\ty = 1\n[s \"\"]\n\tx = 1\n\ty = 1\n";
    const unsets = [_][]const u8{ "a.B.x", "a.b.x", "s.a\"b.x", "s..x", "s.x" };
    for (unsets) |key| {
        try git.writeFile(io, "probe.config", unset_start);
        git.report_failures = false;
        if (git.run(io, &.{ "config", "-f", "probe.config", "--unset", key })) |out| gpa.free(out) else |err| switch (err) {
            error.GitFailed => {},
            else => return err,
        }
        const theirs = try git.readFile(io, "probe.config");
        defer gpa.free(theirs);
        var config = try Config.parseText(gpa, unset_start, .local);
        defer config.deinit();
        config.files.items[0].writable = true;
        try config.unset(key);
        const ours = try config.renderWritable();
        defer gpa.free(ours);
        try std.testing.expectEqualStrings(theirs, ours);
    }
}

test "a value given on the command line is taken as it is, under any subsection" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var config = try Config.open(gpa, io, .{ .command = &.{
        "s.a\"b\\c.x=semi;colon # not a comment",
        "core.bare",
    } }, .{});
    defer config.deinit();
    const value = try unquote(gpa, config.get("s.a\"b\\c.x").?);
    defer gpa.free(value);
    try std.testing.expectEqualStrings("semi;colon # not a comment", value);
    try std.testing.expect(try config.getBool("core.bare", false));
    try std.testing.expectError(error.InvalidKey, Config.open(gpa, io, .{ .command = &.{"core_x.y=1"} }, .{}));
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
    var name_scratch: [64]u8 = undefined;
    const subsection = name_scratch[0..smith.slice(&name_scratch)];
    var value_scratch: [64]u8 = undefined;
    const value = value_scratch[0..smith.slice(&value_scratch)];

    var config = Config.parseText(gpa, input, .local) catch return;
    defer config.deinit();
    _ = config.get("core.autocrlf");
    _ = config.getBool("core.bare", false) catch {};
    _ = config.getInt("core.bigfilethreshold", 0) catch {};
    const values = config.all("core.autocrlf") catch return;
    gpa.free(values);

    // Whatever subsection and value are set, the file written reads back
    // with that value under that name, and the file it was written into
    // still parses. Only a line break in the subsection is refused.
    config.files.items[0].writable = true;
    const key = try std.fmt.allocPrint(gpa, "fuzz.{s}.name", .{subsection});
    defer gpa.free(key);
    config.set(key, value) catch |err| switch (err) {
        error.InvalidKey => {
            try std.testing.expect(std.mem.indexOfScalar(u8, subsection, '\n') != null);
            return;
        },
        else => return err,
    };
    const rendered = try config.renderWritable();
    defer gpa.free(rendered);
    var again = try Config.parseText(gpa, rendered, .local);
    defer again.deinit();
    // Except git's own quirk: `[fuzz.sub]` takes a new `fuzz.SUB.name`,
    // where it reads as `fuzz.sub.name`.
    const raw = again.get(key) orelse {
        for (subsection) |c| {
            if (std.ascii.isUpper(c)) return;
        }
        return error.TestUnexpectedResult;
    };
    const decoded = try unquote(gpa, raw);
    defer gpa.free(decoded);
    try std.testing.expectEqualStrings(value, decoded);
    // Removing the section leaves a file that still parses.
    again.files.items[0].writable = true;
    _ = try again.removeSectionIn(.local, "fuzz", subsection);
    const removed = try again.renderWritable();
    defer gpa.free(removed);
    var third = try Config.parseText(gpa, removed, .local);
    third.deinit();
}
