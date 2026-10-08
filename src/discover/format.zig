//! A repository's format: the hash its objects are named with and where
//! its refs are kept, decided as git's `read_repository_format` and
//! `verify_repository_format` decide them, from the repository's own
//! `config` alone. No include, no other level and no `-c` has a say, and
//! every reader of a repository -- the repository itself, a submodule's
//! gitlink, a new worktree -- takes the format from here rather than from
//! what it finds on the disk.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("../hash/hash.zig");
const config_mod = @import("../config/config.zig");
const fs = @import("../fs/fs.zig");
const diagnostic_mod = @import("../report/diagnostic.zig");
const refs = @import("../refs/value.zig");

const Diagnostic = diagnostic_mod.Diagnostic;

/// What a repository's own configuration says it is.
pub const Format = struct {
    /// The hash every object name is written with:
    /// `extensions.objectFormat`.
    kind: hash.Kind = .sha1,
    /// Where the refs are kept: `extensions.refStorage`.
    ref_storage: refs.Format = .files,
    /// Whether each worktree's `config.worktree` is read after the
    /// repository's own: `extensions.worktreeConfig`.
    worktree_config: bool = false,
};

/// Why a format was refused. `diagnostic`, when given, names the setting.
pub const Error = error{
    /// `core.repositoryFormatVersion` is neither 0 nor 1.
    UnsupportedRepositoryVersion,
    /// An extension this release does not know, or one git honours only
    /// at version 1 found at version 0.
    UnsupportedExtension,
    /// `extensions.objectFormat` names no hash this release has.
    UnknownObjectFormat,
    /// `extensions.refStorage` names neither `files` nor `reftable`.
    UnsupportedRefStorage,
} || config_mod.ValueError || Allocator.Error;

/// Errors from reading the format of a repository on the disk.
pub const ReadError = Error || config_mod.ParseError || Io.Dir.ReadFileAllocError;

/// The largest repository configuration read for its format.
const max_config_bytes = 1 << 24;

/// Read `config` in `common_dir`, the repository's own and nothing it
/// includes, and decide the format from it. A repository with no
/// `config` is a version 0 repository with SHA-1 names and loose refs.
pub fn read(gpa: Allocator, io: Io, common_dir: Io.Dir, diagnostic: ?*Diagnostic) Self.ReadError!Format {
    const text = (try fs.readFileAlloc(gpa, io, common_dir, "config", max_config_bytes)) orelse return .{};
    defer gpa.free(text);
    return parse(gpa, text, diagnostic);
}

/// Errors from `parse`.
pub const ParseError = Self.Error || config_mod.ParseError;

/// Decide the format from the text of a repository's own `config`: what
/// `read` decides once it has the file, and what a write about to replace
/// the file would leave.
pub fn parse(gpa: Allocator, text: []const u8, diagnostic: ?*Diagnostic) ParseError!Format {
    var config = try config_mod.Config.parseText(gpa, text, .local);
    defer config.deinit();
    return decide(&config, diagnostic);
}

/// The extensions git takes only from a version 1 repository: one of
/// them at version 0 is git's "v1-only extension found" and refused.
const v1_only_extensions = [_][]const u8{ "noop-v1", "objectformat", "compatobjectformat", "refstorage", "relativeworktrees" };

/// The extensions this release understands at format version 1.
///
/// Anything else is refused by name rather than ignored, which is what
/// git's own format document requires: an extension exists precisely
/// because a reader that does not know it would read the repository
/// wrongly.
const known_extensions = [_][]const u8{
    "noop",
    "noop-v1",
    "objectformat",
    "preciousobjects",
    "worktreeconfig",
    "relativeworktrees",
    "refstorage",
    // A partial clone's promisor remote, as git before 2.44 names it;
    // the objects it may be asked for are read as any others.
    "partialclone",
};

