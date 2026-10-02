//! A remote, open: the one thing a fetch, a clone or a push talks to.
//!
//! A URL decides the transport. A path or a `file://` URL is another
//! repository on this machine, opened in process by `local.zig`; `ssh://`
//! and the scp-like form start the person's `ssh` through `ssh.zig`; and
//! `http://` and `https://` are git's smart HTTP protocol through
//! `smarthttp.zig`. The last two are conversations with the remote's own
//! `git-upload-pack` or `git-receive-pack`, and the protocol above them —
//! the refs, the negotiation, the pack — is the same for both. A `Session`
//! hides which of the three it is from the operations above.

const core = @import("transport_core.zig");
pub const remote = @import("remote.zig");
pub const url = @import("url.zig");
pub const refspec = @import("refspec.zig");
pub const fetch = @import("fetch.zig");
pub const fetchpack = @import("fetchpack.zig");
pub const clone = @import("clone.zig");
pub const push = @import("push.zig");
pub const sendpack = @import("sendpack.zig");
pub const local = @import("local.zig");
pub const ssh = @import("ssh.zig");
pub const smarthttp = @import("smarthttp.zig");
pub const httpclient = @import("httpclient.zig");
pub const tls = @import("tls/root.zig");
pub const clientcert = @import("clientcert.zig");
pub const httpauth = @import("httpauth.zig");
pub const httpsettings = @import("httpsettings.zig");
pub const credential = @import("credential.zig");
pub const auth = @import("auth.zig");
pub const protocol = @import("protocol.zig");
pub const connection = @import("connection.zig");
pub const pktline = @import("pktline.zig");
pub const sideband = @import("sideband.zig");
pub const uploadpack = @import("uploadpack.zig");
pub const objectwalk = @import("objectwalk.zig");
pub const objectfilter = @import("objectfilter.zig");
pub const partial = @import("partial.zig");
pub const filterspec = @import("filterspec.zig");
pub const progress = @import("progress.zig");
/// Which service a session talks to.
pub const Service = core.Service;
/// Errors from opening and using a remote.
pub const Error = core.Error;
/// How a remote is reached.
pub const Options = core.Options;
/// Whether `config` leaves protocol v2 on: `protocol.version` unset or 2.
pub const wantsV2 = core.wantsV2;
/// An open remote.
pub const Session = core.Session;
