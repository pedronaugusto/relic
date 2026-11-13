//! The contract a public root of relic keeps, checked as it compiles, on any
//! target, so that no build of it breaks one. `relic` and `relic_lfs` each
//! hold their surface to it:
//! - every namespace to the surface's depth has exactly one row in the
//!   root's own module table and one in its README table, and neither table
//!   a row for anything else;
//! - each such namespace is its own, offers no test access and names its
//!   errors (`Error`, an error set), as does each type it owns that a caller
//!   releases with `deinit`;
//! - no public function takes more than five positional inputs.
//! A facade publishes every declaration of its implementation (`covers`),
//! and a namespace chosen whole by a feature has every name of the one
//! without it and the one it adds (`sameNamesBut`). A declaration that is
//! there only with `http` (`Surface.http_only`) is passed over without it.
const std = @import("std");
const conduit = @import("conduit");
const fs = @import("fs/fs.zig");
const features = @import("relic_options");

/// A public root's surface: where its two module tables are, and how deep
/// its namespaces go.
pub const Surface = struct {
    /// The root's own source: its module table is the doc comment rows
    /// beginning "//! | `".
    source: []const u8,
    /// The root's path, as its messages name it.
    path: []const u8,
    /// The README, whose table of this root lies between `begin` and `end`.
    readme: []const u8,
    begin: []const u8,
    end: []const u8,
    /// How many levels of namespaces the tables describe.
    depth: usize,
    /// The root's declarations that exist only with `http`, each a
    /// `@compileError` without it, so the checks pass over them there, as
    /// the tables pass over a row that says "Only with `http`.".
    http_only: []const []const u8 = &.{},
};

/// `root` holds to the contract over `surface`.
pub fn check(comptime root: type, comptime surface: Surface) void {
    @setEvalBranchQuota(50_000_000);
    const own = tableNames(surface.source, "//! | `");
    const begin = std.mem.find(u8, surface.readme, surface.begin) orelse @compileError("README.md: no " ++ surface.begin ++ " marker");
    const end = std.mem.find(u8, surface.readme, surface.end) orelse @compileError("README.md: no " ++ surface.end ++ " marker");
    const documented = tableNames(surface.readme[begin..end], "| `");
    const absent: []const []const u8 = if (features.http) &.{} else surface.http_only;
    const count = checkNamespaces(root, "", surface.depth, own, documented, surface, absent);
    if (own.len != count) @compileError(std.fmt.comptimePrint("{s}'s module table has {d} rows for {d} namespaces", .{ surface.path, own.len, count }));
    if (documented.len != count) @compileError(std.fmt.comptimePrint("README.md's table between {s} and {s} has {d} rows for {d} namespaces", .{ surface.begin, surface.end, documented.len, count }));
    checkErrors(root, "", surface.depth, absent);
    checkInputs(root, "", surface.depth + 4, absent);
}

/// `with` has every public name of `base`, and `extra`, and no other.
pub fn sameNamesBut(comptime base: type, comptime with: type, comptime extra: []const u8) void {
    const had = @typeInfo(base).@"struct".decl_names;
    const has = @typeInfo(with).@"struct".decl_names;
    for (had) |name| if (!@hasDecl(with, name)) @compileError("`" ++ extra ++ "`'s choice lacks `" ++ name ++ "`");
    for (has) |name| if (!@hasDecl(base, name) and !std.mem.eql(u8, name, extra)) @compileError("`" ++ extra ++ "`'s choice adds `" ++ name ++ "`");
}

/// `facade` publishes every declaration of `implementation`, as its type.
pub fn covers(comptime facade: type, comptime path: []const u8, comptime implementation: type) void {
    for (@typeInfo(implementation).@"struct".decl_names) |name| {
        if (!@hasDecl(facade, name)) @compileError("`" ++ path ++ "` does not publish `" ++ name ++ "` of its implementation");
        if (@TypeOf(@field(facade, name)) != @TypeOf(@field(implementation, name))) @compileError("`" ++ path ++ "." ++ name ++ "` is not its implementation's");
    }
}

/// The module names a table's rows begin with: each line starting with
/// `row`, its name to the closing backtick. A row that says it is only with
/// `http` names nothing in a build without it.
fn tableNames(comptime text: []const u8, comptime row: []const u8) []const []const u8 {
    var names: []const []const u8 = &.{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, row)) continue;
        if (std.mem.find(u8, line, "Only with `http`.") != null and !features.http) continue;
        const rest = line[row.len..];
        const close = std.mem.findScalar(u8, rest, '`') orelse continue;
        names = names ++ .{rest[0..close]};
    }
    return names;
}

fn isNamespace(comptime ns: type, comptime name: []const u8) bool {
    if (name.len == 0 or !std.ascii.isLower(name[0])) return false;
    const value = @field(ns, name);
    if (@TypeOf(value) != type) return false;
    return switch (@typeInfo(value)) {
        .@"struct" => |s| s.field_names.len == 0 and !s.is_tuple,
        else => false,
    };
}

