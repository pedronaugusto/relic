//! What a path from a tree, an index or a ref name is allowed to be.
//!
//! A tree entry's name is written by whoever wrote the tree and becomes a
//! filesystem path on checkout. Three published advisories against one widely
//! used implementation are about exactly that, and two of the three have to be
//! refused on every platform rather than on Windows only: an NTFS 8.3 alias
//! reached `.git` past a long-name check and also fired under a Linux
//! subsystem reading a mounted NTFS volume, and an alternate data stream
//! spelled the same directory `.git::$INDEX_ALLOCATION`.
//!
//! So every rule here applies everywhere. A name that is harmless on the
//! machine writing it is not harmless on the machine reading it.

const std = @import("std");

/// Why a path was refused. Each is reported by name so a caller can say which
/// rule decided and show the component.
pub const Reason = enum {
    /// The empty string, which is not a name.
    empty,
    /// `.` or `..`.
    dot_component,
    /// A `/` or `\` inside what should be one component. A backslash is a
    /// separator on Windows, so a tree entry holding one escapes its
    /// directory there.
    separator_inside_component,
    /// A NUL, or another control character a filesystem will not carry.
    control_character,
    /// `.git` in any case, including the NTFS 8.3 alias `git~1` and any
    /// alternate-data-stream spelling such as `.git:` or `.git::$DATA`.
    git_directory,
    /// A DOS device name — `con`, `prn`, `aux`, `nul`, `com1`-`com9`,
    /// `lpt1`-`lpt9` — with or without an extension. Opening one on Windows
    /// talks to a device.
    device_name,
    /// A component ending in `.` or a space. Windows strips both when
    /// opening, so `.git.` and `.git ` both open `.git`.
    trailing_dot_or_space,
    /// An absolute path, or one beginning with a drive letter.
    absolute,
    /// A name a git ref may not carry.
    invalid_ref_name,
};

/// What is being validated, because the rules differ slightly.
pub const Use = enum {
    /// A path that will be created inside a working tree. Every rule
    /// applies.
    worktree,
    /// A path stored in a tree or an index but not necessarily written out.
    /// The `.git` and traversal rules still apply, because such a path is
    /// one checkout away from being written.
    stored,
};

/// Whether a single path component is allowed, and why not when it is not.
pub fn checkComponent(name: []const u8, use: Use) ?Reason {
    if (name.len == 0) return .empty;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return .dot_component;
    for (name) |c| {
        if (c == '/' or c == '\\') return .separator_inside_component;
        if (c < 0x20 or c == 0x7f) return .control_character;
    }

    // Windows strips trailing dots and spaces when it opens a name, so a
    // name that ends in either is a second spelling of a shorter one.
    if (name[name.len - 1] == '.' or name[name.len - 1] == ' ') return .trailing_dot_or_space;

    // An alternate data stream is written `name:stream` or
    // `name::$ATTRIBUTE`; the part before the colon is the file that is
    // actually opened, so that is what the rules are applied to.
    const base = if (std.mem.indexOfScalar(u8, name, ':')) |colon| name[0..colon] else name;
    if (base.len == 0) return .git_directory;

    if (isGitName(base)) return .git_directory;
    if (isDeviceName(base)) return .device_name;

    // A name carrying a colon is refused outright in a working tree: every
    // spelling of an alternate data stream is a second name for the file in
    // front of the colon, and no git repository needs one.
    if (use == .worktree and std.mem.indexOfScalar(u8, name, ':') != null) return .git_directory;

    return null;
}

/// Whether the name opens the `.git` directory on some filesystem.
///
/// Four spellings: the name itself in any case, the same with trailing dots
/// or spaces (checked by the caller above), the NTFS 8.3 alias `git~1`, and
/// `.git` reached through a short name generated for a longer one beginning
/// `git~`.
fn isGitName(base: []const u8) bool {
    if (base.len == 4 and std.ascii.eqlIgnoreCase(base, ".git")) return true;
    // The 8.3 alias NTFS generates for `.git` is `git~1`; other digits are
    // generated when several names collide, so the whole `git~<n>` family
    // is refused.
    if (base.len >= 5 and std.ascii.eqlIgnoreCase(base[0..4], "git~")) {
        for (base[4..]) |c| {
            if (c < '0' or c > '9') return false;
        }
        return true;
    }
    return false;
}

const device_names = [_][]const u8{
    "con",  "prn",  "aux",  "nul",
    "com1", "com2", "com3", "com4",
    "com5", "com6", "com7", "com8",
    "com9", "lpt1", "lpt2", "lpt3",
    "lpt4", "lpt5", "lpt6", "lpt7",
    "lpt8", "lpt9",
};

/// Whether the name is a DOS device, with or without an extension.
///
/// `aux.txt` opens the same device `aux` does, which is why the extension is
/// stripped before the comparison.
fn isDeviceName(base: []const u8) bool {
    const stem = if (std.mem.indexOfScalar(u8, base, '.')) |dot| base[0..dot] else base;
    for (device_names) |device| {
        if (stem.len == device.len and std.ascii.eqlIgnoreCase(stem, device)) return true;
    }
    return false;
}

/// What `check` found.
pub const Refusal = struct {
    reason: Reason,
    /// The component that decided, borrowed from the path.
    component: []const u8,
};

/// Whether a whole `/`-separated path is allowed, and which component
/// decided when it is not.
pub fn check(path: []const u8, use: Use) ?Refusal {
    if (path.len == 0) return .{ .reason = .empty, .component = path };
    if (path[0] == '/' or path[0] == '\\') return .{ .reason = .absolute, .component = path[0..1] };
    // `C:\x` and `C:x` both name something outside the working tree.
    if (path.len >= 2 and path[1] == ':' and std.ascii.isAlphabetic(path[0])) {
        return .{ .reason = .absolute, .component = path[0..2] };
    }
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        if (checkComponent(component, use)) |reason| {
            return .{ .reason = reason, .component = component };
        }
    }
    return null;
}

