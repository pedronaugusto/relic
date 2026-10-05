//! The refs a server does not show: git's `transfer.hideRefs`, with
//! `uploadpack.hideRefs` for a fetch and `receive.hideRefs` for a push.
//!
//! Each value is a ref name prefix; a ref is hidden when its name is the
//! prefix or continues it past a `/`. A value beginning `!` shows what an
//! earlier one hid, and one beginning `^` is matched against the name with
//! its namespace, which here, with no namespaces, is the name. The last
//! value that matches decides, in the order the configuration sets them.
//!
//! A hidden ref is not advertised, so a client neither sees nor asks for
//! it; asked for by name anyway, its tip is a want only where
//! `uploadpack.allowTipSHA1InWant` or `allowReachableSHA1InWant` says, and
//! a push may not update or delete it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const config_mod = @import("../config.zig");

/// Which server the refs are hidden from.
pub const Service = enum {
    upload_pack,
    receive_pack,

    fn section(service: Service) []const u8 {
        return switch (service) {
            .upload_pack => "uploadpack",
            .receive_pack => "receive",
        };
    }
};

/// The patterns, in the order the configuration sets them.
pub const HiddenRefs = struct {
    gpa: Allocator,
    /// Each with its trailing `/` taken off, as git takes them off. Owned.
    patterns: [][]u8 = &.{},

    /// Nothing hidden.
    pub fn none(gpa: Allocator) HiddenRefs {
        return .{ .gpa = gpa };
    }

    /// `transfer.hideRefs` and `<service>.hideRefs`, each value in the
    /// order the configuration sets it. A name with no value is
    /// `error.MalformedValue`, as git refuses one.
    pub fn load(gpa: Allocator, config: *const config_mod.Config, service: Service) (Allocator.Error || error{MalformedValue})!HiddenRefs {
        var patterns: std.ArrayList([]u8) = .empty;
        errdefer {
            for (patterns.items) |p| gpa.free(p);
            patterns.deinit(gpa);
        }
        for (config.entries.items) |entry| {
            if (entry.has_subsection or !std.ascii.eqlIgnoreCase(entry.name, "hiderefs")) continue;
            if (!std.mem.eql(u8, entry.section, "transfer") and !std.mem.eql(u8, entry.section, service.section())) continue;
            const raw = entry.value orelse return error.MalformedValue;
            const value = config_mod.unquote(gpa, raw) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.MalformedValue,
            };
            defer gpa.free(value);
            var len = value.len;
            while (len != 0 and value[len - 1] == '/') len -= 1;
            const trimmed = try gpa.dupe(u8, value[0..len]);
            patterns.append(gpa, trimmed) catch |err| {
                gpa.free(trimmed);
                return err;
            };
        }
        return .{ .gpa = gpa, .patterns = try patterns.toOwnedSlice(gpa) };
    }

    /// Release the patterns.
    pub fn deinit(h: *HiddenRefs) void {
        for (h.patterns) |p| h.gpa.free(p);
        h.gpa.free(h.patterns);
        h.* = undefined;
    }

    /// Whether the ref `name` — `full_name` with its namespace — is
    /// hidden: git's `ref_is_hidden`.
    pub fn isHidden(h: *const HiddenRefs, name: []const u8, full_name: []const u8) bool {
        var i = h.patterns.len;
        while (i > 0) {
            i -= 1;
            var match: []const u8 = h.patterns[i];
            var negated = false;
            if (match.len != 0 and match[0] == '!') {
                negated = true;
                match = match[1..];
            }
            var subject = name;
            if (match.len != 0 and match[0] == '^') {
                subject = full_name;
                match = match[1..];
            }
            if (std.mem.startsWith(u8, subject, match) and (subject.len == match.len or subject[match.len] == '/')) return !negated;
        }
        return false;
    }
};

const testing = std.testing;

test "the last pattern that matches decides, by prefix up to a slash" {
    const gpa = testing.allocator;
    var config = try config_mod.Config.parseText(gpa,
        \\[transfer]
        \\    hideRefs = refs/hidden/
        \\[uploadpack]
        \\    hideRefs = !refs/hidden/shown
        \\[receive]
        \\    hideRefs = refs/heads/locked
        \\[transfer]
        \\    hideRefs = ^refs/pull
        \\
    , .local);
    defer config.deinit();
    var upload = try HiddenRefs.load(gpa, &config, .upload_pack);
    defer upload.deinit();
    try testing.expect(upload.isHidden("refs/hidden", "refs/hidden"));
    try testing.expect(upload.isHidden("refs/hidden/a", "refs/hidden/a"));
    try testing.expect(!upload.isHidden("refs/hiddenness", "refs/hiddenness"));
    try testing.expect(!upload.isHidden("refs/hidden/shown/x", "refs/hidden/shown/x"));
    try testing.expect(upload.isHidden("refs/pull/1/head", "refs/pull/1/head"));
    try testing.expect(!upload.isHidden("refs/heads/locked", "refs/heads/locked"));
    var receive = try HiddenRefs.load(gpa, &config, .receive_pack);
    defer receive.deinit();
    try testing.expect(receive.isHidden("refs/heads/locked", "refs/heads/locked"));
    try testing.expect(receive.isHidden("refs/hidden/shown", "refs/hidden/shown"));

    var bare = try config_mod.Config.parseText(gpa, "[transfer]\n\thideRefs\n", .local);
    defer bare.deinit();
    try testing.expectError(error.MalformedValue, HiddenRefs.load(gpa, &bare, .upload_pack));
}
