//! The suite's remote helper: one program, two helpers by the name it is
//! run under, each reaching another repository on this machine through
//! `git`, so that git and relic can be pointed at the same helper and what
//! each makes of it compared.
//!
//! - `git-remote-testgit` is git's own `t/t5801/git-remote-testgit` in
//!   Zig: `import` and `export` through `git fast-export` and `git
//!   fast-import`, a private namespace by `refspec`, marks files under
//!   `$GIT_DIR/testgit/<alias>`, `option`, `object-format`.
//!   `RELIC_HELPER_NO_PRIVATE_UPDATE` adds `no-private-update`,
//!   `RELIC_HELPER_PUSH_ERROR` answers every pushed ref with `error`.
//! - `git-remote-testfetch` has `fetch` and `push`: the objects fetched are
//!   packed by the remote's `git pack-objects` and indexed here by `git
//!   index-pack`; a push is `git push` from here to there.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Helper = struct {
    gpa: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    /// The remote's git directory.
    remote: []const u8,
    /// This side's, from `GIT_DIR`.
    local: []const u8,
    in: *Io.Reader,
    out: *Io.Writer,
    force: bool = false,
    object_format: bool = false,

    fn git(h: *Helper, git_dir: []const u8, args: []const []const u8, input: ?[]const u8) ![]u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(h.gpa);
        try argv.append(h.gpa, "git");
        if (git_dir.len != 0) try argv.appendSlice(h.gpa, &.{ "--git-dir", git_dir });
        try argv.appendSlice(h.gpa, args);
        var child = try std.process.spawn(h.io, .{
            .argv = argv.items,
            .environ_map = h.environ,
            .stdin = if (input != null) .pipe else .ignore,
            .stdout = .pipe,
            .stderr = .inherit,
        });
        defer child.kill(h.io);
        if (input) |bytes| {
            var buf: [4096]u8 = undefined;
            var w = child.stdin.?.writer(h.io, &buf);
            try w.interface.writeAll(bytes);
            try w.interface.flush();
            child.stdin.?.close(h.io);
            child.stdin = null;
        }
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(h.gpa);
        var buf: [4096]u8 = undefined;
        var reader = child.stdout.?.reader(h.io, &buf);
        try reader.interface.appendRemainingUnlimited(h.gpa, &out);
        const term = try child.wait(h.io);
        switch (term) {
            .exited => |code| if (code != 0) return error.GitFailed,
            else => return error.GitFailed,
        }
        return out.toOwnedSlice(h.gpa);
    }

    fn line(h: *Helper, buf: *std.ArrayList(u8)) !?[]const u8 {
        buf.clearRetainingCapacity();
        var aw: Io.Writer.Allocating = .fromArrayList(h.gpa, buf);
        _ = try h.in.streamDelimiterEnding(&aw.writer, '\n');
        buf.* = aw.toArrayList();
        if (h.in.bufferedLen() == 0) return if (buf.items.len == 0) null else buf.items;
        h.in.toss(1);
        return buf.items;
    }

    fn list(h: *Helper, with_values: bool) !void {
        if (h.object_format) try h.out.writeAll(":object-format sha1\n");
        const format = if (with_values) "%(objectname) %(refname)" else "? %(refname)";
        const refs = try h.git(h.remote, &.{ "for-each-ref", try std.fmt.allocPrint(h.gpa, "--format={s}", .{format}), "refs/heads/", "refs/tags/" }, null);
        defer h.gpa.free(refs);
        try h.out.writeAll(refs);
        const head = try h.git(h.remote, &.{ "symbolic-ref", "HEAD" }, null);
        defer h.gpa.free(head);
        try h.out.print("@{s} HEAD\n\n", .{std.mem.trimEnd(u8, head, "\n")});
        try h.out.flush();
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len < 3) return error.MissingArguments;
    var base = std.fs.path.basename(args[0]);
    if (std.mem.endsWith(u8, base, ".exe")) base = base[0 .. base.len - 4];
    const testgit = std.mem.eql(u8, base, "git-remote-testgit");

    // The gits this runs are pointed at their repository by name, never by
    // the variables that point at this one.
    const local = try gpa.dupe(u8, init.environ_map.get("GIT_DIR") orelse return error.NoGitDir);
    const environ = try gpa.create(std.process.Environ.Map);
    environ.* = try init.environ_map.clone(gpa);
    for ([_][]const u8{ "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY", "GIT_INDEX_FILE" }) |name| _ = environ.swapRemove(name);
    const alias = if (std.mem.startsWith(u8, args[1], "testgit::") and std.mem.eql(u8, args[1]["testgit::".len..], args[2])) "_" else args[1];
    const url = args[2];

    var in_buf: [64 * 1024]u8 = undefined;
    var in = Io.File.stdin().readerStreaming(io, &in_buf);
    var out_buf: [64 * 1024]u8 = undefined;
    var out = Io.File.stdout().writerStreaming(io, &out_buf);
    var h: Helper = .{
        .gpa = gpa,
        .io = io,
        .environ = environ,
        .remote = "",
        .local = local,
        .in = &in.interface,
        .out = &out.interface,
    };
    const absolute = try h.git("", &.{ "-C", url, "rev-parse", "--absolute-git-dir" }, null);
    h.remote = std.mem.trimEnd(u8, absolute, "\r\n");

    const dir = try std.fmt.allocPrint(gpa, "{s}/testgit/{s}", .{ local, alias });
    try Io.Dir.cwd().createDirPath(io, dir);
    const gitmarks = try std.fmt.allocPrint(gpa, "{s}/git.marks", .{dir});
    const testgitmarks = try std.fmt.allocPrint(gpa, "{s}/testgit.marks", .{dir});
    for ([_][]const u8{ gitmarks, testgitmarks }) |path| {
        Io.Dir.cwd().access(io, path, .{}) catch try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "" });
    }
    const h_refspec = try std.fmt.allocPrint(gpa, "refs/heads/*:refs/testgit/{s}/heads/*", .{alias});
    const t_refspec = try std.fmt.allocPrint(gpa, "refs/tags/*:refs/testgit/{s}/tags/*", .{alias});

    var buf: std.ArrayList(u8) = .empty;
    while (try h.line(&buf)) |text| {
        if (std.mem.eql(u8, text, "capabilities")) {
            if (testgit) {
                try h.out.print("import\nexport\nrefspec {s}\nrefspec {s}\n*import-marks {s}\n*export-marks {s}\n", .{ h_refspec, t_refspec, gitmarks, gitmarks });
                if (environ.get("RELIC_HELPER_NO_PRIVATE_UPDATE") != null) try h.out.writeAll("no-private-update\n");
                try h.out.writeAll("option\nobject-format\n\n");
            } else {
                try h.out.writeAll("fetch\npush\noption\n\n");
            }
            try h.out.flush();
        } else if (std.mem.eql(u8, text, "list") or std.mem.eql(u8, text, "list for-push")) {
            try h.list(!testgit);
        } else if (std.mem.startsWith(u8, text, "option ")) {
            var words = std.mem.splitScalar(u8, text["option ".len..], ' ');
            const name = words.next().?;
            const value = words.rest();
            if (std.mem.eql(u8, name, "force")) {
                h.force = std.mem.eql(u8, value, "true");
                try h.out.writeAll("ok\n");
            } else if (std.mem.eql(u8, name, "object-format")) {
                h.object_format = std.mem.eql(u8, value, "true");
                try h.out.writeAll("ok\n");
            } else try h.out.writeAll("unsupported\n");
            try h.out.flush();
        } else if (std.mem.startsWith(u8, text, "import ")) {
            var refs: std.ArrayList([]const u8) = .empty;
            var current: ?[]const u8 = text;
            while (current) |l| {
                if (!std.mem.startsWith(u8, l, "import ")) break;
                try refs.append(gpa, try gpa.dupe(u8, l["import ".len..]));
                current = try h.line(&buf);
            }
            try h.out.print("feature import-marks={s}\nfeature export-marks={s}\nfeature done\n", .{ gitmarks, gitmarks });
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.appendSlice(gpa, &.{
                "fast-export",
                try std.fmt.allocPrint(gpa, "--refspec={s}", .{h_refspec}),
                try std.fmt.allocPrint(gpa, "--refspec={s}", .{t_refspec}),
                try std.fmt.allocPrint(gpa, "--import-marks={s}", .{testgitmarks}),
                try std.fmt.allocPrint(gpa, "--export-marks={s}", .{testgitmarks}),
            });
            try argv.appendSlice(gpa, refs.items);
            const stream = try h.git(h.remote, argv.items, null);
            try h.out.writeAll(stream);
            try h.out.writeAll("done\n");
            try h.out.flush();
        } else if (std.mem.eql(u8, text, "export")) {
            const stream = try readStream(&h, &buf);
            const before = try h.git(h.remote, &.{ "for-each-ref", "--format=%(refname) %(objectname)" }, null);
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.append(gpa, "fast-import");
            if (h.force) try argv.append(gpa, "--force");
            try argv.appendSlice(gpa, &.{
                try std.fmt.allocPrint(gpa, "--import-marks={s}", .{testgitmarks}),
                try std.fmt.allocPrint(gpa, "--export-marks={s}", .{testgitmarks}),
                "--quiet",
            });
            _ = try h.git(h.remote, argv.items, stream);
            const after = try h.git(h.remote, &.{ "for-each-ref", "--format=%(refname) %(objectname)" }, null);
            var lines = std.mem.splitScalar(u8, after, '\n');
            while (lines.next()) |l| {
                if (l.len == 0) continue;
                if (std.mem.indexOf(u8, before, l) != null) continue;
                const ref = l[0..std.mem.indexOfScalar(u8, l, ' ').?];
                if (environ.get("RELIC_HELPER_PUSH_ERROR")) |why| {
                    try h.out.print("error {s} {s}\n", .{ ref, why });
                } else try h.out.print("ok {s}\n", .{ref});
            }
            try h.out.writeAll("\n");
            try h.out.flush();
        } else if (std.mem.startsWith(u8, text, "fetch ")) {
            var oids: std.ArrayList(u8) = .empty;
            var current: ?[]const u8 = text;
            while (current) |l| {
                if (!std.mem.startsWith(u8, l, "fetch ")) break;
                const rest = l["fetch ".len..];
                try oids.appendSlice(gpa, rest[0..std.mem.indexOfScalar(u8, rest, ' ').?]);
                try oids.append(gpa, '\n');
                current = try h.line(&buf);
            }
            const pack = try h.git(h.remote, &.{ "pack-objects", "--revs", "--stdout" }, oids.items);
            _ = try h.git(h.local, &.{ "index-pack", "--stdin" }, pack);
            try h.out.writeAll("\n");
            try h.out.flush();
        } else if (std.mem.startsWith(u8, text, "push ")) {
            var specs: std.ArrayList([]const u8) = .empty;
            var current: ?[]const u8 = text;
            while (current) |l| {
                if (!std.mem.startsWith(u8, l, "push ")) break;
                try specs.append(gpa, try gpa.dupe(u8, l["push ".len..]));
                current = try h.line(&buf);
            }
            for (specs.items) |spec| {
                const dst = spec[std.mem.lastIndexOfScalar(u8, spec, ':').? + 1 ..];
                if (h.git(h.local, &.{ "push", "--quiet", h.remote, spec }, null)) |o| {
                    gpa.free(o);
                    try h.out.print("ok {s}\n", .{dst});
                } else |_| try h.out.print("error {s} rejected\n", .{dst});
            }
            try h.out.writeAll("\n");
            try h.out.flush();
        } else if (text.len == 0) {
            return;
        } else return error.UnknownCommand;
    }
}

/// A fast-import stream, up to and including its `done`, read whole: its
/// `data` read by count or by delimiter, so a `done` inside a file is not
/// taken for the end.
fn readStream(h: *Helper, buf: *std.ArrayList(u8)) ![]u8 {
    var stream: std.ArrayList(u8) = .empty;
    while (try h.line(buf)) |l| {
        try stream.appendSlice(h.gpa, l);
        try stream.append(h.gpa, '\n');
        if (std.mem.eql(u8, l, "done")) break;
        if (!std.mem.startsWith(u8, l, "data ")) continue;
        const arg = l["data ".len..];
        if (std.mem.startsWith(u8, arg, "<<")) {
            const delim = try h.gpa.dupe(u8, arg[2..]);
            while (try h.line(buf)) |d| {
                try stream.appendSlice(h.gpa, d);
                try stream.append(h.gpa, '\n');
                if (std.mem.eql(u8, d, delim)) break;
            }
        } else {
            const n = try std.fmt.parseInt(usize, arg, 10);
            const start = stream.items.len;
            try stream.resize(h.gpa, start + n);
            try h.in.readSliceAll(stream.items[start..]);
        }
    }
    return stream.toOwnedSlice(h.gpa);
}
