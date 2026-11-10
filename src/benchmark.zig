//! Benchmark-only access to public operations, LFS's, and the internal regex core.
pub const api = @import("relic");
pub const lfs = @import("relic_lfs");
pub const regex = @import("relic_core").text.ere;
pub const crc = @import("warp").Crc32;
pub const zstd = @import("warp").zstd;
