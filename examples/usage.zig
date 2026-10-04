//! A whole cycle on a repository in a temporary directory: create it, stage
//! the working tree, write a tree and a commit, move a branch with a reflog
//! entry, read the commit back, and diff two trees.
//!
//! `zig build examples` builds AND runs this; `zig build docs -- usage` extracts
//! the region between the usage markers into README.md, so the snippet a
//! reader copies is code CI executes.

const std = @import("std");
const relic = @import("relic");

pub fn main(init: std.process.Init) !void {
    try run(init.gpa, init.io, .cwd());
}

fn run(gpa: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir) !void {
    const prefix = "relic-example-";
    var scratch_name: [prefix.len + 32]u8 = undefined;
    @memcpy(scratch_name[0..prefix.len], prefix);
    while (true) {
        var random: [16]u8 = undefined;
        io.random(&random);
        const suffix = std.fmt.bytesToHex(random, .lower);
        @memcpy(scratch_name[prefix.len..], &suffix);
        cwd.createDir(io, &scratch_name, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        break;
    }
    defer cwd.deleteTree(io, &scratch_name) catch {};
    var dir = try cwd.openDir(io, &scratch_name, .{ .iterate = true });
    defer dir.close(io);

    // The caller supplies the time and the identity: this package reads no
    // clock and no environment, so a run is reproducible.
    const who: relic.object.Signature = .{
        .name = "Ada Lovelace",
        .email = "ada@example.com",
        .when_secs = 1_700_000_000,
        .offset_minutes = 0,
    };

    // --- README:usage ---

    // Create a repository. `HEAD`, `config`, `objects/` and `refs/` land on
    // the disk and git reads what is written.
    var repo = try relic.repo.Repository.init(gpa, io, dir, .{
        .default_branch = "main",
        .object_format = .sha1,
    });
    defer repo.deinit(io);

    try dir.writeFile(io, .{ .sub_path = "README.md", .data = "# a project\n" });
    try dir.createDirPath(io, "src");
    try dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "pub fn main() void {}\n" });
    try dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "*.log\n" });
    try dir.writeFile(io, .{ .sub_path = "build.log", .data = "not staged\n" });

    // The ignore rules and the attributes come from the repository, because
    // `core.autocrlf` and a `text=auto` line decide the bytes a blob holds
    // and therefore its name.
    var ignore_rules = try repo.loadIgnore(io);
    defer ignore_rules.deinit();
    var attrs = try repo.loadAttrs(io);
    defer attrs.deinit();
    var rules = try repo.worktreeRules();
    rules.ignore = &ignore_rules;
    rules.attrs = &attrs;

    // Stage the working tree. An entry whose recorded stat still matches is
    // neither opened nor hashed, so a second call over an unchanged tree
    // costs a walk and nothing else.
    var index = try repo.openIndex(io);
    defer index.deinit();
    const staged = try relic.worktree.addAll(gpa, io, dir, &index, &repo.odb, .{ .rules = rules });
    std.debug.assert(staged.added == 3);

    // Write the tree, through the cache tree, and the index that describes
    // it. The index goes through `index.lock`; a lock another writer holds
    // is `error.LockHeld` and is never broken.
    const tree = try relic.worktree.writeTree(gpa, io, &index, &repo.odb);
    try index.write(io, repo.git_dir, "index", .{});

    // A commit object, with no ref moved: moving one is a transaction.
    const commit = try repo.writeCommit(io, .{
        .tree = tree,
        .author = who,
        .committer = who,
        .message = "first commit\n",
    }, null);

    // Move the branch under its lock, then append the reflog.
    var tx = repo.beginRefs();
    defer tx.deinit(io);
    try tx.update("refs/heads/main", .{ .direct = commit }, .must_not_exist);
    try tx.commit(io, .{ .who = who, .message = "commit (initial): first commit" });

    // Read it back through the front door.
    const head = (try repo.head(io)).?;
    defer gpa.free(head.name);
    std.debug.assert(std.mem.eql(u8, head.name, "refs/heads/main"));
    std.debug.assert(head.oid.eql(commit));

    // Change a file, stage it, and write a second tree.
    try dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "pub fn main() void {\n    work();\n}\n" });
    _ = try relic.worktree.addAll(gpa, io, dir, &index, &repo.odb, .{ .rules = rules });
    const second = try relic.worktree.writeTree(gpa, io, &index, &repo.odb);

    // What changed, as values rather than as text.
    var changes = try relic.diff.tree(gpa, io, &repo.odb, tree, second, .{});
    defer changes.deinit();
    std.debug.assert(changes.items.len == 1);
    std.debug.assert(changes.items[0].status == .modified);
    std.debug.assert(std.mem.eql(u8, changes.items[0].path(), "src/main.zig"));

    // And as the patch git prints, when text is what you want.
    var patch: std.Io.Writer.Allocating = .init(gpa);
    defer patch.deinit();
    try relic.diff.unified(gpa, io, &patch.writer, &repo.odb, changes.items[0], .{});
    std.debug.assert(std.mem.startsWith(u8, patch.written(), "diff --git a/src/main.zig b/src/main.zig\n"));

    // Put the first tree back: files the tree lacks go, changed ones are
    // rewritten, and untracked and ignored files are left alone.
    const restored = try relic.worktree.checkout(gpa, io, dir, &index, &repo.odb, tree, .{ .rules = rules });
    std.debug.assert(restored.written == 1);

    // --- README:usage ---

    var buf: [64]u8 = undefined;
    std.debug.assert(std.mem.eql(u8, try dir.readFile(io, "src/main.zig", &buf), "pub fn main() void {}\n"));
    std.debug.assert(std.mem.eql(u8, try dir.readFile(io, "build.log", &buf), "not staged\n"));
}

