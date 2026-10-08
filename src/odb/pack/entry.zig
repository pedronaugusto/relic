const hash = @import("../../hash/hash.zig");
const Oid = hash.Oid;
/// One entry, as the index will need it: its name, where it begins in the
/// pack, and the CRC32 of its bytes there.
pub const IndexEntry = struct {
    oid: Oid,
    offset: u64,
    crc: u32,
};
