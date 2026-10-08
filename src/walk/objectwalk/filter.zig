const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const hash = @import("../../hash/hash.zig");
const Kind = hash.Kind;
const Oid = hash.Oid;
const object = @import("../../object/object.zig");
const odb_mod = @import("../../odb/odb.zig");
const ignore = @import("../../patterns/ignore.zig");
/// Errors from walking objects.
pub const Error = error{
    /// An object below a tip is not in the database. `missing_out` names
    /// it.
    MissingObject,
    /// A tree nests deeper than `object.max_tree_depth`.
    TreeTooDeep,
    /// A commit named something that is not a commit as its parent, or a
    /// tree named a tree entry that is not a tree.
    UnexpectedObjectType,
} || odb_mod.Error || object.ParseError || Allocator.Error;

/// What a server's pack leaves out: git's `--filter` specs.
pub const Filter = union(enum) {
    none,
    /// `blob:none`: no blob.
    blob_none,
    /// `blob:limit=<n>`: no blob of `n` bytes or more.
    blob_limit: u64,
    /// `tree:<depth>`: no tree or blob at `depth` or deeper, a commit's
    /// root tree being at depth zero.
    tree_depth: u64,
    /// `object:type=<type>`: only objects of the type.
    object_type: object.Type,
    /// `sparse:oid=<blob>`: every tree, and the blobs the blob's
    /// sparse-checkout patterns take in, a path no pattern decides taking
    /// its directory's answer, as git's sparse filter decides. One to a
    /// filter.
    sparse: *const ignore.Rules,
    /// `combine:<a>+<b>…`: what every one of them keeps.
    combine: []const Filter,
};
