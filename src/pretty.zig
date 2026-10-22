//! Public pretty namespace. Implementation is in `pretty/pretty.zig`.

pub const Error = @import("pretty/pretty.zig").Error;
pub const CommitInputs = @import("pretty/pretty.zig").CommitInputs;
pub const Context = @import("pretty/pretty.zig").Context;
pub const Colors = @import("pretty/pretty.zig").Colors;
pub const Decorations = @import("pretty/pretty.zig").Decorations;
pub const sanitizedSubject = @import("pretty/pretty.zig").sanitizedSubject;
pub const formatCommit = @import("pretty/pretty.zig").formatCommit;
pub const configuredDateMode = @import("pretty/pretty.zig").configuredDateMode;
pub const Reencoded = @import("pretty/pretty.zig").Reencoded;
pub const reencodeCommit = @import("pretty/pretty.zig").reencodeCommit;
pub const outputEncoding = @import("pretty/pretty.zig").outputEncoding;
pub const toOutput = @import("pretty/pretty.zig").toOutput;
pub const log = @import("pretty/log.zig");
pub const refs = @import("pretty/refs.zig");
pub const shortlog = @import("pretty/shortlog.zig");
