//! What a path from a tree or an index is allowed to be.
//!
//! A tree entry's name is written by whoever wrote the tree and becomes a
//! filesystem path on checkout. Three published advisories against one widely
//! used implementation are about exactly that, and two of the three have to be
//! refused on every platform rather than on Windows only: an NTFS 8.3 alias
//! reached `.git` past a long-name check and also fired under a Linux
//! subsystem reading a mounted NTFS volume, and an alternate data stream
//! spelled the same directory `.git::$INDEX_ALLOCATION`.
//!
//! So `.git` in every spelling NTFS or HFS+ opens as it is refused on every
//! platform, as git's `core.protectNTFS` and `core.protectHFS` refuse it.
//! The names only Windows cannot create -- a device name such as `aux.c`, a
//! trailing dot or space, a colon, a control character, a backslash, a drive
//! letter -- are refused where Windows opens the working tree, as git's
//! `is_valid_win32_path` refuses them, and written elsewhere: the Linux
//! kernel's tree holds `aux.c`.

const std = @import("std");
const builtin = @import("builtin");

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
    /// A DOS device name — `con`, `conin$`, `conout$`, `prn`, `aux`,
    /// `nul`, `com1`-`com9`, `lpt0`-`lpt9` — with or without spaces, an
    /// extension or a stream after it. Opening one on Windows talks to a
    /// device.
    device_name,
    /// A component ending in `.` or a space. Windows strips both when
    /// opening, so `.git.` and `.git ` both open `.git`.
    trailing_dot_or_space,
    /// An absolute path, or one beginning with a drive: a letter, or any
    /// other character `subst` names a drive by, then a colon.
    absolute,
    /// A character Windows will not put in a name: `<`, `>`, `"`, `|`,
    /// `?`, `*`, or a colon, which names an alternate data stream of the
    /// file in front of it.
    reserved_character,
    /// A symbolic link named `.gitmodules`, in any spelling HFS+ or NTFS
    /// opens as it: git reads that file, and a link would have it read
    /// whatever the link points at.
    symlinked_gitmodules,
    /// Another entry of the same tree stands where this path's directory
    /// goes, by the same name or one the filesystem folds to it: written in
    /// order, the second would be written through the first, a link
    /// included. git's checkout never writes such a tree.
    path_collision,
    /// A directory above the path is a symbolic link on the disk, which a
    /// write would follow out of the working tree: git's "beyond a symbolic
    /// link".
    beyond_symlink,
};

/// What is being validated, because the rules differ.
pub const Use = enum {
    /// A path that will be created inside a working tree: what git's
    /// `verify_path` refuses on this platform. On Windows that includes the
    /// names Windows cannot create, `aux.c`, `t.` and `a:b` among them.
    worktree,
    /// A path stored in a tree or an index but not necessarily written out:
    /// what git's `verify_path` refuses everywhere. The traversal rules and
    /// `.git` in every spelling HFS+ and NTFS open as it apply, because such
    /// a path is one checkout away from being written; the names only
    /// Windows cannot create are left to the checkout that would write
    /// them. A backslash and a drive letter are refused on Windows, where
    /// they are separators.
    stored,
};

/// Whether a single path component is allowed, and why not when it is not.
pub fn checkComponent(name: []const u8, use: Use) ?Reason {
    if (name.len == 0) return .empty;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return .dot_component;
    const windows = builtin.target.os.tag == .windows;
    for (name) |c| {
        if (c == '/' or (c == '\\' and windows)) return .separator_inside_component;
        // No git path holds a NUL, whatever the platform.
        if (c == 0 or (windows and use == .worktree and (c < 0x20 or c == 0x7f))) return .control_character;
    }
    if (isNtfsDotGit(name) or isHfsDot(name, "git") or isGitName(name)) return .git_directory;
    // What follows a backslash is a component of its own on an NTFS volume,
    // a Linux one mounted from Windows included, so `.\.GIT\x` is refused
    // on every platform as git's `verify_path` refuses it.
    if (afterBackslash(isNtfsDotGit, name)) return .git_directory;
    if (use == .stored or !windows) return null;
    if (std.mem.findScalar(u8, name, ':')) |colon| {
        if (isGitName(name[0..colon])) return .git_directory;
    }
    return win32Reason(name);
}

