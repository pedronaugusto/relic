//! A repository's hooks, found and run the way git finds and runs them.
//!
//! A hook is a program a person put in the repository, so running one is the
//! caller's decision: an operation that could run a hook takes a
//! `?*Runner`, and `null` runs nothing, which is what relic did before it ran
//! anything. A `Runner` carries the permission (`program.Programs`), where
//! the hooks are looked for, and where they run.
//!
//! git looks in `core.hooksPath` when it is set and in the shared `hooks/`
//! directory otherwise, so every linked worktree runs the same hooks. A file
//! there runs only if it is executable; one that is not is passed over, and
//! `Ran.passed_over` says so where git prints its advice. A hook runs with
//! the top of the working tree as its directory — the git directory in a
//! bare repository — directly and never through a shell, with its standard
//! output sent to standard error so that it cannot be mistaken for anything
//! the caller prints. Hooks declared in the configuration, with
//! `hook.<name>.event` and `hook.<name>.command`, run before that file, in
//! the order the configuration last named them, and through the shell,
//! because each is a command line.
//!
//! What a hook starts from is the caller's environment less the variables
//! that point a `git` at a particular repository — `GIT_DIR`,
//! `GIT_INDEX_FILE`, `GIT_WORK_TREE` and the rest of git's own list. The hook
//! runs in this repository, and a `GIT_DIR` inherited from wherever the
//! caller was started would send the hook's own `git` commands somewhere
//! else. What git sets for a particular hook — `GIT_INDEX_FILE` for the
//! commit hooks, `GIT_EDITOR=:` when no editor runs — is set here the same
//! way.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Child = std.process.Child;

const hash = @import("hash.zig");
const object = @import("object.zig");
const config_mod = @import("config.zig");
const program = @import("program.zig");

const Oid = hash.Oid;

/// Errors from finding and running hooks.
pub const Error = error{
    /// A hook that can stop the operation failed: it exited with a status
    /// other than zero, was killed, or could not be started, all of which
    /// git counts alike. `Runner.failure` names the hook and how it ended.
    HookRejected,
    /// `hook.<name>.event` names a hook that has no `hook.<name>.command`
    /// and is not disabled. git refuses to run any hook for that event;
    /// `Runner.refused` names it.
    HookCommandMissing,
    /// A configured hook's own name is the name of an event, which git
    /// refuses because `hook.<name>.enabled` would then mean two things.
    /// `Runner.refused` names it.
    HookNameIsAnEvent,
} || program.Error;

/// Errors from making a runner.
pub const InitError = Allocator.Error || Io.Dir.RealPathError ||
    error{ MalformedValue, NameTooLong };

/// Where a hook's output goes.
pub const Output = enum {
    /// To this process's standard error, as git sends it — or, for
    /// `pre-push`, its standard output to this process's standard output.
    inherit,
    /// Into `Runner.captured`, standard output then standard error, for a
    /// caller that shows it somewhere of its own.
    capture,
    /// Nowhere.
    ignore,
};

/// How a runner behaves.
pub const Options = struct {
    output: Output = .inherit,
    /// `GIT_PREFIX`: the subdirectory of the working tree the person is
    /// working in, `/`-terminated, or empty at the top. git sets it for
    /// every program it starts.
    prefix: []const u8 = "",
};

/// What a runner needs to know about the repository.
pub const Place = struct {
    config: *const config_mod.Config,
    /// The per-worktree directory.
    git_dir: Io.Dir,
    /// The shared directory, where `hooks/` lives.
    common_dir: Io.Dir,
    /// The working tree, or `null` in a bare repository.
    work_dir: ?Io.Dir,
};

/// How a hook that failed ended.
pub const Failure = struct {
    event_buf: [64]u8 = undefined,
    event_len: u8 = 0,
    /// `null` when it could not be started.
    term: ?Child.Term = null,

    /// The event whose hook failed.
    pub fn event(f: *const Failure) []const u8 {
        return f.event_buf[0..f.event_len];
    }

    /// The exit status, or `null` when it was killed or never started.
    pub fn status(f: *const Failure) ?u8 {
        const term = f.term orelse return null;
        return switch (term) {
            .exited => |code| code,
            else => null,
        };
    }

    fn init(name: []const u8, term: ?Child.Term) Failure {
        var f: Failure = .{ .term = term };
        f.event_len = @intCast(@min(name.len, f.event_buf.len));
        @memcpy(f.event_buf[0..f.event_len], name[0..f.event_len]);
        return f;
    }
};

/// What running one event's hooks did.
pub const Ran = struct {
    /// How many hooks ran. Zero when the event has none.
    count: u32 = 0,
    /// The first one that failed, or `null`.
    failure: ?Failure = null,
    /// A file named for the event is in the hooks directory and is not
    /// executable, so it did not run. git prints advice when this happens;
    /// here it is a value for the caller to show.
    passed_over: bool = false,

    /// Whether every hook that ran succeeded.
    pub fn succeeded(r: Ran) bool {
        return r.failure == null;
    }
};

/// Every event git runs a hook for, from githooks(5). A configured hook may
/// not be named after one.
pub const events = [_][]const u8{
    "applypatch-msg",        "pre-applypatch",     "post-applypatch",
    "pre-commit",            "pre-merge-commit",   "prepare-commit-msg",
    "commit-msg",            "post-commit",        "pre-rebase",
    "post-checkout",         "post-merge",         "pre-push",
    "pre-receive",           "update",             "proc-receive",
    "post-receive",          "post-update",        "reference-transaction",
    "push-to-checkout",      "pre-auto-gc",        "post-rewrite",
    "sendemail-validate",    "fsmonitor-watchman", "p4-changelist",
    "p4-prepare-changelist", "p4-post-changelist", "p4-pre-submit",
    "post-index-change",
};

