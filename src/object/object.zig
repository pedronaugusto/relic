//! The four object types, as bytes.
//!
//! Nothing here touches the disk. Every `parse` borrows from the bytes it is
//! given and every `write` appends to a writer the caller owns, so an object
//! may be built in memory, named, and only then stored.

const ErrorNamespace = @This();
const Self = @This();

// The modules relic's API puts under this one, as `relic.object.<name>`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const hash = @import("../hash/hash.zig");
const Oid = hash.Oid;
const Kind = hash.Kind;

/// What an object is.
pub const Type = enum {
    blob,
    tree,
    commit,
    tag,

    /// The word that goes in the object header and in a pack's type field.
    pub fn name(t: Type) []const u8 {
        return switch (t) {
            .blob => "blob",
            .tree => "tree",
            .commit => "commit",
            .tag => "tag",
        };
    }

    /// The type a header word names, or `error.UnknownObjectType`.
    pub const ParseError = error{UnknownObjectType};

    pub fn parse(text: []const u8) Type.ParseError!Type {
        if (std.mem.eql(u8, text, "blob")) return .blob;
        if (std.mem.eql(u8, text, "tree")) return .tree;
        if (std.mem.eql(u8, text, "commit")) return .commit;
        if (std.mem.eql(u8, text, "tag")) return .tag;
        return error.UnknownObjectType;
    }
};

/// An object's type and the length of its content, which is what a caller
/// needs far more often than the content.
pub const Header = struct {
    type: Type,
    size: u64,
};

/// Errors from reading a loose object's `"<type> <size>\0"` header.
pub const HeaderParseError = error{
    /// No NUL terminated the header within the bytes given.
    MissingHeaderTerminator,
    /// No space separated the type from the size.
    MalformedHeader,
    /// The size was not a decimal number, or did not fit in 64 bits.
    InvalidObjectSize,
    /// The type word was none of the four.
    UnknownObjectType,
};

/// Read `"<type> <size>\0"` from the front of `bytes`.
///
/// Returns the header and how many bytes it took, so the content follows at
/// that offset. A size with a leading zero, a sign or anything but digits is
/// refused, because git writes none and accepting one gives an object two
/// spellings.
pub fn parseHeader(bytes: []const u8) HeaderParseError!struct { header: Header, len: usize } {
    const nul = std.mem.findScalar(u8, bytes, 0) orelse return error.MissingHeaderTerminator;
    const line = bytes[0..nul];
    const space = std.mem.findScalar(u8, line, ' ') orelse return error.MalformedHeader;
    const t = try Type.parse(line[0..space]);
    const digits = line[space + 1 ..];
    if (digits.len == 0) return error.InvalidObjectSize;
    if (digits.len > 1 and digits[0] == '0') return error.InvalidObjectSize;
    // Digits only, as git reads it: `parseInt` would also take a sign and
    // `_` separators, and give one object several spellings.
    for (digits) |c| if (c < '0' or c > '9') return error.InvalidObjectSize;
    const size = std.fmt.parseInt(u64, digits, 10) catch return error.InvalidObjectSize;
    return .{ .header = .{ .type = t, .size = size }, .len = nul + 1 };
}

/// The five modes a tree entry may carry.
///
/// git has written `100664` and bare `40000` in the past and `fsck` still
/// reports them; `Mode.parse` accepts what git accepts and `raw` writes what
/// git writes.
pub const Mode = enum(u32) {
    file = 0o100644,
    exec = 0o100755,
    symlink = 0o120000,
    tree = 0o040000,
    gitlink = 0o160000,

    /// The numeric mode, as an integer.
    pub fn raw(m: Mode) u32 {
        return @backingInt(m);
    }

    /// The octal text a tree entry carries: no leading zero, so a directory
    /// is `40000` and a file is `100644`.
    pub fn text(m: Mode, buf: *[6]u8) []const u8 {
        // unreachable: every mode is at most 0o160000, six octal digits
        return std.mem.print(buf, "{o}", .{m.raw()}) catch unreachable;
    }

    /// Whether the entry names a subtree.
    pub fn isTree(m: Mode) bool {
        return m == .tree;
    }

    /// Whether the entry names a blob — a file, an executable or a symlink.
    pub fn isBlob(m: Mode) bool {
        return switch (m) {
            .file, .exec, .symlink => true,
            else => false,
        };
    }

    /// The object type an entry of this mode points at.
    pub fn objectType(m: Mode) ?Type {
        return switch (m) {
            .file, .exec, .symlink => .blob,
            .tree => .tree,
            // A gitlink names a commit in another repository, which this
            // repository does not have.
            .gitlink => null,
        };
    }

    /// The mode an octal tree field names.
    ///
    /// `100664` and `100664`-shaped historical modes fold to `file`, and a
    /// bare `0` directory to `tree`, which is what git's own reader does; a
    /// mode that is none of those is `error.InvalidMode`.
    pub const ParseError = error{InvalidMode};

    pub fn parse(octal: []const u8) Mode.ParseError!Mode {
        if (octal.len == 0 or octal.len > 6) return error.InvalidMode;
        var value: u32 = 0;
        for (octal) |c| {
            if (c < '0' or c > '7') return error.InvalidMode;
            value = value * 8 + (c - '0');
        }
        return fromRaw(value);
    }

    /// Errors from `fromRaw`.
    pub const FromRawError = error{InvalidMode};

    /// The mode a numeric value names, normalising the historical spellings.
    pub fn fromRaw(value: u32) FromRawError!Mode {
        return switch (value) {
            0o040000, 0 => .tree,
            0o120000 => .symlink,
            0o160000 => .gitlink,
            else => switch (value & 0o170000) {
                0o100000 => if (value & 0o111 != 0) .exec else .file,
                else => error.InvalidMode,
            },
        };
    }
};

