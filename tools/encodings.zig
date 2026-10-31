//! Writes `src/text/legacy/tables.zig`: each encoding name both iconvs git
//! is built with take, and how their common meaning of it differs from the
//! WHATWG standard's (designs/relic.md §14).
//!
//! `encodings <glibc source> <output file>`, on macOS. Apple's libiconv,
//! which the Mac's git links, is run. glibc's iconv is read from its source,
//! as its own `iconvdata/tst-tables.sh` states each module: a name is
//! stripped and upper-cased as `iconv/gconv_charset.c` does and followed
//! through the aliases of `iconvdata/gconv-modules*` and
//! `iconv/gconv_builtin.h`; a module's table is its charmap in
//! `localedata/charmaps/`, with `iconvdata/<module>.irreversible` (the
//! entries one way only) and `<module>.precomposed` (two characters as one
//! sequence, both ways). CP1255 and CP1258 also compose a letter and the
//! marks after it as they decode, from the tables in `iconvdata/cp1255.c`
//! and `cp1258.c`.
//!
//! The common meaning of a sequence of bytes is what both iconvs read it
//! as, and of a character what both write it as; anything else is refused.
//! A delta holds the sequences and characters where relic's reading
//! through the standard, `legacy.zig`, would differ from the common
//! meaning. The generator checks the result over every sequence of up to
//! two bytes (three for EUC-JP's JIS X 0212, four for GB18030's, and the
//! letters with up to three marks of the composing encodings) and every
//! character, and writes nothing if any differs.
const std = @import("std");
const xenoglyph = @import("xenoglyph");
const legacy = @import("legacy");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const xg = xenoglyph.encoding;

extern "c" fn iconv_open(to: [*:0]const u8, from: [*:0]const u8) ?*anyopaque;
extern "c" fn iconv(cd: *anyopaque, inbuf: *?[*]u8, inleft: *usize, outbuf: *?[*]u8, outleft: *usize) usize;
const iconv_failed: usize = std.math.maxInt(usize);

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 3) {
        std.debug.print("usage: encodings <glibc source> <output file>\n", .{});
        return error.Usage;
    }
    const root = try Io.Dir.cwd().openDir(io, args[1], .{});
    var glibc = try Glibc.load(a, io, root);
    var out: Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    const macos = try macosVersion(a, io);
    try w.print(
        \\//! Written by tools/encodings.zig from glibc {s}'s source and Apple's
        \\//! libiconv on macOS {s} (designs/relic.md §14). Not to be edited.
        \\const legacy = @import("../legacy.zig");
        \\const Legacy = legacy.Legacy;
        \\
    , .{ glibc.version, macos });

    var meanings: std.ArrayList(Meaning) = .empty;
    var names: std.ArrayList(Name) = .empty;
    var it = glibc.names.iterator();
    var labels: std.ArrayList([]const u8) = .empty;
    while (it.next()) |kv| try labels.append(a, kv.key_ptr.*);
    std.mem.sortUnstable([]const u8, labels.items, {}, lessString);
    for (labels.items) |label| {
        const module = glibc.resolve(label) orelse continue;
        // relic's own: UTF-8 and the UTFs, ASCII and ISO-8859-1.
        if (own(module)) continue;
        const encoding = xg.forLabel(label) orelse continue;
        if (!tabled(encoding)) continue;
        const map = (try glibc.module(a, io, root, module)) orelse continue;
        const dec = appleOpen("UTF-8", label) orelse continue;
        const enc = appleOpen(label, "UTF-8") orelse continue;
        const apple: Apple = .{ .decoder = dec, .encoder = enc };
        const meaning = try measure(a, encoding, map, apple, module);
        const index = for (meanings.items, 0..) |m, i| {
            if (std.mem.eql(u8, m.module, meaning.module) and std.mem.eql(u8, m.text, meaning.text)) break i;
        } else blk: {
            try meanings.append(a, meaning);
            break :blk meanings.items.len - 1;
        };
        try names.append(a, .{ .label = label, .meaning = index });
        std.debug.print("{s}\t{s}\t{s}\n", .{ label, module, meaning.summary });
    }
    // Each meaning, named for its glibc module; a second meaning of one
    // module takes its first name's.
    var used: std.StringHashMapUnmanaged(void) = .empty;
    for (meanings.items, 0..) |*m, i| {
        var ident = try identifier(a, m.module);
        if (used.contains(ident)) {
            const first = for (names.items) |n| {
                if (n.meaning == i) break n.label;
            } else unreachable; // every meaning was added for a name
            ident = try identifier(a, try a.print("{s}_{s}", .{ m.module, first }));
        }
        try used.put(a, ident, {});
        m.ident = ident;
        try w.print("\n/// {s}\npub const {s}: Legacy = {s};\n", .{ m.doc, ident, m.text });
    }
    try w.writeAll(
        \\
        \\/// The names both iconvs take, each as glibc lists it, lower-cased;
        \\/// compared ignoring ASCII case.
        \\pub const names = [_]struct { []const u8, *const Legacy }{
        \\
    );
    for (names.items) |n| try w.print("    .{{ \"{s}\", &{s} }},\n", .{ n.label, meanings.items[n.meaning].ident });
    try w.writeAll("};\n");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = args[2], .data = out.written() });
}

const Name = struct { label: []const u8, meaning: usize };

/// One encoding's meaning, written as a `Legacy` literal.
const Meaning = struct {
    module: []const u8,
    text: []const u8,
    doc: []const u8,
    summary: []const u8,
    ident: []const u8 = "",
};

