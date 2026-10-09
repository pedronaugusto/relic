//! git's text rules, each in one place: C-style quoting, dates, working-tree encodings, regular expressions, globs and column widths.

pub const cquote = @import("text/cquote.zig");
pub const date = @import("text/date.zig");
pub const encoding = @import("text/encoding.zig");
pub const ere = @import("text/ere.zig");
pub const glob = @import("text/glob.zig");
pub const unicodewidth = @import("text/unicodewidth.zig");
