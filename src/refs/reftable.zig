//! reftable: the table format, and the stack of tables `tables.list`
//! names, which is the ref store.

pub const table = @import("reftable/table.zig");
pub const stack = @import("reftable/stack.zig");

/// All errors reported by this namespace.
pub const Error = table.Error || stack.Error;
