//! What git would have printed as `warning:` and went on after.
//!
//! git tells the person, on its standard error, when it did something other
//! than what was asked and carried on — a `--depth` a local clone ignores, a
//! filter a server does not know, certificate checks turned off — and passes
//! along what `ssh` says. relic prints nothing, so an operation handed a
//! `Warnings` adds each one there instead, as a value a caller can show,
//! count or act on; one handed none says nothing and loses nothing.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// One warning.
pub const Warning = union(enum) {
    /// An option a clone or fetch from a path on this machine does not
    /// apply: `--depth`, `--shallow-since`, `--shallow-exclude`, `--filter`.
    /// git ignores them there too; `file://` is how to have them.
    ignored_for_local: []const u8,
    /// The server does not filter, and everything was fetched.
    filter_not_supported,
    /// The server's certificate was not checked, because the named setting
    /// said not to.
    ssl_verify_disabled: []const u8,
    /// What `ssh` wrote on its standard error, a line to a line, on a
    /// conversation that went on to succeed.
    ssh_said: []const u8,

    /// The text git prints after `warning: ` for it, where git prints one.
    /// The result is `arena`'s.
    pub fn message(w: Warning, arena: Allocator) Allocator.Error![]const u8 {
        return switch (w) {
            .ignored_for_local => |option| std.fmt.allocPrint(arena, "{s} is ignored in local clones; use file:// instead.", .{option}),
            .filter_not_supported => "filtering not recognized by server, ignoring",
            .ssl_verify_disabled => |setting| std.fmt.allocPrint(arena, "the server's certificate is not checked ({s})", .{setting}),
            .ssh_said => |text| text,
        };
    }
};

/// Warnings gathered over one operation.
pub const Warnings = struct {
    arena: std.heap.ArenaAllocator,
    items: std.ArrayList(Warning) = .empty,

    /// An empty list.
    pub fn init(gpa: Allocator) Warnings {
        return .{ .arena = .init(gpa) };
    }

    /// Release every warning.
    pub fn deinit(w: *Warnings) void {
        w.arena.deinit();
        w.* = undefined;
    }

    /// Keep `warning`, with its text copied.
    pub fn add(w: *Warnings, warning: Warning) Allocator.Error!void {
        const a = w.arena.allocator();
        const owned: Warning = switch (warning) {
            .ignored_for_local => |t| .{ .ignored_for_local = try a.dupe(u8, t) },
            .filter_not_supported => .filter_not_supported,
            .ssl_verify_disabled => |t| .{ .ssl_verify_disabled = try a.dupe(u8, t) },
            .ssh_said => |t| .{ .ssh_said = try a.dupe(u8, t) },
        };
        try w.items.append(a, owned);
    }
};

/// Keep `warning` in `to`, when there is somewhere to keep it.
pub fn note(to: ?*Warnings, warning: Warning) Allocator.Error!void {
    const w = to orelse return;
    try w.add(warning);
}

test "a warning is kept as a value and read as git words it" {
    var w: Warnings = .init(std.testing.allocator);
    defer w.deinit();
    var option = [_]u8{ '-', '-', 'd', 'e', 'p', 't', 'h' };
    try note(&w, .{ .ignored_for_local = &option });
    option[2] = 'x';
    try note(null, .filter_not_supported);
    try std.testing.expectEqual(@as(usize, 1), w.items.items.len);
    const text = try w.items.items[0].message(w.arena.allocator());
    try std.testing.expectEqualStrings("--depth is ignored in local clones; use file:// instead.", text);
}
