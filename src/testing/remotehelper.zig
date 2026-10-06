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
const program = @import("program.zig");

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
    /// Which helper this runs as: testgit, or testfetch.
    testgit: bool,
    force: bool = false,
    object_format: bool = false,
    /// git's marks and the helper's own, under `$GIT_DIR/testgit/<alias>`.
    gitmarks: []const u8 = "",
    testgitmarks: []const u8 = "",
    /// The private namespace for heads and for tags.
    h_refspec: []const u8 = "",
    t_refspec: []const u8 = "",

    fn git(h: *Helper, git_dir: []const u8, args: []const []const u8, input: ?[]const u8) ![]u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(h.gpa);
        try argv.append(h.gpa, try program.path(h.gpa, h.io, h.environ, "git"));
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

    /// Make the marks files under `$GIT_DIR/testgit/<alias>` when they are
    /// not there yet, and name the private namespace's refspecs.
    fn prepareMarks(h: *Helper, alias: []const u8) !void {
        const dir = try std.fmt.allocPrint(h.gpa, "{s}/testgit/{s}", .{ h.local, alias });
        try Io.Dir.cwd().createDirPath(h.io, dir);
        h.gitmarks = try std.fmt.allocPrint(h.gpa, "{s}/git.marks", .{dir});
        h.testgitmarks = try std.fmt.allocPrint(h.gpa, "{s}/testgit.marks", .{dir});
        for ([_][]const u8{ h.gitmarks, h.testgitmarks }) |path| {
            Io.Dir.cwd().access(h.io, path, .{}) catch try Io.Dir.cwd().writeFile(h.io, .{ .sub_path = path, .data = "" });
        }
        h.h_refspec = try std.fmt.allocPrint(h.gpa, "refs/heads/*:refs/testgit/{s}/heads/*", .{alias});
        h.t_refspec = try std.fmt.allocPrint(h.gpa, "refs/tags/*:refs/testgit/{s}/tags/*", .{alias});
    }

    fn capabilities(h: *Helper) !void {
        if (h.testgit) {
            try h.out.print("import\nexport\nrefspec {s}\nrefspec {s}\n*import-marks {s}\n*export-marks {s}\n", .{ h.h_refspec, h.t_refspec, h.gitmarks, h.gitmarks });
            if (h.environ.get("RELIC_HELPER_NO_PRIVATE_UPDATE") != null) try h.out.writeAll("no-private-update\n");
            try h.out.writeAll("option\nobject-format\n\n");
        } else {
            try h.out.writeAll("fetch\npush\noption\n\n");
        }
        try h.out.flush();
    }

    /// Take `force` and `object-format`; any other option is unsupported.
    fn option(h: *Helper, setting: []const u8) !void {
        var words = std.mem.splitScalar(u8, setting, ' ');
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
    }

    /// The lines of a batch that begins with `first`, each without `prefix`;
    /// the line that ends the batch is read and dropped.
    fn batch(h: *Helper, first: []const u8, prefix: []const u8, buf: *std.ArrayList(u8)) ![]const []const u8 {
        std.debug.assert(std.mem.startsWith(u8, first, prefix));
        var items: std.ArrayList([]const u8) = .empty;
        var current: ?[]const u8 = first;
        while (current) |l| {
            if (!std.mem.startsWith(u8, l, prefix)) break;
            try items.append(h.gpa, try h.gpa.dupe(u8, l[prefix.len..]));
            current = try h.line(buf);
        }
        std.debug.assert(items.items.len >= 1);
        return items.items;
    }

    /// A batch of `import`s: the remote's refs as a fast-export stream,
    /// through the marks.
    fn import(h: *Helper, first: []const u8, buf: *std.ArrayList(u8)) !void {
        const gpa = h.gpa;
        const refs = try h.batch(first, "import ", buf);
        try h.out.print("feature import-marks={s}\nfeature export-marks={s}\nfeature done\n", .{ h.gitmarks, h.gitmarks });
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(gpa, &.{
            "fast-export",
            try std.fmt.allocPrint(gpa, "--refspec={s}", .{h.h_refspec}),
            try std.fmt.allocPrint(gpa, "--refspec={s}", .{h.t_refspec}),
            try std.fmt.allocPrint(gpa, "--import-marks={s}", .{h.testgitmarks}),
            try std.fmt.allocPrint(gpa, "--export-marks={s}", .{h.testgitmarks}),
        });
        try argv.appendSlice(gpa, refs);
        const stream = try h.git(h.remote, argv.items, null);
        try h.out.writeAll(stream);
        try h.out.writeAll("done\n");
        try h.out.flush();
    }

    /// An `export`: the stream fast-imported into the remote, and each ref
    /// it moved answered `ok`, or `error` when the environment asks.
    fn @"export"(h: *Helper, buf: *std.ArrayList(u8)) !void {
        const gpa = h.gpa;
        const stream = try readStream(h, buf);
        const before = try h.git(h.remote, &.{ "for-each-ref", "--format=%(refname) %(objectname)" }, null);
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(gpa, "fast-import");
        if (h.force) try argv.append(gpa, "--force");
        try argv.appendSlice(gpa, &.{
            try std.fmt.allocPrint(gpa, "--import-marks={s}", .{h.testgitmarks}),
            try std.fmt.allocPrint(gpa, "--export-marks={s}", .{h.testgitmarks}),
            "--quiet",
        });
        _ = try h.git(h.remote, argv.items, stream);
        const after = try h.git(h.remote, &.{ "for-each-ref", "--format=%(refname) %(objectname)" }, null);
        var lines = std.mem.splitScalar(u8, after, '\n');
        while (lines.next()) |l| {
            if (l.len == 0) continue;
            if (std.mem.find(u8, before, l) != null) continue;
            const ref = l[0..std.mem.findScalar(u8, l, ' ').?];
            if (h.environ.get("RELIC_HELPER_PUSH_ERROR")) |why| {
                try h.out.print("error {s} {s}\n", .{ ref, why });
            } else try h.out.print("ok {s}\n", .{ref});
        }
        try h.out.writeAll("\n");
        try h.out.flush();
    }

    /// A batch of `fetch`es: the remote packs the objects, and this side
    /// indexes the pack.
    fn fetch(h: *Helper, first: []const u8, buf: *std.ArrayList(u8)) !void {
        const lines = try h.batch(first, "fetch ", buf);
        var oids: std.ArrayList(u8) = .empty;
        for (lines) |rest| {
            try oids.appendSlice(h.gpa, rest[0..std.mem.findScalar(u8, rest, ' ').?]);
            try oids.append(h.gpa, '\n');
        }
        const pack = try h.git(h.remote, &.{ "pack-objects", "--revs", "--stdout" }, oids.items);
        _ = try h.git(h.local, &.{ "index-pack", "--stdin" }, pack);
        try h.out.writeAll("\n");
        try h.out.flush();
    }

    /// A batch of `push`es: each refspec pushed from here to the remote by
    /// git, and answered by its outcome.
    fn push(h: *Helper, first: []const u8, buf: *std.ArrayList(u8)) !void {
        const specs = try h.batch(first, "push ", buf);
        for (specs) |spec| {
            const dst = spec[std.mem.findScalarLast(u8, spec, ':').? + 1 ..];
            if (h.git(h.local, &.{ "push", "--quiet", h.remote, spec }, null)) |o| {
                h.gpa.free(o);
                try h.out.print("ok {s}\n", .{dst});
            } else |_| try h.out.print("error {s} rejected\n", .{dst});
        }
        try h.out.writeAll("\n");
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
        .testgit = std.mem.eql(u8, base, "git-remote-testgit"),
    };
    const absolute = try h.git("", &.{ "-C", url, "rev-parse", "--absolute-git-dir" }, null);
    h.remote = std.mem.trimEnd(u8, absolute, "\r\n");
    try h.prepareMarks(alias);

    var buf: std.ArrayList(u8) = .empty;
    while (try h.line(&buf)) |text| {
        if (std.mem.eql(u8, text, "capabilities")) {
            try h.capabilities();
        } else if (std.mem.eql(u8, text, "list") or std.mem.eql(u8, text, "list for-push")) {
            try h.list(!h.testgit);
        } else if (std.mem.startsWith(u8, text, "option ")) {
            try h.option(text["option ".len..]);
        } else if (std.mem.startsWith(u8, text, "import ")) {
            try h.import(text, &buf);
        } else if (std.mem.eql(u8, text, "export")) {
            try h.@"export"(&buf);
        } else if (std.mem.startsWith(u8, text, "fetch ")) {
            try h.fetch(text, &buf);
        } else if (std.mem.startsWith(u8, text, "push ")) {
            try h.push(text, &buf);
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
