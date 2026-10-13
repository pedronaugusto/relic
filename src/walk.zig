//! Walking history: the commit walk, the object walk and its filters, the
//! shallow boundary and history simplification.

pub const engine = @import("walk/walk.zig");
pub const object = @import("walk/object.zig");
pub const shallow = @import("walk/shallow.zig");
pub const simplify = @import("walk/simplify.zig");
