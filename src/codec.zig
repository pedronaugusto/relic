//! The binary encodings git stores and sends: deltas, EWAH bitmaps, pkt-lines and varints.

pub const delta = @import("codec/delta.zig");
pub const ewah = @import("codec/ewah.zig");
pub const pktline = @import("codec/pktline.zig");
pub const varint = @import("codec/varint.zig");
