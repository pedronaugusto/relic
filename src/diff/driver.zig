//! The lines git takes for the start of a function: the `diff` driver's
//! `funcname` or `xfuncname` from the configuration, else git's built-in
//! driver of that name, else git's default — a line starting with a
//! letter, `_` or `$`. What `git grep -p` and `-W` look for.

const ErrorNamespace = @This();
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const ere = @import("../text.zig").ere;
const config_mod = @import("../config/config.zig");
const attributes = @import("../patterns.zig").attributes;
const object = @import("../object/object.zig");

/// Errors from reading a driver's patterns.
pub const Error = error{
    /// A pattern that does not compile, or a last one that is negated,
    /// both of which git dies on.
    InvalidFunctionPattern,
    /// A `diff.<name>.binary` that is neither a boolean nor `auto`, which
    /// git dies on.
    InvalidDriverBinary,
    /// A `diff.<name>.cachetextconv` that is no boolean, which git dies on.
    InvalidDriverCache,
    /// A function pattern's search took more work than the matcher's
    /// budget allows.
    PatternTooComplex,
} || Allocator.Error;

/// The driver userdiff's lookup gives a path by its `diff` attribute
/// (`userdiff_find_by_path`, then `default` where it finds none): `diff`
/// set is git's text driver, unset its binary one; a name is that driver
/// when it is built in or configured; anything else, and no attribute, is
/// the driver named `default`, which the configuration shapes as any other.
pub const Driver = union(enum) {
    text,
    binary,
    named: []const u8,

    /// The driver for the `diff` attribute's `state`.
    pub fn of(config: ?*const config_mod.Config, state: ?attributes.State) Driver {
        const s = state orelse return .{ .named = "default" };
        return switch (s) {
            .set => .text,
            .unset => .binary,
            .unspecified => .{ .named = "default" },
            .value => |driver| if (exists(config, driver)) .{ .named = driver } else .{ .named = "default" },
        };
    }

    /// `driver->binary`: whether the driver says, or `null` for the bytes
    /// to decide; no configuration is an empty one. Each
    /// `diff.<name>.binary` is read as userdiff's `parse_tristate` reads
    /// it: `auto` leaves it to the bytes, a boolean decides, the last
    /// deciding, and anything else is refused wherever it is, as git dies
    /// on it.
    pub fn says(d: Driver, config: ?*const config_mod.Config) error{InvalidDriverBinary}!?bool {
        switch (d) {
            .text => return false,
            .binary => return true,
            .named => |driver| {
                var key_buf: [512]u8 = undefined;
                const c = config orelse return null;
                // A name past the buffer is no driver a key could name.
                const key = std.mem.print(&key_buf, "diff.{s}.binary", .{driver}) catch return null;
                var said: ?bool = null;
                var it = c.iterate(&.{key});
                while (it.next()) |entry| {
                    const value = entry.value orelse {
                        said = true;
                        continue;
                    };
                    said = if (std.ascii.eqlIgnoreCase(value, "auto")) null else config_mod.parseBool(value) catch return error.InvalidDriverBinary;
                }
                return said;
            },
        }
    }

    /// Whether `bytes` at a path with this driver are binary, as
    /// `diff_filespec_is_binary`, `grep_source_is_binary` and the zip
    /// archive's `entry_is_binary` decide.
    pub fn isBinary(d: Driver, config: ?*const config_mod.Config, bytes: []const u8) error{InvalidDriverBinary}!bool {
        return try d.says(config) orelse attributes.isBinaryForDiff(bytes);
    }

    /// The driver's word regex for a word diff: `diff.<name>.wordRegex`,
    /// the last set deciding, else the built-in driver's with git's
    /// `|[^[:space:]]|[\xc0-\xff][\x80-\xbf]+` after it (userdiff's
    /// `PATTERNS`; the matcher reads bytes, as git's does outside a UTF-8
    /// locale); `null` for none.
    pub fn wordRegex(d: Driver, config: ?*const config_mod.Config) ?[]const u8 {
        const driver = d.name() orelse return null;
        if (config) |c| {
            var key_buf: [512]u8 = undefined;
            // A name past the buffer is no driver a key could name.
            const key = std.mem.print(&key_buf, "diff.{s}.wordregex", .{driver}) catch return null;
            if (c.get(key)) |value| return value;
        }
        inline for (builtins) |b| {
            if (std.mem.eql(u8, b.name, driver)) return b.words ++ word_tail;
        }
        return null;
    }

    /// The driver's `diff.<name>.textconv`, `null` where it has none, as
    /// userdiff's `userdiff_get_textconv` gives it.
    pub fn conversion(d: Driver, config: ?*const config_mod.Config) error{InvalidDriverCache}!?Conversion {
        const driver = d.name() orelse return null;
        const c = config orelse return null;
        var key_buf: [512]u8 = undefined;
        // A name past the buffer is no driver a key could name.
        const command = c.get(std.mem.print(&key_buf, "diff.{s}.textconv", .{driver}) catch return null) orelse return null;
        const cache_key = std.mem.print(&key_buf, "diff.{s}.cachetextconv", .{driver}) catch return null;
        const cached = c.getBool(cache_key, false) catch return error.InvalidDriverCache;
        return .{ .driver = driver, .command = command, .cached = cached };
    }

    /// The name `Rule.init` takes: the text and binary drivers have no
    /// function lines of their own.
    pub fn name(d: Driver) ?[]const u8 {
        return switch (d) {
            .named => |n| n,
            .text, .binary => null,
        };
    }

    /// A driver of that name: built in, or any `diff.<name>.<key>` set,
    /// as `userdiff_config` makes one for any key.
    fn exists(config: ?*const config_mod.Config, driver: []const u8) bool {
        for (builtins) |b| if (std.mem.eql(u8, b.name, driver)) return true;
        const c = config orelse return false;
        for (c.entries.items) |entry| {
            if (std.mem.eql(u8, entry.section, "diff") and entry.has_subsection and std.mem.eql(u8, entry.subsection, driver)) return true;
        }
        return false;
    }
};

