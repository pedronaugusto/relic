//! relic — read and write a git repository from Zig.
//!
//! The table below describes the exported namespaces; it is checked against
//! the API, and the README's against both, wherever relic compiles.
//!
//! | Module | Purpose |
//! |---|---|
//! | `repo` | Public concern. |
//! | `repo.warning` | Module within `repo`. |
//! | `repo.hooks` | Module within `repo`. |
//! | `repo.program` | Module within `repo`. |
//! | `repo.fs` | Module within `repo`. |
//! | `repo.safe` | Module within `repo`. |
//! | `repo.ident` | Module within `repo`. |
//! | `repo.state` | The state files an operation keeps in the git directory: written, read and removed in one place. |
//! | `repo.rev_parse` | Module within `repo`. |
//! | `hash` | Public concern. |
//! | `hash.sha1` | Module within `hash`. |
//! | `hash.sha1dc` | Module within `hash`. |
//! | `object` | Public concern. |
//! | `object.fsck` | Module within `object`. |
//! | `odb` | Public concern. |
//! | `odb.abbrev` | Module within `odb`. |
//! | `odb.bitmap` | Module within `odb`. |
//! | `odb.commit_graph` | Module within `odb`. |
//! | `odb.commit_graph.bloom` | Module within `odb.commit_graph`. |
//! | `odb.rev_index` | Module within `odb`. |
//! | `odb.mtimes` | Module within `odb`. |
//! | `odb.islands` | Delta islands, the pack writer's side: which islands each object is in, and whether one may be a delta of another. |
//! | `odb.index_pack` | Module within `odb`. |
//! | `odb.pack` | Module within `odb`. |
//! | `odb.delta` | Module within `odb`. |
//! | `odb.midx` | Module within `odb`. |
//! | `odb.quarantine` | Module within `odb`. |
//! | `refs` | Public concern. |
//! | `refs.reftable` | Module within `refs`. |
//! | `refs.reftable.table` | The reftable format: one table read and written. |
//! | `refs.reftable.stack` | The stack of tables `tables.list` names: the ref store. |
//! | `refs.verify` | git's `refs verify`: what is wrong with the refs themselves, by `fsck.<msg-id>`. |
//! | `refs.names` | Module within `refs`. |
//! | `config` | Public concern. |
//! | `config.user` | Module within `config`. |
//! | `config.color` | git's colours: values, `color.ui` and the writers' settings and slots. |
//! | `index` | Public concern. |
//! | `index.sparse` | Module within `index`. |
//! | `index.untracked` | The untracked cache, git's `UNTR`: read, kept true as entries come and go, and written. |
//! | `worktree` | Public concern. |
//! | `worktree.sparse_checkout` | Module within `worktree`. |
//! | `worktree.linked` | Module within `worktree`. |
//! | `worktree.snapshot` | Module within `worktree`. |
//! | `worktree.renames` | Module within `worktree`. |
//! | `worktree.remove` | `git rm`: the index entries a pathspec names removed, and their files and submodules, after git's check for what the removal would lose. |
//! | `worktree.move` | `git mv`: files, directories and submodules renamed in the working tree and the index together, after git's checks of every source. |
//! | `worktree.sparse` | Module within `worktree`. |
//! | `worktree.ignore` | Module within `worktree`. |
//! | `worktree.attributes` | Module within `worktree`. |
//! | `worktree.convert` | Module within `worktree`. |
//! | `worktree.encoding` | Module within `worktree`. |
//! | `worktree.fsmonitor` | Module within `worktree`. |
//! | `worktree.filter` | Module within `worktree`. |
//! | `worktree.filter.native` | Native content-filter protocol. |
//! | `worktree.dir_scan` | Module within `worktree`. |
//! | `worktree.safe_path` | Module within `worktree`. |
//! | `diff` | Public concern. |
//! | `diff.blame` | Module within `diff`. |
//! | `diff.combined` | Module within `diff`. |
//! | `diff.driver` | Module within `diff`. |
//! | `diff.external` | Module within `diff`. |
//! | `diff.patch_id` | Module within `diff`. |
//! | `diff.rename` | Module within `diff`. |
//! | `diff.similarity` | Module within `diff`. |
//! | `diff.stat` | Module within `diff`. |
//! | `diff.textconv` | Module within `diff`. |
//! | `rev_walk` | Public concern. |
//! | `rev_walk.bisect` | Module within `rev_walk`. |
//! | `rev_walk.describe` | Module within `rev_walk`. |
//! | `rev_walk.fork_point` | Module within `rev_walk`. |
//! | `rev_walk.follow` | Module within `rev_walk`. |
//! | `rev_walk.last_modified` | Module within `rev_walk`. |
//! | `rev_walk.path_walk` | Module within `rev_walk`. |
//! | `rev_walk.mailmap` | Module within `rev_walk`. |
//! | `rev_walk.shallow` | Module within `rev_walk`. |
//! | `rev_walk.object` | Module within `rev_walk`. |
//! | `rev_walk.object.walk` | Module within `rev_walk.object`. |
//! | `rev_walk.object.filter` | Module within `rev_walk.object`. |
//! | `merge` | Public concern. |
//! | `merge.rerere` | Module within `merge`. |
//! | `merge.three_way` | Module within `merge`. |
//! | `merge.subtree_shift` | Module within `merge`. |
//! | `merge.strategy` | Module within `merge`. |
//! | `merge.ort` | Module within `merge`. |
//! | `merge.octopus` | Module within `merge`. |
//! | `commit` | Public concern. |
//! | `commit.notes` | Module within `commit`. |
//! | `commit.todo` | Module within `commit`. |
//! | `commit.branch` | Module within `commit`. |
//! | `commit.rebase` | Module within `commit`. |
//! | `commit.replay` | Module within `commit`. |
//! | `commit.history` | Module within `commit`. |
//! | `commit.sequencer` | Module within `commit`. |
//! | `commit.merging` | Module within `commit`. |
//! | `commit.stash` | Module within `commit`. |
//! | `commit.in_progress` | `read`: which operations a worktree is in the middle of, as `git status` says. |
//! | `commit.message` | Module within `commit`. |
//! | `commit.trailer` | Module within `commit`. |
//! | `commit.head` | Module within `commit`. |
//! | `commit.reset` | Module within `commit`. |
//! | `commit.signing` | Module within `commit`. |
//! | `commit.hooks` | Module within `commit`. |
//! | `transport` | Public concern. |
//! | `transport.filter_spec` | Module within `transport`. |
//! | `transport.partial` | Module within `transport`. |
//! | `transport.side_band` | Module within `transport`. |
//! | `transport.http_settings` | Module within `transport`. |
//! | `transport.hidden` | Module within `transport`. |
//! | `transport.promisors` | Module within `transport`. |
//! | `transport.push` | Module within `transport`. |
//! | `transport.clone` | Module within `transport`. |
//! | `transport.fetch` | Module within `transport`. |
//! | `transport.pull` | Module within `transport`. |
//! | `transport.backfill` | Module within `transport`. |
//! | `transport.refspec` | Module within `transport`. |
//! | `transport.remote` | Module within `transport`. |
//! | `transport.url` | Module within `transport`. |
//! | `transport.fetch_pack` | Module within `transport`. |
//! | `transport.send_pack` | Module within `transport`. |
//! | `transport.local` | Module within `transport`. |
//! | `transport.ssh` | Module within `transport`. |
//! | `transport.smart_http` | Module within `transport`. |
//! | `transport.credential` | Module within `transport`. |
//! | `transport.credential.cache` | git's `credential-cache` client. |
//! | `transport.credential_cache_daemon` | Module within `transport`. |
//! | `transport.auth` | Module within `transport`. |
//! | `transport.protocol` | Module within `transport`. |
//! | `transport.connection` | Module within `transport`. |
//! | `transport.pkt_line` | Module within `transport`. |
//! | `transport.upload_pack` | Module within `transport`. |
//! | `transport.receive_pack` | Module within `transport`. |
//! | `transport.http_backend` | Module within `transport`. |
//! | `transport.bundle` | Module within `transport`. |
//! | `transport.bundle_uri` | Module within `transport`. |
//! | `transport.progress` | Module within `transport`. |
//! | `transport.remote_helper` | Module within `transport`. |
//! | `transport.policy` | Module within `transport`. |
//! | `submodule` | Public concern. |
//! | `submodule.gitmodules` | Module within `submodule`. |
//! | `submodule.gitlink` | Module within `submodule`. |
//! | `lfs` | Public concern. |
//! | `lfs.filter` | Native LFS filters selected by an operation owner. |
//! | `lfs.clone` | Clone with native LFS checkout and downloads. |
//! | `lfs.netrc` | Module within `lfs`. |
//! | `lfs.ssh` | Module within `lfs`. |
//! | `lfs.hooks` | Module within `lfs`. |
//! | `lfs.push` | Module within `lfs`. |
//! | `lfs.locks` | Module within `lfs`. |
//! | `lfs.transfer` | Module within `lfs`. |
//! | `lfs.custom` | Module within `lfs`. |
//! | `lfs.api` | Module within `lfs`. |
//! | `lfs.server` | Module within `lfs`. |
//! | `patch` | Public concern. |
//! | `patch.am` | Module within `patch`. |
//! | `patch.commit_diff` | Module within `patch`. |
//! | `patch.mail` | Module within `patch`. |
//! | `patch.format` | Module within `patch`. |
//! | `patch.apply` | Module within `patch`. |
//! | `patch.range_diff` | Module within `patch`. |
//! | `grep` | Public concern. |
//! | `archive` | Public concern. |
//! | `archive.remote` | Module within `archive`. |
//! | `pretty` | Public concern. |
//! | `pretty.log` | Module within `pretty`. |
//! | `pretty.refs` | Module within `pretty`. |
//! | `pretty.shortlog` | Module within `pretty`. |
//! | `clean` | Public concern. |
//! | `fast` | Public concern. |
//! | `fast.importer` | Module within `fast`. |
//! | `fast.exporter` | Module within `fast`. |
//! | `maintenance` | Public concern. |

