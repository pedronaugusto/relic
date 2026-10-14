//! Public index namespace. Implementation is in `index/index.zig`.

pub const sparse = @import("index/sparse_index.zig");
pub const magic = @import("index/index.zig").magic;
pub const ReadError = @import("index/index.zig").ReadError;
pub const WriteError = @import("index/index.zig").WriteError;
pub const Entry = @import("index/index.zig").Entry;
pub const RawExtension = @import("index/index.zig").RawExtension;
pub const CacheTreeNode = @import("index/index.zig").CacheTreeNode;
pub const CacheTree = @import("index/index.zig").CacheTree;
pub const Dropped = @import("index/index.zig").Dropped;
pub const ResolveUndo = @import("index/index.zig").ResolveUndo;
pub const ReadOptions = @import("index/index.zig").ReadOptions;
pub const WriteOptions = @import("index/index.zig").WriteOptions;
pub const Index = @import("index/index.zig").Index;
pub const Error = @import("index/index.zig").Error;
