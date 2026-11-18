//! What `check-offline`'s programs reference: every function of a root's
//! namespaces, three levels down, and the remote entry points a namespace
//! holds as a type's method.
const std = @import("std");

/// Every function in `T`'s namespaces and theirs, but those named in
/// `skip`.
pub fn all(comptime T: type, comptime skip: []const []const u8) void {
    @setEvalBranchQuota(50_000_000);
    refNamespace(T, skip, 3);
}

fn refNamespace(comptime T: type, comptime skip: []const []const u8, comptime depth: usize) void {
    if (depth == 0) return;
    inline for (@typeInfo(T).@"struct".decl_names) |name| {
        if (comptime isSkipped(skip, name)) continue;
        const value = @field(T, name);
        if (@TypeOf(value) == type) {
            if (comptime isNamespace(value)) refNamespace(value, skip, depth - 1);
        } else if (@typeInfo(@TypeOf(value)) == .@"fn") {
            _ = &value;
        }
    }
}

/// A struct with no fields: a namespace, whose functions are entry points.
fn isNamespace(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| s.field_names.len == 0 and !s.is_tuple,
        else => false,
    };
}

fn isSkipped(comptime skip: []const []const u8, comptime name: []const u8) bool {
    for (skip) |s| if (std.mem.eql(u8, s, name)) return true;
    return false;
}
