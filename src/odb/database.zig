//! Private read seam for pack reception. The object database owns writes;
//! the receiver asks only for existing objects and collision policy.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const hash = @import("../hash/hash.zig");
const object = @import("../object/object.zig");
const policy = @import("policy.zig");

pub const Read = struct { type: object.Type, bytes: []u8 };

/// What reads the database's objects for a pack being received: a node its
/// owner embeds, found again from the node by `@fieldParentPtr`.
/// `odb.Odb` embeds one.
pub const Source = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        read: *const fn (source: *Source, io: Io, oid: hash.Oid) policy.Error!Read,
        header: *const fn (source: *Source, io: Io, oid: hash.Oid) policy.Error!object.Header,
        exists: *const fn (source: *Source, io: Io, oid: hash.Oid) policy.Error!bool,
        /// See `Database.same`.
        same: *const fn (source: *Source, io: Io, oid: hash.Oid, ours: *Io.Reader, size: u64) policy.Error!bool,
    };
};

pub const Database = struct {
    source: *Source,
    gpa: Allocator,
    kind: hash.Kind,
    detect_collisions: bool,
    /// `core.bigFileThreshold`: a blob past it is named as it is inflated,
    /// never held.
    big_file_bytes: u64,

    pub fn from(db: anytype) Database {
        return .{
            .source = &db.reception,
            .gpa = db.allocator(),
            .kind = db.objectFormat(),
            .detect_collisions = db.settings().detect_sha1_collisions,
            .big_file_bytes = db.settings().packing.big_file_bytes,
        };
    }

    pub fn objectFormat(db: Database) hash.Kind {
        return db.kind;
    }

    pub fn allocator(db: Database) Allocator {
        return db.gpa;
    }

    pub fn read(db: Database, io: Io, oid: hash.Oid) policy.Error!Read {
        return db.source.vtable.read(db.source, io, oid);
    }

    pub fn readHeader(db: Database, io: Io, oid: hash.Oid) policy.Error!object.Header {
        return db.source.vtable.header(db.source, io, oid);
    }

    pub fn exists(db: Database, io: Io, oid: hash.Oid) policy.Error!bool {
        return db.source.vtable.exists(db.source, io, oid);
    }

    /// Whether the object named `oid` is exactly the `size` bytes `ours`
    /// gives, both read as they come and neither held: an object past
    /// `big_file_bytes`. A failure of `ours` is `error.ReadFailed`, for the
    /// caller to name from its own reader.
    pub fn same(db: Database, io: Io, oid: hash.Oid, ours: *Io.Reader, size: u64) policy.Error!bool {
        return db.source.vtable.same(db.source, io, oid, ours, size);
    }
};

/// All errors reported by this namespace.
pub const Error = policy.Error;
