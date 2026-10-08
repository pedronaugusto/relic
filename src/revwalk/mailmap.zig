//! Who a commit's author and committer are, as `.mailmap` says: git's
//! `mailmap.c`.
//!
//! A line maps an email, or a name and an email, to a proper name, a proper
//! email or both:
//!
//!     Proper Name <commit@email>
//!     <proper@email> <commit@email>
//!     Proper Name <proper@email> <commit@email>
//!     Proper Name <proper@email> Commit Name <commit@email>
//!
//! Emails and names are matched without regard to ASCII case, a later line
//! for the same email (and name) replaces an earlier one, and a line naming
//! the commit name as well wins over one that does not, but only for that
//! name. `#` at the very start makes a line a comment; anything else that
//! does not parse is passed over, as git passes it over.
//!
//! git reads a file through `fgets` with a 1024-byte buffer, so a line of
//! 1024 bytes or more is read as several lines, each parsed on its own; a
//! blob is read whole and ends at its first NUL. Both are kept here, since
//! both decide what git maps. `Mailmap.load` reads what `git log` and `git
//! shortlog` read: `.mailmap` at the top of the working tree (not followed
//! when it is a symbolic link), then `mailmap.blob` (`HEAD:.mailmap` by
//! default in a bare repository), then `mailmap.file`, each overriding the
//! one before.
//!
//! This is the one owner of mailmap parsing and lookup in relic: shortlog
//! asks it, and so does anything else that shows a commit's people.

const ErrorNamespace = @This();
const Self = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const odb_mod = @import("../odb/odb.zig");

const repo_mod = @import("../repo/repo.zig");
const revparse = @import("revparse.zig");

const Repository = repo_mod.Repository;

/// An identity a lookup answers with. Both are borrowed: from the mailmap
/// where it replaced them, from the caller where it did not.
pub const Identity = struct {
    name: []const u8,
    email: []const u8,
};

/// Errors from loading a repository's mailmap.
pub const LoadError = Allocator.Error || Io.File.Reader.Error || Io.Dir.ReadFileAllocError ||
    error{MalformedValue} || odb_mod.Error;

/// git's `isspace`: space, tab, newline and carriage return, and not the
/// vertical tab or form feed C's adds.
fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// Keys compared as `strcasecmp` compares them: ASCII case folded.
pub const Folded = struct {
    pub fn hash(_: Folded, key: []const u8) u64 {
        var h = std.hash.Wyhash.init(0);
        var buf: [64]u8 = undefined;
        var at: usize = 0;
        while (at < key.len) {
            const n = @min(buf.len, key.len - at);
            for (key[at .. at + n], buf[0..n]) |c, *d| d.* = std.ascii.toLower(c);
            h.update(buf[0..n]);
            at += n;
        }
        return h.final();
    }
    pub fn eql(_: Folded, a: []const u8, b: []const u8) bool {
        return std.ascii.eqlIgnoreCase(a, b);
    }
};

fn FoldedMap(comptime V: type) type {
    return std.HashMapUnmanaged([]const u8, V, Folded, std.hash_map.default_max_load_percentage);
}

/// What one email, or one name under an email, maps to. `null` leaves that
/// part as it was.
const Info = struct {
    name: ?[]const u8 = null,
    email: ?[]const u8 = null,
};

const Entry = struct {
    /// The simple mapping: by email alone.
    info: Info = .{},
    /// By email and name.
    names: FoldedMap(Info) = .empty,
};