/// How deep trees nest before a walk of them stops: git's
/// `core.maxTreeDepth` default, which keeps a hostile tree from running a
/// recursive walk off its stack. Every walk over trees in relic stops here
/// with `error.TreeTooDeep`.
pub const max_tree_depth = 2048;

/// Errors from reading a tree object.
pub const TreeParseError = error{
    /// An entry ran off the end of the object.
    TruncatedTree,
    /// An entry's mode field was not octal, or named no mode git writes.
    InvalidMode,
    /// An entry had an empty name, or a name holding `/` or NUL.
    InvalidEntryName,
};

/// A tree object: a sorted list of `<octal mode> SP <name> NUL <raw hash>`.
///
/// Borrows the bytes it was parsed from. The entry order is the object's own
/// and is never re-sorted on the way out, because the order is part of the
/// name.
pub const Tree = struct {
    kind: Kind,
    bytes: []const u8,

    /// One line of a tree.
    pub const Entry = struct {
        mode: Mode,
        /// One path component. Borrowed from the tree's bytes.
        name: []const u8,
        oid: Oid,

        /// git's sort key: the name for a blob, the name with `/` appended
        /// for a subtree. `writeKey` fills `buf`, which must hold
        /// `name.len + 1` bytes.
        pub fn sortKey(e: Tree.Entry, buf: []u8) []const u8 {
            @memcpy(buf[0..e.name.len], e.name);
            if (!e.mode.isTree()) return buf[0..e.name.len];
            buf[e.name.len] = '/';
            return buf[0 .. e.name.len + 1];
        }
    };

    /// A tree over `bytes`, which must outlive it.
    ///
    /// Nothing is walked here; a malformed entry is found by the iterator.
    pub fn parse(kind: Kind, bytes: []const u8) Tree {
        return .{ .kind = kind, .bytes = bytes };
    }

    /// A walk over the entries, in the order the object holds them.
    pub fn iterate(tree: Tree) Iterator {
        return .{ .tree = tree, .offset = 0 };
    }

    /// The entry named `name`, or `null`.
    ///
    /// A linear walk: a tree is sorted by git's key and not by plain name, so
    /// a bisection here would be wrong for a subtree.
    pub fn find(tree: Tree, name: []const u8) TreeParseError!?Entry {
        var it = tree.iterate();
        while (try it.next()) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }

    /// How many entries the tree has. Walks it.
    pub fn count(tree: Tree) TreeParseError!usize {
        var it = tree.iterate();
        var n: usize = 0;
        while (try it.next()) |_| n += 1;
        return n;
    }

    /// A walk over a tree's entries.
    pub const Iterator = struct {
        tree: Tree,
        offset: usize,

        /// The next entry, or `null` at the end.
        pub fn next(it: *Iterator) TreeParseError!?Tree.Entry {
            const bytes = it.tree.bytes;
            if (it.offset >= bytes.len) return null;
            const rest = bytes[it.offset..];
            const space = std.mem.findScalar(u8, rest, ' ') orelse return error.TruncatedTree;
            const mode = try Mode.parse(rest[0..space]);
            const after_mode = rest[space + 1 ..];
            const nul = std.mem.findScalar(u8, after_mode, 0) orelse return error.TruncatedTree;
            const name = after_mode[0..nul];
            if (name.len == 0) return error.InvalidEntryName;
            if (std.mem.findScalar(u8, name, '/') != null) return error.InvalidEntryName;
            const raw_len = it.tree.kind.rawLen();
            const oid_start = space + 1 + nul + 1;
            if (rest.len < oid_start + raw_len) return error.TruncatedTree;
            // unreachable: the slice is cut to the format's raw length
            const oid = Oid.fromRaw(it.tree.kind, rest[oid_start..][0..raw_len]) catch unreachable;
            it.offset += oid_start + raw_len;
            return .{ .mode = mode, .name = name, .oid = oid };
        }
    };

    /// Builds a tree object's bytes.
    ///
    /// Entries may be added in any order; `write` sorts them by git's rule,
    /// which is the name for a blob and the name with `/` appended for a
    /// subtree — so `a.c` sorts before the subtree `a` and `a0` after it.
    pub const Builder = struct {
        pub const Error = ErrorNamespace.Error;

        gpa: Allocator,
        kind: Kind,
        entries: std.ArrayList(Owned) = .empty,
        /// The names added so far, borrowed from `entries`, so a duplicate
        /// is found without a scan.
        names: std.StringHashMapUnmanaged(void) = .empty,

        const Owned = struct { mode: Mode, name: []u8, oid: Oid };

        /// Errors from adding an entry.
        pub const AddError = Allocator.Error || error{
            /// Two entries with the same name. A tree with a duplicate is one
            /// `git fsck` reports, so it is refused here.
            DuplicateEntry,
            /// A name that is empty, holds `/` or NUL, or is one a working
            /// tree must never be asked to create.
            InvalidEntryName,
            /// The object name uses a different hash format from the tree.
            ObjectFormatMismatch,
        };

        /// A builder for a tree of `kind` object names.
        pub fn init(gpa: Allocator, kind: Kind) Tree.Builder {
            return .{ .gpa = gpa, .kind = kind };
        }

        /// Release the builder.
        pub fn deinit(b: *Builder) void {
            for (b.entries.items) |e| b.gpa.free(e.name);
            b.entries.deinit(b.gpa);
            b.names.deinit(b.gpa);
            b.* = undefined;
        }

        /// Add one entry. `name` is copied.
        pub fn add(b: *Builder, mode: Mode, name: []const u8, oid: Oid) AddError!void {
            if (oid.kind != b.kind) return error.ObjectFormatMismatch;
            if (name.len == 0) return error.InvalidEntryName;
            if (std.mem.findScalar(u8, name, '/') != null) return error.InvalidEntryName;
            if (std.mem.findScalar(u8, name, 0) != null) return error.InvalidEntryName;
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidEntryName;
            if (b.names.contains(name)) return error.DuplicateEntry;
            try b.entries.ensureUnusedCapacity(b.gpa, 1);
            try b.names.ensureUnusedCapacity(b.gpa, 1);
            const copy = try b.gpa.dupe(u8, name);
            b.names.putAssumeCapacity(copy, {});
            b.entries.appendAssumeCapacity(.{ .mode = mode, .name = copy, .oid = oid });
        }

        /// How many entries have been added.
        pub fn count(b: *const Builder) usize {
            return b.entries.items.len;
        }

        /// The tree object's bytes, sorted. The result is the caller's.
        pub fn build(b: *Builder) Allocator.Error![]u8 {
            std.mem.sort(Owned, b.entries.items, {}, lessThan);
            var out: std.Io.Writer.Allocating = .init(b.gpa);
            errdefer out.deinit();
            const w = &out.writer;
            for (b.entries.items) |e| {
                var mode_buf: [6]u8 = undefined;
                w.writeAll(e.mode.text(&mode_buf)) catch return error.OutOfMemory;
                w.writeByte(' ') catch return error.OutOfMemory;
                w.writeAll(e.name) catch return error.OutOfMemory;
                w.writeByte(0) catch return error.OutOfMemory;
                w.writeAll(e.oid.raw()) catch return error.OutOfMemory;
            }
            return out.toOwnedSlice();
        }

        /// git's `base_name_compare`: a tree sorts as its name and a `/`,
        /// however long the name is.
        fn lessThan(_: void, a: Owned, b_: Owned) bool {
            const len = @min(a.name.len, b_.name.len);
            const order = std.mem.order(u8, a.name[0..len], b_.name[0..len]);
            if (order != .eq) return order == .lt;
            const ca: u8 = if (len < a.name.len) a.name[len] else if (a.mode == .tree) '/' else 0;
            const cb: u8 = if (len < b_.name.len) b_.name[len] else if (b_.mode == .tree) '/' else 0;
            return ca < cb;
        }
    };
};