/// Decide the format from a repository's own configuration, already
/// parsed: the configuration shared by its worktrees, none of whose
/// settings has a say.
pub fn decide(config: *const config_mod.Config, diagnostic: ?*Diagnostic) Self.Error!Format {
    const version = try config.getInt("core.repositoryformatversion", 0);
    if (version < 0 or version > 1) {
        try diagnostic_mod.refuse(diagnostic, "core.repositoryFormatVersion");
        return error.UnsupportedRepositoryVersion;
    }
    if (version == 1) try checkExtensions(config, diagnostic) else {
        for (config.entries.items) |entry| {
            if (!std.ascii.eqlIgnoreCase(entry.section, "extensions") or entry.has_subsection) continue;
            for (v1_only_extensions) |name| {
                if (!std.ascii.eqlIgnoreCase(entry.name, name)) continue;
                try diagnostic_mod.refuse(diagnostic, entry.name);
                return error.UnsupportedExtension;
            }
        }
    }
    const kind = if (config.get("extensions.objectformat")) |text|
        hash.Kind.parse(text) catch {
            try diagnostic_mod.refuse(diagnostic, "extensions.objectFormat");
            return error.UnknownObjectFormat;
        }
    else
        hash.Kind.sha1;
    const storage: refs.Format = if (config.get("extensions.refstorage")) |text| refs.Format.parse(text) orelse .files else .files;
    const worktree_config = config.getBool("extensions.worktreeconfig", false) catch |err| {
        if (err == error.NotABoolean) try diagnostic_mod.refuse(diagnostic, "extensions.worktreeConfig");
        return err;
    };
    return .{
        .kind = kind,
        .ref_storage = if (version == 1) storage else .files,
        .worktree_config = worktree_config,
    };
}

fn checkExtensions(config: *const config_mod.Config, diagnostic: ?*Diagnostic) Error!void {
    for (config.entries.items) |entry| {
        if (!std.ascii.eqlIgnoreCase(entry.section, "extensions")) continue;
        var known = false;
        for (known_extensions) |name| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) known = true;
        }
        if (!known) {
            try diagnostic_mod.refuse(diagnostic, entry.name);
            return error.UnsupportedExtension;
        }
        if (std.ascii.eqlIgnoreCase(entry.name, "refstorage")) {
            const value = entry.value orelse "";
            if (refs.Format.parse(value) == null) {
                try diagnostic_mod.refuse(diagnostic, "extensions.refStorage");
                return error.UnsupportedRefStorage;
            }
        }
    }
}

fn decideText(text: []const u8) Self.Error!Format {
    var config = config_mod.Config.parseText(std.testing.allocator, text, .local) catch return error.UnsupportedExtension;
    defer config.deinit();
    return decide(&config, null);
}

test "a format is what the repository's own configuration says, as git's verify_repository_format decides it" {
    try std.testing.expectEqual(Format{}, try decideText(""));
    try std.testing.expectEqual(Format{ .kind = .sha256, .ref_storage = .reftable }, try decideText("[core]\n\trepositoryformatversion = 1\n[extensions]\n\tobjectformat = sha256\n\trefStorage = Reftable\n"));
    try std.testing.expectEqual(Format{ .worktree_config = true }, try decideText("[extensions]\n\tworktreeConfig = true\n"));
    // version 1's extensions at version 0, and what no release knows
    try std.testing.expectError(error.UnsupportedExtension, decideText("[extensions]\n\trefstorage = reftable\n"));
    try std.testing.expectError(error.UnsupportedExtension, decideText("[core]\n\trepositoryformatversion = 1\n[extensions]\n\tsomethingnew = yes\n"));
    try std.testing.expectError(error.UnsupportedRefStorage, decideText("[core]\n\trepositoryformatversion = 1\n[extensions]\n\trefstorage = mystery\n"));
    try std.testing.expectError(error.UnknownObjectFormat, decideText("[core]\n\trepositoryformatversion = 1\n[extensions]\n\tobjectformat = md5\n"));
    try std.testing.expectError(error.UnsupportedRepositoryVersion, decideText("[core]\n\trepositoryformatversion = 2\n"));
    try std.testing.expectError(error.NotABoolean, decideText("[extensions]\n\tworktreeConfig = maybe\n"));
}
