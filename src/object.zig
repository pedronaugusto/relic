//! The four object types, as bytes.
//!
//! Nothing here touches the disk. Every `parse` borrows from the bytes it is
//! given and every `write` appends to a writer the caller owns, so an object
//! may be built in memory, named, and only then stored.

const core = @import("object_core.zig");
pub const fsck = @import("fsck.zig");
/// What an object is.
pub const Type = core.Type;
/// An object's type and the length of its content, which is what a caller
/// needs far more often than the content.
pub const Header = core.Header;
/// Errors from reading a loose object's `"<type> <size>\0"` header.
pub const HeaderParseError = core.HeaderParseError;
/// Read `"<type> <size>\0"` from the front of `bytes`.
///
/// Returns the header and how many bytes it took, so the content follows at
/// that offset. A size with a leading zero is refused, because git writes none
/// and accepting one gives an object two spellings.
pub const parseHeader = core.parseHeader;
/// The five modes a tree entry may carry.
///
/// git has written `100664` and bare `40000` in the past and `fsck` still
/// reports them; `Mode.parse` accepts what git accepts and `raw` writes what
/// git writes.
pub const Mode = core.Mode;
/// Errors from reading a tree object.
pub const TreeParseError = core.TreeParseError;
/// A tree object: a sorted list of `<octal mode> SP <name> NUL <raw hash>`.
///
/// Borrows the bytes it was parsed from. The entry order is the object's own
/// and is never re-sorted on the way out, because the order is part of the
/// name.
pub const Tree = core.Tree;
/// Who did something, and when.
///
/// The time is the caller's: nothing in this package reads a clock, so a test
/// is deterministic and a replay exact.
pub const Signature = core.Signature;
/// A header a commit or a tag carries that this package does not interpret.
///
/// `gpgsig` and `mergetag` are the ones git writes. The value is the unfolded
/// bytes: git prefixes every continuation line with a space, including the
/// empty ones, and `Commit.parse` takes that space off.
pub const ExtraHeader = core.ExtraHeader;
/// Errors from reading a commit or a tag.
pub const ParseError = core.ParseError;
/// A commit object.
///
/// `parse` allocates the parent list and the extra headers and borrows
/// everything else from the object's bytes, so the bytes must outlive it.
pub const Commit = core.Commit;
/// An annotated tag object.
///
/// A lightweight tag is a ref and no object at all; this is the other kind.
pub const Tag = core.Tag;