/// Who did something, and when.
///
/// The time is the caller's: nothing in this package reads a clock, so a test
/// is deterministic and a replay exact.
pub const Signature = struct {
    name: []const u8,
    email: []const u8,
    /// Seconds since the Unix epoch.
    when_secs: i64,
    /// Minutes east of UTC. `+0100` is 60, `-0500` is -300.
    offset_minutes: i16,

    /// Errors from reading an identity line.
    pub const ParseError = error{
        /// No `<` or no `>` in the line.
        MalformedSignature,
        /// The seconds or the offset were not a number.
        InvalidSignatureTime,
    };

    /// `Name <email> secs ±hhmm`, appended to `w`.
    ///
    /// A name holding `<`, `>` or a newline is what git's `fsck` calls a bad
    /// ident; `write` refuses it rather than producing an object that cannot
    /// be read back.
    pub const WriteError = Io.Writer.Error || error{InvalidSignature};

    pub fn write(sig: Signature, w: *Io.Writer) WriteError!void {
        if (std.mem.findAny(u8, sig.name, "<>\n") != null) return error.InvalidSignature;
        if (std.mem.findAny(u8, sig.email, "<>\n") != null) return error.InvalidSignature;
        const sign: u8 = if (sig.offset_minutes < 0) '-' else '+';
        const abs: u32 = @intCast(@abs(sig.offset_minutes));
        try w.print("{s} <{s}> {d} {c}{d:0>2}{d:0>2}", .{
            sig.name,
            sig.email,
            sig.when_secs,
            sign,
            abs / 60,
            abs % 60,
        });
    }

    /// Read `Name <email> secs ±hhmm`. Borrows `line`.
    ///
    /// A line with no time — which older tools wrote — parses with a time of
    /// zero and an offset of zero rather than failing, because git reads one.
    pub fn parse(line: []const u8) Signature.ParseError!Signature {
        const lt = std.mem.findScalar(u8, line, '<') orelse return error.MalformedSignature;
        const gt = std.mem.findScalarPos(u8, line, lt, '>') orelse return error.MalformedSignature;
        var name = line[0..lt];
        while (name.len > 0 and name[name.len - 1] == ' ') name = name[0 .. name.len - 1];
        const email = line[lt + 1 .. gt];
        var rest = line[gt + 1 ..];
        while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
        if (rest.len == 0) return .{ .name = name, .email = email, .when_secs = 0, .offset_minutes = 0 };
        const space = std.mem.findScalar(u8, rest, ' ') orelse rest.len;
        const secs = std.fmt.parseInt(i64, rest[0..space], 10) catch return error.InvalidSignatureTime;
        var offset: i16 = 0;
        if (space < rest.len) {
            var zone = rest[space + 1 ..];
            while (zone.len > 0 and zone[zone.len - 1] == ' ') zone = zone[0 .. zone.len - 1];
            offset = try parseOffset(zone);
        }
        return .{ .name = name, .email = email, .when_secs = secs, .offset_minutes = offset };
    }

    fn parseOffset(zone: []const u8) !i16 {
        if (zone.len != 5) return error.InvalidSignatureTime;
        const sign: i16 = switch (zone[0]) {
            '+' => 1,
            '-' => -1,
            else => return error.InvalidSignatureTime,
        };
        const hours = std.fmt.parseInt(i16, zone[1..3], 10) catch return error.InvalidSignatureTime;
        const minutes = std.fmt.parseInt(i16, zone[3..5], 10) catch return error.InvalidSignatureTime;
        return sign * (hours * 60 + minutes);
    }
};

