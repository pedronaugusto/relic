//! Everything a remote conversation is made of: URLs and refspecs, the connection and its authentication, the fetch and push commands, and the settings that govern them.

pub const auth = @import("wire/auth.zig");
pub const clientcert = @import("wire/clientcert.zig");
pub const connection = @import("wire/connection.zig");
pub const credential = @import("wire/credential.zig");
pub const fetchpack = @import("wire/fetchpack.zig");
pub const filterspec = @import("wire/filterspec.zig");
pub const hidden = @import("wire/hidden.zig");
pub const httpsettings = @import("wire/httpsettings.zig");
pub const policy = @import("wire/policy.zig");
pub const promisors = @import("wire/promisors.zig");
pub const protocol = @import("wire/protocol.zig");
pub const refspec = @import("wire/refspec.zig");
pub const remote = @import("wire/remote.zig");
pub const sendpack = @import("wire/sendpack.zig");
pub const sideband = @import("wire/sideband.zig");
pub const smarthttp = @import("wire/smarthttp.zig");
pub const ssh = @import("wire/ssh.zig");
pub const url = @import("wire/url.zig");