/// A parsed mailmap.
pub const Mailmap = struct {
    pub const Error = ErrorNamespace.Error;

    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    entries: FoldedMap(Entry) = .empty,

    /// An empty mailmap, which maps nobody.
    pub fn init(gpa: Allocator) Mailmap {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    /// Release everything.
    pub fn deinit(m: *Mailmap) void {
        var it = m.entries.valueIterator();
        while (it.next()) |entry| entry.names.deinit(m.gpa);
        m.entries.deinit(m.gpa);
        m.arena.deinit();
        m.* = undefined;
    }

    /// How many emails the mailmap has an entry for.
    pub fn count(m: *const Mailmap) usize {
        return m.entries.count();
    }

    /// Add the lines of `text` as git reads a mailmap blob: up to its
    /// first NUL, one line at a time.
    pub fn addText(m: *Mailmap, text: []const u8) Allocator.Error!void {
        const end = std.mem.findScalar(u8, text, 0) orelse text.len;
        var lines = std.mem.splitScalar(u8, text[0..end], '\n');
        while (lines.next()) |line| try m.addLine(line);
    }

    /// Add the lines of `bytes` as git reads a mailmap file: `fgets` into
    /// a buffer of 1024, so a longer line arrives in pieces, each a line of
    /// its own, and each piece ends at a NUL in it.
    pub fn addFileBytes(m: *Mailmap, bytes: []const u8) Allocator.Error!void {
        var at: usize = 0;
        while (at < bytes.len) {
            const limit = @min(bytes.len, at + 1023);
            const end = if (std.mem.findScalarPos(u8, bytes[0..limit], at, '\n')) |nl| nl + 1 else limit;
            const piece = bytes[at..end];
            at = end;
            const cut = std.mem.findScalar(u8, piece, 0) orelse piece.len;
            try m.addLine(piece[0..cut]);
        }
    }

    /// `read_mailmap_line`: one line, which may still carry its newline.
    pub fn addLine(m: *Mailmap, line: []const u8) Allocator.Error!void {
        if (line.len > 0 and line[0] == '#') return;
        const first = parseNameAndEmail(line, false);
        const email1 = first.email orelse return;
        var name2: ?[]const u8 = null;
        var email2: ?[]const u8 = null;
        if (first.rest) |rest| {
            const second = parseNameAndEmail(rest, true);
            name2 = second.name;
            email2 = second.email;
        }
        try m.addMapping(first.name, email1, name2, email2);
    }

    /// `add_mapping`.
    fn addMapping(m: *Mailmap, new_name_in: ?[]const u8, new_email_in: ?[]const u8, old_name: ?[]const u8, old_email_in: ?[]const u8) Allocator.Error!void {
        const a = m.arena.allocator();
        var new_email = new_email_in;
        var old_email = old_email_in;
        if (old_email == null) {
            old_email = new_email;
            new_email = null;
        }
        const slot = try m.entries.getOrPut(m.gpa, old_email.?);
        if (!slot.found_existing) {
            slot.key_ptr.* = try a.dupe(u8, old_email.?);
            slot.value_ptr.* = .{};
        }
        const entry = slot.value_ptr;
        if (old_name) |name| {
            const info: Info = .{
                .name = if (new_name_in) |n| try a.dupe(u8, n) else null,
                .email = if (new_email) |e| try a.dupe(u8, e) else null,
            };
            const sub = try entry.names.getOrPut(m.gpa, name);
            if (!sub.found_existing) sub.key_ptr.* = try a.dupe(u8, name);
            sub.value_ptr.* = info;
        } else {
            if (new_name_in) |n| entry.info.name = try a.dupe(u8, n);
            if (new_email) |e| entry.info.email = try a.dupe(u8, e);
        }
    }

    /// `map_user`: what `name` and `email` map to, or `null` when nothing
    /// in the mailmap changes them.
    pub fn lookup(m: *const Mailmap, name: []const u8, email: []const u8) ?Identity {
        const entry = m.entries.getPtr(email) orelse return null;
        var info = entry.info;
        if (entry.names.count() != 0) {
            if (entry.names.get(name)) |sub| info = sub;
        }
        if (info.name == null and info.email == null) return null;
        return .{ .name = info.name orelse name, .email = info.email orelse email };
    }

    /// `name` and `email` as the mailmap shows them: mapped where it maps
    /// them, as given where it does not.
    pub fn map(m: *const Mailmap, name: []const u8, email: []const u8) Identity {
        return m.lookup(name, email) orelse .{ .name = name, .email = email };
    }

    /// `read_mailmap`: the working tree's `.mailmap`, then `mailmap.blob`
    /// (by default `HEAD:.mailmap` in a bare repository), then
    /// `mailmap.file`. One that is missing, cannot be opened, or does not
    /// name a blob is passed over, as git passes over it with an error on
    /// its standard error.
    pub fn load(gpa: Allocator, io: Io, repo: *Repository) Self.LoadError!Mailmap {
        var m: Mailmap = .init(gpa);
        errdefer m.deinit();
        const config = repo.configuration();

        if (!repo.isBare()) if (repo.workDirectory()) |wt| {
            try m.addFileAt(io, wt, ".mailmap", false);
        };

        var blob_name: ?[]u8 = null;
        defer if (blob_name) |b| gpa.free(b);
        if (config.get("mailmap.blob")) |raw| {
            blob_name = try gpa.dupe(u8, raw);
        } else if (repo.isBare()) {
            blob_name = try gpa.dupe(u8, "HEAD:.mailmap");
        }
        if (blob_name) |name| blob: {
            const oid = revparse.resolve(gpa, io, repo, name) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => break :blob,
            };
            const found = repo.objectDatabase().read(io, oid) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => break :blob,
            };
            defer repo.objectDatabase().allocator().free(found.bytes);
            if (found.type != .blob) break :blob;
            try m.addText(found.bytes);
        }

        if (try config.getPath(gpa, "mailmap.file")) |path| {
            defer gpa.free(path);
            const dir = repo.workDirectory() orelse Io.Dir.cwd();
            try m.addFileAt(io, dir, path, true);
        }
        return m;
    }

    /// Errors from `addFileAt`.
    pub const AddFileAtError = Allocator.Error || Io.File.Reader.Error;

    /// Add the file at `path`, read as git reads one; a file that is not
    /// there, or cannot be read, adds nothing. Without `follow_symlinks`, a
    /// symbolic link adds nothing, as git's `open_nofollow` refuses one;
    /// git for Windows has no such open and follows it, and so does this
    /// there.
    pub fn addFileAt(m: *Mailmap, io: Io, dir: Io.Dir, path: []const u8, follow_symlinks: bool) AddFileAtError!void {
        if (!follow_symlinks and builtin.target.os.tag != .windows) {
            const st = dir.statFile(io, path, .{ .follow_symlinks = false }) catch return;
            if (st.kind == .sym_link) return;
        }
        const bytes = dir.readFileAlloc(io, path, m.gpa, .unlimited) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return,
        };
        defer m.gpa.free(bytes);
        try m.addFileBytes(bytes);
    }
};

