//! Bind a reachability bitmap to its pack's or MIDX's object orders.

const Self = @This();
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const hash = @import("../../hash.zig");
const fs = @import("../../repo/fs.zig");
const pack = @import("../pack.zig");
const midx = @import("../midx.zig");
const bitmap = @import("../bitmap.zig");
const object = @import("../../object.zig");
const Oid = hash.Oid;

pub const Error = bitmap.Error || midx.Error || pack.IndexError || Io.Dir.AccessError || Io.Dir.OpenError || Io.Dir.Iterator.Error || Io.Dir.ReadFileAllocError;

/// The two orders a bitmap uses: selected commits are in name order, bits in pack order.
pub const Store = struct {
    gpa: Allocator,
    names: []Oid,
    reverse: []u32,
    bitmap: bitmap.Index,

    pub fn deinit(store: *Store) void {
        store.gpa.free(store.names);
        store.gpa.free(store.reverse);
        store.bitmap.deinit();
        store.* = undefined;
    }

    /// Open a MIDX bitmap first, then a pack bitmap. A caller may fall back on
    /// malformed optional data, but IO and allocation errors keep their names.
    pub fn open(gpa: Allocator, io: Io, objects: Io.Dir, kind: hash.Kind) Self.Error!?Store {
        const dir = objects.openDir(io, "pack", .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer dir.close(io);
        if (try midx.Index.open(gpa, io, dir, kind)) |value| {
            var index = value;
            defer index.deinit();
            try index.verify();
            var hex: [hash.max_hex_len]u8 = undefined;
            const path = try gpa.print("multi-pack-index-{s}.bitmap", .{index.checksum().hex(&hex)});
            defer gpa.free(path);
            if (try fs.readFileAlloc(gpa, io, dir, path, 1 << 30)) |bytes| {
                var parsed = try bitmap.Index.parse(gpa, kind, bytes, index.checksum(), index.count);
                errdefer parsed.deinit();
                const names = try gpa.alloc(Oid, index.count);
                errdefer gpa.free(names);
                const reverse = try gpa.alloc(u32, index.count);
                errdefer gpa.free(reverse);
                for (names, reverse, 0..) |*name, *pos, i| {
                    name.* = index.nameAt(@intCast(i));
                    pos.* = (try index.reverseAt(@intCast(i))) orelse return error.CorruptMultiPackIndex;
                }
                for (0..index.pack_count) |i| {
                    const base = index.packName(@intCast(i)) orelse return error.CorruptMultiPackIndex;
                    const pack_path = try gpa.print("{s}.pack", .{base});
                    defer gpa.free(pack_path);
                    dir.access(io, pack_path, .{}) catch |err| switch (err) {
                        error.FileNotFound => return error.CorruptMultiPackIndex,
                        else => return err,
                    };
                }
                return .{ .gpa = gpa, .names = names, .reverse = reverse, .bitmap = parsed };
            }
        }
        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            if (!std.mem.startsWith(u8, entry.name, "pack-") or !std.mem.endsWith(u8, entry.name, ".bitmap")) continue;
            const base = entry.name[0 .. entry.name.len - 7];
            const index_path = try gpa.print("{s}.idx", .{base});
            defer gpa.free(index_path);
            var index = try pack.Index.open(gpa, io, dir, index_path, kind, 1 << 30);
            defer index.deinit();
            const pack_path = try gpa.print("{s}.pack", .{base});
            defer gpa.free(pack_path);
            dir.access(io, pack_path, .{}) catch |err| switch (err) {
                error.FileNotFound => return error.CorruptReachabilityBitmap,
                else => return err,
            };
            const bytes = (try fs.readFileAlloc(gpa, io, dir, entry.name, 1 << 30)) orelse continue;
            var parsed = try bitmap.Index.parse(gpa, kind, bytes, index.pack_checksum, index.count);
            errdefer parsed.deinit();
            const names = try gpa.alloc(Oid, index.count);
            errdefer gpa.free(names);
            const reverse = try gpa.alloc(u32, index.count);
            errdefer gpa.free(reverse);
            const offsets = try gpa.alloc(u64, index.count);
            defer gpa.free(offsets);
            for (names, reverse, offsets, 0..) |*name, *pos, *offset, i| {
                name.* = index.nameAt(@intCast(i));
                pos.* = @intCast(i);
                offset.* = try index.offsetAt(@intCast(i));
            }
            const Order = struct {
                fn less(context: []const u64, a: u32, b: u32) bool {
                    return context[a] < context[b];
                }
            };
            std.mem.sort(u32, reverse, offsets, Order.less);
            return .{ .gpa = gpa, .names = names, .reverse = reverse, .bitmap = parsed };
        }
        return null;
    }

    /// Find a selected commit by name and return its reachability in pack order.
    pub fn reach(store: *const Store, gpa: Allocator, oid: Oid) bitmap.Error!?[]u64 {
        const Order = struct {
            fn compare(key: Oid, item: Oid) std.math.Order {
                return key.order(item);
            }
        };
        const position = std.sort.binarySearch(Oid, store.names, oid, Order.compare) orelse return null;
        return store.bitmap.reach(gpa, @intCast(position));
    }

    pub fn nameAt(store: *const Store, position: u32) Oid {
        return store.names[store.reverse[position]];
    }
    pub fn typeAt(store: *const Store, position: u32) object.Type {
        const types = [_]object.Type{ .commit, .tree, .blob, .tag };
        for (store.bitmap.types, types) |words, kind| if (bitmap.isSet(words, position)) return kind;
        unreachable;
    }
};
