//! git's text rules, each in one place: C-style quoting, dates, working-tree encodings, regular expressions, globs, column widths, URL matching and whitespace errors.

pub const c_quote = @import("text/c_quote.zig");
pub const ctype = @import("text/ctype.zig");
pub const date = @import("text/date.zig");
pub const decimal = @import("text/decimal.zig");
pub const encoding = @import("text/encoding.zig");
pub const ere = @import("text/ere.zig");
pub const glob = @import("text/glob.zig");
pub const percent = @import("text/percent.zig");
pub const quote = @import("text/quote.zig");
pub const unicode_width = @import("text/unicode_width.zig");
pub const urlmatch = @import("text/urlmatch.zig");
pub const whitespace = @import("text/whitespace.zig");