/// One hook the configuration declares for an event.
pub const Configured = struct {
    /// The hook's own name, the `<name>` of `hook.<name>.command`.
    name: []const u8,
    event: []const u8,
    /// The command line, or `null` when none is set.
    command: ?[]const u8,
    /// `hook.<name>.enabled = false`.
    disabled: bool,
};

/// Permission to run a repository's hooks, and where they are.
///
/// A runner is one task's: `failure` and `captured` record what the last
/// call did.
pub const Runner = struct {
    gpa: Allocator,
    programs: program.Programs,
    options: Options,
    /// The directory traditional hooks are looked for in, absolute.
    dir: []const u8,
    /// The directory a hook runs in, absolute.
    cwd: []const u8,
    /// Every configured hook, in the order git runs them for their event.
    configured: []const Configured,
    /// Events whose configured hooks `hook.<event>.enabled = false` turns
    /// off. A hook file for the event still runs, as it does in git.
    disabled_events: []const []const u8,
    arena: std.heap.ArenaAllocator.State,
    /// What stopped the last operation `error.HookRejected` ended.
    failure: Failure = .{},
    /// The configured hook `error.HookCommandMissing` or
    /// `error.HookNameIsAnEvent` is about.
    refused: []const u8 = "",
    /// What the hooks printed, when `Options.output` is `.capture`. The
    /// caller may clear it between calls.
    captured: std.ArrayList(u8) = .empty,

    /// Find where the repository's hooks are and read which ones the
    /// configuration declares.
    pub fn init(
        gpa: Allocator,
        io: Io,
        place: Place,
        programs: program.Programs,
        options: Options,
    ) InitError!Runner {
        var arena_instance: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena_instance.deinit();
        const arena = arena_instance.allocator();

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const top = place.work_dir orelse place.git_dir;
        const cwd = try arena.dupe(u8, buf[0..try top.realPath(io, &buf)]);

        const dir: []const u8 = if (try place.config.getPath(arena, "core.hookspath")) |configured|
            // A relative `core.hooksPath` is taken from where the hooks run.
            if (std.fs.path.isAbsolute(configured))
                configured
            else
                try std.fs.path.join(arena, &.{ cwd, configured })
        else blk: {
            const common = buf[0..try place.common_dir.realPath(io, &buf)];
            break :blk try std.fs.path.join(arena, &.{ common, "hooks" });
        };

        var disabled_events: std.ArrayList([]const u8) = .empty;
        const configured = try readConfigured(arena, place.config, &disabled_events);

        return .{
            .gpa = gpa,
            .programs = programs,
            .options = options,
            .dir = dir,
            .cwd = cwd,
            .configured = configured,
            .disabled_events = disabled_events.items,
            .arena = arena_instance.state,
        };
    }

    /// Release the runner.
    pub fn deinit(runner: *Runner) void {
        runner.captured.deinit(runner.gpa);
        var arena = runner.arena.promote(runner.gpa);
        arena.deinit();
        runner.* = undefined;
    }

    /// What one event's hooks are handed.
    pub const Request = struct {
        args: []const []const u8 = &.{},
        /// Every hook for the event reads the same bytes on its standard
        /// input. Empty is an empty input, which is what a hook given none
        /// reads.
        input: []const u8 = "",
        /// Set on top of the environment, after git's own list is cleared.
        set: []const program.Var = &.{},
        /// Whether standard output goes where standard error goes. Every
        /// hook's does except `pre-push`'s.
        stdout_to_stderr: bool = true,
    };

    /// Run every hook for `event`, in git's order: the configured ones,
    /// then the file. Each one runs whatever the one before it did, as in
    /// git; the result says whether any failed, and the typed calls below
    /// decide what a failure means.
    pub fn run(runner: *Runner, io: Io, event: []const u8, request: Request) Error!Ran {
        if (misnamed(runner.configured)) |name| {
            runner.refused = name;
            return error.HookNameIsAnEvent;
        }
        var ran: Ran = .{};
        const event_disabled = for (runner.disabled_events) |name| {
            if (std.mem.eql(u8, name, event)) break true;
        } else false;

        for (runner.configured) |hook| {
            if (!std.mem.eql(u8, hook.event, event)) continue;
            if (hook.disabled or event_disabled) continue;
            const command = hook.command orelse {
                runner.refused = hook.name;
                return error.HookCommandMissing;
            };
            try runner.runOne(io, event, &ran, request, command, true);
        }

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        switch (try runner.findFile(io, event, &path_buf)) {
            .missing => {},
            .not_executable => ran.passed_over = true,
            .found => |path| try runner.runOne(io, event, &ran, request, path, false),
        }
        return ran;
    }

    /// Whether any hook would run for `event`.
    pub fn exists(runner: *Runner, io: Io, event: []const u8) bool {
        for (runner.configured) |hook| {
            if (std.mem.eql(u8, hook.event, event) and !hook.disabled) {
                for (runner.disabled_events) |name| {
                    if (std.mem.eql(u8, name, event)) break;
                } else return true;
            }
        }
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        return switch (runner.findFile(io, event, &path_buf) catch return false) {
            .found => true,
            else => false,
        };
    }

    const Lookup = union(enum) { missing, not_executable, found: []const u8 };

    fn findFile(runner: *Runner, io: Io, event: []const u8, buf: []u8) error{NameTooLong}!Lookup {
        const path = std.fmt.bufPrint(buf, "{s}/{s}", .{ runner.dir, event }) catch return error.NameTooLong;
        if (builtin.os.tag == .windows) {
            // Windows has no executable bit. git for Windows runs a file whose
            // name ends in `.exe` or whose first two bytes are `#!`, and tries
            // `<name>.exe` when `<name>` is not one of those.
            if (runsOnWindows(io, path)) return .{ .found = path };
            const exe = std.fmt.bufPrint(buf, "{s}/{s}.exe", .{ runner.dir, event }) catch return error.NameTooLong;
            Io.Dir.accessAbsolute(io, exe, .{}) catch return .missing;
            return .{ .found = exe };
        }
        Io.Dir.accessAbsolute(io, path, .{ .execute = true }) catch |err| switch (err) {
            error.AccessDenied, error.PermissionDenied => {
                Io.Dir.accessAbsolute(io, path, .{}) catch return .missing;
                return .not_executable;
            },
            else => return .missing,
        };
        return .{ .found = path };
    }

    fn runOne(
        runner: *Runner,
        io: Io,
        event: []const u8,
        ran: *Ran,
        request: Request,
        command: []const u8,
        shell: bool,
    ) Error!void {
        const gpa = runner.gpa;
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);

        var interpreter_buf: [100]u8 = undefined;
        if (!shell and builtin.os.tag == .windows) {
            // git for Windows reads the `#!` line itself and starts the
            // interpreter it names, by its base name, with the script as its
            // first argument.
            if (windowsInterpreter(io, command, &interpreter_buf)) |interpreter| {
                try argv.append(gpa, interpreter);
            }
        }
        try argv.append(gpa, command);
        try argv.appendSlice(gpa, request.args);

        var set: std.ArrayList(program.Var) = .empty;
        defer set.deinit(gpa);
        try set.append(gpa, .{ .name = "GIT_PREFIX", .value = runner.options.prefix });
        try set.appendSlice(gpa, request.set);

        const capture = runner.options.output == .capture;
        var outcome = program.run(runner.programs, gpa, io, .{
            .argv = argv.items,
            .shell = shell,
            .cwd = .{ .path = runner.cwd },
            .set = set.items,
            .unset = &program.repository_variables,
            .stderr = switch (runner.options.output) {
                .inherit => .inherit,
                .capture => .capture,
                .ignore => .ignore,
            },
            .stdout = switch (runner.options.output) {
                .inherit => if (request.stdout_to_stderr) .to_stderr else .inherit,
                .capture => .capture,
                .ignore => .ignore,
            },
        }, request.input, .{}) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            // A hook that cannot be started has failed, which is how git
            // counts it too.
            if (cannotStart(err)) {
                ran.count += 1;
                if (ran.failure == null) ran.failure = .init(event, null);
                return;
            }
            return err;
        };
        defer outcome.deinit(gpa);
        ran.count += 1;
        if (capture) {
            try runner.captured.appendSlice(gpa, outcome.stdout);
            try runner.captured.appendSlice(gpa, outcome.stderr);
        }
        if (!outcome.succeeded() and ran.failure == null) ran.failure = .init(event, outcome.term);
    }

    /// Run `event`'s hooks as ones that can stop the operation: a failure is
    /// `error.HookRejected`, with `failure` saying which and how.
    pub fn block(runner: *Runner, io: Io, event: []const u8, request: Request) Error!Ran {
        const ran = try runner.run(io, event, request);
        if (ran.failure) |f| {
            runner.failure = f;
            return error.HookRejected;
        }
        return ran;
    }

    /// What the commit hooks are told about the commit being made.
    pub const CommitEnv = struct {
        /// The index being committed, absolute: `GIT_INDEX_FILE`.
        index_path: []const u8,
        /// The author git exports as `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`
        /// and `GIT_AUTHOR_DATE` while it commits, when there is one.
        author: ?object.Signature = null,
    };

    fn commitRequest(
        runner: *Runner,
        scratch: *[3][64]u8,
        vars: *[5]program.Var,
        env: CommitEnv,
        args: []const []const u8,
    ) Request {
        _ = runner;
        var n: usize = 0;
        vars[n] = .{ .name = "GIT_INDEX_FILE", .value = env.index_path };
        n += 1;
        // No editor runs here, and git tells the hook so.
        vars[n] = .{ .name = "GIT_EDITOR", .value = ":" };
        n += 1;
        if (env.author) |who| {
            const date = formatDate(&scratch[0], who);
            vars[n] = .{ .name = "GIT_AUTHOR_NAME", .value = who.name };
            vars[n + 1] = .{ .name = "GIT_AUTHOR_EMAIL", .value = who.email };
            vars[n + 2] = .{ .name = "GIT_AUTHOR_DATE", .value = date };
            n += 3;
        }
        return .{ .args = args, .set = vars[0..n] };
    }

    /// `pre-commit`, before anything is written. It may change the index,
    /// which is why a commit reads the index again after it.
    pub fn preCommit(runner: *Runner, io: Io, env: CommitEnv) Error!Ran {
        var scratch: [3][64]u8 = undefined;
        var vars: [5]program.Var = undefined;
        return runner.block(io, "pre-commit", runner.commitRequest(&scratch, &vars, env, &.{}));
    }

    /// Where a commit's message came from, as `prepare-commit-msg` is told.
    pub const MessageSource = enum {
        message,
        template,
        merge,
        squash,
        commit,

        fn text(s: MessageSource) []const u8 {
            return @tagName(s);
        }
    };

    /// `prepare-commit-msg <file> [<source> [<commit>]]`, which may rewrite
    /// the message file.
    pub fn prepareCommitMsg(
        runner: *Runner,
        io: Io,
        env: CommitEnv,
        message_path: []const u8,
        source: ?MessageSource,
        commit: ?[]const u8,
    ) Error!Ran {
        var scratch: [3][64]u8 = undefined;
        var vars: [5]program.Var = undefined;
        var args_buf: [3][]const u8 = undefined;
        var n: usize = 0;
        args_buf[n] = message_path;
        n += 1;
        if (source) |s| {
            args_buf[n] = s.text();
            n += 1;
            if (commit) |c| {
                args_buf[n] = c;
                n += 1;
            }
        }
        return runner.block(io, "prepare-commit-msg", runner.commitRequest(&scratch, &vars, env, args_buf[0..n]));
    }

    /// `commit-msg <file>`, which may rewrite the message file or refuse it.
    pub fn commitMsg(runner: *Runner, io: Io, env: CommitEnv, message_path: []const u8) Error!Ran {
        var scratch: [3][64]u8 = undefined;
        var vars: [5]program.Var = undefined;
        return runner.block(io, "commit-msg", runner.commitRequest(&scratch, &vars, env, &.{message_path}));
    }

    /// `post-commit`, after the branch has moved. It cannot undo anything.
    pub fn postCommit(runner: *Runner, io: Io, env: CommitEnv) Error!Ran {
        var scratch: [3][64]u8 = undefined;
        var vars: [5]program.Var = undefined;
        return runner.run(io, "post-commit", runner.commitRequest(&scratch, &vars, env, &.{}));
    }

    /// What a checkout replaced: `1` for a branch, `0` for paths.
    pub const CheckoutKind = enum { paths, branch };

    /// `post-checkout <old> <new> <flag>`. It cannot undo the checkout; git
    /// makes its status the command's own, which `Ran.failure` carries.
    pub fn postCheckout(runner: *Runner, io: Io, old: Oid, new: Oid, kind: CheckoutKind) Error!Ran {
        var old_hex: [hash.max_hex_len]u8 = undefined;
        var new_hex: [hash.max_hex_len]u8 = undefined;
        return runner.run(io, "post-checkout", .{ .args = &.{
            old.hex(&old_hex),
            new.hex(&new_hex),
            if (kind == .branch) "1" else "0",
        } });
    }

    /// `post-merge <squash>`, after a merge that succeeded.
    pub fn postMerge(runner: *Runner, io: Io, squash: bool) Error!Ran {
        return runner.run(io, "post-merge", .{ .args = &.{if (squash) "1" else "0"} });
    }

    /// `pre-rebase <upstream> [<branch>]`, which may refuse the rebase.
    pub fn preRebase(runner: *Runner, io: Io, upstream: []const u8, branch: ?[]const u8) Error!Ran {
        if (branch) |b| return runner.block(io, "pre-rebase", .{ .args = &.{ upstream, b } });
        return runner.block(io, "pre-rebase", .{ .args = &.{upstream} });
    }

    /// One ref a push is about to update, as `pre-push` reads it.
    pub const PushUpdate = struct {
        /// The local ref being pushed, or `(delete)` for a deletion.
        local_ref: []const u8,
        /// Zero for a deletion.
        local: Oid,
        remote_ref: []const u8,
        /// Zero when the remote ref does not exist yet.
        remote: Oid,
    };

    /// `pre-push <remote> <url>`, with one line per ref on its standard
    /// input: `<local ref> SP <local oid> SP <remote ref> SP <remote oid>
    /// LF`. It may refuse the push. Unlike every other hook, its standard
    /// output is left on standard output.
    pub fn prePush(
        runner: *Runner,
        io: Io,
        remote_name: []const u8,
        url: []const u8,
        updates: []const PushUpdate,
    ) Error!Ran {
        var input: std.Io.Writer.Allocating = .init(runner.gpa);
        defer input.deinit();
        var a: [hash.max_hex_len]u8 = undefined;
        var b: [hash.max_hex_len]u8 = undefined;
        for (updates) |u| {
            input.writer.print("{s} {s} {s} {s}\n", .{ u.local_ref, u.local.hex(&a), u.remote_ref, u.remote.hex(&b) }) catch
                return error.OutOfMemory;
        }
        return runner.block(io, "pre-push", .{
            .args = &.{ remote_name, url },
            .input = input.written(),
            .stdout_to_stderr = false,
        });
    }

    /// Where a ref transaction is when `reference-transaction` runs.
    pub const TransactionState = enum {
        /// Every update is queued and no ref is locked yet.
        preparing,
        /// Every ref is locked and checked.
        prepared,
        /// Every ref has its new value.
        committed,
        /// The transaction was given up.
        aborted,
    };

    /// One ref a transaction changes, as `reference-transaction` reads it.
    pub const RefUpdate = struct {
        /// The value the update expected, or `null` when it expected none or
        /// any: git writes the zero name for both.
        old: ?Value,
        /// `null` for a deletion, which git writes as the zero name.
        new: ?Value,
        name: []const u8,

        /// An object name, or a symbolic ref's target, which git writes as
        /// `ref:<target>`.
        pub const Value = union(enum) { oid: Oid, symbolic: []const u8 };
    };

    /// `reference-transaction <state>`, with one line per ref on its
    /// standard input: `<old> SP <new> SP <ref> LF`. In `preparing` and
    /// `prepared` it may refuse the transaction; in the other two its status
    /// is ignored, as git ignores it.
    pub fn referenceTransaction(
        runner: *Runner,
        io: Io,
        kind: hash.Kind,
        state: TransactionState,
        updates: []const RefUpdate,
    ) Error!Ran {
        var input: std.Io.Writer.Allocating = .init(runner.gpa);
        defer input.deinit();
        for (updates) |u| {
            writeValue(&input.writer, kind, u.old) catch return error.OutOfMemory;
            input.writer.writeByte(' ') catch return error.OutOfMemory;
            writeValue(&input.writer, kind, u.new) catch return error.OutOfMemory;
            input.writer.print(" {s}\n", .{u.name}) catch return error.OutOfMemory;
        }
        const request: Request = .{ .args = &.{@tagName(state)}, .input = input.written() };
        return switch (state) {
            .preparing, .prepared => runner.block(io, "reference-transaction", request),
            .committed, .aborted => runner.run(io, "reference-transaction", request),
        };
    }

    /// What rewrote the commits `post-rewrite` is told about.
    pub const RewriteCommand = enum { amend, rebase };

    /// One rewritten commit: `<old> SP <new> [SP <extra>] LF`.
    pub const Rewrite = struct {
        old: Oid,
        new: Oid,
        extra: []const u8 = "",
    };

    /// `post-rewrite <command>`, after `commit --amend` or a rebase has
    /// rewritten commits. It cannot undo anything.
    pub fn postRewrite(runner: *Runner, io: Io, command: RewriteCommand, rewrites: []const Rewrite) Error!Ran {
        var input: std.Io.Writer.Allocating = .init(runner.gpa);
        defer input.deinit();
        var a: [hash.max_hex_len]u8 = undefined;
        var b: [hash.max_hex_len]u8 = undefined;
        for (rewrites) |r| {
            input.writer.print("{s} {s}", .{ r.old.hex(&a), r.new.hex(&b) }) catch return error.OutOfMemory;
            if (r.extra.len != 0) input.writer.print(" {s}", .{r.extra}) catch return error.OutOfMemory;
            input.writer.writeByte('\n') catch return error.OutOfMemory;
        }
        return runner.run(io, "post-rewrite", .{ .args = &.{@tagName(command)}, .input = input.written() });
    }
};

