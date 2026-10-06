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
    /// A symbolic link named `.gitmodules`, in any spelling HFS+ or NTFS
    /// opens as it: git reads that file, and a link would have it read
    /// whatever the link points at.
    symlinked_gitmodules,
};

/// What is being validated, because the rules differ.
pub const Use = enum {
    /// A path that will be created inside a working tree. Every rule
    /// applies, on every platform, so a tree checks out the same anywhere.
    worktree,
    /// A path stored in a tree or an index but not necessarily written out:
    /// what git's `verify_path` refuses everywhere. The traversal rules and
    /// `.git` in every spelling HFS+ and NTFS open as it still apply,
    /// because such a path is one checkout away from being written; the
    /// names only Windows cannot create -- `aux.c`, `t.`, a control
    /// character -- are refused when a checkout would write them, and not
    /// in an index or a tree, as git's are not: the Linux kernel's index
    /// holds `aux.c`. A backslash and a drive letter are refused on
    /// Windows, where they are separators.
    stored,
};

/// Whether a single path component is allowed, and why not when it is not.
pub fn checkComponent(name: []const u8, use: Use) ?Reason {
    if (name.len == 0) return .empty;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return .dot_component;
    const windows_rules = use == .worktree or builtin.os.tag == .windows;
    for (name) |c| {
        if (c == '/' or (c == '\\' and windows_rules)) return .separator_inside_component;
        // No git path holds a NUL, whatever the platform.
        if (c == 0 or (use == .worktree and (c < 0x20 or c == 0x7f))) return .control_character;
    }
    if (use == .stored) {
        if (isNtfsDotGit(name) or isHfsDot(name, "git") or isGitName(name)) return .git_directory;
        return null;
    }
    if (isHfsDot(name, "git")) return .git_directory;

    // Windows strips trailing dots and spaces when it opens a name, so a
    // name that ends in either is a second spelling of a shorter one.
    if (name[name.len - 1] == '.' or name[name.len - 1] == ' ') return .trailing_dot_or_space;

    // An alternate data stream is written `name:stream` or
    // `name::$ATTRIBUTE`; the part before the colon is the file that is
    // actually opened, so that is what the rules are applied to.
    const base = if (std.mem.findScalar(u8, name, ':')) |colon| name[0..colon] else name;
    if (base.len == 0) return .git_directory;

    if (isGitName(base)) return .git_directory;
    if (isDeviceName(base)) return .device_name;

    // A name carrying a colon is refused outright in a working tree: every
    // spelling of an alternate data stream is a second name for the file in
    // front of the colon, and no git repository needs one.
    if (use == .worktree and std.mem.findScalar(u8, name, ':') != null) return .git_directory;

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
    const stem = if (std.mem.findScalar(u8, base, '.')) |dot| base[0..dot] else base;
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
    // A backslash and `C:\x` or `C:x` name something outside the working
    // tree where they are separators.
    const windows_rules = use == .worktree or builtin.os.tag == .windows;
    if (path[0] == '/' or (path[0] == '\\' and windows_rules)) return .{ .reason = .absolute, .component = path[0..1] };
    if (windows_rules and path.len >= 2 and path[1] == ':' and std.ascii.isAlphabetic(path[0])) {
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

/// Whether a whole path is allowed for an entry that is, or is not, a
/// symbolic link: `check`, and for a link git's `verify_path` rule that no
/// component spells `.gitmodules`.
pub fn checkEntry(path: []const u8, use: Use, symlink: bool) ?Refusal {
    if (check(path, use)) |refused| return refused;
    if (!symlink) return null;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        if (isHfsDot(component, "gitmodules") or isNtfsDot(component, "gitmodules", "gi7eba")) {
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
    return c == '/' or (builtin.os.tag == .windows and c == '\\');
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
    if (std.mem.find(u8, name, "..") != null) return .invalid_ref_name;
    if (std.mem.find(u8, name, "//") != null) return .invalid_ref_name;
    if (std.mem.find(u8, name, "@{") != null) return .invalid_ref_name;
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
    try std.testing.expectEqual(Reason.absolute, check("C:/Windows", .worktree).?.reason);
    try std.testing.expectEqual(Reason.separator_inside_component, checkComponent("a\\b", .worktree).?);
    try std.testing.expectEqual(Reason.control_character, checkComponent("a\x00b", .stored).?);
    try std.testing.expect(check("a/b/c.txt", .worktree) == null);
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqual(Reason.absolute, check("C:/Windows", .stored).?.reason);
        try std.testing.expectEqual(Reason.separator_inside_component, checkComponent("a\\b", .stored).?);
    } else {
        try std.testing.expect(check("C:/Windows", .stored) == null);
        try std.testing.expect(checkComponent("a\\b", .stored) == null);
    }
}

test "a stored path refuses what git's verify_path refuses everywhere, and no more" {
    // Names only Windows cannot create, which a Linux or macOS index holds.
    for ([_][]const u8{ "d/aux.c", "a\tb", "t.", "x ", "con", "a:b" }) |path| {
        try std.testing.expectEqual(null, check(path, .stored));
        try std.testing.expect(check(path, .worktree) != null);
    }
    for ([_][]const u8{ ".git", "a/.GIT/b", ".git.", "git~1", ".git:x", ".g\u{200c}it", "../a", "" }) |path| {
        try std.testing.expect(check(path, .stored) != null);
        try std.testing.expect(check(path, .worktree) != null);
    }
}

test "trailing dots and spaces are refused" {
    try std.testing.expectEqual(Reason.trailing_dot_or_space, checkComponent("x.", .worktree).?);
    try std.testing.expectEqual(Reason.trailing_dot_or_space, checkComponent("x ", .worktree).?);
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
