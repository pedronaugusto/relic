//! git's configuration files, read losslessly and written back the same way.
//!
//! A file is kept as the lines it was made of, so setting one value rewrites
//! one line and leaves every comment, every blank line and every other value's
//! spelling exactly as it was. That is the difference between a configuration
//! writer a person can live with and one that reformats their file.
//!
//! `includeIf` is not optional. A caller that misses one reads the wrong
//! `core.autocrlf` and therefore writes a different blob than git would.

const core = @import("config_core.zig");
pub const userconfig = @import("userconfig.zig");
/// Errors from reading a configuration file.
pub const ParseError = core.ParseError;
/// Errors from asking for a value in a particular shape.
pub const ValueError = core.ValueError;
/// Where a value came from, which is what decides precedence when two files
/// set the same name.
pub const Level = core.Level;
/// One configuration file, parsed into lines.
pub const SourceFile = core.SourceFile;
/// One name and value, with where it came from.
pub const Entry = core.Entry;
/// What `open` is asked to read, in git's own order.
pub const Sources = core.Sources;
/// What an `includeIf` condition needs to know about the repository.
///
/// The caller supplies it, because this package reads no environment and has
/// no opinion about where a repository is. `Repository.open` supplies the
/// first two itself. `Config.open` and `Config.openFile` keep their own
/// copy.
pub const Context = core.Context;
/// How deep `include.path` may nest before it is refused.
pub const max_include_depth = core.max_include_depth;
/// A merged view of every configuration file that applies.
///
/// It holds what the files held when they were read. Nothing reads them
/// again on its own: `isStale` says whether any has changed since, and
/// `Repository.refreshConfig` is what reads them again.
pub const Config = core.Config;
/// A full name split into its parts: `remote.origin.url` is the section
/// `remote`, the subsection `origin` and the name `url`.
pub const FullName = core.FullName;
/// Split `section.name` or `section.subsection.name`.
///
/// The subsection may itself hold dots — `url.https://example.com/.insteadOf`
/// is one — so the split is at the first dot and the last, not at every dot.
pub const splitFullName = core.splitFullName;
/// git's boolean spellings.
pub const parseBool = core.parseBool;
/// git's integer spellings, including the `k`, `m` and `g` size suffixes.
pub const parseInt = core.parseInt;
/// Check `full` the way git checks a name before it writes one, and split
/// it.
///
/// git's `git_config_parse_key`: the variable is what follows the last dot
/// and must begin with a letter; it and the section hold only letters,
/// digits and `-`; the subsection between them may hold anything but a line
/// break, which no header can carry. A section may be empty only when a
/// subsection follows it, as in `.sub.name`.
pub const checkKey = core.checkKey;
/// A value spelled the way git writes one: escaped where it must be, and
/// quoted only where a leading or trailing space, a `;`, a `#` or a
/// carriage return would otherwise be lost. The result is the caller's.
pub const escapeValue = core.escapeValue;
pub const unquote = core.unquote;