fn writeValue(w: *Io.Writer, kind: hash.Kind, value: ?Runner.RefUpdate.Value) Io.Writer.Error!void {
    var hex: [hash.max_hex_len]u8 = undefined;
    const v = value orelse return w.writeAll(Oid.zero(kind).hex(&hex));
    switch (v) {
        .oid => |oid| try w.writeAll(oid.hex(&hex)),
        .symbolic => |target| try w.print("ref:{s}", .{target}),
    }
}

/// `@<secs> <±hhmm>`, the form git exports `GIT_AUTHOR_DATE` in.
fn formatDate(buf: *[64]u8, who: object.Signature) []const u8 {
    const sign: u8 = if (who.offset_minutes < 0) '-' else '+';
    const abs: u32 = @intCast(@abs(who.offset_minutes));
    return std.fmt.bufPrint(buf, "@{d} {c}{d:0>2}{d:0>2}", .{ who.when_secs, sign, abs / 60, abs % 60 }) catch unreachable;
}

/// Read `hook.<name>.*` in git's way: an event list per name in the order the
/// configuration last named it, an empty `event` value clearing the name
/// from every event, and the last `command` and `enabled` winning.
fn readConfigured(
    arena: Allocator,
    config: *const config_mod.Config,
    disabled_events: *std.ArrayList([]const u8),
) (Allocator.Error || error{MalformedValue})![]const Configured {
    const Pair = struct { name: []const u8, event: []const u8 };
    var pairs: std.ArrayList(Pair) = .empty;
    var commands: std.StringHashMapUnmanaged([]const u8) = .empty;
    var disabled: std.StringHashMapUnmanaged(void) = .empty;
    var parallel: std.StringHashMapUnmanaged(void) = .empty;

    for (config.entries.items) |entry| {
        if (!std.ascii.eqlIgnoreCase(entry.section, "hook")) continue;
        if (entry.subsection.len == 0) continue;
        const name = entry.subsection;
        const raw = entry.value orelse "";
        const value = config_mod.unquote(arena, raw) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.MalformedValue,
        };
        if (std.ascii.eqlIgnoreCase(entry.name, "event")) {
            var i: usize = 0;
            while (i < pairs.items.len) {
                const p = pairs.items[i];
                if (std.mem.eql(u8, p.name, name) and (value.len == 0 or std.mem.eql(u8, p.event, value))) {
                    _ = pairs.orderedRemove(i);
                } else i += 1;
            }
            if (value.len != 0) try pairs.append(arena, .{ .name = name, .event = value });
        } else if (std.ascii.eqlIgnoreCase(entry.name, "command")) {
            try commands.put(arena, name, value);
        } else if (std.ascii.eqlIgnoreCase(entry.name, "enabled")) {
            const on = config_mod.parseBool(value) catch continue;
            if (on) _ = disabled.remove(name) else try disabled.put(arena, name, {});
        } else if (std.ascii.eqlIgnoreCase(entry.name, "parallel")) {
            try parallel.put(arena, name, {});
        }
    }

    const out = try arena.alloc(Configured, pairs.items.len);
    for (pairs.items, out) |p, *c| {
        c.* = .{
            .name = p.name,
            .event = p.event,
            .command = commands.get(p.name),
            .disabled = disabled.contains(p.name),
        };
    }

    // `hook.<event>.enabled = false` for a name that is not itself a hook
    // turns the event's configured hooks off.
    var it = disabled.keyIterator();
    while (it.next()) |key| {
        const is_hook = commands.contains(key.*) or parallel.contains(key.*) or for (pairs.items) |p| {
            if (std.mem.eql(u8, p.name, key.*)) break true;
        } else false;
        if (!is_hook) try disabled_events.append(arena, key.*);
    }
    return out;
}