test "a malformed timezone is not silently UTC" {
    try std.testing.expectError(
        error.InvalidSignatureTime,
        Signature.parse("Ada <a@b> 1 +0x00"),
    );
}

test "a tree builder refuses an object name from another hash format" {
    const gpa = std.testing.allocator;
    var builder: Tree.Builder = .init(gpa, .sha256);
    defer builder.deinit();
    try std.testing.expectError(
        error.ObjectFormatMismatch,
        builder.add(.file, "file.txt", Oid.zero(.sha1)),
    );
}

/// A header a commit or a tag carries that this package does not interpret.
///
/// `gpgsig` and `mergetag` are the ones git writes. The value is the unfolded
/// bytes: git prefixes every continuation line with a space, including the
/// empty ones, and `Commit.parse` takes that space off.
pub const ExtraHeader = struct {
    name: []const u8,
    /// Owned by the object it came from, or by the caller who built it.
    value: []const u8,
};

/// Errors from reading a commit or a tag.
pub const ParseError = error{
    /// A header line with no space in it, or a body with no blank line
    /// before it.
    MalformedObject,
    /// The required `tree` header was missing, or `object` on a tag.
    MissingHeader,
    /// A header carrying an object name whose text was not one.
    InvalidObjectId,
    /// An identity line that was not `Name <email> secs ±hhmm`.
    MalformedSignature,
    InvalidSignatureTime,
    UnknownObjectType,
} || Allocator.Error;

/// A commit object.
///
/// `parse` allocates the parent list and the extra headers and borrows
/// everything else from the object's bytes, so the bytes must outlive it.
pub const Commit = struct {
    pub const Error = ErrorNamespace.Error;

    kind: Kind,
    tree: Oid,
    /// In the order the object holds them, which is significant: the first is
    /// the first parent.
    parents: []const Oid,
    author: Signature,
    committer: Signature,
    /// `encoding`, if the object carries one.
    encoding: ?[]const u8,
    /// Every header that is not one of the above, in order, unfolded.
    extra: []const ExtraHeader,
    /// Everything after the blank line, byte for byte.
    message: []const u8,

    arena: ?std.heap.ArenaAllocator.State = null,
    gpa: ?Allocator = null,

    /// Release what `parse` allocated.
    pub fn deinit(c: *Commit) void {
        if (c.gpa) |gpa| {
            if (c.arena) |state| {
                var arena = state.promote(gpa);
                arena.deinit();
            }
        }
        c.* = undefined;
    }

    /// Read a commit object's bytes.
    pub fn parse(gpa: Allocator, kind: Kind, bytes: []const u8) Self.ParseError!Commit {
        var arena_instance: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena_instance.deinit();
        const arena = arena_instance.allocator();

        var parents: std.ArrayList(Oid) = .empty;
        var extra: std.ArrayList(ExtraHeader) = .empty;
        var author: ?Signature = null;
        var committer: ?Signature = null;
        var encoding: ?[]const u8 = null;

        // git reads a commit's tree from the first line and its parents
        // from the lines straight after it, and nowhere else, so a `tree`
        // or `parent` further down is an extra header like any other.
        var rest = bytes;
        const tree_line = takeLine(&rest);
        if (!std.mem.startsWith(u8, tree_line, "tree ")) return error.MissingHeader;
        const tree = Oid.parse(kind, tree_line["tree ".len..]) catch return error.InvalidObjectId;
        while (std.mem.startsWith(u8, rest, "parent ")) {
            const line = takeLine(&rest);
            const oid = Oid.parse(kind, line["parent ".len..]) catch return error.InvalidObjectId;
            try parents.append(arena, oid);
        }

        while (true) {
            if (rest.len == 0) break;
            if (rest[0] == '\n') {
                rest = rest[1..];
                break;
            }
            const line = takeLine(&rest);
            const space = std.mem.findScalar(u8, line, ' ') orelse return error.MalformedObject;
            const key = line[0..space];
            const value = try unfold(arena, line[space + 1 ..], &rest);

            // The first of each is the one git reads.
            if (author == null and std.mem.eql(u8, key, "author")) {
                author = try Signature.parse(value);
            } else if (committer == null and std.mem.eql(u8, key, "committer")) {
                committer = try Signature.parse(value);
            } else if (encoding == null and std.mem.eql(u8, key, "encoding")) {
                encoding = value;
            } else {
                try extra.append(arena, .{ .name = key, .value = value });
            }
        }

        return .{
            .kind = kind,
            .tree = tree,
            .parents = parents.items,
            .author = author orelse return error.MissingHeader,
            .committer = committer orelse return error.MissingHeader,
            .encoding = encoding,
            .extra = extra.items,
            .message = rest,
            .arena = arena_instance.state,
            .gpa = gpa,
        };
    }

    /// The value of the extra header named `name`, unfolded, or `null`.
    ///
    /// `gpgsig` is the one a caller usually wants; the bytes come back with
    /// git's leading continuation space removed from every line, which is the
    /// form a signature verifier takes.
    pub fn extraHeader(c: Commit, name: []const u8) ?[]const u8 {
        for (c.extra) |h| {
            if (std.mem.eql(u8, h.name, name)) return h.value;
        }
        return null;
    }

    /// What a commit is made of, on the way in.
    pub const Fields = struct {
        tree: Oid,
        parents: []const Oid = &.{},
        author: Signature,
        committer: Signature,
        encoding: ?[]const u8 = null,
        extra: []const ExtraHeader = &.{},
        message: []const u8,
    };

    /// Errors from writing a commit.
    pub const WriteError = Io.Writer.Error || error{
        /// An identity holding `<`, `>` or a newline.
        InvalidSignature,
        /// A parent, or the tree, named with a different hash than the
        /// commit.
        MixedHashKinds,
    };

    /// Append a commit object's bytes to `w`, in git's header order: tree,
    /// parents in order, author, committer, encoding, extra headers, a blank
    /// line, the message.
    pub fn write(w: *Io.Writer, kind: Kind, f: Fields) WriteError!void {
        if (f.tree.kind != kind) return error.MixedHashKinds;
        var hex: [hash.max_hex_len]u8 = undefined;
        try w.print("tree {s}\n", .{f.tree.hex(&hex)});
        for (f.parents) |p| {
            if (p.kind != kind) return error.MixedHashKinds;
            try w.print("parent {s}\n", .{p.hex(&hex)});
        }
        try w.writeAll("author ");
        try f.author.write(w);
        try w.writeAll("\ncommitter ");
        try f.committer.write(w);
        try w.writeByte('\n');
        if (f.encoding) |e| try w.print("encoding {s}\n", .{e});
        for (f.extra) |h| try writeFolded(w, h);
        try w.writeByte('\n');
        try w.writeAll(f.message);
    }

    /// Errors from `build`.
    pub const BuildError = WriteError || Allocator.Error;

    /// The bytes of a commit object. The result is the caller's.
    pub fn build(gpa: Allocator, kind: Kind, f: Fields) BuildError![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        try write(&out.writer, kind, f);
        return out.toOwnedSlice();
    }
};