/// Whether `name` is one of `absent`: a declaration this build does not have.
fn isAbsent(comptime absent: []const []const u8, comptime name: []const u8) bool {
    for (absent) |gone| if (std.mem.eql(u8, gone, name)) return true;
    return false;
}

fn rowsOf(comptime names: []const []const u8, comptime path: []const u8) usize {
    var count: usize = 0;
    for (names) |name| {
        if (std.mem.eql(u8, name, path)) count += 1;
    }
    return count;
}

/// Each namespace under `ns` to `depth` levels, held to one row in each
/// table, to being its own and to offering no test access; how many there
/// are.
fn checkNamespaces(comptime ns: type, comptime prefix: []const u8, comptime depth: usize, comptime own: []const []const u8, comptime documented: []const []const u8, comptime surface: Surface, comptime absent: []const []const u8) usize {
    var count: usize = 0;
    for (@typeInfo(ns).@"struct".decl_names) |name| {
        if (isAbsent(absent, name) or !isNamespace(ns, name)) continue;
        const path = if (prefix.len == 0) name else prefix ++ "." ++ name;
        if (rowsOf(own, path) != 1) @compileError("`" ++ path ++ "` needs one row in " ++ surface.path ++ "'s module table: //! | `" ++ path ++ "` | <purpose> |");
        if (rowsOf(documented, path) != 1) @compileError("`" ++ path ++ "` needs one row in README.md's module table, between its " ++ surface.begin ++ " and " ++ surface.end ++ " markers");
        if (@hasDecl(@field(ns, name), "test_access")) @compileError("`" ++ path ++ "` offers test access");
        for (@typeInfo(ns).@"struct".decl_names) |other| {
            if (!std.mem.eql(u8, name, other) and !isAbsent(absent, other) and isNamespace(ns, other) and @field(ns, name) == @field(ns, other))
                @compileError("`" ++ path ++ "` is the same namespace as `" ++ other ++ "`");
        }
        count += 1;
        if (depth > 1) count += checkNamespaces(@field(ns, name), path, depth - 1, own, documented, surface, &.{});
    }
    return count;
}

/// Types relic publishes as the family package's own, whose conventions
/// are that package's.
const foreign = .{ conduit.Child, fs.OwnedDir, fs.OwnedFile, fs.OwnedStream, fs.OwnedServer };

fn isForeign(comptime T: type) bool {
    inline for (foreign) |F| if (T == F) return true;
    return false;
}

/// Each namespace under `ns` to `depth` levels, and each type of one that
/// a caller releases with `deinit`, names its errors: `Error`, an error
/// set with names.
fn checkErrors(comptime ns: type, comptime prefix: []const u8, comptime depth: usize, comptime absent: []const []const u8) void {
    for (@typeInfo(ns).@"struct".decl_names) |name| {
        if (isAbsent(absent, name)) continue;
        const value = @field(ns, name);
        if (@TypeOf(value) != type or isForeign(value) or @typeInfo(value) != .@"struct") continue;
        const path = if (prefix.len == 0) name else prefix ++ "." ++ name;
        if (isNamespace(ns, name) or @hasDecl(value, "deinit")) {
            if (!@hasDecl(value, "Error")) @compileError("`" ++ path ++ "` names no errors: it needs `pub const Error`, an error set");
            if (@typeInfo(value.Error) != .error_set or @typeInfo(value.Error).error_set.error_names == null)
                @compileError("`" ++ path ++ ".Error` is not an error set with names");
        }
        if (isNamespace(ns, name) and depth > 1) checkErrors(value, path, depth - 1, &.{});
    }
}

/// No public function under `ns`, to `depth` levels of namespaces and
/// types, takes more than five positional inputs; more go in an options
/// or inputs struct.
fn checkInputs(comptime ns: type, comptime prefix: []const u8, comptime depth: usize, comptime absent: []const []const u8) void {
    if (depth == 0) return;
    const names = switch (@typeInfo(ns)) {
        .@"struct" => |s| s.decl_names,
        .@"union" => |s| s.decl_names,
        .@"enum" => |s| s.decl_names,
        else => return,
    };
    for (names) |name| {
        if (isAbsent(absent, name)) continue;
        const value = @field(ns, name);
        const path = if (prefix.len == 0) name else prefix ++ "." ++ name;
        if (@TypeOf(value) == type) {
            checkInputs(value, path, depth - 1, &.{});
        } else if (@typeInfo(@TypeOf(value)) == .@"fn") {
            const inputs = @typeInfo(@TypeOf(value)).@"fn".param_types.len;
            if (inputs > 5) @compileError(std.fmt.comptimePrint("`{s}` takes {d} positional inputs; at most five, the rest in an options or inputs struct", .{ path, inputs }));
        }
    }
}