/// The configured hook named after an event, which git refuses, or `null`.
fn misnamed(configured: []const Configured) ?[]const u8 {
    for (configured) |hook| {
        for (events) |name| {
            if (std.mem.eql(u8, hook.name, name)) return hook.name;
        }
    }
    return null;
}

/// Whether `err` says the hook itself could not be started — it is not an
/// executable, or it names an interpreter that is not there — rather than
/// that this process ran out of something.
fn cannotStart(err: program.Error) bool {
    return switch (err) {
        error.AccessDenied,
        error.PermissionDenied,
        error.InvalidExe,
        error.IsDir,
        error.FileNotFound,
        error.NotDir,
        error.FileBusy,
        error.SymLinkLoop,
        error.InvalidName,
        error.NameTooLong,
        error.BadPathName,
        => true,
        else => false,
    };
}

fn runsOnWindows(io: Io, path: []const u8) bool {
    if (std.ascii.endsWithIgnoreCase(path, ".exe")) {
        Io.Dir.accessAbsolute(io, path, .{}) catch return false;
        return true;
    }
    const file = Io.Dir.openFileAbsolute(io, path, .{}) catch return false;
    defer file.close(io);
    var head: [2]u8 = undefined;
    const n = file.readPositionalAll(io, &head, 0) catch return false;
    return n == 2 and head[0] == '#' and head[1] == '!';
}