/// The next line of `rest`, without its newline, and `rest` moved past it.
fn takeLine(rest: *[]const u8) []const u8 {
    const text = rest.*;
    const nl = std.mem.findScalar(u8, text, '\n') orelse text.len;
    rest.* = if (nl < text.len) text[nl + 1 ..] else text[text.len..];
    return text[0..nl];
}

/// A header's value with its continuation lines folded in, and `rest` moved
/// past them. A continuation line begins with a space, which is dropped;
/// the newlines are kept. The lines are measured first and copied once, so
/// a value of many lines costs its length and no more.
fn unfold(arena: Allocator, value: []const u8, rest: *[]const u8) Allocator.Error![]const u8 {
    // Each continuation line's space becomes the newline before it.
    var len = value.len;
    var scan = rest.*;
    while (scan.len > 0 and scan[0] == ' ') len += takeLine(&scan).len;
    if (scan.len == rest.*.len) return value;
    const out = try arena.alloc(u8, len);
    @memcpy(out[0..value.len], value);
    var at = value.len;
    while (rest.*.len > 0 and rest.*[0] == ' ') {
        const cont = takeLine(rest)[1..];
        out[at] = '\n';
        @memcpy(out[at + 1 ..][0..cont.len], cont);
        at += 1 + cont.len;
    }
    return out;
}

fn writeFolded(w: *Io.Writer, h: ExtraHeader) Io.Writer.Error!void {
    try w.writeAll(h.name);
    try w.writeByte(' ');
    var it = std.mem.splitScalar(u8, h.value, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) {
            try w.writeByte('\n');
            try w.writeByte(' ');
        }
        try w.writeAll(line);
        first = false;
    }
    try w.writeByte('\n');
}

