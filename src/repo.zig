//! The front door: open or create a repository and reach everything in it.
//!
//! A repository is a local directory. Nothing here talks to a network or
//! reads a clock. Signing a write needs the caller's `program.Programs`.

const core = @import("repo_core.zig");
pub const hooks = @import("hooks.zig");
pub const program = @import("program.zig");
pub const warning = @import("warning.zig");
pub const fs = @import("fs.zig");
/// Errors from opening, creating or refreshing a repository and reading its objects.
pub const Error = core.Error;
/// Errors from writing a commit or a tag, which may be signed.
pub const WriteError = core.WriteError;
/// How deep `open` walks upwards looking for a `.git`.
pub const max_discovery_depth = core.max_discovery_depth;
/// Caller-owned output for repository and history operations.
pub const Diagnostic = core.Diagnostic;
/// The caller-owned diagnostic used by earlier open callers.
pub const OpenDiagnostic = core.OpenDiagnostic;
/// How a repository is created.
pub const InitOptions = core.InitOptions;
pub const Repository = core.Repository;