/// The interpreter a `#!` line names, by its base name and without its
/// options, as git for Windows reads it; `null` for anything else.
fn windowsInterpreter(io: Io, path: []const u8, buf: *[100]u8) ?[]const u8 {
    if (std.ascii.endsWithIgnoreCase(path, ".exe")) return null;
    const file = Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);
    const n = file.readPositionalAll(io, buf[0 .. buf.len - 1], 0) catch return null;
    return parseInterpreter(buf[0..n]);
}

fn parseInterpreter(head: []const u8) ?[]const u8 {
    if (head.len < 4 or head[0] != '#' or head[1] != '!') return null;
    const end = std.mem.indexOfAny(u8, head, "\r\n") orelse return null;
    const line = head[2..end];
    const slash = std.mem.lastIndexOfAny(u8, line, "/\\") orelse return null;
    const rest = line[slash + 1 ..];
    const space = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    return rest[0..space];
}

//=========================================================================
// Tests
//=========================================================================

const testing = std.testing;
const testgit = @import("testgit.zig");

test "a #! line names its interpreter by base name, as git for Windows reads it" {
    try testing.expectEqualStrings("sh", parseInterpreter("#!/bin/sh\necho\n").?);
    try testing.expectEqualStrings("env", parseInterpreter("#!/usr/bin/env python3\n").?);
    try testing.expectEqualStrings("bash", parseInterpreter("#!C:\\tools\\bash -e\r\n").?);
    try testing.expect(parseInterpreter("#!sh\n") == null);
    try testing.expect(parseInterpreter("echo\n") == null);
    try testing.expect(parseInterpreter("#!/bin/sh") == null);
}

