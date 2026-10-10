//! Files, locks and the write policy: the one concern that names the disk's
//! modes, locks and durability.

pub const engine = @import("fs/fs.zig");
pub const stat = @import("fs/stat.zig");