pub const repo = @import("repo.zig");
pub const hash = @import("hash.zig");
pub const object = @import("object.zig");
pub const odb = @import("odb.zig");
pub const refs = @import("refs.zig");
pub const config = @import("config.zig");
pub const index = @import("index.zig");
pub const worktree = @import("worktree.zig");
pub const diff = @import("diff.zig");
pub const rev_walk = @import("rev_walk.zig");
pub const merge = @import("merge.zig");
pub const commit = @import("commit.zig");
pub const transport = @import("transport.zig");
pub const submodule = @import("submodule.zig");
pub const lfs = @import("lfs.zig");
pub const patch = @import("patch.zig");
pub const grep = @import("grep.zig");
pub const archive = @import("archive.zig");
pub const pretty = @import("pretty.zig");
pub const clean = @import("clean.zig");
pub const fast = @import("fast.zig");

pub const maintenance = @import("maintenance.zig");

// The contract relic's public surface keeps, checked as relic compiles, on
// any target, so that no build of it breaks one:
// - every namespace three levels down has exactly one row in the table
//   above and one in the README's, and neither table a row for anything
//   else;
// - each such namespace is its own, offers no test access and names its
//   errors (`Error`, an error set), as does each type it owns that a caller
//   releases with `deinit`;
// - a facade publishes every declaration of its implementation, as the
//   implementation's type;
// - no public function takes more than five positional inputs;
// - how a program ended is conduit's `Term` wherever relic shows it, and a
//   program's working directory is relic's own `Cwd`.
comptime {
    @setEvalBranchQuota(50_000_000);
    const own = tableNames(@embedFile("relic.zig"), "//! | `");
    const readme = @embedFile("README.md");
    const begin = std.mem.find(u8, readme, "<!-- BEGIN MODULES -->") orelse @compileError("README.md: no <!-- BEGIN MODULES --> marker");
    const end = std.mem.find(u8, readme, "<!-- END MODULES -->") orelse @compileError("README.md: no <!-- END MODULES --> marker");
    const documented = tableNames(readme[begin..end], "| `");
    const count = checkNamespaces(@This(), "", 3, own, documented);
    if (own.len != count) @compileError(std.fmt.comptimePrint("src/relic.zig's module table has {d} rows for {d} namespaces", .{ own.len, count }));
    if (documented.len != count) @compileError(std.fmt.comptimePrint("README.md's module table has {d} rows for {d} namespaces", .{ documented.len, count }));
    checkErrors(@This(), "", 3);
    checkInputs(@This(), "", 7);
    for (facades) |facade| covers(facade[0], facade[1], facade[2]);
    checkPrograms();
}