/// An annotated tag object.
///
/// A lightweight tag is a ref and no object at all; this is the other kind.
pub const Tag = struct {
    pub const Error = ErrorNamespace.Error;

    kind: Kind,
    /// What the tag points at.
    target: Oid,
    target_type: Type,
    /// The tag's own name, which the object repeats.
    name: []const u8,
    /// Absent on a tag written by a tool that leaves it out.
    tagger: ?Signature,
    extra: []const ExtraHeader,
    message: []const u8,

    arena: ?std.heap.ArenaAllocator.State = null,
    gpa: ?Allocator = null,

    /// Release what `parse` allocated.
    pub fn deinit(t: *Tag) void {
        if (t.gpa) |gpa| {
            if (t.arena) |state| {
                var arena = state.promote(gpa);
                arena.deinit();
            }
        }
        t.* = undefined;
    }

    /// Read a tag object's bytes.
    pub fn parse(gpa: Allocator, kind: Kind, bytes: []const u8) Self.ParseError!Tag {
        var arena_instance: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena_instance.deinit();
        const arena = arena_instance.allocator();

        var extra: std.ArrayList(ExtraHeader) = .empty;
        var tagger: ?Signature = null;

        // git reads `object`, `type` and `tag` from the first three lines
        // and `tagger` from the fourth, so the same names further down are
        // extra headers like any other.
        var rest = bytes;
        const object_line = takeLine(&rest);
        if (!std.mem.startsWith(u8, object_line, "object ")) return error.MissingHeader;
        const target = Oid.parse(kind, object_line["object ".len..]) catch return error.InvalidObjectId;
        const type_line = takeLine(&rest);
        if (!std.mem.startsWith(u8, type_line, "type ")) return error.MissingHeader;
        const target_type = try Type.parse(type_line["type ".len..]);
        const name_line = takeLine(&rest);
        if (!std.mem.startsWith(u8, name_line, "tag ")) return error.MissingHeader;
        const name = name_line["tag ".len..];

        var first = true;
        while (true) {
            if (rest.len == 0) break;
            if (rest[0] == '\n') {
                rest = rest[1..];
                break;
            }
            const line = takeLine(&rest);
            const space = std.mem.findScalar(u8, line, ' ') orelse return error.MalformedObject;
            const key = line[0..space];
            const value = try unfold(arena, line[space + 1 ..], &rest);

            if (first and std.mem.eql(u8, key, "tagger")) {
                tagger = try Signature.parse(value);
            } else {
                try extra.append(arena, .{ .name = key, .value = value });
            }
            first = false;
        }

        return .{
            .kind = kind,
            .target = target,
            .target_type = target_type,
            .name = name,
            .tagger = tagger,
            .extra = extra.items,
            .message = rest,
            .arena = arena_instance.state,
            .gpa = gpa,
        };
    }

    /// The value of the extra header named `name`, or `null`.
    pub fn extraHeader(t: Tag, name: []const u8) ?[]const u8 {
        for (t.extra) |h| {
            if (std.mem.eql(u8, h.name, name)) return h.value;
        }
        return null;
    }

    /// What a tag is made of, on the way in.
    pub const Fields = struct {
        target: Oid,
        target_type: Type,
        name: []const u8,
        tagger: ?Signature = null,
        extra: []const ExtraHeader = &.{},
        message: []const u8,
    };

    /// Errors from writing a tag.
    pub const WriteError = Commit.WriteError;

    /// Append a tag object's bytes to `w`, in git's header order: object,
    /// type, tag, tagger, extra headers, a blank line, the message.
    pub fn write(w: *Io.Writer, kind: Kind, f: Fields) WriteError!void {
        if (f.target.kind != kind) return error.MixedHashKinds;
        var hex: [hash.max_hex_len]u8 = undefined;
        try w.print("object {s}\n", .{f.target.hex(&hex)});
        try w.print("type {s}\n", .{f.target_type.name()});
        try w.print("tag {s}\n", .{f.name});
        if (f.tagger) |t| {
            try w.writeAll("tagger ");
            try t.write(w);
            try w.writeByte('\n');
        }
        for (f.extra) |h| try writeFolded(w, h);
        try w.writeByte('\n');
        try w.writeAll(f.message);
    }

    /// Errors from `build`.
    pub const BuildError = WriteError || Allocator.Error;

    /// The bytes of a tag object. The result is the caller's.
    pub fn build(gpa: Allocator, kind: Kind, f: Fields) BuildError![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        try write(&out.writer, kind, f);
        return out.toOwnedSlice();
    }
};

test "tree entries sort by git's rule" {
    const gpa = std.testing.allocator;
    var b: Tree.Builder = .init(gpa, .sha1);
    defer b.deinit();
    const oid = try Oid.parse(.sha1, &@as([40]u8, @splat('0')));
    try b.add(.tree, "a", oid);
    try b.add(.file, "a.c", oid);
    try b.add(.file, "a0", oid);
    const bytes = try b.build();
    defer gpa.free(bytes);

    var tree: Tree = .parse(.sha1, bytes);
    var it = tree.iterate();
    try std.testing.expectEqualStrings("a.c", (try it.next()).?.name);
    try std.testing.expectEqualStrings("a", (try it.next()).?.name);
    try std.testing.expectEqualStrings("a0", (try it.next()).?.name);
    try std.testing.expect((try it.next()) == null);
}

test "a duplicate entry is refused" {
    const gpa = std.testing.allocator;
    var b: Tree.Builder = .init(gpa, .sha1);
    defer b.deinit();
    const oid = try Oid.parse(.sha1, &@as([40]u8, @splat('0')));
    try b.add(.file, "a", oid);
    try std.testing.expectError(error.DuplicateEntry, b.add(.file, "a", oid));
    try std.testing.expectError(error.DuplicateEntry, b.add(.tree, "a", oid));
    try std.testing.expectError(error.InvalidEntryName, b.add(.file, "a/b", oid));
}

test "a tree of many entries is built in what sorting them costs, and still refuses a name twice" {
    const gpa = std.testing.allocator;
    var b: Tree.Builder = .init(gpa, .sha1);
    defer b.deinit();
    const oid = try Oid.parse(.sha1, &@as([40]u8, @splat('0')));
    // Each add once scanned every entry before it: four hundred million
    // comparisons here, and seconds even when optimised.
    const count = 20_000;
    var name: [16]u8 = undefined;
    for (0..count) |i| try b.add(.file, try std.mem.print(&name, "f{d}", .{count - i}), oid);
    try std.testing.expectError(error.DuplicateEntry, b.add(.tree, "f7", oid));
    const bytes = try b.build();
    defer gpa.free(bytes);
    try std.testing.expect(std.mem.startsWith(u8, bytes, "100644 f1\x00"));
}

