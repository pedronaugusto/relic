//! The fixture harness: a real `git` on the machine, run in a temporary
//! directory, generating the bytes the suite compares against.
//!
//! Nothing in the library spawns a process. This file is test-only, and it
//! exists so that a format change in git arrives as a red build rather than as
//! a silent divergence. A machine with no `git` skips the tests that need one.
//!
//! Every invocation carries a fixed set of `-c` settings, so a person's own
//! `~/.gitconfig` cannot change the bytes a fixture holds. A test that wants
//! one of those settings — the line-ending fixture wants `core.autocrlf` —
//! takes it out of `defaults` and puts it in the repository's own config,
//! which is where the library reads it from.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// The settings every invocation carries unless a test changes them.
pub const default_settings = [_][]const u8{
    "-c", "user.name=Fixture",
    "-c", "user.email=fixture@example.com",
    "-c", "commit.gpgsign=false",
    "-c", "tag.gpgsign=false",
    "-c", "gc.auto=0",
    "-c", "core.autocrlf=false",
    "-c", "core.safecrlf=false",
    "-c", "core.excludesFile=",
    "-c", "core.fsmonitor=false",
    "-c", "core.hooksPath=relic-no-hooks",
    "-c", "advice.detachedHead=false",
    "-c", "protocol.file.allow=always",
    "-c", "feature.manyFiles=false",
};

/// A scratch repository built by the real `git`.
pub const Repo = struct {
    gpa: Allocator,
    tmp: std.testing.TmpDir,
    /// The working tree's directory.
    dir: Io.Dir,
    /// The `-c` settings every invocation carries. A test may replace this
    /// with a shorter list to let a repository's own config decide.
    defaults: []const []const u8 = &default_settings,

    /// Make a temporary directory and run `git init` in it.
    ///
    /// Returns `error.SkipZigTest` when there is no usable `git`, so a
    /// machine without one runs the rest of the suite rather than failing.
    pub fn init(gpa: Allocator, io: Io, extra_args: []const []const u8) !Repo {
        try requireGit(gpa, io);
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();

        var repo: Repo = .{ .gpa = gpa, .tmp = tmp, .dir = tmp.dir };
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ "init", "-q", "-b", "main" });
        try argv.appendSlice(gpa, extra_args);
        try argv.append(gpa, ".");
        try repo.exec(io, argv.items);
        return repo;
    }

    /// Remove the directory and release everything.
    pub fn deinit(r: *Repo) void {
        r.tmp.cleanup();
        r.* = undefined;
    }

    /// Run `git` in the repository and return its standard output, which is
    /// the caller's. `args` begins with the subcommand; `git` and the default
    /// settings are prepended. A non-zero exit is `error.GitFailed`.
    pub fn run(r: *Repo, io: Io, args: []const []const u8) ![]u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(r.gpa);
        try argv.append(r.gpa, "git");
        try argv.appendSlice(r.gpa, r.defaults);
        try argv.appendSlice(r.gpa, args);

        const result = try std.process.run(r.gpa, io, .{
            .argv = argv.items,
            .cwd = .{ .dir = r.dir },
        });
        defer r.gpa.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) {
                std.debug.print("git {s} failed ({d}):\n{s}\n", .{ args[0], code, result.stderr });
                r.gpa.free(result.stdout);
                return error.GitFailed;
            },
            else => {
                r.gpa.free(result.stdout);
                return error.GitFailed;
            },
        }
        return result.stdout;
    }

    /// Run `git` and discard its output.
    pub fn exec(r: *Repo, io: Io, args: []const []const u8) !void {
        const out = try r.run(io, args);
        r.gpa.free(out);
    }

    /// Run `git` and return its output with the trailing newline removed.
    pub fn line(r: *Repo, io: Io, args: []const []const u8) ![]u8 {
        const out = try r.run(io, args);
        defer r.gpa.free(out);
        var end = out.len;
        while (end > 0 and (out[end - 1] == '\n' or out[end - 1] == '\r')) end -= 1;
        return r.gpa.dupe(u8, out[0..end]);
    }

    /// Write a file in the working tree, making the directories it needs.
    pub fn writeFile(r: *Repo, io: Io, path: []const u8, bytes: []const u8) !void {
        if (std.fs.path.dirname(path)) |parent| try r.dir.createDirPath(io, parent);
        try r.dir.writeFile(io, .{ .sub_path = path, .data = bytes });
    }

    /// The `.git` directory, opened. The caller closes it.
    pub fn gitDir(r: *Repo, io: Io) !Io.Dir {
        return r.dir.openDir(io, ".git", .{ .iterate = true });
    }

    /// The whole of a file in the repository, as the caller's bytes.
    pub fn readFile(r: *Repo, io: Io, path: []const u8) ![]u8 {
        return r.dir.readFileAlloc(io, path, r.gpa, .limited(64 << 20));
    }
};

var git_checked: bool = false;
var git_present: bool = false;

/// `error.SkipZigTest` unless a usable `git` is on the path.
pub fn requireGit(gpa: Allocator, io: Io) !void {
    if (!git_checked) {
        git_checked = true;
        const result = std.process.run(gpa, io, .{ .argv = &.{ "git", "--version" } }) catch {
            git_present = false;
            return error.SkipZigTest;
        };
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        git_present = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };
    }
    if (!git_present) return error.SkipZigTest;
}