const Parsed = struct {
    name: ?[]const u8 = null,
    email: ?[]const u8 = null,
    /// What follows the `>`, when anything does.
    rest: ?[]const u8 = null,
};

/// `parse_name_and_email`.
fn parseNameAndEmail(buffer: []const u8, allow_empty_email: bool) Parsed {
    const left = std.mem.findScalar(u8, buffer, '<') orelse return .{};
    const right = std.mem.findScalarPos(u8, buffer, left + 1, '>') orelse return .{};
    if (!allow_empty_email and left + 1 == right) return .{};
    var nstart: usize = 0;
    while (nstart < left and isSpace(buffer[nstart])) nstart += 1;
    // `nend` is the last byte of the name, one before `<` to start with;
    // a name of nothing leaves it before `nstart`.
    var nend: isize = @as(isize, @intCast(left)) - 1;
    while (nend > @as(isize, @intCast(nstart)) and isSpace(buffer[@intCast(nend)])) nend -= 1;
    const name: ?[]const u8 = if (@as(isize, @intCast(nstart)) <= nend) buffer[nstart..@intCast(nend + 1)] else null;
    const rest = buffer[right + 1 ..];
    return .{ .name = name, .email = buffer[left + 1 .. right], .rest = if (rest.len == 0) null else rest };
}

