//! A whole cycle on a repository in a temporary directory: create it, stage
//! the working tree, write a tree and a commit, move a branch with a reflog
//! entry, read the commit back, and diff two trees.
//!
//! `zig build examples` builds AND runs this; `ci/readme_usage.sh` extracts
//! the region between the usage markers into README.md, so the snippet a
//! reader copies is code CI executes.

const std = @import("std");
const relic = @import("relic");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var cwd: std.Io.Dir = .cwd();
    defer cwd.deleteTree(io, "relic-example") catch {};
    try cwd.createDirPath(io, "relic-example");
    var dir = try cwd.openDir(io, "relic-example", .{ .iterate = true });
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
    var rules = repo.worktreeRules();
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
    });

    // Move the branch and write the reflog, both or neither.
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