const std = @import("std");
const conduit = @import("conduit");

/// The module names a table's rows begin with: each line starting with
/// `row`, its name to the closing backtick.
fn tableNames(comptime text: []const u8, comptime row: []const u8) []const []const u8 {
    var names: []const []const u8 = &.{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, row)) continue;
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
fn checkNamespaces(comptime ns: type, comptime prefix: []const u8, comptime depth: usize, comptime own: []const []const u8, comptime documented: []const []const u8) usize {
    var count: usize = 0;
    for (@typeInfo(ns).@"struct".decl_names) |name| {
        if (!isNamespace(ns, name)) continue;
        const path = if (prefix.len == 0) name else prefix ++ "." ++ name;
        if (rowsOf(own, path) != 1) @compileError("`" ++ path ++ "` needs one row in src/relic.zig's module table: //! | `" ++ path ++ "` | <purpose> |");
        if (rowsOf(documented, path) != 1) @compileError("`" ++ path ++ "` needs one row in README.md's module table, between its BEGIN MODULES and END MODULES markers");
        if (@hasDecl(@field(ns, name), "test_access")) @compileError("`" ++ path ++ "` offers test access");
        for (@typeInfo(ns).@"struct".decl_names) |other| {
            if (!std.mem.eql(u8, name, other) and isNamespace(ns, other) and @field(ns, name) == @field(ns, other))
                @compileError("`" ++ path ++ "` is the same namespace as `" ++ other ++ "`");
        }
        count += 1;
        if (depth > 1) count += checkNamespaces(@field(ns, name), path, depth - 1, own, documented);
    }
    return count;
}