/// Whether a path may be written into a working tree.
pub fn isSafeWorktreePath(path: []const u8) bool {
    return check(path, .worktree) == null;
}

/// Whether a path may be stored in a tree or an index.
pub fn isSafeStoredPath(path: []const u8) bool {
    return check(path, .stored) == null;
}

/// Whether a ref name is one git will accept.
///
/// git's own rules, plus the one the field has learned the hard way: a name
/// ending in `.lock` is refused, because `refs/heads/main.lock` is the file
/// that blocks every update to `main` and a loose-ref walk that skips
/// `.lock` names will never show it.
pub fn checkRefName(name: []const u8) ?Reason {
    if (name.len == 0) return .empty;
    if (std.mem.endsWith(u8, name, ".lock")) return .invalid_ref_name;
    if (std.mem.endsWith(u8, name, "/") or std.mem.startsWith(u8, name, "/")) return .invalid_ref_name;
    if (std.mem.endsWith(u8, name, ".")) return .invalid_ref_name;
    if (std.mem.indexOf(u8, name, "..") != null) return .invalid_ref_name;
    if (std.mem.indexOf(u8, name, "//") != null) return .invalid_ref_name;
    if (std.mem.indexOf(u8, name, "@{") != null) return .invalid_ref_name;
    if (std.mem.eql(u8, name, "@")) return .invalid_ref_name;
    for (name) |c| {
        switch (c) {
            0...0x20, 0x7f, '~', '^', ':', '?', '*', '[', '\\' => return .invalid_ref_name,
            else => {},
        }
    }
    var it = std.mem.splitScalar(u8, name, '/');
    while (it.next()) |component| {
        if (component.len == 0) return .invalid_ref_name;
        if (component[0] == '.') return .invalid_ref_name;
        if (std.mem.endsWith(u8, component, ".lock")) return .invalid_ref_name;
    }
    return null;
}

/// Whether a ref name is one git will accept.
pub fn isValidRefName(name: []const u8) bool {
    return checkRefName(name) == null;
}

test "the git directory is refused in every spelling" {
    for ([_][]const u8{
        ".git",       ".GIT",  ".Git",  "git~1", "GIT~1",
        "git~12",     ".git.", ".git ", ".git:", ".git::$INDEX_ALLOCATION",
        ".git:$DATA",
    }) |name| {
        try std.testing.expect(checkComponent(name, .worktree) != null);
        try std.testing.expect(checkComponent(name, .stored) != null);
    }
    try std.testing.expect(checkComponent(".gitignore", .worktree) == null);
    try std.testing.expect(checkComponent("gitk", .worktree) == null);
    try std.testing.expect(checkComponent("git~x", .worktree) == null);
}

test "device names are refused with and without an extension" {
    for ([_][]const u8{ "con", "CON", "aux", "nul.txt", "com1", "LPT9.tar.gz", "prn" }) |name| {
        try std.testing.expectEqual(Reason.device_name, checkComponent(name, .worktree).?);
    }
    try std.testing.expect(checkComponent("console", .worktree) == null);
    try std.testing.expect(checkComponent("com0", .worktree) == null);
    try std.testing.expect(checkComponent("com10", .worktree) == null);
}

test "traversal and separators are refused" {
    try std.testing.expectEqual(Reason.dot_component, check("a/../b", .stored).?.reason);
    try std.testing.expectEqual(Reason.dot_component, check("./a", .stored).?.reason);
    try std.testing.expectEqual(Reason.absolute, check("/etc/passwd", .stored).?.reason);
    try std.testing.expectEqual(Reason.absolute, check("C:/Windows", .stored).?.reason);
    try std.testing.expectEqual(Reason.separator_inside_component, checkComponent("a\\b", .stored).?);
    try std.testing.expectEqual(Reason.control_character, checkComponent("a\x00b", .stored).?);
    try std.testing.expect(check("a/b/c.txt", .worktree) == null);
}

test "trailing dots and spaces are refused" {
    try std.testing.expectEqual(Reason.trailing_dot_or_space, checkComponent("x.", .worktree).?);
    try std.testing.expectEqual(Reason.trailing_dot_or_space, checkComponent("x ", .worktree).?);
    try std.testing.expect(checkComponent(".x", .worktree) == null);
}

test "ref names follow git's rules and refuse a .lock suffix" {
    try std.testing.expect(isValidRefName("refs/heads/main"));
    try std.testing.expect(isValidRefName("HEAD"));
    try std.testing.expect(!isValidRefName("refs/heads/main.lock"));
    try std.testing.expect(!isValidRefName("refs/heads/.hidden"));
    try std.testing.expect(!isValidRefName("refs/heads/a..b"));
    try std.testing.expect(!isValidRefName("refs/heads/a b"));
    try std.testing.expect(!isValidRefName("refs/heads/a~1"));
    try std.testing.expect(!isValidRefName("refs/heads/a:b"));
    try std.testing.expect(!isValidRefName("refs/heads/"));
    try std.testing.expect(!isValidRefName("@"));
    try std.testing.expect(!isValidRefName("refs/heads/x@{1}"));
}

test "fuzz: any bytes answer without a crash" {
    try std.testing.fuzz({}, fuzzOne, .{});
}

fn fuzzOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var scratch: [256]u8 = undefined;
    const input = scratch[0..smith.slice(&scratch)];
    _ = check(input, .worktree);
    _ = check(input, .stored);
    _ = checkRefName(input);
}