fn lessString(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

/// The modules relic converts with code of its own.
fn own(module: []const u8) bool {
    for ([_][]const u8{ "ANSI_X3.4-1968", "ISO-8859-1", "UTF-8", "UTF-16", "UTF-16LE", "UTF-16BE", "UTF-32", "UTF-32LE", "UTF-32BE", "UNICODE", "ISO-10646/UCS2", "ISO-10646/UCS4", "UTF-7" }) |m| {
        if (std.mem.eql(u8, m, module)) return true;
    }
    return false;
}

/// An encoding the standard reads sequence by sequence: not the UTFs, the
/// replacement and x-user-defined, and not ISO-2022-JP, whose escapes
/// change how every later byte reads.
fn tabled(e: xg.Encoding) bool {
    return switch (e) {
        .utf_8, .utf_16le, .utf_16be, .replacement, .x_user_defined, .iso_2022_jp => false,
        else => true,
    };
}

fn identifier(a: Allocator, module: []const u8) ![]const u8 {
    const out = try a.alloc(u8, module.len);
    for (module, out) |c, *o| o.* = if (std.ascii.isAlphanumeric(c)) std.ascii.toLower(c) else '_';
    if (std.ascii.isDigit(out[0])) return a.print("cp_{s}", .{out});
    return out;
}

fn macosVersion(a: Allocator, io: Io) ![]const u8 {
    const plist = try Io.Dir.cwd().readFileAlloc(io, "/System/Library/CoreServices/SystemVersion.plist", a, .limited(1 << 16));
    const key = "<key>ProductVersion</key>";
    const at = std.mem.find(u8, plist, key) orelse return error.NoVersion;
    const open = std.mem.findPos(u8, plist, at, "<string>") orelse return error.NoVersion;
    const close = std.mem.findPos(u8, plist, open, "</string>") orelse return error.NoVersion;
    return plist[open + "<string>".len .. close];
}

//=========================================================================
// Apple's libiconv
//=========================================================================

const Apple = struct {
    decoder: *anyopaque,
    encoder: *anyopaque,
};

fn appleOpen(to: []const u8, from: []const u8) ?*anyopaque {
    var t: [64:0]u8 = @splat(0);
    var f: [64:0]u8 = @splat(0);
    if (to.len >= t.len or from.len >= f.len) return null;
    @memcpy(t[0..to.len], to);
    @memcpy(f[0..from.len], from);
    const cd = iconv_open(&t, &f) orelse return null;
    if (@intFromPtr(cd) == iconv_failed) return null;
    return cd;
}

/// `in` whole through `cd` into `out`, or null where it stops.
fn appleRun(cd: *anyopaque, in: []const u8, out: []u8) ?[]const u8 {
    var no_in: ?[*]u8 = null;
    var no_len: usize = 0;
    var no_out: ?[*]u8 = null;
    var no_out_len: usize = 0;
    _ = iconv(cd, &no_in, &no_len, &no_out, &no_out_len);
    var copy: [32]u8 = undefined;
    if (in.len > copy.len) return null;
    @memcpy(copy[0..in.len], in);
    var ip: ?[*]u8 = &copy;
    var il = in.len;
    var op: ?[*]u8 = out.ptr;
    var ol = out.len;
    if (iconv(cd, &ip, &il, &op, &ol) == iconv_failed) return null;
    if (iconv(cd, &no_in, &no_len, &op, &ol) == iconv_failed) return null;
    if (il != 0) return null;
    return out[0 .. out.len - ol];
}

//=========================================================================
// glibc, from its source
//=========================================================================

const Glibc = struct {
    version: []const u8,
    /// Every name glibc knows, lower-cased, to what it names.
    names: std.StringHashMapUnmanaged([]const u8) = .empty,
    modules: std.StringHashMapUnmanaged(void) = .empty,
    charmaps: std.StringHashMapUnmanaged([]const u8) = .empty,
    loaded: std.StringHashMapUnmanaged(?*Map) = .empty,

    fn load(a: Allocator, io: Io, root: Io.Dir) !Glibc {
        var g: Glibc = .{ .version = undefined };
        const version_h = try readAll(a, io, root, "version.h");
        g.version = quoted(version_h, "#define VERSION ") orelse return error.NoVersion;
        for ([_][]const u8{ "iconvdata/gconv-modules", "iconvdata/gconv-modules-extra.conf" }) |path| {
            const text = try readAll(a, io, root, path);
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |line| {
                var t = std.mem.tokenizeAny(u8, line, " \t");
                const kind = t.next() orelse continue;
                const from = t.next() orelse continue;
                const to = t.next() orelse continue;
                if (std.mem.eql(u8, kind, "alias")) {
                    try g.names.put(a, try lower(a, trimSlashes(from)), try upper(a, trimSlashes(to)));
                } else if (std.mem.eql(u8, kind, "module") and std.mem.eql(u8, to, "INTERNAL")) {
                    const m = try upper(a, trimSlashes(from));
                    try g.modules.put(a, m, {});
                    try g.names.put(a, try lower(a, m), m);
                }
            }
        }
        {
            const text = try readAll(a, io, root, "iconv/gconv_builtin.h");
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |line| {
                if (!std.mem.startsWith(u8, line, "BUILTIN_ALIAS (\"")) continue;
                var q = std.mem.splitScalar(u8, line, '"');
                _ = q.next();
                const from = q.next() orelse continue;
                _ = q.next();
                const to = q.next() orelse continue;
                const m = try upper(a, trimSlashes(to));
                try g.names.put(a, try lower(a, trimSlashes(from)), m);
                try g.modules.put(a, m, {});
                try g.names.put(a, try lower(a, m), m);
            }
        }
        var dir = try root.openDir(io, "localedata/charmaps", .{ .iterate = true });
        defer dir.close(io);
        var files = dir.iterate();
        while (try files.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const path = try a.print("localedata/charmaps/{s}", .{entry.name});
            const head = dir.readFileAlloc(io, entry.name, a, .limited(64 << 20)) catch continue;
            var lines = std.mem.splitScalar(u8, head, '\n');
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "CHARMAP")) break;
                if (std.mem.startsWith(u8, line, "<code_set_name>")) {
                    try g.charmaps.put(a, try strip(a, line["<code_set_name>".len..]), path);
                } else if (std.mem.startsWith(u8, line, "% alias")) {
                    _ = try g.charmaps.getOrPutValue(a, try strip(a, line["% alias".len..]), path);
                }
            }
            _ = try g.charmaps.getOrPutValue(a, try strip(a, entry.name), path);
        }
        return g;
    }

    /// The module iconv_open reaches from `label`, or null where it reaches none.
    fn resolve(g: *const Glibc, label: []const u8) ?[]const u8 {
        var target = g.names.get(label) orelse return null;
        var hops: usize = 0;
        while (!g.modules.contains(target)) : (hops += 1) {
            var buf: [64]u8 = undefined;
            if (hops > 8 or target.len > buf.len) return null;
            const next = g.names.get(std.ascii.lowerString(&buf, target)) orelse return null;
            if (std.mem.eql(u8, next, target)) return null;
            target = next;
        }
        return target;
    }

    /// The table of `module`, null where glibc's source states none.
    fn module(g: *Glibc, a: Allocator, io: Io, root: Io.Dir, name: []const u8) !?*Map {
        if (g.loaded.get(name)) |m| return m;
        const result = try g.loadModule(a, io, root, name);
        try g.loaded.put(a, name, result);
        return result;
    }

    fn loadModule(g: *Glibc, a: Allocator, io: Io, root: Io.Dir, name: []const u8) !?*Map {
        // The charmap of the module's own name, or of any name glibc gives it.
        var path = g.charmaps.get(try strip(a, name));
        if (path == null) {
            var it = g.names.iterator();
            while (it.next()) |kv| if (std.mem.eql(u8, kv.value_ptr.*, name)) {
                if (g.charmaps.get(try strip(a, kv.key_ptr.*))) |p| {
                    path = p;
                    break;
                }
            };
        }
        const charmap = path orelse return null;
        const m = try a.create(Map);
        m.* = .{ .charmap = charmap };
        try m.readCharmap(a, try readAll(a, io, root, charmap));
        if (readAll(a, io, root, try a.print("iconvdata/{s}.irreversible", .{name}))) |text| {
            try m.readIrreversible(a, text);
        } else |_| {}
        if (readAll(a, io, root, try a.print("iconvdata/{s}.precomposed", .{name}))) |text| {
            try m.readPrecomposed(a, text);
        } else |_| {}
        if (readAll(a, io, root, try a.print("iconvdata/{s}.c", .{try lower(a, name)}))) |text| {
            m.compose = try Compose.parse(a, text);
        } else |_| {}
        return m;
    }
};