/// Types relic publishes as the family package's own, whose conventions
/// are that package's.
const foreign = .{conduit.Child};

fn isForeign(comptime T: type) bool {
    inline for (foreign) |F| if (T == F) return true;
    return false;
}

/// Each namespace under `ns` to `depth` levels, and each type of one that
/// a caller releases with `deinit`, names its errors: `Error`, an error
/// set with names.
fn checkErrors(comptime ns: type, comptime prefix: []const u8, comptime depth: usize) void {
    for (@typeInfo(ns).@"struct".decl_names) |name| {
        const value = @field(ns, name);
        if (@TypeOf(value) != type or isForeign(value) or @typeInfo(value) != .@"struct") continue;
        const path = if (prefix.len == 0) name else prefix ++ "." ++ name;
        if (isNamespace(ns, name) or @hasDecl(value, "deinit")) {
            if (!@hasDecl(value, "Error")) @compileError("`" ++ path ++ "` names no errors: it needs `pub const Error`, an error set");
            if (@typeInfo(value.Error) != .error_set or @typeInfo(value.Error).error_set.error_names == null)
                @compileError("`" ++ path ++ ".Error` is not an error set with names");
        }
        if (isNamespace(ns, name) and depth > 1) checkErrors(value, path, depth - 1);
    }
}

