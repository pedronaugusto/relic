//! Benchmark-only access to public operations and the internal regex core.
pub const api = @import("relic.zig");
pub const regex = @import("text.zig").ere;
pub const crc = @import("warp").Crc32;
pub const zstd = @import("warp").zstd;