/// A glibc module's table, as tst-tables holds the module to it.
const Map = struct {
    charmap: []const u8,
    /// Bytes to the characters they read as, in UTF-8.
    decode: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// One or two characters, in UTF-8, to the bytes written.
    encode: std.StringHashMapUnmanaged([]const u8) = .empty,
    longest: usize = 1,
    compose: ?Compose = null,
    /// Two characters written as one sequence, in UTF-8.
    pairs: std.ArrayList([]const u8) = .empty,

    fn readCharmap(m: *Map, a: Allocator, text: []const u8) !void {
        var in_map = false;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (std.mem.eql(u8, line, "CHARMAP")) {
                in_map = true;
                continue;
            }
            if (std.mem.eql(u8, line, "END CHARMAP")) break;
            if (!in_map or line.len == 0 or line[0] != '<') continue;
            var f = std.mem.tokenizeAny(u8, line, " \t");
            const u = f.next() orelse continue;
            const b = f.next() orelse continue;
            if (!std.mem.startsWith(u8, b, "/x")) continue;
            if (std.mem.find(u8, u, "..")) |dots| {
                const first = try std.fmt.parseInt(u21, u[2 .. dots - 1], 16);
                const last = try std.fmt.parseInt(u21, u[dots + 4 .. u.len - 1], 16);
                const bytes = try parseBytes(a, b);
                var cp = first;
                while (cp <= last) : (cp += 1) {
                    try m.both(a, try a.dupe(u8, bytes), try utf8Of(a, &.{cp}));
                    step(bytes);
                }
                continue;
            }
            const val = parseUnicode(a, u) catch continue;
            try m.both(a, try parseBytes(a, b), val);
        }
    }

    fn both(m: *Map, a: Allocator, bytes: []const u8, chars: []const u8) !void {
        try m.decode.put(a, bytes, chars);
        _ = try m.encode.getOrPutValue(a, chars, bytes);
        m.longest = @max(m.longest, bytes.len);
    }

    /// An entry of the charmap's is one way only, decoding; one that is not
    /// the charmap's, encoding (tst-table.sh takes the difference both ways).
    fn readIrreversible(m: *Map, a: Allocator, text: []const u8) !void {
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            var f = std.mem.tokenizeAny(u8, line, " \t");
            const bytes = try hexBytes(a, f.next() orelse continue);
            const cp = try std.fmt.parseInt(u21, (f.next() orelse continue)[2..], 16);
            const chars = try utf8Of(a, &.{cp});
            if (m.decode.get(bytes)) |d| if (std.mem.eql(u8, d, chars)) {
                if (m.encode.get(chars)) |e| if (std.mem.eql(u8, e, bytes)) {
                    _ = m.encode.remove(chars);
                };
                continue;
            };
            try m.encode.put(a, chars, bytes);
        }
    }

    fn readPrecomposed(m: *Map, a: Allocator, text: []const u8) !void {
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            var f = std.mem.tokenizeAny(u8, line, " \t");
            const bytes = try hexBytes(a, f.next() orelse continue);
            var cps: [2]u21 = undefined;
            for (&cps) |*cp| cp.* = try std.fmt.parseInt(u21, (f.next() orelse return error.BadPrecomposed)[2..], 16);
            const chars = try utf8Of(a, &cps);
            try m.decode.put(a, bytes, chars);
            try m.encode.put(a, chars, bytes);
            try m.pairs.append(a, chars);
        }
    }

    /// What glibc reads `bytes` as, in UTF-8, into `out`; false where it stops.
    fn read(m: *const Map, bytes: []const u8, out: *std.ArrayList(u8), a: Allocator) !bool {
        out.clearRetainingCapacity();
        if (m.compose) |c| return c.read(m, bytes, out, a);
        var i: usize = 0;
        while (i < bytes.len) {
            var n = @min(m.longest, bytes.len - i);
            const chars = while (n > 0) : (n -= 1) {
                if (m.decode.get(bytes[i .. i + n])) |d| break d;
            } else return false;
            try out.appendSlice(a, chars);
            i += n;
        }
        return true;
    }

    /// What glibc writes `cps` as into `out`; false where it stops.
    fn write(m: *const Map, cps: []const u21, out: *std.ArrayList(u8), a: Allocator) !bool {
        out.clearRetainingCapacity();
        var i: usize = 0;
        var buf: [8]u8 = undefined;
        while (i < cps.len) {
            if (i + 1 < cps.len) if (m.encode.get(utf8Into(&buf, cps[i .. i + 2]))) |bytes| {
                try out.appendSlice(a, bytes);
                i += 2;
                continue;
            };
            const bytes = m.encode.get(utf8Into(&buf, cps[i .. i + 1])) orelse return false;
            try out.appendSlice(a, bytes);
            i += 1;
        }
        return true;
    }
};