/// No public function under `ns`, to `depth` levels of namespaces and
/// types, takes more than five positional inputs; more go in an options
/// or inputs struct.
fn checkInputs(comptime ns: type, comptime prefix: []const u8, comptime depth: usize) void {
    if (depth == 0) return;
    const names = switch (@typeInfo(ns)) {
        .@"struct" => |s| s.decl_names,
        .@"union" => |s| s.decl_names,
        .@"enum" => |s| s.decl_names,
        else => return,
    };
    for (names) |name| {
        const value = @field(ns, name);
        const path = if (prefix.len == 0) name else prefix ++ "." ++ name;
        if (@TypeOf(value) == type) {
            checkInputs(value, path, depth - 1);
        } else if (@typeInfo(@TypeOf(value)) == .@"fn") {
            const inputs = @typeInfo(@TypeOf(value)).@"fn".param_types.len;
            if (inputs > 5) @compileError(std.fmt.comptimePrint("`{s}` takes {d} positional inputs; at most five, the rest in an options or inputs struct", .{ path, inputs }));
        }
    }
}

/// Each facade, its path, and the implementation it publishes.
const facades = .{
    .{ repo, "repo", @import("repo/repo.zig") },
    .{ hash, "hash", @import("hash/hash.zig") },
    .{ object, "object", @import("object/object.zig") },
    .{ odb, "odb", @import("odb/odb.zig") },
    .{ refs, "refs", @import("refs/refs.zig") },
    .{ config, "config", @import("config/config.zig") },
    .{ index, "index", @import("index/index.zig") },
    .{ worktree, "worktree", @import("checkout/checkout.zig") },
    .{ diff, "diff", @import("diff/diff.zig") },
    .{ rev_walk, "rev_walk", @import("walk/walk.zig") },
    .{ merge, "merge", @import("merge/merge.zig") },
    .{ commit, "commit", @import("commit/commit.zig") },
    .{ transport, "transport", @import("transport/transport.zig") },
    .{ submodule, "submodule", @import("submodule/submodule.zig") },
    .{ lfs, "lfs", @import("lfs/lfs.zig") },
    .{ patch, "patch", @import("patch/patch.zig") },
    .{ pretty, "pretty", @import("pretty/pretty.zig") },
    .{ maintenance, "maintenance", @import("maintenance/maintenance.zig") },
};

/// `facade` publishes every declaration of `implementation`, as its type.
fn covers(comptime facade: type, comptime path: []const u8, comptime implementation: type) void {
    for (@typeInfo(implementation).@"struct".decl_names) |name| {
        if (!@hasDecl(facade, name)) @compileError("`" ++ path ++ "` does not publish `" ++ name ++ "` of its implementation");
        if (@TypeOf(@field(facade, name)) != @TypeOf(@field(implementation, name))) @compileError("`" ++ path ++ "." ++ name ++ "` is not its implementation's");
    }
}

/// How a program ended is conduit's `Term` wherever relic shows it, never
/// the standard library's, and a program's working directory is relic's
/// own `Cwd`.
fn checkPrograms() void {
    const program = repo.program;
    if (@FieldType(program.Invocation, "cwd") != program.Cwd or @FieldType(commit.trailer.Commands, "cwd") != program.Cwd)
        @compileError("a program's working directory is `repo.program.Cwd`");
    const terms = .{
        program.Term,
        @FieldType(program.Outcome, "term"),
        program.Child.Term,
        @typeInfo(@typeInfo(@TypeOf(program.Running.wait)).@"fn".return_type.?).error_union.payload,
        @typeInfo(@typeInfo(@TypeOf(program.Child.wait)).@"fn".return_type.?).error_union.payload,
        @typeInfo(@FieldType(repo.hooks.Failure, "term")).optional.child,
        @typeInfo(@FieldType(transport.connection.Process, "term")).optional.child,
    };
    inline for (terms) |term| if (term != conduit.Term) @compileError("how a program ended is `conduit.Term`");
}
