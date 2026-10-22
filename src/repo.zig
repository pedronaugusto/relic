//! Public repo namespace. Implementation is in `repo/repo.zig`.

pub const warning = @import("report.zig").warning;
pub const hooks = @import("hooks/hooks.zig");
pub const program = @import("process.zig").program;
pub const fs = @import("fs.zig").engine;
pub const safe = @import("repo/safe.zig");
pub const ident = @import("repo/ident.zig");
pub const state = @import("repo/state.zig");
pub const rev_parse = @import("repo/rev_parse.zig");
pub const Error = @import("repo/repo.zig").Error;
pub const WriteError = @import("repo/repo.zig").WriteError;
pub const max_discovery_depth = @import("repo/repo.zig").max_discovery_depth;
pub const Diagnostic = @import("repo/repo.zig").Diagnostic;
pub const templateDir = @import("repo/repo.zig").templateDir;
pub const IgnoreSources = @import("repo/repo.zig").IgnoreSources;
pub const Repository = @import("repo/repo.zig").Repository;
pub const Settings = @import("repo/repo.zig").Settings;
pub const TemplateDirError = @import("repo/repo.zig").TemplateDirError;