/// CP1255's and CP1258's composition as they decode: a character in
/// `buffered` waits for a mark after it, and a mark that composes with it
/// makes the composite, which waits again where it is in `again`.
const Compose = struct {
    /// mark, then the base and what the pair composes to
    table: std.AutoHashMapUnmanaged([2]u21, u21) = .empty,
    marks: std.AutoHashMapUnmanaged(u21, void) = .empty,
    buffered: [2]u21,
    again: []const u21,

    fn parse(a: Allocator, source: []const u8) !?Compose {
        const start = std.mem.find(u8, source, "comp_table_data[] =") orelse return null;
        const end = std.mem.findPos(u8, source, start, "};") orelse return error.BadCompose;
        var c: Compose = .{ .buffered = undefined, .again = &.{} };
        var mark: ?u21 = null;
        var lines = std.mem.splitScalar(u8, source[start..end], '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\\");
            if (std.mem.startsWith(u8, line, "#define COMP_TABLE_LEN_")) {
                mark = try std.fmt.parseInt(u21, line["#define COMP_TABLE_LEN_".len..][0..4], 16);
                try c.marks.put(a, mark.?, {});
            } else if (std.mem.startsWith(u8, line, "{ 0x")) {
                var nums = hexNumbers(line);
                const base = nums.next() orelse return error.BadCompose;
                const composed = nums.next() orelse return error.BadCompose;
                try c.table.put(a, .{ mark orelse return error.BadCompose, base }, composed);
            }
        }
        const buffer_at = std.mem.find(u8, source, "must_buffer_ch = (ch >= ") orelse return error.BadCompose;
        var bounds = hexNumbers(source[buffer_at .. buffer_at + 80]);
        c.buffered = .{ bounds.next() orelse return error.BadCompose, bounds.next() orelse return error.BadCompose };
        // The composites kept waiting: the `if` after the composite is taken, when it buffers.
        const taken = std.mem.find(u8, source, "last_ch = comp_table_data[i].composed;") orelse return error.BadCompose;
        const next_comment = std.mem.findPos(u8, source, taken, "/*") orelse return error.BadCompose;
        if (std.mem.startsWith(u8, source[next_comment..], "/* Buffer")) {
            var again: std.ArrayList(u21) = .empty;
            var nums = hexNumbers(source[taken..next_comment]);
            while (nums.next()) |n| try again.append(a, n);
            c.again = again.items;
        }
        return c;
    }

    /// glibc's decoding loop (cp1255.c's and cp1258.c's BODY), byte by byte.
    fn read(c: *const Compose, m: *const Map, bytes: []const u8, out: *std.ArrayList(u8), a: Allocator) !bool {
        var last: ?u21 = null;
        var buf: [4]u8 = undefined;
        for (bytes) |byte| {
            const chars = m.decode.get(&.{byte}) orelse return false;
            const ch = firstOf(chars) orelse return false;
            if (last) |l| {
                if (c.marks.contains(ch)) if (c.table.get(.{ ch, l })) |composed| {
                    if (std.mem.findScalar(u21, c.again, composed) != null) {
                        last = composed;
                    } else {
                        try out.appendSlice(a, buf[0..try std.unicode.utf8Encode(composed, &buf)]);
                        last = null;
                    }
                    continue;
                };
                try out.appendSlice(a, buf[0..try std.unicode.utf8Encode(l, &buf)]);
                last = null;
            }
            if (ch >= c.buffered[0] and ch <= c.buffered[1]) {
                last = ch;
            } else try out.appendSlice(a, buf[0..try std.unicode.utf8Encode(ch, &buf)]);
        }
        if (last) |l| try out.appendSlice(a, buf[0..try std.unicode.utf8Encode(l, &buf)]);
        return true;
    }
};

//=========================================================================
// The common meaning, against relic's reading through the standard
//=========================================================================

