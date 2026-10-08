//! Public config namespace. Implementation is in `config/config.zig`.

pub const user = @import("config/userconfig.zig");
pub const ParseError = @import("config/config.zig").ParseError;
pub const ValueError = @import("config/config.zig").ValueError;
pub const Level = @import("config/config.zig").Level;
pub const SourceFile = @import("config/config.zig").SourceFile;
pub const Entry = @import("config/config.zig").Entry;
pub const Sources = @import("config/config.zig").Sources;
pub const Context = @import("config/config.zig").Context;
pub const max_include_depth = @import("config/config.zig").max_include_depth;
pub const Config = @import("config/config.zig").Config;
pub const FullName = @import("config/config.zig").FullName;
pub const splitFullName = @import("config/config.zig").splitFullName;
pub const parseBool = @import("config/config.zig").parseBool;
pub const parseInt = @import("config/config.zig").parseInt;
pub const checkKey = @import("config/config.zig").checkKey;
pub const escapeValue = @import("config/config.zig").escapeValue;
pub const unquote = @import("config/config.zig").unquote;
pub const CheckKeyError = @import("config/config.zig").CheckKeyError;
pub const UnquoteError = @import("config/config.zig").UnquoteError;
pub const Error = @import("config/config.zig").Error;
