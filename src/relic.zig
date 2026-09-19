//! relic — read and write a git repository from Zig.

pub const hash = @import("hash.zig");
pub const object = @import("object.zig");
pub const fs = @import("fs.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