/// The common meaning of one name, and its delta.
fn measure(a: Allocator, encoding: xg.Encoding, map: *const Map, apple: Apple, module: []const u8) !Meaning {
    var cx: Context = .{ .a = a, .map = map, .apple = apple, .l = .{ .encoding = encoding } };
    const keys = try cx.decodeKeys(encoding);
    try cx.buildDecode(keys);
    const chars = try cx.encodeKeys(encoding);
    try cx.buildEncode(chars);
    const pairs = try cx.pairKeys();
    try cx.buildPairs(pairs);
    try cx.verify(keys, chars, pairs);
    var text: Io.Writer.Allocating = .init(a);
    try cx.write(&text.writer);
    return .{
        .module = module,
        .text = text.written(),
        .doc = try a.print("glibc's {s} ({s}) and Apple's, from the standard's {s}.", .{ module, map.charmap, xg.name(encoding) }),
        .summary = try a.print("{s}: {d} decode, {d} encode, {d} pairs", .{ xg.name(encoding), cx.decode.items.len, cx.encode.items.len, cx.pairs.items.len }),
    };
}

const Key = struct {
    bytes: []const u8,
    /// What both iconvs read it as, in UTF-8; null where they do not agree.
    common: ?[]const u8,
};

const CharKey = struct {
    cps: []const u21,
    common: ?[]const u8,
};

