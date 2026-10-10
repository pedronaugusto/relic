//! What every group of rows shares: the options the program's arguments ask
//! for, `--smoke` and `--row PREFIX`, and the commit its rows name, as
//! preflight's `bench-ab` reads them.
const std = @import("std");
const benchmark = @import("shakedown").bench;

/// The revision this program was built from.
pub const commit = @import("preflight_bench_options").commit;

/// The options `args` ask for, over the sampling every row here uses.
pub fn options(init: std.process.Init, args: []const [:0]const u8) !benchmark.Options {
    const asked = try init.arena.allocator().alloc([]const u8, args.len -| 1);
    for (asked, args[@min(1, args.len)..]) |*to, from| to.* = from;
    var out = benchmark.Options.fromArguments(asked) catch return error.InvalidArguments;
    out.samples = 11;
    out.minimum = .fromMilliseconds(5);
    return out;
}

/// Whether `prefix` selects any of `rows`. A group none of whose rows ran has
/// done no work to check.
pub fn selects(prefix: []const u8, rows: anytype) bool {
    for (rows) |row| if (std.mem.startsWith(u8, row.name, prefix)) return true;
    return false;
}

/// Whether `prefix` selects the row `name`: a group with expensive setup asks
/// before it builds anything.
pub fn wants(prefix: []const u8, name: []const u8) bool {
    return std.mem.startsWith(u8, name, prefix);
}
