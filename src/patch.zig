//! Public patch namespace. Implementation is in `patch/patch.zig`.

pub const am = @import("patch/am.zig");
pub const mail = @import("mail/mail.zig");
pub const format = @import("patch/format.zig");
pub const apply = @import("patch/apply.zig");
pub const rangediff = @import("patch/rangediff.zig");
pub const Error = @import("patch/patch.zig").Error;
pub const max_patch_bytes = @import("patch/patch.zig").max_patch_bytes;
pub const Options = @import("patch/patch.zig").Options;
pub const Diagnostic = @import("patch/patch.zig").Diagnostic;
pub const Mode = @import("patch/patch.zig").Mode;
pub const mode_file = @import("patch/patch.zig").mode_file;
pub const mode_exec = @import("patch/patch.zig").mode_exec;
pub const mode_symlink = @import("patch/patch.zig").mode_symlink;
pub const mode_gitlink = @import("patch/patch.zig").mode_gitlink;
pub const mode_dir = @import("patch/patch.zig").mode_dir;
pub const isRegular = @import("patch/patch.zig").isRegular;
pub const isSymlink = @import("patch/patch.zig").isSymlink;
pub const isGitlink = @import("patch/patch.zig").isGitlink;
pub const kind = @import("patch/patch.zig").kind;
pub const Fragment = @import("patch/patch.zig").Fragment;
pub const BinaryHunk = @import("patch/patch.zig").BinaryHunk;
pub const Tri = @import("patch/patch.zig").Tri;
pub const FilePatch = @import("patch/patch.zig").FilePatch;
pub const Patch = @import("patch/patch.zig").Patch;
pub const parse = @import("patch/patch.zig").parse;
