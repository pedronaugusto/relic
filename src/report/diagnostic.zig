//! Caller-owned repository and write output. Only this owner allocates,
//! clears and releases its copies; each entry point starts a fresh output.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// A refused setting or signing stderr, owned by the caller.
/// Initialize with `init` and release with `deinit`. Each operation clears it;
/// its text stays valid until the next operation using it or `deinit`, even
/// after failure or after the repository is closed.
pub const Diagnostic = struct {
    gpa: Allocator,
    /// The full setting that was refused, or an empty string.
    unsupported_setting: []const u8 = "",
    /// Standard error from a failed signing program, or an empty string.
    signing_stderr: []const u8 = "",

    /// Use this allocator for the diagnostic's own copy of the setting.
    pub fn init(gpa: Allocator) Diagnostic {
        return .{ .gpa = gpa };
    }

    /// Release the diagnostic's copies.
    pub fn deinit(diagnostic: *Diagnostic) void {
        diagnostic.clear();
        diagnostic.* = undefined;
    }

    fn clear(diagnostic: *Diagnostic) void {
        if (diagnostic.unsupported_setting.len != 0) diagnostic.gpa.free(diagnostic.unsupported_setting);
        diagnostic.unsupported_setting = "";
        if (diagnostic.signing_stderr.len != 0) diagnostic.gpa.free(diagnostic.signing_stderr);
        diagnostic.signing_stderr = "";
    }

    fn set(diagnostic: *Diagnostic, text: []const u8) Allocator.Error!void {
        const owned = try diagnostic.gpa.dupe(u8, text);
        diagnostic.clear();
        diagnostic.unsupported_setting = owned;
    }
};

pub fn reset(output: ?*Diagnostic) void {
    if (output) |d| d.clear();
}

pub fn refuse(output: ?*Diagnostic, setting: []const u8) Allocator.Error!void {
    if (output) |d| try d.set(setting);
}

pub fn signingFailure(output: ?*Diagnostic, stderr: []const u8) Allocator.Error!void {
    if (output) |d| d.signing_stderr = try d.gpa.dupe(u8, stderr);
}
