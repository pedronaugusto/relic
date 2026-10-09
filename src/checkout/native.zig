//! Native content filters supplied by an operation's owner. Checkout owns the
//! conversion protocol; a provider owns its format, store and fetch policy.
const Self = @This();
const std = @import("std");
const config = @import("../config/config.zig");
const fs = @import("../fs.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Error = config.ValueError || config.ParseError || Allocator.Error || Io.Cancelable || fs.ReadSizedError ||
    Io.Reader.ShortError || Io.File.Reader.Error || Io.File.Writer.Error ||
    Io.File.OpenError || Io.File.StatError || Io.File.ReadPositionalError ||
    Io.Dir.CreateDirPathError || Io.Dir.RenameError || Io.Dir.ReadFileAllocError || error{
    NameTooLong,
    NativeFilterExtensionUnsupported,
    NativeFilterFetchFailed,
    NativeFilterObjectMismatch,
};

/// A native filter can name an object without installing it during status.
pub const Storing = enum { store, hash_only };

/// Bytes borrow the input, the call allocator, or the session until its
/// deinit. An open
/// file belongs to the caller. Delayed content is delivered by `nextReady`.
pub const Content = union(enum) { bytes: []const u8, file: Io.File, delayed };
pub const Ready = struct { path: []const u8, content: Content };

/// Identity of content a native filter could not make available. The identity
/// is opaque to checkout; its interpretation belongs to the provider.
pub const Object = struct { id: []const u8, size: u64 };
pub const Observer = struct {
    context: *anyopaque,
    missing_fn: *const fn (*anyopaque, []const u8, Object, bool) Allocator.Error!void,

    pub fn missing(o: Observer, path: []const u8, object: Object, declined: bool) Allocator.Error!void {
        return o.missing_fn(o.context, path, object, declined);
    }
};

/// The commands configured for a named filter. The native provider decides
/// whether these name its own implementation; custom commands remain programs.
pub const Commands = struct {
    clean: ?[]const u8 = null,
    smudge: ?[]const u8 = null,
    process: ?[]const u8 = null,
};

pub const SessionOptions = struct { wt: Io.Dir, observer: ?Observer = null };
pub const CleanInput = struct { bytes: []const u8, storing: Storing = .store };
pub const FileInput = struct { path: []const u8, storing: Storing = .store };
pub const SmudgeInput = struct { path: []const u8, bytes: []const u8, can_delay: bool = false };

/// One operation's native filter state. Opening and releasing it is the
/// provider's responsibility; checkout borrows it only until `deinit(io)`.
pub const Session = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const Error = Self.Error;
    pub const VTable = struct {
        clean: *const fn (Allocator, Io, *anyopaque, CleanInput) Self.Error![]const u8,
        clean_file: *const fn (Allocator, Io, *anyopaque, FileInput) Self.Error![]const u8,
        smudge: *const fn (Allocator, Io, *anyopaque, SmudgeInput) Self.Error!Content,
        canonical: *const fn (Allocator, *anyopaque, []const u8) Self.Error!?[]const u8,
        next_ready: *const fn (Allocator, Io, *anyopaque) Self.Error!?Ready,
        fallbacks: *const fn (*const anyopaque) u32,
        deinit: *const fn (Io, *anyopaque) void,
    };

    pub fn clean(s: Session, gpa: Allocator, io: Io, input: CleanInput) Self.Error![]const u8 {
        return s.vtable.clean(gpa, io, s.context, input);
    }
    pub fn cleanFile(s: Session, gpa: Allocator, io: Io, input: FileInput) Self.Error![]const u8 {
        return s.vtable.clean_file(gpa, io, s.context, input);
    }
    pub fn smudge(s: Session, gpa: Allocator, io: Io, input: SmudgeInput) Self.Error!Content {
        return s.vtable.smudge(gpa, io, s.context, input);
    }
    pub fn canonical(s: Session, gpa: Allocator, bytes: []const u8) Self.Error!?[]const u8 {
        return s.vtable.canonical(gpa, s.context, bytes);
    }
    pub fn nextReady(s: Session, gpa: Allocator, io: Io) Self.Error!?Ready {
        return s.vtable.next_ready(gpa, io, s.context);
    }
    pub fn fallbacks(s: Session) u32 {
        return s.vtable.fallbacks(s.context);
    }
    pub fn deinit(s: Session, io: Io) void {
        s.vtable.deinit(io, s.context);
    }
};

/// An owned native driver installed in a filter collection by a higher layer.
/// The provider's directories are borrowed for the collection's lifetime.
pub const Driver = struct {
    name: []const u8,
    context: *anyopaque,
    vtable: *const VTable,

    pub const Error = Self.Error;
    pub const VTable = struct {
        accepts: *const fn (*const anyopaque, Commands) bool,
        open: *const fn (Allocator, Io, *anyopaque, SessionOptions) Self.Error!Session,
        /// Redirect an isolated operation's writes to its private store.
        retarget: *const fn (*anyopaque, Io.Dir) void,
        deinit: *const fn (Io, *anyopaque) void,
    };

    pub fn accepts(d: Driver, commands: Commands) bool {
        return d.vtable.accepts(d.context, commands);
    }
    pub fn open(d: Driver, gpa: Allocator, io: Io, options: SessionOptions) Self.Error!Session {
        return d.vtable.open(gpa, io, d.context, options);
    }
    pub fn retarget(d: Driver, dir: Io.Dir) void {
        d.vtable.retarget(d.context, dir);
    }
    pub fn deinit(d: Driver, io: Io) void {
        d.vtable.deinit(io, d.context);
    }
};

/// A native provider selected by the caller before loading a collection.
/// The optional context is borrowed only for `load`, never by the result.
pub const Provider = struct {
    context: ?*const anyopaque = null,
    load_fn: *const fn (Allocator, Io, ?*const anyopaque, *const config.Config, LoadOptions) Self.Error!Driver,

    pub fn load(p: Provider, gpa: Allocator, io: Io, settings: *const config.Config, options: LoadOptions) Self.Error!Driver {
        return p.load_fn(gpa, io, p.context, settings, options);
    }
};

pub const LoadOptions = struct {
    common_dir: Io.Dir,
    work_dir: ?Io.Dir = null,
    config_text: ?[]const u8 = null,
    skip_smudge: bool = false,
};
