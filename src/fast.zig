//! git's fast-import stream: read into a repository (`importer`, as
//! `git fast-import`), and written from its history (`exporter`, as
//! `git fast-export`).

pub const importer = @import("fast/importer.zig");
pub const exporter = @import("fast/exporter.zig");
