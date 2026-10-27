//! The binary encodings git stores and sends: deltas, EWAH bitmaps, pkt-lines and varints, and the fixed-width tables its files hold.

pub const delta = @import("codec/delta.zig");
pub const ewah = @import("codec/ewah.zig");
pub const pkt_line = @import("codec/pkt_line.zig");
pub const varint = @import("codec/varint.zig");
pub const Rows = @import("codec/rows.zig").Rows;
