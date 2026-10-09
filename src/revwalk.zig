//! Public revwalk namespace. Implementation is in `walk.zig`.

pub const bisect = @import("revwalk/bisect.zig");
pub const describe = @import("revwalk/describe.zig");
pub const mailmap = @import("revwalk/mailmap.zig");
pub const revparse = @import("revwalk/revparse.zig");
pub const shallow = @import("walk/shallow.zig");
pub const Error = @import("walk.zig").Error;
pub const Sort = @import("walk.zig").Sort;
pub const Commit = @import("walk.zig").Commit;
pub const Walk = @import("walk.zig").Walk;
pub const parentsOf = @import("walk.zig").parentsOf;
pub const mergeBases = @import("walk.zig").mergeBases;
pub const Pair = @import("walk.zig").Pair;
pub const Many = @import("walk.zig").Many;
pub const Ancestry = @import("walk.zig").Ancestry;
pub const BaseOptions = @import("walk.zig").BaseOptions;
pub const Virtual = @import("walk.zig").Virtual;
pub const mergeBasesMany = @import("walk.zig").mergeBasesMany;
pub const mergeBase = @import("walk.zig").mergeBase;
pub const isAncestor = @import("walk.zig").isAncestor;
pub const objectwalk = @import("walk/objectwalk.zig");
pub const objectfilter = @import("walk/objectfilter.zig");
