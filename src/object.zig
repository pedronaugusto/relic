//! Public object namespace. Implementation is in `object/object.zig`.

pub const fsck = @import("object/fsck.zig");
pub const Type = @import("object/object.zig").Type;
pub const Header = @import("object/object.zig").Header;
pub const HeaderParseError = @import("object/object.zig").HeaderParseError;
pub const parseHeader = @import("object/object.zig").parseHeader;
pub const Mode = @import("object/object.zig").Mode;
pub const max_tree_depth = @import("object/object.zig").max_tree_depth;
pub const TreeParseError = @import("object/object.zig").TreeParseError;
pub const Tree = @import("object/object.zig").Tree;
pub const Signature = @import("object/object.zig").Signature;
pub const ExtraHeader = @import("object/object.zig").ExtraHeader;
pub const ParseError = @import("object/object.zig").ParseError;
pub const Commit = @import("object/object.zig").Commit;
pub const Tag = @import("object/object.zig").Tag;
