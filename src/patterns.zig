//! The pattern files a working tree is read through: attributes, ignore rules, pathspecs and sparse checkout.

pub const attributes = @import("patterns/attributes.zig");
pub const ignore = @import("patterns/ignore.zig");
pub const pathspec = @import("patterns/pathspec.zig");
pub const sparse = @import("patterns/sparse.zig");