/// Whether `matches` holds for what follows any backslash in `name`.
fn afterBackslash(comptime matches: fn ([]const u8) bool, name: []const u8) bool {
    var at: usize = 0;
    while (std.mem.findScalarPos(u8, name, at, '\\')) |slash| {
        if (matches(name[slash + 1 ..])) return true;
        at = slash + 1;
    }
    return false;
}

/// git's `is_valid_win32_path` for one component: why Windows would open
/// `name` as another file or a device, or refuse to create it; `null` when
/// it would not. Applied where Windows opens the working tree, and public
/// so that the rule can be checked on every platform.
pub fn win32Reason(name: []const u8) ?Reason {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return null;
    if (isDeviceName(name)) return .device_name;
    for (name) |c| switch (c) {
        // An alternate data stream is written `name:stream` or
        // `name::$ATTRIBUTE`, a second name for the file in front of the
        // colon; the rest Windows will not create.
        ':', '<', '>', '"', '|', '?', '*' => return .reserved_character,
        0x01...0x1f => return .control_character,
        else => {},
    };
    // Windows strips trailing dots and spaces when it opens a name, so a
    // name that ends in either is a second spelling of a shorter one.
    if (name[name.len - 1] == '.' or name[name.len - 1] == ' ') return .trailing_dot_or_space;
    return null;
}

/// git's `is_valid_win32_path` for a whole path: the first component that
/// Windows would not open as itself, after any drive prefix, with `/` and
/// `\` both separators.
pub fn win32PathReason(path: []const u8) ?Reason {
    var it = std.mem.tokenizeAny(u8, path[dosDrivePrefixLen(path)..], "/\\");
    while (it.next()) |component| {
        if (win32Reason(component)) |reason| return reason;
    }
    return null;
}

/// git's `win32_has_dos_drive_prefix`: how many bytes a drive prefix takes
/// at the front of `path`, or 0. Not only `C:`: `subst` names a drive by
/// any character, `1:` and a non-ASCII one included.
pub fn dosDrivePrefixLen(path: []const u8) usize {
    if (path.len < 2) return 0;
    if (path[0] & 0x80 == 0) return if (path[1] == ':') 2 else 0;
    var i: usize = 1;
    while (i < 4 and i < path.len and path[i] & 0x80 != 0) : (i += 1) {}
    return if (i < path.len and path[i] == ':') i + 1 else 0;
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

/// The DOS devices, longest first so that `conin$` is not taken for `con`.
const device_names = [_][]const u8{ "conout$", "conin$", "aux", "con", "nul", "prn" };

/// Whether the name opens a DOS device: one of `device_names`, `com1` to
/// `com9` or `lpt0` to `lpt9`, then any spaces, then the end, an extension
/// or a stream. `aux.txt` and `aux .c` open the same device `aux` does.
fn isDeviceName(name: []const u8) bool {
    var len: usize = 0;
    for (device_names) |device| {
        if (name.len >= device.len and std.ascii.eqlIgnoreCase(name[0..device.len], device)) {
            len = device.len;
            break;
        }
    } else if (name.len >= 4) {
        const head = name[0..3];
        if (std.ascii.eqlIgnoreCase(head, "com") and name[3] >= '1' and name[3] <= '9') len = 4;
        if (std.ascii.eqlIgnoreCase(head, "lpt") and std.ascii.isDigit(name[3])) len = 4;
    }
    if (len == 0) return false;
    while (len < name.len and name[len] == ' ') len += 1;
    return len == name.len or name[len] == '.' or name[len] == ':';
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
    // A backslash and `C:\x` or `C:x` name something outside the working
    // tree where they are separators.
    const windows = builtin.target.os.tag == .windows;
    if (path[0] == '/' or (path[0] == '\\' and windows)) return .{ .reason = .absolute, .component = path[0..1] };
    if (windows) {
        const drive = dosDrivePrefixLen(path);
        if (drive != 0) return .{ .reason = .absolute, .component = path[0..drive] };
    }
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        if (checkComponent(component, use)) |reason| {
            return .{ .reason = reason, .component = component };
        }
    }
    return null;
}

