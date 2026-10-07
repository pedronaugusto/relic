const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const hash = @import("../hash.zig");
const Oid = hash.Oid;
const Kind = hash.Kind;
const object = @import("../object.zig");
const fs = @import("../repo/fs.zig");
const reftable = @import("reftable.zig");
const reflog = @import("reflog.zig");
const hooks = @import("../repo/hooks.zig");
const policy = @import("reftablestack/policy.zig");
/// The header `packed-refs` carries, with the space before the newline that
/// is in git's source and in no document.
pub const packed_header = "# pack-refs with: peeled fully-peeled sorted \n";

/// How deep a chain of symbolic refs may go. git's own cap.
pub const max_symbolic_depth: u8 = 5;

/// Errors from reading refs.
pub const ReadError = error{
    /// A loose ref file that is neither an object name nor `ref: <name>`.
    MalformedRef,
    /// A `packed-refs` line that is neither a ref nor a peel nor a comment.
    MalformedPackedRefs,
    /// A symbolic ref chain longer than `max_symbolic_depth`, or one that
    /// came back to a name it had already been through.
    SymbolicRefLoop,
    /// A ref name git would not accept — including one ending in `.lock`,
    /// which is the name of the file that blocks every update to the ref
    /// without it.
    InvalidRefName,
} || Allocator.Error || Io.Dir.ReadFileAllocError || Io.Dir.OpenError || Io.Dir.Iterator.Error ||
    policy.Error;

/// Errors from a transaction.
pub const TransactionError = error{
    /// The ref's current value is not the one the edit expected. Nothing has
    /// changed.
    ExpectedValueMismatch,
    /// The ref exists and the edit required that it did not.
    RefAlreadyExists,
    /// The ref does not exist and the edit required that it did.
    RefNotFound,
    /// Another writer holds `<ref>.lock`. Nothing has changed and the lock
    /// is exactly as it was found.
    LockHeld,
    /// The same ref was named twice in one transaction.
    DuplicateEdit,
    /// A ref name and a directory of refs cannot both exist:
    /// `refs/heads/a` and `refs/heads/a/b` are the same path.
    RefNameConflict,
    /// A name that reaches another worktree's own refs,
    /// `main-worktree/<name>` or `worktrees/<id>/<name>`: they are read
    /// from any worktree, and written by a store opened in that one.
    OtherWorktreeRef,
} || ReadError || fs.CommitError || fs.LockError || reflog.AppendError ||
    Io.Dir.DeleteFileError || Io.Dir.CreateDirPathError || hooks.Error || Io.Dir.WriteFileError;

/// Errors from laying down a new ref store's directories.
pub const CreateError = Io.Dir.CreateDirPathError || Io.Dir.WriteFileError;

/// Where a repository's refs are kept.
pub const Format = enum {
    /// Loose files under `refs/` and `packed-refs`.
    files,
    /// A reftable stack under `reftable/`, which `extensions.refStorage`
    /// names.
    reftable,

    /// The format's name in `extensions.refStorage`.
    pub fn name(format: Format) []const u8 {
        return switch (format) {
            .files => "files",
            .reftable => "reftable",
        };
    }

    /// The format `extensions.refStorage` names, in any case, or `null`.
    pub fn parse(text: []const u8) ?Format {
        inline for (comptime std.enums.values(Format)) |format| {
            if (std.ascii.eqlIgnoreCase(text, format.name())) return format;
        }
        return null;
    }
};

/// Peels an object name for a ref about to be written, so that a reftable
/// can record what an annotated tag points at beside it, as git's does.
/// `Repository.beginRefs` supplies one.
pub const Peeler = struct {
    context: *anyopaque,
    /// The object `oid` peels to when it is an annotated tag, or `null`
    /// when it is not one or cannot be read.
    peel: *const fn (io: Io, context: *anyopaque, oid: Oid) ?Oid,
};

/// What a ref points at.
pub const Ref = union(enum) {
    /// An object name.
    direct: Oid,
    /// Another ref's name, which is what `HEAD` usually holds. Owned by
    /// whatever produced it.
    symbolic: []const u8,
};

/// A ref with its name, as `list` hands them back.
pub const Named = struct {
    /// Owned by the listing.
    name: []const u8,
    target: Ref,
    /// The object an annotated tag points at, when `packed-refs` carried a
    /// peel line for it.
    peeled: ?Oid = null,
    /// Whether the ref was found loose rather than in `packed-refs`.
    loose: bool,
};

/// A fully resolved ref: the name it ended at and the object it points to.
pub const Resolved = struct {
    /// The last name in the chain. Owned by the caller.
    name: []const u8,
    oid: Oid,
};

/// What an edit requires the ref's current value to be.
pub const Expected = union(enum) {
    /// Whatever it is.
    any,
    /// It must not exist.
    must_not_exist,
    /// It must exist, with any value.
    must_exist,
    /// It must be exactly this.
    matches: Oid,
};

/// What a log entry a transaction writes says.
pub const LogMessage = struct {
    who: object.Signature,
    /// The text after the tab, which the transaction collapses as git
    /// does: every run of whitespace one space, none at either end. Empty
    /// writes no tab.
    message: []const u8 = "",
    policy: reflog.Policy = .standard,
};

/// A ref a listing found and could not take as one: git's
/// `REF_ISBROKEN`. It is not in `entries`, and no read gives it a value;
/// one whose name is still safe can be deleted by that name.
pub const Broken = struct {
    /// Owned by the listing.
    name: []const u8,
    why: Why,

    pub const Why = enum {
        /// A name `names.checkFormat` refuses and `names.isSafe` takes:
        /// listed, never read, and deletable.
        bad_name,
        /// A name that reaches out of the ref directories, on which git
        /// dies: listed, and neither read nor deleted.
        unsafe_name,
        /// A file whose content is no ref, which shadows anything packed
        /// under its name.
        bad_content,
    };
};

/// A list of refs, loose entries shadowing packed ones.
pub const Listing = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator.State,
    entries: []Named,
    /// What was found and is not a ref git would read, sorted by name.
    broken: []Broken = &.{},

    /// Release the listing and everything in it.
    pub fn deinit(listing: *Listing) void {
        var arena = listing.arena.promote(listing.gpa);
        arena.deinit();
        listing.* = undefined;
    }

    /// The entry named `name`, or `null`. A linear walk over a sorted
    /// list; the lists are small enough that a bisection would only make
    /// the code longer.
    pub fn find(listing: *const Listing, name: []const u8) ?Named {
        for (listing.entries) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }
};

/// One ref's change.
pub const Edit = struct {
    /// Owned by the transaction.
    name: []const u8,
    /// `null` deletes the ref.
    new: ?Ref,
    expected: Expected,
    /// Filled in by `prepare`.
    old: ?Oid = null,
    lock: ?fs.LockFile = null,
    lock_buffer: []u8 = &.{},
    /// Whether a deleted ref is in `packed-refs`, read under its lock,
    /// whether or not it is loose too: what decides whether the packed
    /// file has to be rewritten.
    was_packed: bool = false,
    /// Whether to go through the ref to the one it names, when it is
    /// symbolic.
    deref: bool = true,
    /// Set by `prepare` on a symbolic ref an update went through, and on
    /// `HEAD` when the branch it names moves: the ref is locked and its
    /// log gains the line, and its own value is left alone. The line's
    /// values are those of the edit at `via`.
    via: ?usize = null,
    /// This edit's own log text, owned: `EditOptions.message`.
    message: ?[]const u8 = null,
};
