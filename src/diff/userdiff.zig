//! The lines git takes for the start of a function: the `diff` driver's
//! `funcname` or `xfuncname` from the configuration, else git's built-in
//! driver of that name, else git's default — a line starting with a
//! letter, `_` or `$`. What `git grep -p` and `-W` look for.

const ErrorNamespace = @This();
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const ere = @import("../text/ere.zig");
const config_mod = @import("../config/config.zig");

/// Errors from reading a driver's patterns.
pub const Error = error{
    /// A pattern that does not compile, or a last one that is negated,
    /// both of which git dies on.
    InvalidFunctionPattern,
} || Allocator.Error;

const Builtin = struct { name: []const u8, pattern: []const u8, icase: bool = false };

/// userdiff.c's drivers: the lines of each pattern are tried in turn, a
/// `!` line refusing what it matches; every one is extended, and those
/// marked are blind to case.
const builtins = [_]Builtin{
    .{ .name = "ada", .pattern = "!^(.*[ \t])?(is[ \t]+new|renames|is[ \t]+separate)([ \t].*)?$\n!^[ \t]*with[ \t].*$\n^[ \t]*((procedure|function)[ \t]+.*)$\n^[ \t]*((package|protected|task)[ \t]+.*)$", .icase = true },
    .{ .name = "bash", .pattern = "^[ \t]*((([a-zA-Z_][a-zA-Z0-9_]*[ \t]*\\([ \t]*\\))|(function[ \t]+[a-zA-Z_][a-zA-Z0-9_]*(([ \t]*\\([ \t]*\\))|([ \t]+)))).*$)" },
    .{ .name = "bibtex", .pattern = "(@[a-zA-Z]{1,}[ \t]*\\{{0,1}[ \t]*[^ \t\"@',\\#}{~%]*).*$" },
    .{ .name = "cpp", .pattern = "!^[ \t]*[A-Za-z_][A-Za-z_0-9]*:[[:space:]]*($|/[/*])\n^((::[[:space:]]*)?[A-Za-z_].*)$" },
    .{ .name = "csharp", .pattern = "!(^|[ \t]+)(do|while|for|foreach|if|else|new|default|return|switch|case|throw|catch|using|lock|fixed)([ \t(]+|$)\n^[ \t]*(([][[:alnum:]@_.](<[][[:alnum:]@_, \t<>]+>)?)+([ \t]+([][[:alnum:]@_.](<[][[:alnum:]@_, \t<>]+>)?)+)+[ \t]*\\([^;]*)$\n^[ \t]*(([][[:alnum:]@_.](<[][[:alnum:]@_, \t<>]+>)?)+([ \t]+([][[:alnum:]@_.](<[][[:alnum:]@_, \t<>]+>)?)+)+[^;=:,()]*)$\n^[ \t]*(((static|public|internal|private|protected|new|unsafe|sealed|abstract|partial)[ \t]+)*(class|enum|interface|struct|record)[ \t]+.*)$\n^[ \t]*(namespace[ \t]+.*)$" },
    .{ .name = "css", .pattern = "![:;][[:space:]]*$\n^[:[@.#]?[_a-z0-9].*$", .icase = true },
    .{ .name = "dts", .pattern = "!;\n!=\n^[ \t]*((/[ \t]*\\{|&?[a-zA-Z_]).*)" },
    .{ .name = "elixir", .pattern = "^[ \t]*((def(macro|module|impl|protocol|p)?|test)[ \t].*)$" },
    .{ .name = "fortran", .pattern = "!^([C*]|[ \t]*!)\n!^[ \t]*MODULE[ \t]+PROCEDURE[ \t]\n^[ \t]*((END[ \t]+)?(PROGRAM|MODULE|BLOCK[ \t]+DATA|([^!'\" \t]+[ \t]+)*(SUBROUTINE|FUNCTION))[ \t]+[A-Z].*)$", .icase = true },
    .{ .name = "fountain", .pattern = "^((\\.[^.]|(int|ext|est|int\\.?/ext|i/e)[. ]).*)$", .icase = true },
    .{ .name = "golang", .pattern = "^[ \t]*(func[ \t]*.*(\\{[ \t]*)?)\n^[ \t]*(type[ \t].*(struct|interface)[ \t]*(\\{[ \t]*)?)" },
    .{ .name = "html", .pattern = "^[ \t]*(<[Hh][1-6]([ \t].*)?>.*)$" },
    .{ .name = "ini", .pattern = "^[ \t]*\\[[^]]+\\]" },
    .{ .name = "java", .pattern = "!^[ \t]*(catch|do|for|if|instanceof|new|return|switch|throw|while)\n^[ \t]*(([a-z-]+[ \t]+)*(class|enum|interface|record)[ \t]+.*)$\n^[ \t]*(([A-Za-z_<>&][][?&<>.,A-Za-z_0-9]*[ \t]+)+[A-Za-z_][A-Za-z_0-9]*[ \t]*\\([^;]*)$" },
    .{ .name = "kotlin", .pattern = "^[ \t]*(([a-z]+[ \t]+)*(fun|class|interface)[ \t]+.*)$" },
    .{ .name = "markdown", .pattern = "^ {0,3}#{1,6}[ \t].*" },
    .{ .name = "matlab", .pattern = "^[[:space:]]*((classdef|function)[[:space:]].*)$|^(%%%?|##)[[:space:]].*$" },
    .{ .name = "objc", .pattern = "!^[ \t]*(do|for|if|else|return|switch|while)\n^[ \t]*([-+][ \t]*\\([ \t]*[A-Za-z_][A-Za-z_0-9* \t]*\\)[ \t]*[A-Za-z_].*)$\n^[ \t]*(([A-Za-z_][A-Za-z_0-9]*[ \t]+)+[A-Za-z_][A-Za-z_0-9]*[ \t]*\\([^;]*)$\n^(@(implementation|interface|protocol)[ \t].*)$" },
    .{ .name = "pascal", .pattern = "^(((class[ \t]+)?(procedure|function)|constructor|destructor|interface|implementation|initialization|finalization)[ \t]*.*)$\n^(.*=[ \t]*(class|record).*)$" },
    .{ .name = "perl", .pattern = "^package .*\n^sub [[:alnum:]_':]+[ \t]*(\\([^)]*\\)[ \t]*)?(:[^;#]*)?(\\{[ \t]*)?(#.*)?$\n^(BEGIN|END|INIT|CHECK|UNITCHECK|AUTOLOAD|DESTROY)[ \t]*(\\{[ \t]*)?(#.*)?$\n^=head[0-9] .*" },
    .{ .name = "php", .pattern = "^[\t ]*(((public|protected|private|static|abstract|final)[\t ]+)*function.*)$\n^[\t ]*((((final|abstract)[\t ]+)?class|enum|interface|trait).*)$" },
    .{ .name = "python", .pattern = "^[ \t]*((class|(async[ \t]+)?def)[ \t].*)$" },
    .{ .name = "r", .pattern = "^[ \t]*([a-zA-z][a-zA-Z0-9_.]*[ \t]*(<-|=)[ \t]*function.*)$" },
    .{ .name = "ruby", .pattern = "^[ \t]*((class|module|def)[ \t].*)$" },
    .{ .name = "rust", .pattern = "^[\t ]*((pub(\\([^\\)]+\\))?[\t ]+)?((async|const|unsafe|extern([\t ]+\"[^\"]+\"))[\t ]+)?(struct|enum|union|mod|trait|fn|impl|macro_rules!)[< \t]+[^;]*)$" },
    .{ .name = "scheme", .pattern = "^(\\(.*)$\n^[\t ]*(\\(((define|def(struct|syntax|class|method|rules|record|proto|alias)?)[-*/ \t]|(library|module|struct|class)[*+ \t]).*)$\n^  ?(\\([Dd][Ee][Ff].*)$" },
    .{ .name = "tex", .pattern = "^(\\\\((sub)*section|chapter|part)\\*{0,1}\\{.*)$" },
};

/// How one file's function lines are found.
pub const Rule = struct {
    pub const Error = ErrorNamespace.Error;

    arena: std.heap.ArenaAllocator,
    /// Empty for git's default.
    regs: []Reg,

    const Reg = struct { re: ere.Regex, negate: bool };

    /// The rule for the driver the `diff` attribute names, or git's
    /// default for `null` or a name no driver has.
    pub fn init(gpa: Allocator, config: *const config_mod.Config, driver: ?[]const u8) Self.Error!Rule {
        var rule: Rule = .{ .arena = .init(gpa), .regs = &.{} };
        errdefer rule.deinit();
        const name = driver orelse return rule;
        // the last of `funcname` and `xfuncname` set wins, as git reads
        // them into one place
        var pattern: ?[]const u8 = null;
        var extended = true;
        var icase = false;
        var from_config = false;
        for (config.entries.items) |entry| {
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