/// Whether a whole path is allowed for an entry that is, or is not, a
/// symbolic link: `check`, and for a link git's `verify_path` rule that no
/// component spells `.gitmodules`.
pub fn checkEntry(path: []const u8, use: Use, symlink: bool) ?Refusal {
    if (check(path, use)) |refused| return refused;
    if (!symlink) return null;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        if (isHfsDot(component, "gitmodules") or isNtfsDotGitmodules(component) or
            afterBackslash(isNtfsDotGitmodules, component))
        {
            return .{ .reason = .symlinked_gitmodules, .component = component };
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

/// The byte at `i`, or NUL past the end, as git's NUL-terminated buffers
/// read.
fn byteAt(bytes: []const u8, i: usize) u8 {
    return if (i < bytes.len) bytes[i] else 0;
}

/// The code point at the front of `s`, git's `pick_one_utf8_char`, and how
/// many bytes it took; `null` for malformed UTF-8 or a NUL.
fn pickUtf8(s: []const u8) ?struct { cp: u21, len: usize } {
    const b0 = byteAt(s, 0);
    if (b0 < 0x80) return .{ .cp = b0, .len = 1 };
    const b1 = byteAt(s, 1);
    if (b0 & 0xe0 == 0xc0) {
        if (b1 & 0xc0 != 0x80 or b0 & 0xfe == 0xc0) return null;
        return .{ .cp = (@as(u21, b0 & 0x1f) << 6) | (b1 & 0x3f), .len = 2 };
    }
    const b2 = byteAt(s, 2);
    if (b0 & 0xf0 == 0xe0) {
        if (b1 & 0xc0 != 0x80 or b2 & 0xc0 != 0x80 or
            (b0 == 0xe0 and b1 & 0xe0 == 0x80) or
            (b0 == 0xed and b1 & 0xe0 == 0xa0) or
            (b0 == 0xef and b1 == 0xbf and b2 & 0xfe == 0xbe)) return null;
        return .{ .cp = (@as(u21, b0 & 0x0f) << 12) | (@as(u21, b1 & 0x3f) << 6) | (b2 & 0x3f), .len = 3 };
    }
    const b3 = byteAt(s, 3);
    if (b0 & 0xf8 == 0xf0) {
        if (b1 & 0xc0 != 0x80 or b2 & 0xc0 != 0x80 or b3 & 0xc0 != 0x80 or
            (b0 == 0xf0 and b1 & 0xf0 == 0x80) or
            (b0 == 0xf4 and b1 > 0x8f) or b0 > 0xf4) return null;
        return .{ .cp = (@as(u21, b0 & 0x07) << 18) | (@as(u21, b1 & 0x3f) << 12) | (@as(u21, b2 & 0x3f) << 6) | (b3 & 0x3f), .len = 4 };
    }
    return null;
}

/// git's `next_hfs_char`: the next code point HFS+ does not ignore, `0`
/// at the end or for malformed UTF-8.
fn nextHfsChar(s: []const u8, at: *usize) u21 {
    while (true) {
        if (at.* >= s.len) return 0;
        const picked = pickUtf8(s[at.*..]) orelse {
            at.* = s.len;
            return 0;
        };
        at.* += picked.len;
        switch (picked.cp) {
            0x200c, 0x200d, 0x200e, 0x200f, 0x202a, 0x202b, 0x202c, 0x202d, 0x202e, 0x206a, 0x206b, 0x206c, 0x206d, 0x206e, 0x206f, 0xfeff => continue,
            else => return picked.cp,
        }
    }
}

fn isDirSep(c: u21) bool {
    return c == '/' or (builtin.target.os.tag == .windows and c == '\\');
}

/// git's `is_hfs_dot_generic`: `.<needle>` as HFS+ reads it, ignoring
/// the code points it ignores and case.
pub fn isHfsDot(name: []const u8, needle: []const u8) bool {
    var at: usize = 0;
    if (nextHfsChar(name, &at) != '.') return false;
    for (needle) |n| {
        const c = nextHfsChar(name, &at);
        if (c > 127) return false;
        if (std.ascii.toLower(@intCast(c)) != n) return false;
    }
    const c = nextHfsChar(name, &at);
    return c == 0 or isDirSep(c);
}

/// git's `is_ntfs_dotgit`: `.git` or `git~1`, then only spaces and dots
/// to a separator, a colon or the end.
pub fn isNtfsDotGit(name: []const u8) bool {
    var i: usize = 0;
    const c0 = byteAt(name, 0);
    if (c0 == '.') {
        if (std.ascii.toLower(byteAt(name, 1)) != 'g' or std.ascii.toLower(byteAt(name, 2)) != 'i' or std.ascii.toLower(byteAt(name, 3)) != 't') return false;
        i = 4;
    } else if (c0 == 'g' or c0 == 'G') {
        if (std.ascii.toLower(byteAt(name, 1)) != 'i' or std.ascii.toLower(byteAt(name, 2)) != 't' or byteAt(name, 3) != '~' or byteAt(name, 4) != '1') return false;
        i = 5;
    } else return false;
    while (true) : (i += 1) {
        const c = byteAt(name, i);
        if (c == 0 or c == '/' or c == '\\' or c == ':') return true;
        if (c != '.' and c != ' ') return false;
    }
}

/// git's `is_ntfs_dot_generic`: `.<name>`, its 8.3 short name `<first
/// six>~<1-4>`, or the fall-back short name `<prefix>~<digit>`, then only
/// spaces and dots to a colon or the end.
pub fn isNtfsDot(name: []const u8, dotgit_name: []const u8, shortname_prefix: []const u8) bool {
    const onlySpacesAndPeriods = struct {
        fn f(n: []const u8, start: usize) bool {
            var i = start;
            while (true) : (i += 1) {
                const c = byteAt(n, i);
                if (c == 0 or c == ':') return true;
                if (c != ' ' and c != '.') return false;
            }
        }
    }.f;
    if (byteAt(name, 0) == '.' and strncasecmp(name[@min(1, name.len)..], dotgit_name, dotgit_name.len)) {
        return onlySpacesAndPeriods(name, dotgit_name.len + 1);
    }
    if (strncasecmp(name, dotgit_name, 6) and byteAt(name, 6) == '~' and byteAt(name, 7) >= '1' and byteAt(name, 7) <= '4') {
        return onlySpacesAndPeriods(name, 8);
    }
    var saw_tilde = false;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const c = byteAt(name, i);
        if (c == 0) return false;
        if (saw_tilde) {
            if (c < '0' or c > '9') return false;
        } else if (c == '~') {
            i += 1;
            const d = byteAt(name, i);
            if (d < '1' or d > '9') return false;
            saw_tilde = true;
        } else if (i >= 6) {
            return false;
        } else if (c & 0x80 != 0) {
            return false;
        } else if (std.ascii.toLower(c) != shortname_prefix[i]) return false;
    }
    return onlySpacesAndPeriods(name, i);
}

/// git's `is_ntfs_dotgitmodules`.
pub fn isNtfsDotGitmodules(name: []const u8) bool {
    return isNtfsDot(name, "gitmodules", "gi7eba");
}

/// C's `strncasecmp(a, b, n) == 0`, with `a` NUL-terminated at its end.
fn strncasecmp(a: []const u8, b: []const u8, n: usize) bool {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const ca = std.ascii.toLower(byteAt(a, i));
        const cb = std.ascii.toLower(byteAt(b, i));
        if (ca != cb) return false;
        if (ca == 0) return true;
    }
    return true;
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

test "device names are refused with and without an extension where Windows opens them" {
    for ([_][]const u8{ "con", "CON", "aux", "nul.txt", "com1", "LPT9.tar.gz", "prn" }) |name| {
        if (builtin.target.os.tag == .windows) {
            try std.testing.expectEqual(Reason.device_name, checkComponent(name, .worktree).?);
        } else try std.testing.expectEqual(null, checkComponent(name, .worktree));
    }
    try std.testing.expect(checkComponent("console", .worktree) == null);
    try std.testing.expect(checkComponent("com0", .worktree) == null);
    try std.testing.expect(checkComponent("com10", .worktree) == null);
}

test "traversal and separators are refused" {
    try std.testing.expectEqual(Reason.dot_component, check("a/../b", .stored).?.reason);
    try std.testing.expectEqual(Reason.dot_component, check("./a", .stored).?.reason);
    try std.testing.expectEqual(Reason.absolute, check("/etc/passwd", .stored).?.reason);
    try std.testing.expectEqual(Reason.control_character, checkComponent("a\x00b", .stored).?);
    try std.testing.expect(check("a/b/c.txt", .worktree) == null);
    for ([_]Use{ .stored, .worktree }) |use| {
        if (builtin.target.os.tag == .windows) {
            try std.testing.expectEqual(Reason.absolute, check("C:/Windows", use).?.reason);
            try std.testing.expectEqual(Reason.separator_inside_component, checkComponent("a\\b", use).?);
        } else {
            try std.testing.expect(check("C:/Windows", use) == null);
            try std.testing.expect(checkComponent("a\\b", use) == null);
        }
    }
}

test "a path refuses what git's verify_path refuses on this platform, and no more" {
    // Names only Windows cannot create, which a Linux or macOS tree holds
    // and git writes there.
    for ([_][]const u8{ "d/aux.c", "a\tb", "t.", "x ", "con", "ab:c", "v1." }) |path| {
        try std.testing.expectEqual(null, check(path, .stored));
        if (builtin.target.os.tag == .windows) {
            try std.testing.expect(check(path, .worktree) != null);
        } else try std.testing.expectEqual(null, check(path, .worktree));
    }
    for ([_][]const u8{ ".git", "a/.GIT/b", ".git.", ".git ", "git~1", ".git:x", ".git::$INDEX_ALLOCATION", ".g\u{200c}it", "../a", "" }) |path| {
        try std.testing.expect(check(path, .stored) != null);
        try std.testing.expect(check(path, .worktree) != null);
    }
}

test "trailing dots and spaces are refused where Windows strips them" {
    for ([_][]const u8{ "x.", "x " }) |name| {
        if (builtin.target.os.tag == .windows) {
            try std.testing.expectEqual(Reason.trailing_dot_or_space, checkComponent(name, .worktree).?);
        } else try std.testing.expectEqual(null, checkComponent(name, .worktree));
    }
    try std.testing.expect(checkComponent(".x", .worktree) == null);
}

test "a symbolic link may not be .gitmodules in any spelling, and a file may" {
    for ([_][]const u8{ ".gitmodules", ".GitModules", "sub/.gitmodules", "gitmod~1", "GI7EBA~1", ".git\u{200c}modules" }) |path| {
        try std.testing.expectEqual(Reason.symlinked_gitmodules, checkEntry(path, .worktree, true).?.reason);
        try std.testing.expectEqual(null, checkEntry(path, .stored, false));
    }
    for ([_][]const u8{ ".gitmodulesx", "gitmodules", ".gitattributes" }) |path| {
        try std.testing.expectEqual(null, checkEntry(path, .worktree, true));
    }
}

test "fuzz: any bytes answer without a crash" {
    try std.testing.fuzz({}, fuzzOne, .{});
}

fn fuzzOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var scratch: [256]u8 = undefined;
    const input = scratch[0..smith.slice(&scratch)];
    _ = check(input, .worktree);
    _ = check(input, .stored);
}
