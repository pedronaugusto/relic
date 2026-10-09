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
    read_fn: *const fn (Io, *anyopaque, hash.Oid) policy.Error!Read,
    header_fn: *const fn (Io, *anyopaque, hash.Oid) policy.Error!object.Header,
    exists_fn: *const fn (Io, *anyopaque, hash.Oid) policy.Error!bool,

    pub fn from(db: anytype) Database {
        const T = @TypeOf(db);
        const Adapter = struct {
            fn read(io: Io, raw: *anyopaque, oid: hash.Oid) policy.Error!Read {
                const owner: T = @ptrCast(@alignCast(raw)); // safe: from stores the adapted owner, whose type is T
                const result = try owner.read(io, oid);
                return .{ .type = result.type, .bytes = result.bytes };
            }
            fn header(io: Io, raw: *anyopaque, oid: hash.Oid) policy.Error!object.Header {
                const owner: T = @ptrCast(@alignCast(raw)); // safe: from stores the adapted owner, whose type is T
                return owner.readHeader(io, oid);
            }
            fn exists(io: Io, raw: *anyopaque, oid: hash.Oid) policy.Error!bool {
                const owner: T = @ptrCast(@alignCast(raw)); // safe: from stores the adapted owner, whose type is T
                return owner.exists(io, oid);
            }
        };
        return .{
            .context = db,
            .gpa = db.allocator(),
            .kind = db.objectFormat(),
            .detect_collisions = db.settings().detect_sha1_collisions,
            .read_fn = Adapter.read,
            .header_fn = Adapter.header,
            .exists_fn = Adapter.exists,
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
};

/// All errors reported by this namespace.
pub const Error = policy.Error;
