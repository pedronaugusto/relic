//! Who an author or committer is, as git's `ident.c` decides it for a
//! commit: `GIT_AUTHOR_NAME` and its siblings, then `author.*` or
//! `committer.*`, then `user.*`, then what the machine says, which only
//! the caller knows. Under `user.useConfigOnly` the machine is never
//! asked: a name or an email the configuration and the environment do not
//! give is a refusal.

const object = @import("../object/object.zig");
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

const config_mod = @import("../config/config.zig");
const gitdate = @import("../text.zig").date;

/// Whose identity: the commit's author or its committer.
pub const Role = enum { author, committer };

/// What git would find on the machine for an identity nothing else gives:
/// the account's full name, and `user@host`, or `EMAIL`. `bogus` marks a
/// name or an address git could not make out, which a strict identity
/// refuses.
pub const Machine = struct {
    name: ?[]const u8 = null,
    name_bogus: bool = false,
    email: ?[]const u8 = null,
    email_bogus: bool = false,
};

/// The time an identity is stamped with when `GIT_<ROLE>_DATE` is not set.
pub const Now = struct {
    secs: i64,
    offset_minutes: i32 = 0,
};

/// Errors from deciding an identity.
pub const Error = errors: {
    break :errors error{
        /// `user.useConfigOnly` and no email from the configuration or the
        /// environment: "no email was given and auto-detection is disabled".
        NoEmailGiven,
        /// `user.useConfigOnly` and no name: "no name was given and
        /// auto-detection is disabled".
        NoNameGiven,
        /// The machine's address is one git could not make out: "unable to
        /// auto-detect email address".
        EmailNotDetected,
        /// The machine's name is one git could not make out.
        NameNotDetected,
        /// An empty name: "empty ident name not allowed".
        EmptyName,
        /// A name of nothing but `.,:;<>"\'` and whitespace.
        NameOnlyDisallowedCharacters,
        /// `GIT_<ROLE>_DATE` git cannot read: "invalid date format".
        InvalidDate,
    } || Allocator.Error;
};

fn decoded(arena: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    const copy = try arena.dupe(u8, raw);
    return copy;
}

fn configValue(arena: Allocator, config: *const config_mod.Config, name: []const u8) Allocator.Error!?[]const u8 {
    const entry = config.find(name) orelse return null;
    // a name with no value is git's `config_error_nonbool`; it gives nothing
    const raw = entry.value orelse return null;
    const value = try decoded(arena, raw);
    return value;
}

fn environValue(environ: ?*const Environ.Map, name: []const u8) ?[]const u8 {
    const map = environ orelse return null;
    return map.get(name);
}

/// git's `crud`: what an identity's ends are trimmed of.
fn crud(c: u8) bool {
    return c <= 32 or c == ',' or c == ':' or c == ';' or c == '<' or c == '>' or c == '"' or c == '\\' or c == '\'';
}

/// git's `strbuf_addstr_without_crud`: the ends trimmed of crud, and `<`,
/// `>` and a newline taken out of the rest.
fn withoutCrud(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var start: usize = 0;
    while (start < text.len and crud(text[start])) start += 1;
    var end = text.len;
    while (end > start and crud(text[end - 1])) end -= 1;
    var out: std.ArrayList(u8) = .empty;
    for (text[start..end]) |c| switch (c) {
        '\n', '<', '>' => {},
        else => try out.append(arena, c),
    };
    // A signature line is `name <email> when`: neither field may close it.
    assert(std.mem.findAny(u8, out.items, "\n<>") == null);
    return out.items;
}

/// Caller-selected role, fallback machine identity and timestamp.
pub const Inputs = struct { role: Role, machine: Machine = .{}, now: Now };

/// The identity git's `fmt_ident` gives `role` for a commit, strictly, as
/// `git commit` asks for it. Strings are `arena`'s.
pub fn signature(arena: Allocator, config: *const config_mod.Config, environ: ?*const Environ.Map, inputs: Inputs) Error!object.Signature {
    const role = inputs.role;
    const machine = inputs.machine;
    const now = inputs.now;
    const role_name = @tagName(role);
    const config_only = config.getBool("user.useconfigonly", false) catch false;
    const email_given = config.has("author.email") or config.has("committer.email") or config.has("user.email");
    const name_given = config.has("author.name") or config.has("committer.name") or config.has("user.name");

    var email: ?[]const u8 = environValue(environ, "GIT_" ++ "AUTHOR_EMAIL");
    var name: ?[]const u8 = environValue(environ, "GIT_" ++ "AUTHOR_NAME");
    var date_text: ?[]const u8 = environValue(environ, "GIT_AUTHOR_DATE");
    if (role == .committer) {
        email = environValue(environ, "GIT_COMMITTER_EMAIL");
        name = environValue(environ, "GIT_COMMITTER_NAME");
        date_text = environValue(environ, "GIT_COMMITTER_DATE");
    }
    var key_buf: [32]u8 = undefined;
    if (email == null) {
        // unreachable: the longest role, committer, and `.email` are fifteen bytes
        const key = std.mem.print(&key_buf, "{s}.email", .{role_name}) catch unreachable;
        if (try configValue(arena, config, key)) |v| {
            if (v.len != 0) email = v;
        }
    }
    if (email == null) {
        if (config_only and !email_given) return error.NoEmailGiven;
        if (try configValue(arena, config, "user.email")) |v| {
            email = v;
        } else if (email_given) {
            // another role's email, configured, keeps git from asking the
            // machine, and leaves this one empty
            email = "";
        } else if (environValue(environ, "EMAIL")) |v| {
            if (v.len != 0) email = std.mem.trim(u8, v, " \t\r\n");
        }
        if (email == null) {
            if (machine.email_bogus) return error.EmailNotDetected;
            email = machine.email orelse return error.EmailNotDetected;
        }
    }
    if (name == null) {
        // unreachable: the longest role, committer, and `.name` are fourteen bytes
        const key = std.mem.print(&key_buf, "{s}.name", .{role_name}) catch unreachable;
        if (try configValue(arena, config, key)) |v| {
            if (v.len != 0) name = v;
        }
    }
    if (name == null) {
        if (config_only and !name_given) return error.NoNameGiven;
        if (try configValue(arena, config, "user.name")) |v| {
            name = v;
        } else if (name_given) {
            name = "";
        } else {
            if (machine.name_bogus) return error.NameNotDetected;
            name = std.mem.trim(u8, machine.name orelse return error.NameNotDetected, " \t\r\n");
        }
    }
    if (name.?.len == 0) return error.EmptyName;
    for (name.?) |c| {
        if (!crud(c)) break;
    } else return error.NameOnlyDisallowedCharacters;

    var when = now;
    if (date_text) |text| if (text.len != 0) {
        const parsed = gitdate.parse(text, .{ .now = gitdate.timestamp(now.secs), .local_offset_minutes = now.offset_minutes }) orelse return error.InvalidDate;
        when = .{ .secs = parsed.secs, .offset_minutes = parsed.offset_minutes };
    };
    return .{
        .name = try withoutCrud(arena, name.?),
        .email = try withoutCrud(arena, email.?),
        .when_secs = when.secs,
        .offset_minutes = @intCast(when.offset_minutes),
    };
}