test "a mailmap maps by email, and by name and email, as git's examples do" {
    const gpa = std.testing.allocator;
    var m: Mailmap = .init(gpa);
    defer m.deinit();
    try m.addText(
        \\# a comment
        \\Proper Name <commit@email.xx>
        \\<proper@email.xx> <other@email.xx>
        \\Joe R. Developer <joe@example.com> Joe <bugs@example.com>
        \\Jane Doe <jane@example.com> <jane@desktop.(none)>
        \\
    );
    const a = m.map("whoever", "COMMIT@email.xx");
    try std.testing.expectEqualStrings("Proper Name", a.name);
    try std.testing.expectEqualStrings("COMMIT@email.xx", a.email);
    const b = m.map("Other", "other@email.xx");
    try std.testing.expectEqualStrings("Other", b.name);
    try std.testing.expectEqualStrings("proper@email.xx", b.email);
    const c = m.map("joe", "bugs@example.com");
    try std.testing.expectEqualStrings("Joe R. Developer", c.name);
    try std.testing.expectEqualStrings("joe@example.com", c.email);
    // Another name at the same email is not this entry's.
    try std.testing.expect(m.lookup("Jim", "bugs@example.com") == null);
    try std.testing.expectEqualStrings("Jane Doe", m.map("x", "jane@desktop.(none)").name);
}

test "a line too long for git's buffer is read in pieces, as git reads it" {
    const gpa = std.testing.allocator;
    var m: Mailmap = .init(gpa);
    defer m.deinit();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendNTimes(gpa, 'x', 1020);
    try text.appendSlice(gpa, "A <a@b> B <c@d>\n");
    try m.addFileBytes(text.items);
    // The first piece ends at `A <`, which has no `>`; the second is
    // `a@b> B <c@d>`, which maps `c@d` to the name `a@b> B`, as `git
    // check-mailmap` says.
    try std.testing.expectEqualStrings("a@b> B", m.map("n", "c@d").name);
}

test "fuzz: any bytes are a mailmap, and every lookup answers" {
    try std.testing.fuzz({}, fuzzMailmap, .{});
}

fn fuzzMailmap(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;
    var buf: [512]u8 = undefined;
    const text = buf[0..smith.slice(&buf)];
    var m: Mailmap = .init(gpa);
    defer m.deinit();
    try m.addFileBytes(text);
    try m.addText(text);
    var it = m.entries.iterator();
    while (it.next()) |kv| {
        const found = m.map("name", kv.key_ptr.*);
        try std.testing.expect(found.email.len <= text.len or std.mem.eql(u8, found.email, kv.key_ptr.*));
    }
}

const testgit = @import("../testing/git.zig");

/// Ask `git check-mailmap` and this the same questions, over a mailmap of
/// lines put together from pieces that exercise case, overriding, empty
/// emails, stray whitespace and lines that do not parse.
fn compareWithGit(gpa: Allocator, io: Io, seed: u64) !void {
    var r = try testgit.Repo.init(gpa, io, &.{});
    defer r.deinit();
    var prng: std.Random.DefaultPrng = .init(seed);
    const rand = prng.random();
    const names = [_][]const u8{ "Ann", "ann", "ANN Lee", "Bob", " Bob ", "", "\tCy" };
    const emails = [_][]const u8{ "a@x", "A@X", "b@x", "c@Y", "" };
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (0..24) |_| {
        const n1 = names[rand.uintLessThan(usize, names.len)];
        const e1 = emails[rand.uintLessThan(usize, emails.len)];
        const n2 = names[rand.uintLessThan(usize, names.len)];
        const e2 = emails[rand.uintLessThan(usize, emails.len)];
        switch (rand.uintLessThan(u8, 8)) {
            0 => try text.print(gpa, "{s} <{s}>\n", .{ n1, e1 }),
            1 => try text.print(gpa, "<{s}> <{s}>\n", .{ e1, e2 }),
            2 => try text.print(gpa, "{s} <{s}> <{s}>\n", .{ n1, e1, e2 }),
            3 => try text.print(gpa, "{s} <{s}> {s} <{s}>\n", .{ n1, e1, n2, e2 }),
            4 => try text.print(gpa, "# {s} <{s}>\n", .{ n1, e1 }),
            5 => try text.print(gpa, "  {s}  <{s}>   {s}\t<{s}>  trailing\n", .{ n1, e1, n2, e2 }),
            6 => try text.print(gpa, "{s} {s}>\n", .{ n1, e1 }),
            else => try text.print(gpa, "<{s}>\n", .{e1}),
        }
    }
    try r.writeFile(io, ".mailmap", text.items);

    var args: std.ArrayList([]const u8) = .empty;
    defer {
        for (args.items[1..]) |a| gpa.free(a);
        args.deinit(gpa);
    }
    try args.append(gpa, "check-mailmap");
    for (names) |n| for (emails) |e| {
        // git cannot be asked about an empty name with a space before `<`.
        if (n.len == 0) {
            try args.append(gpa, try gpa.print("<{s}>", .{e}));
        } else {
            try args.append(gpa, try gpa.print("{s} <{s}>", .{ std.mem.trim(u8, n, " \t"), e }));
        }
    };
    const expected = try r.run(io, args.items);
    defer gpa.free(expected);

    var repo = try Repository.open(gpa, io, r.dir, .{});
    defer repo.deinit(io);
    var m = try Mailmap.load(gpa, io, &repo);
    defer m.deinit();
    var got: std.Io.Writer.Allocating = .init(gpa);
    defer got.deinit();
    for (args.items[1..]) |contact| {
        const lt = std.mem.findScalar(u8, contact, '<').?;
        var name = contact[0..lt];
        while (name.len > 0 and isSpace(name[name.len - 1])) name = name[0 .. name.len - 1];
        const email = contact[lt + 1 .. contact.len - 1];
        const shown = m.map(name, email);
        if (shown.name.len != 0) try got.writer.print("{s} ", .{shown.name});
        try got.writer.print("<{s}>\n", .{shown.email});
    }
    std.testing.expectEqualStrings(expected, got.written()) catch |err| {
        std.log.err("seed {d}, mailmap:\n{s}", .{ seed, text.items });
        return err;
    };
}

