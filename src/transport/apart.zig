//! What one of several fetches or clones run beside each other keeps apart
//! from the rest, and hands to the caller's own once it is done: its
//! warnings and a refused credential. The progress and the prompt answer
//! on the caller's task, so the work beside runs without them.

const std = @import("std");
const Allocator = std.mem.Allocator;

const auth = @import("../wire.zig").auth;
const warning = @import("../report.zig").warning;

pub const Apart = struct {
    warnings: ?warning.Warnings = null,
    auth_failure: auth.Failure = .{},

    /// `shared`, a `fetch.Options` or `clone.Options`, with this one's own
    /// lists in place of the caller's.
    pub fn options(apart: *Apart, gpa: Allocator, shared: anytype) Allocator.Error!@TypeOf(shared) {
        var own = shared;
        if (shared.warnings != null) {
            if (apart.warnings == null) apart.warnings = .init(gpa);
            own.warnings = &apart.warnings.?;
        }
        if (shared.auth_failure != null) own.auth_failure = &apart.auth_failure;
        own.progress = null;
        own.prompt = null;
        return own;
    }

    /// Hand what was kept to `shared`'s lists: every warning, and the
    /// refusal when the caller has none yet.
    pub fn merge(apart: *Apart, shared: anytype) Allocator.Error!void {
        if (apart.warnings) |*own| {
            for (own.items.items) |item| try warning.note(shared.warnings, item);
            own.deinit();
            apart.warnings = null;
        }
        if (shared.auth_failure) |failure| if (failure.reason == .none and apart.auth_failure.reason != .none) {
            failure.* = apart.auth_failure;
            apart.auth_failure = .{};
        };
    }

    pub fn deinit(apart: *Apart) void {
        if (apart.warnings) |*own| own.deinit();
        apart.auth_failure.deinit();
        apart.* = undefined;
    }
};
