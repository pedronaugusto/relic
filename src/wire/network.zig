//! How relic reaches a remote: the means a program hands to every operation
//! that starts a conversation with one (clone, fetch, push, ls-remote, a
//! submodule's update, a lazy fetch of missing objects, a bundle URI, Git
//! LFS's transfers and locks).
//!
//! The means are two: `programs`, the permission to run programs (ssh, a
//! remote helper, a credential helper, a proxy command), and `network`, the
//! engines that speak to a remote over a socket of relic's own: HTTP and
//! HTTPS, TCP to a git daemon, Git LFS's HTTP API. relic's core reaches
//! the network only through a `Network`; the package's `relic_net` module
//! holds the one relic makes, over uplink and cloak, and a program that
//! never names it compiles neither. A future means of reaching a remote
//! adds a field here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const program = @import("../process.zig").program;
const url_mod = @import("url.zig");
const connection = @import("connection.zig");
const smart_http = @import("smart_http.zig");

/// What an operation that reaches a remote is given to reach it with.
/// Required in every such operation's options: each program states both,
/// `null` where it grants none.
pub const Means = struct {
    /// The permission to run programs, and the environment they and
    /// relic read: `GIT_SSH_COMMAND`, `GIT_ASKPASS`, the proxies' variables.
    /// `null` runs none: ssh, a remote helper or a configured proxy
    /// command is then `error.ProgramsNotGranted`, and no credential
    /// helper is asked.
    programs: ?program.Programs,
    /// The engines that reach a remote over relic's own sockets:
    /// `relic_net.network`. `null` opens none: an `http://` or `https://`
    /// remote (a bundle URI and Git LFS's API among them) is
    /// `error.HttpUnavailable`, and a `git://` remote reached over TCP is
    /// `error.DaemonUnavailable`; one that `GIT_PROXY_COMMAND` or
    /// `core.gitProxy` reaches is still reached, through its program.
    network: ?*const Network,

    /// No programs and no network: local repositories, bundles and
    /// remotes on the file system alone.
    pub const none: Means = .{ .programs = null, .network = null };
};

/// The engines a `Means` reaches the network through: each a function the
/// engine's module supplies (`relic_net.network`). relic calls them only
/// for a remote they speak to.
pub const Network = struct {
    /// Open a conversation with `service` at an `http(s)` `url`: smart
    /// HTTP, or for upload-pack a dumb server's files, as git's
    /// `check_smart_http` tells them apart.
    connect: *const fn (gpa: Allocator, io: Io, url: url_mod.Url, service: connection.Service, options: smart_http.Options) smart_http.Error!smart_http.Opened,
    /// A dumb server's files under `url` with no request made: an
    /// alternate a dumb server names, asked as its own repository is.
    openFiles: *const fn (gpa: Allocator, io: Io, url: url_mod.Url, options: smart_http.Options) smart_http.Error!smart_http.Files,
    /// One `GET` of an `http(s)` `url`, its body written to `w`: a bundle
    /// URI's download.
    download: *const fn (gpa: Allocator, io: Io, w: *Io.Writer, url: url_mod.Url, options: smart_http.Options) (smart_http.Error || Io.Writer.Error)!void,
    /// A TCP connection to a git daemon's `host` and `port`.
    dial: *const fn (gpa: Allocator, io: Io, host: []const u8, port: u16) connection.Error!*connection.Connection,
    /// Git LFS's HTTP engine, `relic_lfs.api.Engine`, which the core does
    /// not name: relic_lfs reads it back as that type.
    lfs: *const anyopaque,
};
