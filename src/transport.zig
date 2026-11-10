//! Public transport namespace. Implementation is in `transport/transport.zig`.

pub const filter_spec = @import("wire.zig").filter_spec;
pub const partial = @import("transport/partial.zig");
pub const side_band = @import("wire.zig").side_band;
pub const http_settings = @import("wire.zig").http_settings;
pub const hidden = @import("wire.zig").hidden;
pub const promisors = @import("wire.zig").promisors;
pub const push = @import("transport/push.zig");
pub const clone = @import("transport/clone.zig");
pub const fetch = @import("transport/fetch.zig");
pub const pull = @import("transport/pull.zig");
pub const backfill = @import("transport/backfill.zig");
pub const refspec = @import("wire.zig").refspec;
pub const remote = @import("wire.zig").remote;
pub const url = @import("wire.zig").url;
pub const fetch_pack = @import("wire.zig").fetch_pack;
pub const send_pack = @import("wire.zig").send_pack;
pub const local = @import("transport/local.zig");
pub const ssh = @import("wire.zig").ssh;
pub const smart_http = if (features.http) @import("wire.zig").smart_http else smart_http_without_http;
pub const credential = @import("wire.zig").credential;
pub const credential_cache_daemon = @import("wire.zig").credential_cache_daemon;
pub const auth = @import("wire.zig").auth;
pub const protocol = @import("wire.zig").protocol;
pub const connection = @import("wire.zig").connection;
pub const pkt_line = @import("codec.zig").pkt_line;
pub const upload_pack = @import("transport/upload_pack.zig");
pub const receive_pack = @import("transport/receive_pack.zig");
pub const bundle = @import("transport/bundle.zig");
pub const bundle_uri = @import("transport/bundle/uri.zig");
pub const progress = @import("report.zig").progress;
pub const remote_helper = @import("transport/remote_helper.zig");
pub const policy = @import("wire.zig").policy;
pub const Error = @import("transport/transport.zig").Error;
pub const Options = @import("transport/transport.zig").Options;
pub const wantsV2 = @import("transport/transport.zig").wantsV2;
pub const Session = @import("transport/transport.zig").Session;
pub const download = @import("transport/transport.zig").download;

/// The features this build has: `http` (uplink and cloak) and `lfs` (strand).
const features = @import("relic_options");

/// `smart_http` without `http`: every name of its file but a dumb server's
/// `Files` and the `Early` requests they send, which only uplink makes.
/// `connect` and `download` are `error.HttpUnavailable`.
const smart_http_without_http = struct {
    const full = @import("wire.zig").smart_http;
    pub const max_dumb_file_bytes = full.max_dumb_file_bytes;
    pub const Error = full.Error;
    pub const Options = full.Options;
    pub const user_agent = full.user_agent;
    pub const Opened = full.Opened;
    pub const connect = full.connect;
    pub const download = full.download;
};