/// An environment for a hook: the machine's `PATH`, and a `GIT_DIR` and
/// `GIT_INDEX_FILE` planted to prove the runner takes them away.
fn testEnviron(gpa: Allocator) !std.process.Environ.Map {
    var map = try testgit.programEnviron(gpa);
    errdefer map.deinit();
    try map.put("GIT_DIR", "/nowhere/.git");
    try map.put("GIT_INDEX_FILE", "/nowhere/index");
    try map.put("RELIC_KEPT", "kept");
    return map;
}

fn writeHook(io: Io, dir: Io.Dir, path: []const u8, body: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(io, parent);
    try dir.writeFile(io, .{ .sub_path = path, .data = body });
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);
    try file.setPermissions(io, .fromMode(0o755));
}

fn openRunner(gpa: Allocator, io: Io, repo: *testgit.Repo, environ: *const std.process.Environ.Map, config_text: []const u8) !struct { runner: Runner, config: config_mod.Config, git_dir: Io.Dir } {
    var git_dir = try repo.gitDir(io);
    errdefer git_dir.close(io);
    var config = try config_mod.Config.parseText(gpa, config_text, .local);
    errdefer config.deinit();
    const runner = try Runner.init(gpa, io, .{
        .config = &config,
        .git_dir = git_dir,
        .common_dir = git_dir,
        .work_dir = repo.dir,
    }, .{ .environ = environ }, .{ .output = .capture });
    return .{ .runner = runner, .config = config, .git_dir = git_dir };
}