test "every identity maps as git check-mailmap maps it, over mailmaps of every shape" {
    for (0..12) |seed| try compareWithGit(std.testing.allocator, std.testing.io, seed);
}

test "mailmap.blob and mailmap.file override the working tree's .mailmap in git's order" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var r = try testgit.Repo.init(gpa, io, &.{});
    defer r.deinit();
    try r.writeFile(io, "committed", "From Blob <a@x>\nBlob Only <b@x>\n");
    try r.exec(io, &.{ "add", "committed" });
    try r.exec(io, &.{ "commit", "-q", "-m", "mailmap" });
    try r.writeFile(io, ".mailmap", "From Tree <a@x>\nTree Only <c@x>\nTree <d@x>\n");
    try r.writeFile(io, "elsewhere", "From File <d@x>\n");
    try r.exec(io, &.{ "config", "mailmap.blob", "HEAD:committed" });
    try r.exec(io, &.{ "config", "mailmap.file", "elsewhere" });
    const contacts = [_][]const u8{ "n <a@x>", "n <b@x>", "n <c@x>", "n <d@x>", "n <e@x>" };
    const expected = try r.run(io, &(.{"check-mailmap"} ++ contacts));
    defer gpa.free(expected);
    var repo = try Repository.open(gpa, io, r.dir, .{});
    defer repo.deinit(io);
    var m = try Mailmap.load(gpa, io, &repo);
    defer m.deinit();
    var got: std.Io.Writer.Allocating = .init(gpa);
    defer got.deinit();
    for (contacts) |contact| {
        const shown = m.map("n", contact[3 .. contact.len - 1]);
        try got.writer.print("{s} <{s}>\n", .{ shown.name, shown.email });
    }
    try std.testing.expectEqualStrings(expected, got.written());
}

test "a .mailmap that is a symbolic link is not read, as git does not read one" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var r = try testgit.Repo.init(gpa, io, &.{});
    defer r.deinit();
    try r.writeFile(io, "real", "Linked <a@x>\n");
    try r.dir.symLink(io, "real", ".mailmap", .{});
    const expected = try r.run(io, &.{ "check-mailmap", "n <a@x>" });
    defer gpa.free(expected);
    var repo = try Repository.open(gpa, io, r.dir, .{});
    defer repo.deinit(io);
    var m = try Mailmap.load(gpa, io, &repo);
    defer m.deinit();
    try std.testing.expectEqualStrings("n <a@x>\n", expected);
    try std.testing.expect(m.lookup("n", "a@x") == null);
}

/// All errors reported by this namespace.
pub const Error = LoadError || Mailmap.AddFileAtError || Allocator.Error || Self.LoadError;