/// A driver's `textconv`: the program a file's bytes are converted by.
pub const Conversion = struct {
    driver: []const u8,
    command: []const u8,
    /// `diff.<driver>.cachetextconv`.
    cached: bool,
};

/// The drivers of a repository's files, as a diff's sides take them: git's
/// `diff_filespec_load_driver`. A regular file's is its path's `diff`
/// attribute's (`Driver.of`); anything else -- a symbolic link, a gitlink,
/// the side a creation or a deletion lacks -- is the driver named
/// `default`, whose `textconv`, `binary` and function lines the
/// configuration sets as any other's. The zero value has no attributes or
/// configuration: every file is `default`'s, binary by its bytes.
pub const Drivers = struct {
    attrs: ?*attributes.Attrs = null,
    /// The working tree whose `.gitattributes` are read on the way down to
    /// a path; `null` reads only what `attrs` holds.
    work_dir: ?Io.Dir = null,
    /// Where `diff.<driver>.*` is read.
    config: ?*const config_mod.Config = null,

    /// A side of a diff: the file's path and mode.
    pub const File = struct { path: []const u8, mode: object.Mode };

    /// The driver `side` takes, `null` being the side a creation or a
    /// deletion lacks. `a` holds the lookup.
    pub fn of(d: Drivers, a: Allocator, io: Io, side: ?File) attributes.Error!Driver {
        const s = side orelse return .{ .named = "default" };
        if (s.mode != .file and s.mode != .exec) return .{ .named = "default" };
        const attrs = d.attrs orelse return Driver.of(d.config, null);
        if (d.work_dir) |wt| try attrs.enter(io, wt, s.path);
        return Driver.of(d.config, (try attrs.lookup(a, s.path, .file)).get("diff"));
    }

    /// Whether `side`, holding `bytes`, is binary, as git's
    /// `diff_filespec_is_binary` decides it. `a` holds the lookup.
    pub fn isBinary(d: Drivers, a: Allocator, io: Io, side: ?File, bytes: []const u8) (attributes.Error || error{InvalidDriverBinary})!bool {
        return (try d.of(a, io, side)).isBinary(d.config, bytes);
    }
};

