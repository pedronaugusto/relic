//! Everything a remote conversation is made of: URLs and refspecs, the connection and its authentication, the fetch and push commands, and the settings that govern them.

pub const auth = @import("wire/auth.zig");
pub const authorities = if (features.http) @import("wire/authorities.zig") else authorities_without_http;
pub const client_cert = if (features.http) @import("wire/client_cert.zig") else client_cert_without_http;
pub const connection = @import("wire/connection.zig");
pub const credential = @import("wire/credential.zig");
pub const credential_cache_daemon = @import("wire/credential/cache/daemon.zig");
pub const daemon = @import("wire/daemon.zig");
pub const dumb_http = if (features.http) @import("wire/dumb_http.zig") else dumb_http_without_http;
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

/// The features this build has: `http` (uplink and cloak) and `lfs` (strand).
const features = @import("relic_options");

// Without `http` a function whose answer is cloak's does not exist: each
// namespace below is its file's names but those.

/// `authorities` without `http`: its sources and failures, and no `load`, whose trust is cloak's.
const authorities_without_http = struct {
    const full = @import("wire/authorities.zig");
    pub const Error = full.Error;
    pub const Failed = full.Failed;
    pub const Sources = full.Sources;
};

/// `client_cert` without `http`: its files and formats, and neither `load`, whose key is cloak's, nor `keyIsEncrypted`, which only cloak answers.
const client_cert_without_http = struct {
    const full = @import("wire/client_cert.zig");
    pub const Error = full.Error;
    pub const Files = full.Files;
    pub const keyPath = full.keyPath;
    pub const LoadOptions = full.LoadOptions;
    pub const Format = full.Format;
};

/// `dumb_http` without `http`: its errors, which `transport.Error` carries, and no remote, whose files only uplink fetches.
const dumb_http_without_http = struct {
    const full = @import("wire/dumb_http.zig");
    pub const Error = full.Error;
};
