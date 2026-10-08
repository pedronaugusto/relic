//! Public hash namespace. Implementation is in `hash/hash.zig`.

pub const sha1 = @import("hash/sha1.zig");
pub const sha1dc = @import("hash/sha1dc.zig");
pub const Kind = @import("hash/hash.zig").Kind;
pub const max_raw_len = @import("hash/hash.zig").max_raw_len;
pub const max_hex_len = @import("hash/hash.zig").max_hex_len;
pub const Oid = @import("hash/hash.zig").Oid;
pub const Hasher = @import("hash/hash.zig").Hasher;
pub const Error = @import("hash/hash.zig").Error;
