//! The repository's published configuration, owned behind a handle of its
//! own so that only `Repository` replaces it.
//! Package plumbing, reached by no public name.
const config = @import("config.zig");
const Allocator = @import("std").mem.Allocator;

/// One allocated configuration, which `create` makes and `destroy` ends.
pub const State = struct {
    value: config.Config,
};

pub fn get(state: *State) *config.Config {
    return &state.value;
}

/// Takes the configuration on success and failure.
pub fn create(value: config.Config) Allocator.Error!*State {
    const owned = value.gpa.create(State) catch |err| {
        var refused = value;
        refused.deinit();
        return err;
    };
    owned.* = .{ .value = value };
    return owned;
}

pub fn destroy(state: *State) void {
    const gpa = state.value.gpa;
    state.value.deinit();
    gpa.destroy(state);
}

/// All errors reported by this namespace.
pub const Error = Allocator.Error;
