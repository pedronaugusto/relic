//! The shakedown-timed benchmark rows, one program so the whole library is
//! compiled once for all of them. Each group is a file beside this one with a
//! `run` that prints its rows; `--smoke` runs every row once without a clock.
const std = @import("std");
const native = @import("native.zig");
const groups = .{
    @import("rules.zig"),
    @import("ere.zig"),
    @import("pack_codec.zig"),
    @import("zstd.zig"),
    @import("local_push.zig"),
    native,
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    // The native group starts this program again as its echo peer.
    if (args.len > 1 and std.mem.eql(u8, args[1], "--echo")) return native.echo(init.io);
    inline for (groups) |group| try group.run(init, args);
}
