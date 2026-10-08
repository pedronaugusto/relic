//! Public revwalk namespace. Implementation is in `walk/walk.zig`.

pub const bisect = @import("revwalk/bisect.zig");
pub const describe = @import("revwalk/describe.zig");
pub const mailmap = @import("revwalk/mailmap.zig");
pub const revparse = @import("revwalk/revparse.zig");
pub const shallow = @import("walk/shallow.zig");
pub const Error = @import("walk/walk.zig").Error;
pub const Sort = @import("walk/walk.zig").Sort;
pub const Commit = @import("walk/walk.zig").Commit;
pub const Walk = @import("walk/walk.zig").Walk;
pub const parentsOf = @import("walk/walk.zig").parentsOf;
pub const mergeBases = @import("walk/walk.zig").mergeBases;
pub const Pair = @import("walk/walk.zig").Pair;
pub const Many = @import("walk/walk.zig").Many;
pub const Ancestry = @import("walk/walk.zig").Ancestry;
pub const BaseOptions = @import("walk/walk.zig").BaseOptions;
pub const Virtual = @import("walk/walk.zig").Virtual;
pub const mergeBasesMany = @import("walk/walk.zig").mergeBasesMany;
pub const mergeBase = @import("walk/walk.zig").mergeBase;
pub const isAncestor = @import("walk/walk.zig").isAncestor;
pub const objectwalk = @import("walk/objectwalk.zig");
pub const objectfilter = @import("walk/objectfilter.zig");
