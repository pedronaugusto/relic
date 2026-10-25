//! Private read seam for pack reception. The object database owns writes;
//! the receiver asks only for existing objects and collision policy.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const policy = @import("policy.zig");

pub const Read = struct { type: object.Type, bytes: []u8 };
pub const Database = struct {
    context: *anyopaque,
    gpa: Allocator,
    kind: hash.Kind,
    detect_collisions: bool,
    /// `core.bigFileThreshold`: a blob past it is named as it is inflated,
    /// never held.
    big_file_bytes: u64,
    read_fn: *const fn (Io, *anyopaque, hash.Oid) policy.Error!Read,
    header_fn: *const fn (Io, *anyopaque, hash.Oid) policy.Error!object.Header,
    exists_fn: *const fn (Io, *anyopaque, hash.Oid) policy.Error!bool,
    same_fn: *const fn (Io, *anyopaque, hash.Oid, *Io.Reader, u64) policy.Error!bool,

    pub fn from(db: anytype) Database {
        const T = @TypeOf(db);
        const Adapter = struct {
            fn read(io: Io, raw: *anyopaque, oid: hash.Oid) policy.Error!Read {
                const owner: T = @ptrCast(@alignCast(raw)); // aegis: no-danger: from stores the adapted owner, whose type is T
                const result = try owner.read(io, oid);
                return .{ .type = result.type, .bytes = result.bytes };
            }
            fn header(io: Io, raw: *anyopaque, oid: hash.Oid) policy.Error!object.Header {
                const owner: T = @ptrCast(@alignCast(raw)); // aegis: no-danger: from stores the adapted owner, whose type is T
                return owner.readHeader(io, oid);
            }
            fn exists(io: Io, raw: *anyopaque, oid: hash.Oid) policy.Error!bool {
                const owner: T = @ptrCast(@alignCast(raw)); // aegis: no-danger: from stores the adapted owner, whose type is T
                return owner.exists(io, oid);
            }
            fn same(io: Io, raw: *anyopaque, oid: hash.Oid, ours: *Io.Reader, size: u64) policy.Error!bool {
                const owner: T = @ptrCast(@alignCast(raw)); // aegis: no-danger: from stores the adapted owner, whose type is T
                const theirs = try owner.stream(io, oid);
                defer theirs.close(io);
                if (theirs.size != size) return false;
                var held: [16 * 1024]u8 = undefined;
                var given: [16 * 1024]u8 = undefined;
                var left = size;
                while (left != 0) {
                    const n: usize = @intCast(@min(@as(u64, held.len), left));
                    theirs.reader().readSliceAll(held[0..n]) catch |err| return switch (err) {
                        error.ReadFailed => theirs.err() orelse error.ReadFailed,
                        error.EndOfStream => error.CorruptLooseObject,
                    };
                    // The caller's reader failing is the caller's to name.
                    ours.readSliceAll(given[0..n]) catch return error.ReadFailed;
                    if (!std.mem.eql(u8, held[0..n], given[0..n])) return false;
                    left -= n;
                }
                return true;
            }
        };
        return .{
            .context = db,
            .gpa = db.allocator(),
            .kind = db.objectFormat(),
            .detect_collisions = db.settings().detect_sha1_collisions,
            .big_file_bytes = db.settings().packing.big_file_bytes,
            .read_fn = Adapter.read,
            .header_fn = Adapter.header,
            .exists_fn = Adapter.exists,
            .same_fn = Adapter.same,
        };
    }

    pub fn objectFormat(db: Database) hash.Kind {
        return db.kind;
    }

    pub fn allocator(db: Database) Allocator {
        return db.gpa;
    }

    pub fn read(db: Database, io: Io, oid: hash.Oid) policy.Error!Read {
        return db.read_fn(io, db.context, oid);
    }

    pub fn readHeader(db: Database, io: Io, oid: hash.Oid) policy.Error!object.Header {
        return db.header_fn(io, db.context, oid);
    }

    pub fn exists(db: Database, io: Io, oid: hash.Oid) policy.Error!bool {
        return db.exists_fn(io, db.context, oid);
    }

    /// Whether the object named `oid` is exactly the `size` bytes `ours`
    /// gives, both read as they come and neither held: an object past
    /// `big_file_bytes`. A failure of `ours` is `error.ReadFailed`, for the
    /// caller to name from its own reader.
    pub fn same(db: Database, io: Io, oid: hash.Oid, ours: *Io.Reader, size: u64) policy.Error!bool {
        return db.same_fn(io, db.context, oid, ours, size);
    }
};

/// All errors reported by this namespace.
pub const Error = policy.Error;