test "a tree with one file has the name git gives it" {
    const gpa = std.testing.allocator;
    // The tree holding one file `a` whose blob is the empty blob.
    var b: Tree.Builder = .init(gpa, .sha1);
    defer b.deinit();
    try b.add(.file, "a", try Oid.parse(.sha1, "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"));
    const bytes = try b.build();
    defer gpa.free(bytes);
    const oid = hash.Hasher.object(.sha1, "tree", bytes);
    var hex: [hash.max_hex_len]u8 = undefined;
    try std.testing.expectEqualStrings("496d6428b9cf92981dc9495211e6e1120fb6f2ba", oid.hex(&hex));
}

test "commit round trip keeps parent order and header order" {
    const gpa = std.testing.allocator;
    const tree = try Oid.parse(.sha1, "496d6428b9cf92981dc9495211e6e1120fb6f2ba");
    const p1 = try Oid.parse(.sha1, &@as([40]u8, @splat('1')));
    const p2 = try Oid.parse(.sha1, &@as([40]u8, @splat('2')));
    const sig: Signature = .{
        .name = "Ada",
        .email = "ada@example.com",
        .when_secs = 1_700_000_000,
        .offset_minutes = -300,
    };
    const bytes = try Commit.build(gpa, .sha1, .{
        .tree = tree,
        .parents = &.{ p1, p2 },
        .author = sig,
        .committer = sig,
        .extra = &.{.{ .name = "gpgsig", .value = "-----BEGIN-----\n\nline\n-----END-----" }},
        .message = "subject\n",
    });
    defer gpa.free(bytes);

    try std.testing.expect(std.mem.startsWith(u8, bytes, "tree 496d6428"));
    try std.testing.expect(std.mem.find(u8, bytes, "author Ada <ada@example.com> 1700000000 -0500\n") != null);
    try std.testing.expect(std.mem.find(u8, bytes, "gpgsig -----BEGIN-----\n \n line\n -----END-----\n") != null);

    var c = try Commit.parse(gpa, .sha1, bytes);
    defer c.deinit();
    try std.testing.expect(c.tree.eql(tree));
    try std.testing.expectEqual(@as(usize, 2), c.parents.len);
    try std.testing.expect(c.parents[0].eql(p1));
    try std.testing.expect(c.parents[1].eql(p2));
    try std.testing.expectEqualStrings("subject\n", c.message);
    try std.testing.expectEqualStrings(
        "-----BEGIN-----\n\nline\n-----END-----",
        c.extraHeader("gpgsig").?,
    );
    try std.testing.expectEqual(@as(i16, -300), c.author.offset_minutes);
}

test "a commit's tree is its first line and its parents the lines after, as git reads them" {
    const gpa = std.testing.allocator;
    const zero = &@as([40]u8, @splat('0'));
    const one = &@as([40]u8, @splat('1'));
    const two = &@as([40]u8, @splat('2'));
    const ident = "A <a@b> 1 +0000";
    // A second tree, a parent after the identities, and a second author
    // are all extra headers: git reads the first tree and no parents.
    var c = try Commit.parse(gpa, .sha1, "tree " ++ zero ++ "\nauthor " ++ ident ++ "\ncommitter " ++ ident ++
        "\ntree " ++ one ++ "\nparent " ++ two ++ "\nauthor B <b@b> 2 +0000\n\nm\n");
    defer c.deinit();
    try std.testing.expect(c.tree.eql(try Oid.parse(.sha1, zero)));
    try std.testing.expectEqual(@as(usize, 0), c.parents.len);
    try std.testing.expectEqualStrings("A", c.author.name);
    try std.testing.expectEqual(@as(usize, 3), c.extra.len);
    try std.testing.expectEqualStrings("tree", c.extra[0].name);
    try std.testing.expectEqualStrings("parent", c.extra[1].name);
    try std.testing.expectEqualStrings("author", c.extra[2].name);
    // A tree anywhere but the first line is no tree.
    try std.testing.expectError(error.MissingHeader, Commit.parse(gpa, .sha1, "author " ++ ident ++ "\ntree " ++ zero ++
        "\ncommitter " ++ ident ++ "\n\nm\n"));
}

test "a tag's object, type and name are its first three lines" {
    const gpa = std.testing.allocator;
    const zero = &@as([40]u8, @splat('0'));
    var t = try Tag.parse(gpa, .sha1, "object " ++ zero ++ "\ntype commit\ntag v1\ntagger A <a@b> 1 +0000\n" ++
        "object " ++ @as([40]u8, @splat('1')) ++ "\ntag v2\n\nm\n");
    defer t.deinit();
    try std.testing.expect(t.target.eql(try Oid.parse(.sha1, zero)));
    try std.testing.expectEqualStrings("v1", t.name);
    try std.testing.expect(t.tagger != null);
    try std.testing.expectEqual(@as(usize, 2), t.extra.len);
    try std.testing.expectError(error.MissingHeader, Tag.parse(gpa, .sha1, "type commit\nobject " ++ zero ++ "\ntag v1\n\nm\n"));
}