test "a hook runs from the top of the working tree with git's arguments, and nothing that points elsewhere" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    var environ = try testEnviron(gpa);
    defer environ.deinit();

    try writeHook(io, repo.dir, ".git/hooks/post-merge",
        \\#!/bin/sh
        \\echo "args=$# $*"
        \\[ "$(pwd -P)" = "$(git rev-parse --show-toplevel)" ] && echo top
        \\echo "dir=${GIT_DIR-unset} index=${GIT_INDEX_FILE-unset} prefix=${GIT_PREFIX-unset} kept=$RELIC_KEPT"
        \\echo to-stderr >&2
        \\
    );

    var opened = try openRunner(gpa, io, &repo, &environ, "");
    defer opened.git_dir.close(io);
    defer opened.config.deinit();
    defer opened.runner.deinit();
    const ran = try opened.runner.postMerge(io, true);
    try testing.expectEqual(@as(u32, 1), ran.count);
    try testing.expect(ran.succeeded());
    try testing.expectEqualStrings(
        "args=1 1\ntop\ndir=unset index=unset prefix= kept=kept\nto-stderr\n",
        opened.runner.captured.items,
    );
}

test "a hook that is not executable is passed over and said to be" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    var environ = try testEnviron(gpa);
    defer environ.deinit();
    try repo.writeFile(io, ".git/hooks/pre-rebase", "#!/bin/sh\nexit 1\n");

    var opened = try openRunner(gpa, io, &repo, &environ, "");
    defer opened.git_dir.close(io);
    defer opened.config.deinit();
    defer opened.runner.deinit();
    const ran = try opened.runner.preRebase(io, "main", null);
    try testing.expectEqual(@as(u32, 0), ran.count);
    try testing.expect(ran.passed_over);
    try testing.expect(!opened.runner.exists(io, "pre-rebase"));
}

test "a blocking hook that fails is a named refusal carrying its status" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    var environ = try testEnviron(gpa);
    defer environ.deinit();
    try writeHook(io, repo.dir, ".git/hooks/pre-rebase", "#!/bin/sh\necho \"no: $*\" >&2\nexit 3\n");

    var opened = try openRunner(gpa, io, &repo, &environ, "");
    defer opened.git_dir.close(io);
    defer opened.config.deinit();
    defer opened.runner.deinit();
    try testing.expectError(error.HookRejected, opened.runner.preRebase(io, "origin/main", "topic"));
    try testing.expectEqualStrings("pre-rebase", opened.runner.failure.event());
    try testing.expectEqual(@as(?u8, 3), opened.runner.failure.status());
    try testing.expectEqualStrings("no: origin/main topic\n", opened.runner.captured.items);
}

test "core.hooksPath moves the hooks, relative to where they run" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    var environ = try testEnviron(gpa);
    defer environ.deinit();
    try writeHook(io, repo.dir, ".git/hooks/post-merge", "#!/bin/sh\necho shared\n");
    try writeHook(io, repo.dir, "tools/hooks/post-merge", "#!/bin/sh\necho moved\n");

    var opened = try openRunner(gpa, io, &repo, &environ, "[core]\n\thooksPath = tools/hooks\n");
    defer opened.git_dir.close(io);
    defer opened.config.deinit();
    defer opened.runner.deinit();
    _ = try opened.runner.postMerge(io, false);
    try testing.expectEqualStrings("moved\n", opened.runner.captured.items);
}

test "configured hooks run first, in the order last named, through the shell" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    var environ = try testEnviron(gpa);
    defer environ.deinit();
    try writeHook(io, repo.dir, ".git/hooks/post-merge", "#!/bin/sh\necho file $1\n");

    const text =
        \\[hook "second"]
        \\    event = post-merge
        \\    command = echo second \"$1\"
        \\[hook "first"]
        \\    event = post-merge
        \\    command = echo first
        \\[hook "off"]
        \\    event = post-merge
        \\    command = echo off
        \\    enabled = false
        \\[hook "second"]
        \\    event = post-merge
        \\
    ;
    var opened = try openRunner(gpa, io, &repo, &environ, text);
    defer opened.git_dir.close(io);
    defer opened.config.deinit();
    defer opened.runner.deinit();
    const ran = try opened.runner.postMerge(io, true);
    try testing.expectEqual(@as(u32, 3), ran.count);
    try testing.expectEqualStrings("first 1\nsecond 1 1\nfile 1\n", opened.runner.captured.items);

    // git runs the same hooks in the same order.
    try repo.writeFile(io, "a", "a\n");
    try repo.exec(io, &.{ "add", "a" });
    try repo.exec(io, &.{ "commit", "-q", "-m", "a" });
    try repo.exec(io, &.{ "branch", "side" });
    try repo.exec(io, &.{ "commit", "-q", "--allow-empty", "-m", "b" });
    try repo.exec(io, &.{ "checkout", "-q", "side" });
    var config_file = try opened.git_dir.openFile(io, "config", .{ .mode = .read_write });
    defer config_file.close(io);
    try config_file.writePositionalAll(io, text, try config_file.length(io));
    // Hooks declared in the configuration are git 2.54's.
    testgit.requireGitVersion(gpa, io, 2, 54) catch return;
    const printed = try gitStderr(gpa, io, &repo, &.{ "-c", "core.hooksPath=.git/hooks", "merge", "-q", "--squash", "main" });
    defer gpa.free(printed);
    try testing.expectEqualStrings("first 1\nsecond 1 1\nfile 1\n", printed);
}