/// What userdiff's `PATTERNS` puts after each built-in driver's words:
/// any other byte that is no space, and a UTF-8 sequence whole.
const word_tail = "|[^[:space:]]|[\xc0-\xff][\x80-\xbf]+";

const Builtin = struct {
    name: []const u8,
    pattern: []const u8,
    icase: bool = false,
    /// The words a word diff cuts lines into, before git's `|[^[:space:]]`
    /// and UTF-8 tail.
    words: []const u8,
};

/// userdiff.c's drivers: the lines of each pattern are tried in turn, a
/// `!` line refusing what it matches; every one is extended, and those
/// marked are blind to case.
const builtins = [_]Builtin{
    .{ .name = "ada", .pattern = "!^(.*[ \t])?(is[ \t]+new|renames|is[ \t]+separate)([ \t].*)?$\n!^[ \t]*with[ \t].*$\n^[ \t]*((procedure|function)[ \t]+.*)$\n^[ \t]*((package|protected|task)[ \t]+.*)$", .icase = true, .words = "[a-zA-Z][a-zA-Z0-9_]*|[-+]?[0-9][0-9#_.aAbBcCdDeEfF]*([eE][+-]?[0-9_]+)?|=>|\\.\\.|\\*\\*|:=|/=|>=|<=|<<|>>|<>" },
    .{ .name = "bash", .pattern = "^[ \t]*((([a-zA-Z_][a-zA-Z0-9_]*[ \t]*\\([ \t]*\\))|(function[ \t]+[a-zA-Z_][a-zA-Z0-9_]*(([ \t]*\\([ \t]*\\))|([ \t]+)))).*$)", .words = "[a-zA-Z_][a-zA-Z0-9_]*|\\$[a-zA-Z0-9_]+|\\$\\{|\\|\\||&&|<<|>>|==|!=|<=|>=|[-+*/%&|^]=|:=|:-|:\\+|:\\?|##|%%|\\^\\^|,,|[-a-zA-Z0-9_]+|\\(|\\)|\\{|\\}|\\[|\\]" },
    .{ .name = "bibtex", .pattern = "(@[a-zA-Z]{1,}[ \t]*\\{{0,1}[ \t]*[^ \t\"@',\\#}{~%]*).*$", .words = "[={}\"]|[^={}\" \t]+" },
    .{ .name = "cpp", .pattern = "!^[ \t]*[A-Za-z_][A-Za-z_0-9]*:[[:space:]]*($|/[/*])\n^((::[[:space:]]*)?[A-Za-z_].*)$", .words = "[a-zA-Z_][a-zA-Z0-9_]*|[0-9][0-9.]*([Ee][-+]?[0-9]+)?[fFlLuU]*|0[xXbB][0-9a-fA-F]+[lLuU]*|\\.[0-9][0-9]*([Ee][-+]?[0-9]+)?[fFlL]?|[-+*/<>%&^|=!]=|--|\\+\\+|<<=?|>>=?|&&|\\|\\||::|->\\*?|\\.\\*|<=>" },
    .{ .name = "csharp", .pattern = "!(^|[ \t]+)(do|while|for|foreach|if|else|new|default|return|switch|case|throw|catch|using|lock|fixed)([ \t(]+|$)\n^[ \t]*(([][[:alnum:]@_.](<[][[:alnum:]@_, \t<>]+>)?)+([ \t]+([][[:alnum:]@_.](<[][[:alnum:]@_, \t<>]+>)?)+)+[ \t]*\\([^;]*)$\n^[ \t]*(([][[:alnum:]@_.](<[][[:alnum:]@_, \t<>]+>)?)+([ \t]+([][[:alnum:]@_.](<[][[:alnum:]@_, \t<>]+>)?)+)+[^;=:,()]*)$\n^[ \t]*(((static|public|internal|private|protected|new|unsafe|sealed|abstract|partial)[ \t]+)*(class|enum|interface|struct|record)[ \t]+.*)$\n^[ \t]*(namespace[ \t]+.*)$", .words = "[a-zA-Z_][a-zA-Z0-9_]*|[-+0-9.e]+[fFlL]?|0[xXbB]?[0-9a-fA-F]+[lL]?|[-+*/<>%&^|=!]=|--|\\+\\+|<<=?|>>=?|&&|\\|\\||::|->" },
    .{ .name = "css", .pattern = "![:;][[:space:]]*$\n^[:[@.#]?[_a-z0-9].*$", .icase = true, .words = "-?[_a-zA-Z][-_a-zA-Z0-9]*|-?[0-9]+|\\#[0-9a-fA-F]+" },
    .{ .name = "dts", .pattern = "!;\n!=\n^[ \t]*((/[ \t]*\\{|&?[a-zA-Z_]).*)", .words = "[a-zA-Z0-9,._+?#-]+|[-+*/%&^|!~]|>>|<<|&&|\\|\\|" },
    .{ .name = "elixir", .pattern = "^[ \t]*((def(macro|module|impl|protocol|p)?|test)[ \t].*)$", .words = "[@:]?[a-zA-Z0-9@_?!]+|[-+]?0[xob][0-9a-fA-F]+|[-+]?[0-9][0-9_.]*([eE][-+]?[0-9_]+)?|:?(\\+\\+|--|\\.\\.|~~~|<>|\\^\\^\\^|<?\\|>|<<<?|>?>>|<<?~|~>?>|<~>|<=|>=|===?|!==?|=~|&&&?|\\|\\|\\|?|=>|<-|\\\\\\\\|->)|:?%[A-Za-z0-9_.]\\{\\}?" },
    .{ .name = "fortran", .pattern = "!^([C*]|[ \t]*!)\n!^[ \t]*MODULE[ \t]+PROCEDURE[ \t]\n^[ \t]*((END[ \t]+)?(PROGRAM|MODULE|BLOCK[ \t]+DATA|([^!'\" \t]+[ \t]+)*(SUBROUTINE|FUNCTION))[ \t]+[A-Z].*)$", .icase = true, .words = "[a-zA-Z][a-zA-Z0-9_]*|\\.([Ee][Qq]|[Nn][Ee]|[Gg][TtEe]|[Ll][TtEe]|[Tt][Rr][Uu][Ee]|[Ff][Aa][Ll][Ss][Ee]|[Aa][Nn][Dd]|[Oo][Rr]|[Nn]?[Ee][Qq][Vv]|[Nn][Oo][Tt])\\.|[-+]?[0-9.]+([AaIiDdEeFfLlTtXx][Ss]?[-+]?[0-9.]*)?(_[a-zA-Z0-9][a-zA-Z0-9_]*)?|//|\\*\\*|::|[/<>=]=" },
    .{ .name = "fountain", .pattern = "^((\\.[^.]|(int|ext|est|int\\.?/ext|i/e)[. ]).*)$", .icase = true, .words = "[^ \t-]+" },
    .{ .name = "golang", .pattern = "^[ \t]*(func[ \t]*.*(\\{[ \t]*)?)\n^[ \t]*(type[ \t].*(struct|interface)[ \t]*(\\{[ \t]*)?)", .words = "[a-zA-Z_][a-zA-Z0-9_]*|[-+0-9.eE]+i?|0[xX]?[0-9a-fA-F]+i?|[-+*/<>%&^|=!:]=|--|\\+\\+|<<=?|>>=?|&\\^=?|&&|\\|\\||<-|\\.{3}" },
    .{ .name = "html", .pattern = "^[ \t]*(<[Hh][1-6]([ \t].*)?>.*)$", .words = "[^<>= \t]+" },
    .{ .name = "ini", .pattern = "^[ \t]*\\[[^]]+\\]", .words = "[^ \t]+" },
    .{ .name = "java", .pattern = "!^[ \t]*(catch|do|for|if|instanceof|new|return|switch|throw|while)\n^[ \t]*(([a-z-]+[ \t]+)*(class|enum|interface|record)[ \t]+.*)$\n^[ \t]*(([A-Za-z_<>&][][?&<>.,A-Za-z_0-9]*[ \t]+)+[A-Za-z_][A-Za-z_0-9]*[ \t]*\\([^;]*)$", .words = "[a-zA-Z_][a-zA-Z0-9_]*|[-+0-9.e]+[fFlL]?|0[xXbB]?[0-9a-fA-F]+[lL]?|[-+*/<>%&^|=!]=|--|\\+\\+|<<=?|>>>?=?|&&|\\|\\|" },
    .{ .name = "kotlin", .pattern = "^[ \t]*(([a-z]+[ \t]+)*(fun|class|interface)[ \t]+.*)$", .words = "[a-zA-Z_][a-zA-Z0-9_]*|0[xXbB][0-9a-fA-F_]+[lLuU]*|[0-9][0-9_]*([.][0-9_]*)?([Ee][-+]?[0-9]+)?[fFlLuU]*|[.][0-9][0-9_]*([Ee][-+]?[0-9]+)?[fFlLuU]?|[-+*/<>%&^|=!]==?|--|\\+\\+|<<=|>>=|&&|\\|\\||->|\\.\\*|!!|[?:.][.:]" },
    .{ .name = "markdown", .pattern = "^ {0,3}#{1,6}[ \t].*", .words = "[^<>= \t]+" },
    .{ .name = "matlab", .pattern = "^[[:space:]]*((classdef|function)[[:space:]].*)$|^(%%%?|##)[[:space:]].*$", .words = "[a-zA-Z_][a-zA-Z0-9_]*|[-+0-9.e]+|[=~<>]=|\\.[*/\\^']|\\|\\||&&" },
    .{ .name = "objc", .pattern = "!^[ \t]*(do|for|if|else|return|switch|while)\n^[ \t]*([-+][ \t]*\\([ \t]*[A-Za-z_][A-Za-z_0-9* \t]*\\)[ \t]*[A-Za-z_].*)$\n^[ \t]*(([A-Za-z_][A-Za-z_0-9]*[ \t]+)+[A-Za-z_][A-Za-z_0-9]*[ \t]*\\([^;]*)$\n^(@(implementation|interface|protocol)[ \t].*)$", .words = "[a-zA-Z_][a-zA-Z0-9_]*|[-+0-9.e]+[fFlL]?|0[xXbB]?[0-9a-fA-F]+[lL]?|[-+*/<>%&^|=!]=|--|\\+\\+|<<=?|>>=?|&&|\\|\\||::|->" },
    .{ .name = "pascal", .pattern = "^(((class[ \t]+)?(procedure|function)|constructor|destructor|interface|implementation|initialization|finalization)[ \t]*.*)$\n^(.*=[ \t]*(class|record).*)$", .words = "[a-zA-Z_][a-zA-Z0-9_]*|[-+0-9.e]+|0[xXbB]?[0-9a-fA-F]+|<>|<=|>=|:=|\\.\\." },
    .{ .name = "perl", .pattern = "^package .*\n^sub [[:alnum:]_':]+[ \t]*(\\([^)]*\\)[ \t]*)?(:[^;#]*)?(\\{[ \t]*)?(#.*)?$\n^(BEGIN|END|INIT|CHECK|UNITCHECK|AUTOLOAD|DESTROY)[ \t]*(\\{[ \t]*)?(#.*)?$\n^=head[0-9] .*", .words = "[[:alpha:]_'][[:alnum:]_']*|0[xb]?[0-9a-fA-F_]*|[0-9a-fA-F_]+(\\.[0-9a-fA-F_]+)?([eE][-+]?[0-9_]+)?|=>|-[rwxoRWXOezsfdlpSugkbctTBMAC>]|~~|::|&&=|\\|\\|=|//=|\\*\\*=|&&|\\|\\||//|\\+\\+|--|\\*\\*|\\.\\.\\.?|[-+*/%.^&<>=!|]=|=~|!~|<<|<>|<=>|>>" },
    .{ .name = "php", .pattern = "^[\t ]*(((public|protected|private|static|abstract|final)[\t ]+)*function.*)$\n^[\t ]*((((final|abstract)[\t ]+)?class|enum|interface|trait).*)$", .words = "[a-zA-Z_][a-zA-Z0-9_]*|[-+0-9.e]+|0[xXbB]?[0-9a-fA-F]+|[-+*/<>%&^|=!.]=|--|\\+\\+|<<=?|>>=?|===|&&|\\|\\||::|->" },
    .{ .name = "python", .pattern = "^[ \t]*((class|(async[ \t]+)?def)[ \t].*)$", .words = "[a-zA-Z_][a-zA-Z0-9_]*|[-+0-9.e]+[jJlL]?|0[xX]?[0-9a-fA-F]+[lL]?|[-+*/<>%&^|=!]=|//=?|<<=?|>>=?|\\*\\*=?" },
    .{ .name = "r", .pattern = "^[ \t]*([a-zA-z][a-zA-Z0-9_.]*[ \t]*(<-|=)[ \t]*function.*)$", .words = "[^ \t]+" },
    .{ .name = "ruby", .pattern = "^[ \t]*((class|module|def)[ \t].*)$", .words = "(@|@@|\\$)?[a-zA-Z_][a-zA-Z0-9_]*|[-+0-9.e]+|0[xXbB]?[0-9a-fA-F]+|\\?(\\\\C-)?(\\\\M-)?.|//=?|[-+*/<>%&^|=!]=|<<=?|>>=?|===|\\.{1,3}|::|[!=]~" },
    .{ .name = "rust", .pattern = "^[\t ]*((pub(\\([^\\)]+\\))?[\t ]+)?((async|const|unsafe|extern([\t ]+\"[^\"]+\"))[\t ]+)?(struct|enum|union|mod|trait|fn|impl|macro_rules!)[< \t]+[^;]*)$", .words = "[a-zA-Z_][a-zA-Z0-9_]*|[0-9][0-9_a-fA-Fiosuxz]*(\\.([0-9]*[eE][+-]?)?[0-9_fF]*)?|[-+*\\/<>%&^|=!:]=|<<=?|>>=?|&&|\\|\\||->|=>|\\.{2}=|\\.{3}|::" },
    .{ .name = "scheme", .pattern = "^(\\(.*)$\n^[\t ]*(\\(((define|def(struct|syntax|class|method|rules|record|proto|alias)?)[-*/ \t]|(library|module|struct|class)[*+ \t]).*)$\n^  ?(\\([Dd][Ee][Ff].*)$", .words = "\\|([^|\\\\]|\\\\.)*\\||([^][)(}{ \t])+" },
    .{ .name = "tex", .pattern = "^(\\\\((sub)*section|chapter|part)\\*{0,1}\\{.*)$", .words = "\\\\[a-zA-Z@]+|\\\\.|([a-zA-Z0-9]|[^\x01-\x7f])+" },
};

