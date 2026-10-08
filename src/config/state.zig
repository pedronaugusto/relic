//! The repository's published configuration, owned behind an opaque
//! handle so that only `Repository` replaces it.
//! Package plumbing, reached by no public name.
const config = @import("config.zig");
const Allocator = @import("std").mem.Allocator;

pub const State = opaque {};

pub fn get(state: *State) *config.Config {
    return @ptrCast(@alignCast(state)); // safe: create allocates each State as aligned Config.
}

/// Takes the configuration on success and failure.
pub fn create(value: config.Config) Allocator.Error!*State {
    const owned = value.gpa.create(config.Config) catch |err| {
        var refused = value;
        refused.deinit();
        return err;
    };
    owned.* = value;
    return @ptrCast(owned); // safe: the opaque owner retains the allocated Config pointer.
}

pub fn destroy(state: *State) void {
    const owned = get(state);
    const gpa = owned.gpa;
    owned.deinit();
    gpa.destroy(owned);
}

/// All errors reported by this namespace.
pub const Error = Allocator.Error;