test "an event's configured hooks can be turned off while its file still runs" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    var environ = try testEnviron(gpa);
    defer environ.deinit();
    try writeHook(io, repo.dir, ".git/hooks/post-merge", "#!/bin/sh\necho file\n");
    var opened = try openRunner(gpa, io, &repo, &environ,
        \\[hook "one"]
        \\    event = post-merge
        \\    command = echo one
        \\[hook "post-merge"]
        \\    enabled = false
        \\
    );
    defer opened.git_dir.close(io);
    defer opened.config.deinit();
    defer opened.runner.deinit();
    _ = try opened.runner.postMerge(io, false);
    try testing.expectEqualStrings("file\n", opened.runner.captured.items);
}

test "a configured hook named after an event is refused by name" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    var environ = try testEnviron(gpa);
    defer environ.deinit();
    var opened = try openRunner(gpa, io, &repo, &environ, "[hook \"pre-commit\"]\n\tevent = post-merge\n\tcommand = true\n");
    defer opened.git_dir.close(io);
    defer opened.config.deinit();
    defer opened.runner.deinit();
    try testing.expectError(error.HookNameIsAnEvent, opened.runner.postMerge(io, false));
    try testing.expectEqualStrings("pre-commit", opened.runner.refused);
}

test "a configured hook with no command is refused by name" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    var environ = try testEnviron(gpa);
    defer environ.deinit();
    var opened = try openRunner(gpa, io, &repo, &environ, "[hook \"lint\"]\n\tevent = pre-commit\n");
    defer opened.git_dir.close(io);
    defer opened.config.deinit();
    defer opened.runner.deinit();
    try testing.expectError(error.HookCommandMissing, opened.runner.preCommit(io, .{ .index_path = "/i" }));
    try testing.expectEqualStrings("lint", opened.runner.refused);
}

test "pre-push, reference-transaction and post-rewrite read git's lines" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    var environ = try testEnviron(gpa);
    defer environ.deinit();
    for ([_][]const u8{ "pre-push", "reference-transaction", "post-rewrite" }) |name| {
        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, ".git/hooks/{s}", .{name});
        try writeHook(io, repo.dir, path, "#!/bin/sh\necho \"$(basename \"$0\") $*\"\ncat\n");
    }
    var opened = try openRunner(gpa, io, &repo, &environ, "");
    defer opened.git_dir.close(io);
    defer opened.config.deinit();
    defer opened.runner.deinit();

    const one = try Oid.parse(.sha1, "1" ** 40);
    const two = try Oid.parse(.sha1, "2" ** 40);
    _ = try opened.runner.prePush(io, "origin", "file:///r", &.{
        .{ .local_ref = "refs/heads/main", .local = one, .remote_ref = "refs/heads/main", .remote = two },
        .{ .local_ref = "(delete)", .local = Oid.zero(.sha1), .remote_ref = "refs/heads/old", .remote = one },
    });
    _ = try opened.runner.referenceTransaction(io, .sha1, .prepared, &.{
        .{ .old = null, .new = .{ .oid = one }, .name = "refs/heads/new" },
        .{ .old = .{ .oid = one }, .new = null, .name = "refs/heads/gone" },
        .{ .old = null, .new = .{ .symbolic = "refs/heads/new" }, .name = "HEAD" },
    });
    _ = try opened.runner.postRewrite(io, .amend, &.{.{ .old = one, .new = two }});
    try testing.expectEqualStrings(
        "pre-push origin file:///r\n" ++
            "refs/heads/main " ++ "1" ** 40 ++ " refs/heads/main " ++ "2" ** 40 ++ "\n" ++
            "(delete) " ++ "0" ** 40 ++ " refs/heads/old " ++ "1" ** 40 ++ "\n" ++
            "reference-transaction prepared\n" ++
            "0" ** 40 ++ " " ++ "1" ** 40 ++ " refs/heads/new\n" ++
            "1" ** 40 ++ " " ++ "0" ** 40 ++ " refs/heads/gone\n" ++
            "0" ** 40 ++ " ref:refs/heads/new HEAD\n" ++
            "post-rewrite amend\n" ++
            "1" ** 40 ++ " " ++ "2" ** 40 ++ "\n",
        opened.runner.captured.items,
    );
}

test "a hook that fails where it cannot stop anything is reported, not raised" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var repo = try testgit.Repo.init(gpa, io, &.{});
    defer repo.deinit();
    var environ = try testEnviron(gpa);
    defer environ.deinit();
    try writeHook(io, repo.dir, ".git/hooks/reference-transaction", "#!/bin/sh\nexit 1\n");
    try writeHook(io, repo.dir, ".git/hooks/post-checkout", "#!/bin/sh\nexit 2\n");
    var opened = try openRunner(gpa, io, &repo, &environ, "");
    defer opened.git_dir.close(io);
    defer opened.config.deinit();
    defer opened.runner.deinit();
    const one = try Oid.parse(.sha1, "1" ** 40);
    const committed = try opened.runner.referenceTransaction(io, .sha1, .committed, &.{});
    try testing.expect(!committed.succeeded());
    try testing.expectError(error.HookRejected, opened.runner.referenceTransaction(io, .sha1, .preparing, &.{}));
    const checkout = try opened.runner.postCheckout(io, one, one, .branch);
    try testing.expectEqual(@as(?u8, 2), checkout.failure.?.status());
}

/// Run git and return what it printed on standard error.
fn gitStderr(gpa: Allocator, io: Io, repo: *testgit.Repo, args: []const []const u8) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "git");
    try argv.appendSlice(gpa, repo.defaults);
    try argv.appendSlice(gpa, args);
    const result = try std.process.run(gpa, io, .{ .argv = argv.items, .cwd = .{ .dir = repo.dir } });
    gpa.free(result.stdout);
    return result.stderr;
}
