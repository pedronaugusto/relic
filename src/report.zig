//! What operations hand back besides their result: caller-owned diagnostics, progress as a long operation runs, and the warnings git would have printed.

pub const diagnostic = @import("report/diagnostic.zig");
pub const progress = @import("report/progress.zig");
pub const warning = @import("report/warning.zig");
