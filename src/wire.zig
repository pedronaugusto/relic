//! Everything a remote conversation is made of: URLs and refspecs, the connection and its authentication, the fetch and push commands, and the settings that govern them.

pub const auth = @import("wire/auth.zig");
pub const authorities = @import("wire/authorities.zig");
pub const client_cert = @import("wire/client_cert.zig");
pub const connection = @import("wire/connection.zig");
pub const credential = @import("wire/credential.zig");
pub const credential_cache_daemon = @import("wire/credential/cache/daemon.zig");
pub const dumb_http = @import("wire/dumb_http.zig");
pub const fetch_pack = @import("wire/fetch_pack.zig");
pub const filter_spec = @import("wire/filter_spec.zig");
pub const hidden = @import("wire/hidden.zig");
pub const http_settings = @import("wire/http_settings.zig");
pub const pinned_key = @import("wire/pinned_key.zig");
pub const policy = @import("wire/policy.zig");
pub const promisors = @import("wire/promisors.zig");
pub const protocol = @import("wire/protocol.zig");
pub const refspec = @import("wire/refspec.zig");
pub const remote = @import("wire/remote.zig");
pub const send_pack = @import("wire/send_pack.zig");
pub const side_band = @import("wire/side_band.zig");
pub const smart_http = @import("wire/smart_http.zig");
pub const ssh = @import("wire/ssh.zig");
pub const url = @import("wire/url.zig");
