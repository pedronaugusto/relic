//! relic — read and write a git repository from Zig.

pub const hash = @import("hash.zig");
pub const object = @import("object.zig");
pub const fs = @import("fs.zig");
pub const delta = @import("delta.zig");
pub const pack = @import("pack.zig");
pub const odb = @import("odb.zig");
pub const index = @import("index.zig");
pub const varint = @import("varint.zig");
pub const ewah = @import("ewah.zig");
pub const safepath = @import("safepath.zig");
pub const platstat = @import("platstat.zig");

const builtin = @import("builtin");

test {
    @import("std").testing.refAllDecls(@This());
    if (builtin.is_test) {
        _ = @import("testgit.zig");
        _ = @import("fixture_test.zig");
    }
}