/// How one file's function lines are found.
pub const Rule = struct {
    pub const Error = ErrorNamespace.Error;

    arena: std.heap.ArenaAllocator,
    /// Empty for git's default.
    regs: []Reg,

    const Reg = struct { re: ere.Regex, negate: bool };

    /// The rule for the driver `Driver.name` gives, or git's default lines
    /// for `null` and for a driver with no pattern.
    pub fn init(gpa: Allocator, config: ?*const config_mod.Config, driver: ?[]const u8) Self.Error!Rule {
        var rule: Rule = .{ .arena = .init(gpa), .regs = &.{} };
        errdefer rule.deinit();
        const name = driver orelse return rule;
        const entries = if (config) |c| c.entries.items else &.{};
        // the last of `funcname` and `xfuncname` set wins, as git reads
        // them into one place
        var pattern: ?[]const u8 = null;
        var extended = true;
        var icase = false;
        var from_config = false;
        for (entries) |entry| {
            if (!std.mem.eql(u8, entry.section, "diff") or !entry.has_subsection or !std.mem.eql(u8, entry.subsection, name)) continue;
            if (std.mem.eql(u8, entry.name, "funcname") or std.mem.eql(u8, entry.name, "xfuncname")) {
                pattern = entry.value orelse "";
                extended = entry.name[0] == 'x';
                from_config = true;
            }
        }
        if (pattern == null) for (builtins) |b| {
            if (std.mem.eql(u8, b.name, name)) {
                pattern = b.pattern;
                icase = b.icase;
                break;
            }
        };
        const text = pattern orelse return rule;
        rule.regs = try compile(rule.arena.allocator(), gpa, text, .{ .syntax = if (extended) .extended else .basic, .icase = icase });
        return rule;
    }

    fn compile(a: Allocator, gpa: Allocator, text: []const u8, flags: ere.Flags) ErrorNamespace.Error![]Reg {
        var regs: std.ArrayList(Reg) = .empty;
        errdefer for (regs.items) |*r| r.re.deinit();
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line_in| {
            var line = line_in;
            const negate = line.len > 0 and line[0] == '!';
            if (negate) {
                if (lines.index == null) return error.InvalidFunctionPattern;
                line = line[1..];
            }
            const re = ere.Regex.compile(gpa, line, flags) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidPattern, error.PatternTooComplex => return error.InvalidFunctionPattern,
            };
            try regs.append(a, .{ .re = re, .negate = negate });
        }
        return regs.items;
    }

    pub fn deinit(rule: *Rule) void {
        for (rule.regs) |*r| r.re.deinit();
        rule.arena.deinit();
        rule.* = undefined;
    }

    /// The scratch a `matches` needs, for a `Vm` shared by many rules.
    pub fn programLen(rule: *const Rule) usize {
        var n: usize = 1;
        for (rule.regs) |r| n = @max(n, r.re.program.len);
        return n;
    }

    /// Whether the rule is a driver's pattern rather than git's default.
    pub fn hasPattern(rule: *const Rule) bool {
        return rule.regs.len != 0;
    }

    /// What a hunk's `@@` line shows for `line`, without its newline, when
    /// the driver's pattern takes it for the start of a function: the
    /// pattern's first group, or its whole match where the group took no
    /// part, as git's `ff_regexp` gives it; `null` when a negated line
    /// refuses it or none matches. The caller cuts it and drops its
    /// trailing whitespace. A rule with no pattern finds nothing: git's
    /// default is the caller's.
    pub fn heading(rule: *const Rule, line: []const u8) ere.Regex.FindWithError!?[]const u8 {
        for (rule.regs) |r| {
            var groups: [ere.Regex.max_groups]?ere.Match = undefined;
            const whole = (try r.re.findGroups(line, &groups)) orelse continue;
            if (r.negate) return null;
            const taken = groups[1] orelse whole;
            return line[taken.start..taken.end];
        }
        return null;
    }

    /// Whether `line`, without its newline, starts a function. `vm` is at
    /// least `programLen` long.
    pub fn matches(rule: *const Rule, vm: *ere.Vm, line: []const u8) ere.Regex.FindWithError!bool {
        if (rule.regs.len == 0) {
            if (line.len == 0) return false;
            return std.ascii.isAlphabetic(line[0]) or line[0] == '_' or line[0] == '$';
        }
        for (rule.regs) |r| {
            if (try r.re.findWith(vm, line, false) != null) return !r.negate;
        }
        return false;
    }
};

test "every built-in driver's pattern compiles" {
    const gpa = std.testing.allocator;
    var config = config_mod.Config.initEmpty(gpa);
    defer config.deinit();
    for (builtins) |b| {
        var rule = try Rule.init(gpa, &config, b.name);
        defer rule.deinit();
        try std.testing.expect(rule.regs.len > 0);
    }
}

test "a driver's lines are tried in turn, a negated one refusing the line" {
    const gpa = std.testing.allocator;
    var config = config_mod.Config.initEmpty(gpa);
    defer config.deinit();
    var rule = try Rule.init(gpa, &config, "cpp");
    defer rule.deinit();
    var vm: ere.Vm = try .init(gpa, rule.programLen());
    defer vm.deinit(gpa);
    try std.testing.expect(try rule.matches(&vm, "int main(void)"));
    try std.testing.expect(!try rule.matches(&vm, "label:"));
    try std.testing.expect(!try rule.matches(&vm, "    x = 1;"));
    var default = try Rule.init(gpa, &config, null);
    defer default.deinit();
    try std.testing.expect(try default.matches(&vm, "$x"));
    try std.testing.expect(!try default.matches(&vm, " x"));
}