const Context = struct {
    a: Allocator,
    map: *const Map,
    apple: Apple,
    l: legacy.Legacy,
    decode: std.ArrayList(legacy.Decode) = .empty,
    encode: std.ArrayList(legacy.Encode) = .empty,
    pairs: std.ArrayList(legacy.Pair) = .empty,
    scratch: std.ArrayList(u8) = .empty,

    fn sync(cx: *Context) void {
        cx.l.decode = cx.decode.items;
        cx.l.encode = cx.encode.items;
        cx.l.pairs = cx.pairs.items;
    }

    /// What both iconvs read `bytes` as.
    fn commonRead(cx: *Context, bytes: []const u8) !?[]const u8 {
        var buf: [64]u8 = undefined;
        const theirs = appleRun(cx.apple.decoder, bytes, &buf) orelse return null;
        if (!try cx.map.read(bytes, &cx.scratch, cx.a)) return null;
        if (!std.mem.eql(u8, theirs, cx.scratch.items)) return null;
        return try cx.a.dupe(u8, theirs);
    }

    /// What both iconvs write `cps` as.
    fn commonWrite(cx: *Context, cps: []const u21) !?[]const u8 {
        var buf: [64]u8 = undefined;
        var in: [8]u8 = undefined;
        const theirs = appleRun(cx.apple.encoder, utf8Into(&in, cps), &buf) orelse return null;
        if (!try cx.map.write(cps, &cx.scratch, cx.a)) return null;
        if (!std.mem.eql(u8, theirs, cx.scratch.items)) return null;
        return try cx.a.dupe(u8, theirs);
    }

    /// relic's reading of `bytes`, in UTF-8, into `out`; false where it stops.
    fn relicRead(cx: *Context, bytes: []const u8, out: *std.ArrayList(u8)) !bool {
        out.clearRetainingCapacity();
        var i: usize = 0;
        var cps: [2]u21 = undefined;
        var buf: [4]u8 = undefined;
        while (i < bytes.len) {
            const n = legacy.decodeAt(&cx.l, bytes, &i, &cps) orelse return false;
            for (cps[0..n]) |cp| try out.appendSlice(cx.a, buf[0..try std.unicode.utf8Encode(cp, &buf)]);
        }
        return true;
    }

    fn relicWrite(cx: *Context, cps: []const u21, out: *std.ArrayList(u8)) !bool {
        out.clearRetainingCapacity();
        var i: usize = 0;
        var bytes: [4]u8 = undefined;
        while (i < cps.len) {
            const n = legacy.encodeAt(&cx.l, cps, &i, &bytes) orelse return false;
            try out.appendSlice(cx.a, bytes[0..n]);
        }
        return true;
    }

    fn agrees(cx: *Context, got: bool, out: []const u8, want: ?[]const u8) bool {
        _ = cx;
        if (want) |w| return got and std.mem.eql(u8, out, w);
        return !got;
    }

    /// Every sequence the delta is held to: each byte, each two bytes from a
    /// lead past ASCII, the three and four of EUC-JP and GB18030, and the
    /// letters with marks of the composing encodings; shortest first.
    fn decodeKeys(cx: *Context, e: xg.Encoding) ![]Key {
        var keys: std.ArrayList(Key) = .empty;
        const a = cx.a;
        for (0..256) |b0| try cx.addKey(&keys, &.{@intCast(b0)});
        const multibyte = cx.map.longest > 1 or switch (e) {
            .gbk, .gb18030, .big5, .euc_jp, .euc_kr, .shift_jis => true,
            else => false,
        };
        if (multibyte) for (0x80..256) |b0| for (0..256) |b1| try cx.addKey(&keys, &.{ @intCast(b0), @intCast(b1) });
        if (e == .euc_jp) for (0xa1..0xff) |b1| for (0xa1..0xff) |b2| try cx.addKey(&keys, &.{ 0x8f, @intCast(b1), @intCast(b2) });
        if (e == .gb18030) for (0x81..0xff) |b0| for (0x30..0x3a) |b1| for (0x81..0xff) |b2| for (0x30..0x3a) |b3| {
            try cx.addKey(&keys, &.{ @intCast(b0), @intCast(b1), @intCast(b2), @intCast(b3) });
        };
        if (cx.map.compose != null) {
            // A byte, then marks: any byte that reads as a combining mark in
            // either iconv's table or the standard's.
            var marks: std.ArrayList(u8) = .empty;
            for (0x80..256) |b| {
                const byte: u8 = @intCast(b);
                const chars = cx.map.decode.get(&.{byte}) orelse continue;
                const cp = firstOf(chars) orelse continue;
                if ((cp >= 0x0300 and cp < 0x0370) or (cp >= 0x0591 and cp < 0x05c8)) try marks.append(a, byte);
            }
            for (1..256) |b0| for (marks.items) |m1| {
                try cx.addKey(&keys, &.{ @intCast(b0), m1 });
                for (marks.items) |m2| {
                    try cx.addKey(&keys, &.{ @intCast(b0), m1, m2 });
                    for (marks.items) |m3| try cx.addKey(&keys, &.{ @intCast(b0), m1, m2, m3 });
                }
            };
            std.mem.sortUnstable(Key, keys.items, {}, lessKey);
        }
        return keys.items;
    }

    fn addKey(cx: *Context, keys: *std.ArrayList(Key), bytes: []const u8) !void {
        const owned = try cx.a.dupe(u8, bytes);
        try keys.append(cx.a, .{ .bytes = owned, .common = try cx.commonRead(owned) });
    }

    fn lessKey(_: void, x: Key, y: Key) bool {
        if (x.bytes.len != y.bytes.len) return x.bytes.len < y.bytes.len;
        return std.mem.order(u8, x.bytes, y.bytes) == .lt;
    }

    /// One entry for each sequence relic would read otherwise, shortest first:
    /// a longer sequence is read after the shorter ones it holds.
    fn buildDecode(cx: *Context, keys: []const Key) !void {
        var out: std.ArrayList(u8) = .empty;
        for (keys) |k| {
            cx.sync();
            const got = try cx.relicRead(k.bytes, &out);
            if (cx.agrees(got, out.items, k.common)) continue;
            var entry: legacy.Decode = .{ .len = @intCast(k.bytes.len), .first = keyValue(k.bytes), .last = keyValue(k.bytes) };
            if (k.common) |chars| {
                var view = (try std.unicode.Utf8View.init(chars)).iterator();
                while (view.nextCodepoint()) |cp| {
                    if (entry.count == 2) return error.SequenceReadsAsMore;
                    entry.to[entry.count] = cp;
                    entry.count += 1;
                }
            }
            try cx.decode.append(cx.a, entry);
            cx.l.longest = @max(cx.l.longest, entry.len);
        }
        cx.sync();
        try cx.mergeRefusals(keys);
    }

    /// Adjacent refusals of one length as one range, over the sequences
    /// between them that no input beginning with reads: none is a sequence,
    /// begins with a shorter one, or begins a longer one.
    fn mergeRefusals(cx: *Context, keys: []const Key) !void {
        var prefixes: std.AutoHashMapUnmanaged(u64, void) = .empty;
        for (keys) |k| if (k.common != null) for (1..k.bytes.len) |n| try prefixes.put(cx.a, packed64(k.bytes[0..n]), {});
        var merged: std.ArrayList(legacy.Decode) = .empty;
        var out: std.ArrayList(u8) = .empty;
        for (cx.decode.items) |d| {
            if (merged.items.len > 0) {
                const prev = &merged.items[merged.items.len - 1];
                if (prev.count == 0 and d.count == 0 and prev.len == d.len and d.first - prev.last <= 0x10000) {
                    var fits = true;
                    var k = prev.last + 1;
                    while (k < d.first) : (k += 1) {
                        var bytes: [4]u8 = undefined;
                        std.mem.writeInt(u32, &bytes, k, .big);
                        const seq = bytes[4 - d.len ..];
                        if (prefixes.contains(packed64(seq))) {
                            fits = false;
                            break;
                        }
                        var at: usize = 0;
                        var cps: [2]u21 = undefined;
                        if (legacy.decodeAt(&cx.l, seq, &at, &cps) != null) {
                            fits = false;
                            break;
                        }
                        _ = &out;
                    }
                    if (fits) {
                        prev.last = d.last;
                        continue;
                    }
                }
            }
            try merged.append(cx.a, d);
        }
        cx.decode = merged;
        cx.sync();
    }

    /// Every character either iconv or the standard writes as bytes.
    fn encodeKeys(cx: *Context, e: xg.Encoding) ![]CharKey {
        var keys: std.ArrayList(CharKey) = .empty;
        var cp: u21 = 0;
        var buf: [8]u8 = undefined;
        var in: [4]u8 = undefined;
        while (cp <= 0x10ffff) : (cp += 1) {
            if (cp >= 0xd800 and cp <= 0xdfff) continue;
            const n = std.unicode.utf8Encode(cp, &in) catch continue;
            var w: Io.Writer = .fixed(&buf);
            const standard = if (xg.encode(e, in[0..n], &w, .{ .mode = .fatal })) true else |_| false;
            if (!standard and !cx.map.encode.contains(in[0..n])) continue;
            const cps = try cx.a.dupe(u21, &.{cp});
            try keys.append(cx.a, .{ .cps = cps, .common = try cx.commonWrite(cps) });
        }
        return keys.items;
    }

    fn buildEncode(cx: *Context, keys: []const CharKey) !void {
        var out: std.ArrayList(u8) = .empty;
        for (keys) |k| {
            cx.sync();
            const got = try cx.relicWrite(k.cps, &out);
            if (cx.agrees(got, out.items, k.common)) continue;
            var entry: legacy.Encode = .{ .first = k.cps[0], .last = k.cps[0] };
            if (k.common) |bytes| {
                if (bytes.len > 4) return error.CharacterWritesAsMore;
                entry.len = @intCast(bytes.len);
                @memcpy(entry.bytes[0..bytes.len], bytes);
            }
            try cx.encode.append(cx.a, entry);
        }
        // Adjacent refusals as one range, over characters relic writes as nothing.
        var merged: std.ArrayList(legacy.Encode) = .empty;
        cx.sync();
        for (cx.encode.items) |e| {
            if (merged.items.len > 0) {
                const prev = &merged.items[merged.items.len - 1];
                if (prev.len == 0 and e.len == 0) {
                    var fits = true;
                    var cp = prev.last + 1;
                    while (cp < e.first) : (cp += 1) {
                        var i: usize = 0;
                        var bytes: [4]u8 = undefined;
                        if (legacy.encodeAt(&cx.l, &.{cp}, &i, &bytes) != null) {
                            fits = false;
                            break;
                        }
                    }
                    if (fits) {
                        prev.last = e.last;
                        continue;
                    }
                }
            }
            try merged.append(cx.a, e);
        }
        cx.encode = merged;
        cx.sync();
    }

    /// The two characters glibc writes as one sequence, and for the
    /// composing encodings each letter with each mark.
    fn pairKeys(cx: *Context) ![]CharKey {
        var keys: std.ArrayList(CharKey) = .empty;
        for (cx.map.pairs.items) |chars| try cx.addPair(&keys, chars);
        if (cx.map.compose) |c| {
            var bases: std.ArrayList(u21) = .empty;
            var it = cx.map.encode.iterator();
            while (it.next()) |kv| {
                const cp = firstOf(kv.key_ptr.*) orelse continue;
                if (kv.key_ptr.len > 4) continue;
                if (cp >= c.buffered[0] and cp <= c.buffered[1]) try bases.append(cx.a, cp);
            }
            std.mem.sortUnstable(u21, bases.items, {}, std.sort.asc(u21));
            var marks = c.marks.keyIterator();
            var mark_list: std.ArrayList(u21) = .empty;
            while (marks.next()) |m| try mark_list.append(cx.a, m.*);
            std.mem.sortUnstable(u21, mark_list.items, {}, std.sort.asc(u21));
            for (bases.items) |b| for (mark_list.items) |m| {
                var buf: [8]u8 = undefined;
                try cx.addPair(&keys, try cx.a.dupe(u8, utf8Into(&buf, &.{ b, m })));
            };
        }
        return keys.items;
    }

    fn addPair(cx: *Context, keys: *std.ArrayList(CharKey), chars: []const u8) !void {
        var cps: [2]u21 = undefined;
        var view = (try std.unicode.Utf8View.init(chars)).iterator();
        for (&cps) |*cp| cp.* = view.nextCodepoint() orelse return error.BadPair;
        const owned = try cx.a.dupe(u21, &cps);
        try keys.append(cx.a, .{ .cps = owned, .common = try cx.commonWrite(owned) });
    }

    fn buildPairs(cx: *Context, keys: []const CharKey) !void {
        var out: std.ArrayList(u8) = .empty;
        for (keys) |k| {
            cx.sync();
            const got = try cx.relicWrite(k.cps, &out);
            if (cx.agrees(got, out.items, k.common)) continue;
            var entry: legacy.Pair = .{ .first = k.cps[0], .second = k.cps[1] };
            if (k.common) |bytes| {
                if (bytes.len > 4) return error.CharacterWritesAsMore;
                entry.len = @intCast(bytes.len);
                @memcpy(entry.bytes[0..bytes.len], bytes);
            }
            try cx.pairs.append(cx.a, entry);
        }
        std.mem.sortUnstable(legacy.Pair, cx.pairs.items, {}, lessPair);
        cx.sync();
    }

    fn lessPair(_: void, x: legacy.Pair, y: legacy.Pair) bool {
        if (x.first != y.first) return x.first < y.first;
        return x.second < y.second;
    }

    /// Fails unless relic, with the delta as written, reads and writes every
    /// key as both iconvs do.
    fn verify(cx: *Context, keys: []const Key, chars: []const CharKey, pairs: []const CharKey) !void {
        cx.sync();
        var out: std.ArrayList(u8) = .empty;
        for (keys) |k| if (!cx.agrees(try cx.relicRead(k.bytes, &out), out.items, k.common)) {
            std.debug.print("{s}: {x} reads otherwise\n", .{ xg.name(cx.l.encoding), k.bytes });
            return error.DeltaDiffers;
        };
        for (chars) |k| if (!cx.agrees(try cx.relicWrite(k.cps, &out), out.items, k.common)) {
            std.debug.print("{s}: U+{X:0>4} writes otherwise\n", .{ xg.name(cx.l.encoding), k.cps[0] });
            return error.DeltaDiffers;
        };
        for (pairs) |k| if (!cx.agrees(try cx.relicWrite(k.cps, &out), out.items, k.common)) {
            std.debug.print("{s}: U+{X:0>4} U+{X:0>4} writes otherwise\n", .{ xg.name(cx.l.encoding), k.cps[0], k.cps[1] });
            return error.DeltaDiffers;
        };
    }

    fn write(cx: *const Context, w: *Io.Writer) !void {
        try w.print(".{{ .encoding = .{s}", .{@tagName(cx.l.encoding)});
        if (cx.decode.items.len > 0) {
            try w.writeAll(", .decode = &.{\n");
            for (cx.decode.items) |d| {
                try w.print("    .{{ .len = {d}, .first = 0x{x}, .last = 0x{x}", .{ d.len, d.first, d.last });
                if (d.count > 0) try w.print(", .count = {d}, .to = .{{ 0x{x}, 0x{x} }}", .{ d.count, d.to[0], d.to[1] });
                try w.writeAll(" },\n");
            }
            try w.writeAll("}");
        }
        if (cx.encode.items.len > 0) {
            try w.writeAll(", .encode = &.{\n");
            for (cx.encode.items) |e| {
                try w.print("    .{{ .first = 0x{x}, .last = 0x{x}", .{ e.first, e.last });
                if (e.len > 0) try w.print(", .len = {d}, .bytes = .{{ 0x{x}, 0x{x}, 0x{x}, 0x{x} }}", .{ e.len, e.bytes[0], e.bytes[1], e.bytes[2], e.bytes[3] });
                try w.writeAll(" },\n");
            }
            try w.writeAll("}");
        }
        if (cx.pairs.items.len > 0) {
            try w.writeAll(", .pairs = &.{\n");
            for (cx.pairs.items) |p| {
                try w.print("    .{{ .first = 0x{x}, .second = 0x{x}", .{ p.first, p.second });
                if (p.len > 0) try w.print(", .len = {d}, .bytes = .{{ 0x{x}, 0x{x}, 0x{x}, 0x{x} }}", .{ p.len, p.bytes[0], p.bytes[1], p.bytes[2], p.bytes[3] });
                try w.writeAll(" },\n");
            }
            try w.writeAll("}");
        }
        if (cx.l.longest > 1) try w.print(", .longest = {d}", .{cx.l.longest});
        try w.writeAll(" }");
    }
};