test "overlapping usage examples own different scratch directories" {
    const Io = std.Io;
    const Controlled = struct {
        parent: Io.Dir,
        lock: Io.Mutex = .init,
        opened: usize = 0,
        paths: [2][256]u8 = undefined,
        lengths: [2]usize = undefined,
        ready: Io.Event = .unset,
        proceed: Io.Event = .unset,
        threadlocal var state: ?*@This() = null;
        threadlocal var intercepted: bool = false;

        fn open(context: ?*anyopaque, parent: Io.Dir, path: []const u8, options: Io.Dir.OpenOptions) Io.Dir.OpenError!Io.Dir {
            const dir = try std.testing.io.vtable.dirOpenDir(context, parent, path, options);
            errdefer dir.close(std.testing.io);
            if (state) |control| {
                if (!intercepted and parent.handle == control.parent.handle and std.mem.startsWith(u8, path, "relic-example")) {
                    intercepted = true;
                    {
                        control.lock.lockUncancelable(std.testing.io);
                        defer control.lock.unlock(std.testing.io);
                        const i = control.opened;
                        @memcpy(control.paths[i][0..path.len], path);
                        control.lengths[i] = path.len;
                        control.opened += 1;
                        if (control.opened == 2) control.ready.set(std.testing.io);
                    }
                    control.proceed.wait(std.testing.io) catch return error.Canceled;
                }
            }
            return dir;
        }

        fn example(control: *@This(), io: Io) !void {
            state = control;
            intercepted = false;
            defer state = null;
            try run(std.testing.allocator, io, control.parent);
        }
    };
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var control: Controlled = .{ .parent = tmp.dir };
    var vtable = io.vtable.*;
    vtable.dirOpenDir = Controlled.open;
    const guarded: Io = .{ .userdata = io.userdata, .vtable = &vtable };
    var first = try io.concurrent(Controlled.example, .{ &control, guarded });
    defer first.cancel(io) catch {};
    var second = try io.concurrent(Controlled.example, .{ &control, guarded });
    defer second.cancel(io) catch {};
    defer control.proceed.set(io);
    const example_watchdog: Io.Duration = .fromSeconds(5);
    try control.ready.waitTimeout(io, .{ .duration = .{ .raw = example_watchdog, .clock = .awake } });
    try std.testing.expect(!std.mem.eql(u8, control.paths[0][0..control.lengths[0]], control.paths[1][0..control.lengths[1]]));
    control.proceed.set(io);
    try first.await(io);
    try second.await(io);
    var entries = tmp.dir.iterate();
    try std.testing.expectEqual(@as(?Io.Dir.Entry, null), try entries.next(io));
}
