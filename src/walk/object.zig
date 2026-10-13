//! The object walk: every object a set of tips reaches past what is
//! excluded, and the filters a partial clone asks it to apply.

pub const walk = @import("object/walk.zig");
pub const filter = @import("object/filter.zig");

/// All errors reported by this namespace.
pub const Error = walk.Error;