/// The first character of `chars`, UTF-8.
fn firstOf(chars: []const u8) ?u21 {
    const view = std.unicode.Utf8View.init(chars) catch return null;
    var it = view.iterator();
    return it.nextCodepoint();
}

fn keyValue(bytes: []const u8) u32 {
    return std.mem.readVarInt(u32, bytes, .big);
}

fn packed64(bytes: []const u8) u64 {
    return (@as(u64, bytes.len) << 32) | keyValue(bytes);
}

//=========================================================================
// Reading glibc's files
//=========================================================================

fn readAll(a: Allocator, io: Io, dir: Io.Dir, path: []const u8) ![]u8 {
    return dir.readFileAlloc(io, path, a, .limited(64 << 20));
}

fn quoted(text: []const u8, prefix: []const u8) ?[]const u8 {
    const at = std.mem.find(u8, text, prefix) orelse return null;
    const open = std.mem.findScalarPos(u8, text, at, '"') orelse return null;
    const close = std.mem.findScalarPos(u8, text, open + 1, '"') orelse return null;
    return text[open + 1 .. close];
}

fn trimSlashes(name: []const u8) []const u8 {
    return std.mem.trimEnd(u8, name, "/");
}

fn upper(a: Allocator, s: []const u8) ![]u8 {
    const out = try a.dupe(u8, s);
    for (out) |*c| c.* = std.ascii.toUpper(c.*);
    return out;
}

