//! Public pretty namespace. Implementation is in `pretty/pretty.zig`.

pub const Error = @import("pretty/pretty.zig").Error;
pub const CommitInputs = @import("pretty/pretty.zig").CommitInputs;
pub const Context = @import("pretty/pretty.zig").Context;
pub const Decorations = @import("pretty/pretty.zig").Decorations;
pub const sanitizedSubject = @import("pretty/pretty.zig").sanitizedSubject;
pub const formatCommit = @import("pretty/pretty.zig").formatCommit;
pub const refs = @import("pretty/refs.zig");
pub const shortlog = @import("pretty/shortlog.zig");