test "a header of many continuation lines costs its length to unfold, not its square" {
    const gpa = std.testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    const ident = "A <a@b> 1 +0000";
    try bytes.appendSlice(gpa, "tree " ++ @as([40]u8, @splat('0')) ++ "\nauthor " ++ ident ++ "\ncommitter " ++ ident ++ "\ngpgsig -----BEGIN-----\n");
    const lines = 4000;
    for (0..lines) |_| try bytes.appendSlice(gpa, " " ++ @as([63]u8, @splat('x')) ++ "\n");
    try bytes.appendSlice(gpa, "\nm\n");
    const tag_bytes = try std.mem.replaceOwned(u8, gpa, bytes.items, "tree " ++ @as([40]u8, @splat('0')), "object " ++ @as([40]u8, @splat('0')) ++ "\ntype commit\ntag v1");
    defer gpa.free(tag_bytes);
    for ([_]bool{ false, true }) |tag| {
        var counting: std.testing.FailingAllocator = .init(gpa, .{});
        const value_len = if (tag) blk: {
            var t = try Tag.parse(counting.allocator(), .sha1, tag_bytes);
            defer t.deinit();
            break :blk t.extraHeader("gpgsig").?.len;
        } else blk: {
            var c = try Commit.parse(counting.allocator(), .sha1, bytes.items);
            defer c.deinit();
            break :blk c.extraHeader("gpgsig").?.len;
        };
        try std.testing.expectEqual(@as(usize, "-----BEGIN-----".len + lines * 64), value_len);
        try std.testing.expect(counting.allocated_bytes < 4 * bytes.items.len);
    }
}

test "tag round trip" {
    const gpa = std.testing.allocator;
    const target = try Oid.parse(.sha1, &@as([40]u8, @splat('3')));
    const bytes = try Tag.build(gpa, .sha1, .{
        .target = target,
        .target_type = .commit,
        .name = "v1.0",
        .tagger = .{ .name = "Ada", .email = "ada@example.com", .when_secs = 1, .offset_minutes = 0 },
        .message = "release\n",
    });
    defer gpa.free(bytes);
    var t = try Tag.parse(gpa, .sha1, bytes);
    defer t.deinit();
    try std.testing.expect(t.target.eql(target));
    try std.testing.expectEqual(Type.commit, t.target_type);
    try std.testing.expectEqualStrings("v1.0", t.name);
    try std.testing.expectEqualStrings("release\n", t.message);
}

test "modes read and write the way a tree carries them" {
    var buf: [6]u8 = undefined;
    try std.testing.expectEqualStrings("40000", Mode.tree.text(&buf));
    try std.testing.expectEqualStrings("100644", Mode.file.text(&buf));
    try std.testing.expectEqualStrings("120000", Mode.symlink.text(&buf));
    try std.testing.expectEqual(Mode.file, try Mode.parse("100664"));
    try std.testing.expectEqual(Mode.tree, try Mode.parse("40000"));
    try std.testing.expectError(error.InvalidMode, Mode.parse("777777"));
}

test "a loose object header parses and refuses a padded size" {
    const parsed = try parseHeader("blob 12\x00hello");
    try std.testing.expectEqual(Type.blob, parsed.header.type);
    try std.testing.expectEqual(@as(u64, 12), parsed.header.size);
    try std.testing.expectEqual(@as(usize, 8), parsed.len);
    try std.testing.expectError(error.InvalidObjectSize, parseHeader("blob 012\x00"));
    try std.testing.expectError(error.InvalidObjectSize, parseHeader("blob +5\x00hello"));
    try std.testing.expectError(error.InvalidObjectSize, parseHeader("blob 1_0\x00"));
    try std.testing.expectError(error.UnknownObjectType, parseHeader("blub 1\x00"));
    try std.testing.expectError(error.MissingHeaderTerminator, parseHeader("blob 1"));
}

test "fuzz: any bytes are an object or a named error" {
    try std.testing.fuzz({}, fuzzObject, .{});
}

fn fuzzObject(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;
    var scratch: [2048]u8 = undefined;
    const input = scratch[0..smith.slice(&scratch)];

    if (parseHeader(input)) |parsed| {
        std.debug.assert(parsed.len <= input.len);
    } else |_| {}

    for ([_]Kind{ .sha1, .sha256 }) |kind| {
        const tree: Tree = .parse(kind, input);
        var it = tree.iterate();
        while (it.next() catch null) |entry| {
            std.debug.assert(entry.name.len != 0);
        }
        // glint-ignore: Z026 -- refusing a malformed input is the expected outcome; only a crash or a leak fails the fuzzer
        _ = tree.find("a") catch {};

        if (Commit.parse(gpa, kind, input)) |parsed| {
            var commit = parsed;
            defer commit.deinit();
            _ = commit.extraHeader("gpgsig");
        } else |_| {}

        if (Tag.parse(gpa, kind, input)) |parsed| {
            var tag = parsed;
            defer tag.deinit();
            _ = tag.extraHeader("gpgsig");
        } else |_| {}
    }

    // glint-ignore: Z026 -- refusing a malformed input is the expected outcome; only a crash or a leak fails the fuzzer
    _ = Signature.parse(input) catch {};
    // glint-ignore: Z026 -- refusing a malformed input is the expected outcome; only a crash or a leak fails the fuzzer
    _ = Mode.parse(input[0..@min(input.len, 6)]) catch {};
}

/// All errors reported by this namespace.
pub const Error = Type.ParseError || HeaderParseError || Mode.ParseError || Mode.FromRawError || TreeParseError || Tree.Builder.AddError || Signature.ParseError || Signature.WriteError || ParseError || Commit.WriteError || Commit.BuildError || Tag.WriteError || Tag.BuildError || Allocator.Error || Self.ParseError;