fn lower(a: Allocator, s: []const u8) ![]u8 {
    const out = try a.dupe(u8, s);
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}

/// gconv_charset.c's strip: alphanumerics and `_-.,:` kept, upper-cased.
fn strip(a: Allocator, name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (std.mem.trim(u8, name, " \t\r")) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.' or c == ',' or c == ':') try out.append(a, std.ascii.toUpper(c));
    }
    return out.items;
}

/// `/xHH/xHH...` as bytes.
fn parseBytes(a: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i + 4 <= s.len) : (i += 4) {
        if (s[i] != '/' or s[i + 1] != 'x') return error.BadBytes;
        try out.append(a, try std.fmt.parseInt(u8, s[i + 2 .. i + 4], 16));
    }
    return out.items;
}

/// `0xHHHH...` as bytes.
fn hexBytes(a: Allocator, s: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, s, "0x")) return error.BadBytes;
    const digits = s[2..];
    var out: std.ArrayList(u8) = .empty;
    var k: usize = 0;
    while (k + 2 <= digits.len) : (k += 2) try out.append(a, try std.fmt.parseInt(u8, digits[k .. k + 2], 16));
    return out.items;
}

/// `<U0041><U030A>` as UTF-8.
fn parseUnicode(a: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '<' or i + 1 >= s.len or s[i + 1] != 'U') return error.BadUnicode;
        const end = std.mem.findScalarPos(u8, s, i, '>') orelse return error.BadUnicode;
        const cp = try std.fmt.parseInt(u21, s[i + 2 .. end], 16);
        var b: [4]u8 = undefined;
        try out.appendSlice(a, b[0..try std.unicode.utf8Encode(cp, &b)]);
        i = end + 1;
    }
    return out.items;
}

/// The sequence after `bytes` in a charmap range: GB18030's four-byte
/// counter, else the last byte's.
fn step(bytes: []u8) void {
    if (bytes.len == 4) {
        const lo = [_]u8{ 0x81, 0x30, 0x81, 0x30 };
        const hi = [_]u8{ 0xfe, 0x39, 0xfe, 0x39 };
        var k: usize = 4;
        while (k > 0) {
            k -= 1;
            if (bytes[k] < hi[k]) {
                bytes[k] += 1;
                return;
            }
            bytes[k] = lo[k];
        }
        return;
    }
    bytes[bytes.len - 1] +%= 1;
}

fn utf8Of(a: Allocator, cps: []const u21) ![]u8 {
    var buf: [8]u8 = undefined;
    return a.dupe(u8, utf8Into(&buf, cps));
}

fn utf8Into(buf: *[8]u8, cps: []const u21) []const u8 {
    var n: usize = 0;
    // unreachable: at most two scalar values of four bytes each
    for (cps) |cp| n += std.unicode.utf8Encode(cp, buf[n..]) catch unreachable;
    return buf[0..n];
}

/// The `0x` numbers in `text`, in order.
fn hexNumbers(text: []const u8) HexNumbers {
    return .{ .text = text };
}

const HexNumbers = struct {
    text: []const u8,
    at: usize = 0,

    fn next(h: *HexNumbers) ?u21 {
        const start = std.mem.findPos(u8, h.text, h.at, "0x") orelse return null;
        var end = start + 2;
        while (end < h.text.len and std.ascii.isHex(h.text[end])) end += 1;
        h.at = end;
        return std.fmt.parseInt(u21, h.text[start + 2 .. end], 16) catch null;
    }
};
