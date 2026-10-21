//! Public commit namespace. Implementation is in `commit/commit.zig`.

pub const notes = @import("commit/notes.zig");
pub const todo = @import("commit/todo.zig");
pub const branch = @import("commit/branch.zig");
pub const rebase = @import("rebase/rebase.zig");
pub const replay = @import("commit/replay.zig");
pub const history = @import("commit/history.zig");
pub const sequencer = @import("commit/sequencer.zig");
pub const merging = @import("commit/merging.zig");
pub const stash = @import("commit/stash.zig");
pub const in_progress = @import("commit/in_progress.zig");
pub const message = @import("object/message.zig");
pub const trailer = @import("object/trailer.zig");
pub const head = @import("repo/head.zig");
pub const reset = @import("commit/reset.zig");
pub const signing = @import("object/signing.zig");
pub const hooks = @import("commit/commit_hooks.zig");
pub const Error = @import("commit/commit.zig").Error;
pub const Options = @import("commit/commit.zig").Options;
pub const Request = @import("commit/commit.zig").Request;
pub const Outcome = @import("commit/commit.zig").Outcome;
pub const commit = @import("commit/commit.zig").commit;
pub const template = @import("commit/commit.zig").template;
pub const templateUntouched = @import("commit/commit.zig").templateUntouched;
