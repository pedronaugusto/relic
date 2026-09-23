//! Signing and verifying commits and tags the way git does: through the
//! program the configuration names, with git's arguments, and with the
//! signature where git puts it.
//!
//! A commit carries its signature as a `gpgsig` header — `gpgsig-sha256` in
//! a SHA-256 repository — after every other header, one line of the
//! signature per line of the header, each continuation line beginning with
//! a space. What is signed is the commit without that header, so taking the
//! header out again gives back the bytes the signature covers. A tag carries
//! its signature at the end of its message, and what is signed is
//! everything before it.
//!
//! `gpg.format` chooses the program: `openpgp` runs `gpg` as
//! `gpg --status-fd=2 -bsau <key>`, `x509` runs `gpgsm` the same way, and
//! `ssh` runs `ssh-keygen -Y sign -n git -f <key>`. `gpg.program`,
//! `gpg.<format>.program` and `user.signingKey` change the program and the
//! key, as they do in git; a program named there is run directly, as git
//! runs it, never through a shell. With no key configured, `gpg` and
//! `gpgsm` sign as the committer's `Name <email>` and `ssh-keygen` asks
//! `gpg.ssh.defaultKeyCommand`. Verifying runs the same programs the way git
//! does and reads their answer into a `Verdict`, whose letter is what git's
//! `%G?` prints.
//!
//! Running any of them needs the caller's `program.Programs`. With signing
//! configured — `commit.gpgSign`, `tag.gpgSign` — and no `Programs`, the
//! object is refused by name rather than written unsigned.
//!
//! A signature is handed to a verifier through a file, because both `gpg`
//! and `ssh-keygen` read the signature from a file and the signed bytes from
//! standard input. The file is made in the temporary directory the
//! caller's environment names, as git's is, and removed afterwards.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("hash.zig");
const object = @import("object.zig");
const config_mod = @import("config.zig");
const program = @import("program.zig");
const fs = @import("fs.zig");

const Oid = hash.Oid;

/// Errors from signing and verifying.
pub const Error = error{
    /// Signing is asked for, by the caller or by `commit.gpgSign` or
    /// `tag.gpgSign`, and the caller gave no `program.Programs` to run the
    /// signer with. The object is not written unsigned in its place.
    SigningRequiresPrograms,
    /// `gpg.format` names a format git does not know.
    UnknownSignatureFormat,
    /// `gpg.minTrustLevel` names a level git does not know.
    UnknownTrustLevel,
    /// The signing program failed, or said nothing of a signature.
    /// `Signer.diagnostics` holds what it printed.
    SigningFailed,
    /// SSH signing needs `user.signingKey`, or a
    /// `gpg.ssh.defaultKeyCommand` that prints a key.
    NoSigningKey,
    /// SSH verification needs `gpg.ssh.allowedSignersFile`.
    AllowedSignersFileMissing,
    /// A signature in none of the formats git knows.
    UnknownSignature,
    /// No temporary directory to hand the signature through.
    NoTemporaryDirectory,
} || program.Error || Allocator.Error || Io.File.OpenError || Io.Writer.Error ||
    Io.File.WritePositionalError || Io.Dir.DeleteFileError || Io.Dir.OpenError ||
    error{MalformedValue};

/// The kinds of signature git makes.
pub const Format = enum {
    openpgp,
    x509,
    ssh,

    /// The program git runs for the format when none is configured.
    pub fn defaultProgram(f: Format) []const u8 {
        return switch (f) {
            .openpgp => "gpg",
            .x509 => "gpgsm",
            .ssh => "ssh-keygen",
        };
    }

    /// The format a signature is in, from its first line, or `null`.
    pub fn of(signature: []const u8) ?Format {
        const openings = [_]struct { text: []const u8, format: Format }{
            .{ .text = "-----BEGIN PGP SIGNATURE-----", .format = .openpgp },
            .{ .text = "-----BEGIN PGP MESSAGE-----", .format = .openpgp },
            .{ .text = "-----BEGIN SIGNED MESSAGE-----", .format = .x509 },
            .{ .text = "-----BEGIN SSH SIGNATURE-----", .format = .ssh },
        };
        for (openings) |o| {
            if (std.mem.startsWith(u8, signature, o.text)) return o.format;
        }
        return null;
    }
};

/// How far a key is trusted, as gpg reports it, lowest first.
pub const Trust = enum {
    undefined,
    never,
    marginal,
    fully,
    ultimate,

    fn parse(text: []const u8) ?Trust {
        inline for (@typeInfo(Trust).@"enum".fields) |f| {
            if (std.ascii.eqlIgnoreCase(text, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

/// What a signature check found: the letters git's `%G?` prints.
pub const Result = enum {
    /// `G`: good, from a key trusted at least marginally.
    good,
    /// `B`: bad.
    bad,
    /// `U`: good, from a key whose trust is unknown or none.
    good_untrusted,
    /// `X`: good, and the signature has expired.
    expired_signature,
    /// `Y`: good, by a key that has expired.
    expired_key,
    /// `R`: good, by a key that has been revoked.
    revoked_key,
    /// `E`: it could not be checked, which usually means the key is not
    /// there.
    cannot_check,
    /// `N`: there is no signature.
    none,

    /// The letter `%G?` prints.
    pub fn letter(r: Result) u8 {
        return switch (r) {
            .good => 'G',
            .bad => 'B',
            .good_untrusted => 'U',
            .expired_signature => 'X',
            .expired_key => 'Y',
            .revoked_key => 'R',
            .cannot_check => 'E',
            .none => 'N',
        };
    }
};

/// A signature check's answer.
pub const Verdict = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator.State,
    result: Result = .none,
    trust: Trust = .undefined,
    /// The key that made the signature: a long key id, or an SSH key's
    /// fingerprint.
    key: ?[]const u8 = null,
    /// Who the key belongs to: the user id, or the SSH principal.
    signer: ?[]const u8 = null,
    fingerprint: ?[]const u8 = null,
    /// The primary key's fingerprint, when a subkey signed.
    primary_fingerprint: ?[]const u8 = null,
    /// What the program said for a person to read.
    output: []const u8 = "",
    /// gpg's machine-readable status lines, or the SSH output again.
    status: []const u8 = "",
    /// Whether the program itself accepted the signature: gpg exited well
    /// and reported a good signature, or `ssh-keygen` verified it for a
    /// principal the allowed signers name. A key the allowed signers do not
    /// name is `U` and not accepted, which is why git fails its check.
    accepted: bool = false,

    /// Release the verdict.
    pub fn deinit(v: *Verdict) void {
        var arena = v.arena.promote(v.gpa);
        arena.deinit();
        v.* = undefined;
    }

    /// What `%G?` prints.
    pub fn letter(v: *const Verdict) u8 {
        return v.result.letter();
    }

    /// Whether `git verify-commit` or `git verify-tag` would succeed: a
    /// good signature, or one by a key since expired, from a key trusted at
    /// least as far as `minimum` — `gpg.minTrustLevel`, which is
    /// `undefined` unless set.
    pub fn verified(v: *const Verdict, minimum: Trust) bool {
        const good = switch (v.result) {
            .good, .good_untrusted, .expired_key => true,
            else => false,
        };
        return v.accepted and good and @intFromEnum(v.trust) >= @intFromEnum(minimum);
    }
};

/// Whether an object is signed: the configuration's word, or the caller's.
pub const Sign = enum {
    /// `commit.gpgSign` or `tag.gpgSign` decides.
    config,
    /// `-S`.
    always,
    /// `--no-gpg-sign`.
    never,
};

/// What a caller writing a commit or a tag says about signing it.
pub const Request = struct {
    sign: Sign = .config,
    /// The key to sign with in place of `user.signingKey`: what `-S<key>`
    /// names.
    key: ?[]const u8 = null,
    /// Permission to run the signing program.
    programs: ?program.Programs = null,
};

/// The signing settings of a repository, and permission to run them.
pub const Signer = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator.State,
    programs: program.Programs,
    format: Format,
    /// The program for `format`.
    program: []const u8,
    /// `user.signingKey`, with a leading `~/` expanded.
    signing_key: ?[]const u8,
    /// `gpg.ssh.defaultKeyCommand`.
    default_key_command: ?[]const u8,
    /// `gpg.ssh.allowedSignersFile`.
    allowed_signers: ?[]const u8,
    /// `gpg.ssh.revocationFile`.
    revocation_file: ?[]const u8,
    /// `gpg.minTrustLevel`.
    min_trust: Trust,
    /// What the signing program printed when it failed.
    diagnostics: std.ArrayList(u8) = .empty,

    /// Read the settings from a repository's configuration.
    pub fn init(gpa: Allocator, config: *const config_mod.Config, programs: program.Programs) Error!Signer {
        var arena_instance: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena_instance.deinit();
        const arena = arena_instance.allocator();

        const format: Format = if (config.get("gpg.format")) |raw| blk: {
            const text = try unquote(arena, raw);
            break :blk std.meta.stringToEnum(Format, text) orelse return error.UnknownSignatureFormat;
        } else .openpgp;

        // `gpg.program` and `gpg.openpgp.program` are one setting, and the
        // one the configuration names last wins.
        var chosen: ?[]const u8 = null;
        for (config.entries.items) |entry| {
            if (!std.ascii.eqlIgnoreCase(entry.section, "gpg")) continue;
            if (!std.ascii.eqlIgnoreCase(entry.name, "program")) continue;
            const this: ?Format = if (entry.subsection.len == 0)
                .openpgp
            else
                std.meta.stringToEnum(Format, entry.subsection);
            if (this != format) continue;
            chosen = entry.value orelse "";
        }
        const program_name: []const u8 = if (chosen) |raw|
            try expandPath(arena, config, try unquote(arena, raw))
        else
            format.defaultProgram();

        const min_trust: Trust = if (config.get("gpg.mintrustlevel")) |raw|
            Trust.parse(try unquote(arena, raw)) orelse return error.UnknownTrustLevel
        else
            .undefined;

        return .{
            .gpa = gpa,
            .arena = arena_instance.state,
            .programs = programs,
            .format = format,
            .program = program_name,
            .signing_key = if (config.get("user.signingkey")) |raw| try expandPath(arena, config, try unquote(arena, raw)) else null,
            .default_key_command = if (config.get("gpg.ssh.defaultkeycommand")) |raw| try unquote(arena, raw) else null,
            .allowed_signers = try config.getPath(arena, "gpg.ssh.allowedsignersfile"),
            .revocation_file = try config.getPath(arena, "gpg.ssh.revocationfile"),
            .min_trust = min_trust,
        };
    }

    /// Release the signer.
    pub fn deinit(signer: *Signer) void {
        signer.diagnostics.deinit(signer.gpa);
        var arena = signer.arena.promote(signer.gpa);
        arena.deinit();
        signer.* = undefined;
    }

    /// Sign `payload` and return the signature, which is the caller's.
    ///
    /// `key` beats `user.signingKey`; with neither, `gpg` and `gpgsm` sign
    /// as `identity`, the committer or the tagger, as git does.
    pub fn sign(signer: *Signer, io: Io, payload: []const u8, key: ?[]const u8, identity: ?object.Signature) Error![]u8 {
        signer.diagnostics.clearRetainingCapacity();
        var arena_instance: std.heap.ArenaAllocator = .init(signer.gpa);
        defer arena_instance.deinit();
        const arena = arena_instance.allocator();
        const chosen = key orelse signer.signing_key;
        return switch (signer.format) {
            .openpgp, .x509 => signer.signGpg(io, payload, chosen orelse blk: {
                const who = identity orelse return error.NoSigningKey;
                break :blk try std.fmt.allocPrint(arena, "{s} <{s}>", .{ who.name, who.email });
            }),
            .ssh => signer.signSsh(io, arena, payload, chosen orelse try signer.defaultSshKey(io, arena)),
        };
    }

    fn signGpg(signer: *Signer, io: Io, payload: []const u8, key: []const u8) Error![]u8 {
        var outcome = try program.run(signer.programs, signer.gpa, io, .{
            .argv = &.{ signer.program, "--status-fd=2", "-bsau", key },
        }, payload, .{});
        defer outcome.deinit(signer.gpa);
        // A signature was made only if gpg says so on a line of its own.
        const created = std.mem.startsWith(u8, outcome.stderr, "[GNUPG:] SIG_CREATED ") or
            std.mem.indexOf(u8, outcome.stderr, "\n[GNUPG:] SIG_CREATED ") != null;
        if (!outcome.succeeded() or !created) {
            try signer.diagnostics.appendSlice(signer.gpa, outcome.stderr);
            return error.SigningFailed;
        }
        return withoutCarriageReturns(signer.gpa, outcome.stdout);
    }

    fn signSsh(signer: *Signer, io: Io, arena: Allocator, payload: []const u8, key: []const u8) Error![]u8 {
        // A key given as text rather than as a file goes through a file, and
        // `-U` says its private half is in the agent.
        var key_file: ?TempFile = null;
        defer if (key_file) |*f| f.remove(io);
        var key_path = key;
        if (literalSshKey(key)) |text| {
            key_file = try TempFile.create(arena, io, signer.programs, ".git_signing_key_tmp", text);
            key_path = key_file.?.path;
        }
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{ signer.program, "-Y", "sign", "-n", "git", "-f", key_path });
        if (key_file != null) try argv.append(arena, "-U");
        // With no file named, `ssh-keygen` signs its standard input and
        // writes the signature to its standard output.
        var outcome = try program.run(signer.programs, signer.gpa, io, .{ .argv = argv.items }, payload, .{});
        defer outcome.deinit(signer.gpa);
        if (!outcome.succeeded() or Format.of(outcome.stdout) != .ssh) {
            try signer.diagnostics.appendSlice(signer.gpa, outcome.stderr);
            return error.SigningFailed;
        }
        return withoutCarriageReturns(signer.gpa, outcome.stdout);
    }

    /// The first line `gpg.ssh.defaultKeyCommand` prints, when it is a key.
    fn defaultSshKey(signer: *Signer, io: Io, arena: Allocator) Error![]const u8 {
        const command = signer.default_key_command orelse return error.NoSigningKey;
        const argv = try splitCommandLine(arena, command);
        if (argv.len == 0) return error.NoSigningKey;
        var outcome = try program.run(signer.programs, signer.gpa, io, .{ .argv = argv }, "", .{});
        defer outcome.deinit(signer.gpa);
        if (!outcome.succeeded()) return error.NoSigningKey;
        const end = std.mem.indexOfScalar(u8, outcome.stdout, '\n') orelse outcome.stdout.len;
        const first = outcome.stdout[0..end];
        if (literalSshKey(first) == null) return error.NoSigningKey;
        return arena.dupe(u8, first);
    }

    /// Check `signature` over `payload`. `signed_at` is the committer's or
    /// the tagger's time, which an SSH check holds the key's validity to.
    pub fn verify(signer: *Signer, io: Io, payload: []const u8, signature: []const u8, signed_at: ?i64) Error!Verdict {
        const format = Format.of(signature) orelse return error.UnknownSignature;
        var arena_instance: std.heap.ArenaAllocator = .init(signer.gpa);
        errdefer arena_instance.deinit();
        var verdict: Verdict = .{ .gpa = signer.gpa, .arena = undefined };
        const arena = arena_instance.allocator();
        // The program for the signature's own format, which need not be the
        // one this repository signs with.
        const program_name = if (format == signer.format) signer.program else format.defaultProgram();
        switch (format) {
            .openpgp, .x509 => try signer.verifyGpg(io, arena, program_name, format, payload, signature, &verdict),
            .ssh => try signer.verifySsh(io, arena, program_name, payload, signature, signed_at, &verdict),
        }
        verdict.arena = arena_instance.state;
        return verdict;
    }

    fn verifyGpg(
        signer: *Signer,
        io: Io,
        arena: Allocator,
        program_name: []const u8,
        format: Format,
        payload: []const u8,
        signature: []const u8,
        verdict: *Verdict,
    ) Error!void {
        var sig_file = try TempFile.create(arena, io, signer.programs, ".git_vtag_tmp", signature);
        defer sig_file.remove(io);
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(arena, program_name);
        if (format == .openpgp) try argv.append(arena, "--keyid-format=long");
        try argv.appendSlice(arena, &.{ "--status-fd=1", "--verify", sig_file.path, "-" });
        var outcome = try program.run(signer.programs, signer.gpa, io, .{ .argv = argv.items }, payload, .{});
        defer outcome.deinit(signer.gpa);
        verdict.output = try arena.dupe(u8, outcome.stderr);
        verdict.status = try arena.dupe(u8, outcome.stdout);
        verdict.accepted = outcome.succeeded() and
            (std.mem.indexOf(u8, outcome.stdout, "\n[GNUPG:] GOODSIG ") != null or
                std.mem.indexOf(u8, outcome.stdout, "\n[GNUPG:] EXPKEYSIG ") != null);
        parseGpgStatus(verdict);
    }

    fn verifySsh(
        signer: *Signer,
        io: Io,
        arena: Allocator,
        program_name: []const u8,
        payload: []const u8,
        signature: []const u8,
        signed_at: ?i64,
        verdict: *Verdict,
    ) Error!void {
        const allowed = signer.allowed_signers orelse return error.AllowedSignersFileMissing;
        var sig_file = try TempFile.create(arena, io, signer.programs, ".git_vtag_tmp", signature);
        defer sig_file.remove(io);

        // A key's validity window is compared with the time the object says
        // it was signed. git writes that time in the local zone; it is
        // written here in UTC, marked so, which names the same moment.
        var time_arg: ?[]const u8 = null;
        if (signed_at) |secs| time_arg = try verifyTime(arena, secs);

        var find: std.ArrayList([]const u8) = .empty;
        try find.appendSlice(arena, &.{ program_name, "-Y", "find-principals", "-f", allowed, "-s", sig_file.path });
        if (time_arg) |t| try find.append(arena, t);
        var principals = try program.run(signer.programs, signer.gpa, io, .{ .argv = find.items }, "", .{});
        defer principals.deinit(signer.gpa);

        var output: std.ArrayList(u8) = .empty;
        var err_output: std.ArrayList(u8) = .empty;
        if (!principals.succeeded() or principals.stdout.len == 0) {
            // No principal in the allowed signers: check the signature
            // alone, which shows whose key it is, and fail it.
            var check: std.ArrayList([]const u8) = .empty;
            try check.appendSlice(arena, &.{ program_name, "-Y", "check-novalidate", "-n", "git", "-s", sig_file.path });
            if (time_arg) |t| try check.append(arena, t);
            var checked = try program.run(signer.programs, signer.gpa, io, .{ .argv = check.items }, payload, .{});
            defer checked.deinit(signer.gpa);
            try output.appendSlice(arena, checked.stdout);
            try err_output.appendSlice(arena, checked.stderr);
        } else {
            var lines = std.mem.splitScalar(u8, principals.stdout, '\n');
            while (lines.next()) |raw| {
                const principal = std.mem.trimEnd(u8, raw, "\r");
                if (principal.len == 0) continue;
                var check: std.ArrayList([]const u8) = .empty;
                try check.appendSlice(arena, &.{ program_name, "-Y", "verify", "-n", "git", "-f", allowed, "-I", principal, "-s", sig_file.path });
                if (time_arg) |t| try check.append(arena, t);
                if (signer.revocation_file) |revoked| {
                    if (Io.Dir.accessAbsolute(io, revoked, .{})) |_| {
                        try check.appendSlice(arena, &.{ "-r", revoked });
                    } else |_| {}
                }
                var checked = try program.run(signer.programs, signer.gpa, io, .{ .argv = check.items }, payload, .{});
                defer checked.deinit(signer.gpa);
                output.clearRetainingCapacity();
                err_output.clearRetainingCapacity();
                try output.appendSlice(arena, checked.stdout);
                try err_output.appendSlice(arena, checked.stderr);
                if (checked.succeeded() and std.mem.startsWith(u8, checked.stdout, "Good")) {
                    verdict.accepted = true;
                    break;
                }
            }
        }

        const text = try stripspace(arena, output.items);
        const errors = try stripspace(arena, err_output.items);
        verdict.output = try std.mem.concat(arena, u8, &.{ text, principals.stderr, errors });
        verdict.status = verdict.output;
        parseSshOutput(verdict);
    }
};

/// `-Overify-time=YYYYMMDDHHMMSSZ` for a moment in seconds since the epoch.
fn verifyTime(arena: Allocator, secs: i64) Allocator.Error![]const u8 {
    const clamped: u64 = if (secs < 0) 0 else @intCast(secs);
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = clamped };
    const day = epoch.getEpochDay().calculateYearDay();
    const month_day = day.calculateMonthDay();
    const clock = epoch.getDaySeconds();
    return std.fmt.allocPrint(arena, "-Overify-time={d:0>4}{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}Z", .{
        day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        clock.getHoursIntoDay(),
        clock.getMinutesIntoHour(),
        clock.getSecondsIntoMinute(),
    });
}

/// Read gpg's status lines as git reads them: the one result line, the key
/// and user id beside it, the fingerprints, and the trust. A second result
/// line means more than one signature, which git refuses to judge, and so
/// does this.
fn parseGpgStatus(v: *Verdict) void {
    const Line = struct { prefix: []const u8, result: ?Result, exclusive: bool, key: bool, uid: bool };
    const table = [_]Line{
        .{ .prefix = "GOODSIG ", .result = .good, .exclusive = true, .key = true, .uid = true },
        .{ .prefix = "BADSIG ", .result = .bad, .exclusive = true, .key = true, .uid = true },
        .{ .prefix = "ERRSIG ", .result = .cannot_check, .exclusive = true, .key = true, .uid = false },
        .{ .prefix = "EXPSIG ", .result = .expired_signature, .exclusive = true, .key = true, .uid = true },
        .{ .prefix = "EXPKEYSIG ", .result = .expired_key, .exclusive = true, .key = true, .uid = true },
        .{ .prefix = "REVKEYSIG ", .result = .revoked_key, .exclusive = true, .key = true, .uid = true },
    };
    var seen_exclusive = false;
    var lines = std.mem.splitScalar(u8, v.status, '\n');
    while (lines.next()) |raw| {
        const line = if (std.mem.startsWith(u8, raw, "[GNUPG:] ")) raw["[GNUPG:] ".len..] else continue;
        for (table) |entry| {
            if (!std.mem.startsWith(u8, line, entry.prefix)) continue;
            if (entry.exclusive) {
                if (seen_exclusive) return fail(v);
                seen_exclusive = true;
            }
            v.result = entry.result.?;
            const rest = line[entry.prefix.len..];
            const space = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
            v.key = rest[0..space];
            if (entry.uid and space < rest.len) v.signer = rest[space + 1 ..];
            break;
        } else if (std.mem.startsWith(u8, line, "VALIDSIG ")) {
            var fields = std.mem.splitScalar(u8, line["VALIDSIG ".len..], ' ');
            v.fingerprint = fields.next();
            // The primary key's fingerprint is the tenth field, and only an
            // OpenPGP signature has one.
            var i: usize = 0;
            while (fields.next()) |field| {
                i += 1;
                if (i == 9) v.primary_fingerprint = field;
            }
        } else if (std.mem.startsWith(u8, line, "TRUST_")) {
            const rest = line["TRUST_".len..];
            const end = std.mem.indexOfAny(u8, rest, " \n") orelse rest.len;
            v.trust = Trust.parse(rest[0..end]) orelse return fail(v);
        }
    }
    if (v.result == .good and (v.trust == .undefined or v.trust == .never)) v.result = .good_untrusted;
}

fn fail(v: *Verdict) void {
    v.result = .cannot_check;
    v.key = null;
    v.signer = null;
    v.fingerprint = null;
    v.primary_fingerprint = null;
}

/// Read `ssh-keygen`'s answer as git reads it. `Good "git" signature for
/// <principal> with <type> key <fingerprint>` is good and trusted;
/// `Good "git" signature with …`, from a key no allowed signer names, is good
/// and untrusted; anything else is bad.
fn parseSshOutput(v: *Verdict) void {
    v.result = .bad;
    v.trust = .never;
    const end = std.mem.indexOfScalar(u8, v.output, '\n') orelse v.output.len;
    var line = v.output[0..end];
    const for_prefix = "Good \"git\" signature for ";
    const with_prefix = "Good \"git\" signature with ";
    if (std.mem.startsWith(u8, line, for_prefix)) {
        const principal_start = line[for_prefix.len..];
        // The principal may itself hold " with ", so the last one ends it.
        const last = std.mem.lastIndexOf(u8, principal_start, " with ") orelse return;
        v.result = .good;
        v.trust = .fully;
        v.signer = principal_start[0..last];
        line = principal_start[last + 1 ..];
    } else if (std.mem.startsWith(u8, line, with_prefix)) {
        v.result = .good_untrusted;
        v.trust = .undefined;
        line = line[with_prefix.len..];
    } else return;
    const key_at = std.mem.indexOf(u8, line, "key ") orelse {
        v.result = .bad;
        return;
    };
    v.fingerprint = line[key_at + 4 ..];
    v.key = v.fingerprint;
}

/// A signed object taken apart: what the signature covers, and the
/// signature. Both are the caller's.
pub const Signed = struct {
    payload: []u8,
    signature: []u8,

    /// Release both.
    pub fn deinit(s: *Signed, gpa: Allocator) void {
        gpa.free(s.payload);
        gpa.free(s.signature);
        s.* = undefined;
    }
};

/// The header a commit's signature goes in for this hash.
pub fn commitHeader(kind: hash.Kind) []const u8 {
    return switch (kind) {
        .sha1 => "gpgsig",
        .sha256 => "gpgsig-sha256",
    };
}

/// Take a commit's signature out of it, as git does: the header for this
/// hash is the signature, unfolded, and every `gpgsig` header — this hash's
/// or another's — comes out of the payload. `null` when it is not signed.
pub fn splitCommit(gpa: Allocator, kind: hash.Kind, bytes: []const u8) Allocator.Error!?Signed {
    const header = commitHeader(kind);
    var payload: std.ArrayList(u8) = .empty;
    errdefer payload.deinit(gpa);
    var signature: std.ArrayList(u8) = .empty;
    errdefer signature.deinit(gpa);
    var in_signature = false;
    var other_signature = false;
    var saw = false;
    var at: usize = 0;
    while (at < bytes.len) {
        const nl = std.mem.indexOfScalarPos(u8, bytes, at, '\n');
        var next = if (nl) |n| n + 1 else bytes.len;
        const line = bytes[at..next];
        var sig: ?[]const u8 = null;
        if (in_signature and line[0] == ' ') {
            sig = line[1..];
        } else if (std.mem.startsWith(u8, line, header) and line.len > header.len and line[header.len] == ' ') {
            sig = line[header.len + 1 ..];
            other_signature = false;
        } else if (std.mem.startsWith(u8, line, "gpgsig")) {
            other_signature = true;
        } else if (other_signature and line[0] != ' ') {
            other_signature = false;
        }
        if (sig) |s| {
            try signature.appendSlice(gpa, s);
            saw = true;
            in_signature = true;
        } else {
            // The message is past the headers, and all of it is payload.
            if (line[0] == '\n') next = bytes.len;
            if (!other_signature) try payload.appendSlice(gpa, bytes[at..next]);
            in_signature = false;
        }
        at = next;
    }
    if (!saw) {
        payload.deinit(gpa);
        signature.deinit(gpa);
        return null;
    }
    return .{ .payload = try payload.toOwnedSlice(gpa), .signature = try signature.toOwnedSlice(gpa) };
}

/// Take a tag's signature out of it, as git does: the signature starts at
/// the last line that opens one, and a `gpgsig` header in the tag's own
/// headers comes out of the payload. `null` when it is not signed.
pub fn splitTag(gpa: Allocator, bytes: []const u8) Allocator.Error!?Signed {
    var match: usize = bytes.len;
    var at: usize = 0;
    while (at < bytes.len) {
        if (Format.of(bytes[at..]) != null) match = at;
        const nl = std.mem.indexOfScalarPos(u8, bytes, at, '\n');
        at = if (nl) |n| n + 1 else bytes.len;
    }
    if (match == bytes.len) return null;
    const payload = try removeHeaderSignatures(gpa, bytes[0..match]);
    errdefer gpa.free(payload);
    return .{ .payload = payload, .signature = try gpa.dupe(u8, bytes[match..]) };
}

fn removeHeaderSignatures(gpa: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var in_signature = false;
    var at: usize = 0;
    while (at < bytes.len) {
        const nl = std.mem.indexOfScalarPos(u8, bytes, at, '\n');
        var next = if (nl) |n| n + 1 else bytes.len;
        const line = bytes[at..next];
        if (in_signature and line[0] == ' ') {
            // Still inside the signature header.
        } else if ((std.mem.startsWith(u8, line, "gpgsig ") or std.mem.startsWith(u8, line, "gpgsig-sha256 "))) {
            in_signature = true;
        } else {
            if (line[0] == '\n') next = bytes.len;
            try out.appendSlice(gpa, bytes[at..next]);
            in_signature = false;
        }
        at = next;
    }
    return out.toOwnedSlice(gpa);
}

/// A commit's bytes, signed: the fields written once to be signed, then
/// again with the signature as the last header.
pub fn signCommit(signer: *Signer, io: Io, kind: hash.Kind, fields: object.Commit.Fields, key: ?[]const u8) (Error || object.Commit.WriteError)![]u8 {
    const gpa = signer.gpa;
    const payload = try object.Commit.build(gpa, kind, fields);
    defer gpa.free(payload);
    const signature = try signer.sign(io, payload, key, fields.committer);
    defer gpa.free(signature);
    const value = if (std.mem.endsWith(u8, signature, "\n")) signature[0 .. signature.len - 1] else signature;

    const extra = try gpa.alloc(object.ExtraHeader, fields.extra.len + 1);
    defer gpa.free(extra);
    @memcpy(extra[0..fields.extra.len], fields.extra);
    extra[fields.extra.len] = .{ .name = commitHeader(kind), .value = value };
    var signed = fields;
    signed.extra = extra;
    return object.Commit.build(gpa, kind, signed);
}

/// A tag's bytes, signed: the tag with the signature after its message.
pub fn signTag(signer: *Signer, io: Io, kind: hash.Kind, fields: object.Tag.Fields, key: ?[]const u8) (Error || object.Tag.WriteError)![]u8 {
    const gpa = signer.gpa;
    const payload = try object.Tag.build(gpa, kind, fields);
    defer gpa.free(payload);
    const signature = try signer.sign(io, payload, key, fields.tagger);
    defer gpa.free(signature);
    return std.mem.concat(gpa, u8, &.{ payload, signature });
}

/// Check a commit's signature: `git verify-commit`, or `%G?` in a log.
pub fn verifyCommit(signer: *Signer, io: Io, kind: hash.Kind, bytes: []const u8) (Error || object.ParseError)!Verdict {
    var split = (try splitCommit(signer.gpa, kind, bytes)) orelse return .{ .gpa = signer.gpa, .arena = .{} };
    defer split.deinit(signer.gpa);
    var parsed = try object.Commit.parse(signer.gpa, kind, bytes);
    defer parsed.deinit();
    return signer.verify(io, split.payload, split.signature, parsed.committer.when_secs);
}

/// Check a tag's signature: `git verify-tag`.
pub fn verifyTag(signer: *Signer, io: Io, kind: hash.Kind, bytes: []const u8) (Error || object.ParseError)!Verdict {
    var split = (try splitTag(signer.gpa, bytes)) orelse return .{ .gpa = signer.gpa, .arena = .{} };
    defer split.deinit(signer.gpa);
    var parsed = try object.Tag.parse(signer.gpa, kind, bytes);
    defer parsed.deinit();
    return signer.verify(io, split.payload, split.signature, if (parsed.tagger) |t| t.when_secs else null);
}

/// A literal SSH key in place of a file: `key::<key>`, or a line that
/// begins `ssh-`. The key text, or `null` for a path.
fn literalSshKey(text: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, text, "key::")) return text["key::".len..];
    if (std.mem.startsWith(u8, text, "ssh-")) return text;
    return null;
}

fn withoutCarriageReturns(gpa: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    const out = try gpa.alloc(u8, bytes.len);
    var n: usize = 0;
    for (bytes) |c| {
        if (c == '\r') continue;
        out[n] = c;
        n += 1;
    }
    return gpa.realloc(out, n);
}

fn unquote(arena: Allocator, raw: []const u8) (Allocator.Error || error{MalformedValue})![]u8 {
    return config_mod.unquote(arena, raw) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.MalformedValue,
    };
}

fn expandPath(arena: Allocator, config: *const config_mod.Config, text: []const u8) Allocator.Error![]const u8 {
    if (std.mem.startsWith(u8, text, "~/")) {
        if (config.context.home) |home| return std.fmt.allocPrint(arena, "{s}/{s}", .{ home, text[2..] });
    }
    return text;
}

/// A command line split into words the way git splits
/// `gpg.ssh.defaultKeyCommand`: at whitespace, with single and double quotes
/// and backslashes keeping a word together, and no shell.
fn splitCommandLine(arena: Allocator, line: []const u8) Allocator.Error![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var word: std.ArrayList(u8) = .empty;
    var in_word = false;
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (quote != 0) {
            if (c == quote) {
                quote = 0;
            } else if (c == '\\' and quote == '"' and i + 1 < line.len) {
                i += 1;
                try word.append(arena, line[i]);
            } else try word.append(arena, c);
            continue;
        }
        switch (c) {
            ' ', '\t', '\n' => if (in_word) {
                try words.append(arena, try word.toOwnedSlice(arena));
                in_word = false;
            },
            '\'', '"' => {
                quote = c;
                in_word = true;
            },
            '\\' => {
                in_word = true;
                if (i + 1 < line.len) {
                    i += 1;
                    try word.append(arena, line[i]);
                }
            },
            else => {
                in_word = true;
                try word.append(arena, c);
            },
        }
    }
    if (in_word) try words.append(arena, try word.toOwnedSlice(arena));
    return words.items;
}

/// git's `stripspace` without comments, for the verifier's output.
fn stripspace(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var empties: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r\n");
        if (line.len == 0) {
            empties += 1;
            continue;
        }
        if (empties > 0 and out.items.len > 0) try out.append(arena, '\n');
        empties = 0;
        try out.appendSlice(arena, line);
        try out.append(arena, '\n');
    }
    return out.items;
}

/// A file in the caller's temporary directory holding bytes a program
/// reads by name.
const TempFile = struct {
    path: []const u8,

    fn create(arena: Allocator, io: Io, programs: program.Programs, prefix: []const u8, bytes: []const u8) Error!TempFile {
        const dir_path = programs.environ.get("TMPDIR") orelse
            programs.environ.get("TEMP") orelse
            programs.environ.get("TMP") orelse
            (if (builtin.os.tag == .windows) return error.NoTemporaryDirectory else "/tmp");
        var name_buf: [96]u8 = undefined;
        const name = fs.tempName(io, &name_buf, prefix);
        const path = try std.fs.path.join(arena, &.{ dir_path, name });
        const file = try Io.Dir.createFileAbsolute(io, path, .{ .exclusive = true });
        defer file.close(io);
        errdefer Io.Dir.deleteFileAbsolute(io, path) catch {};
        try file.writePositionalAll(io, bytes, 0);
        return .{ .path = path };
    }

    fn remove(f: *TempFile, io: Io) void {
        Io.Dir.deleteFileAbsolute(io, f.path) catch {};
    }
};

//=========================================================================
// Tests
//=========================================================================

const testing = std.testing;

test "a commit's signature comes out as git takes it out, other hashes' too" {
    const gpa = testing.allocator;
    const bytes =
        "tree 1111111111111111111111111111111111111111\n" ++
        "author A <a@b> 1 +0000\n" ++
        "committer A <a@b> 1 +0000\n" ++
        "gpgsig-sha256 -----BEGIN PGP SIGNATURE-----\n" ++
        " other\n" ++
        "gpgsig -----BEGIN PGP SIGNATURE-----\n" ++
        " \n" ++
        " body\n" ++
        " -----END PGP SIGNATURE-----\n" ++
        "\n" ++
        "message\n gpgsig not a header\n";
    var split = (try splitCommit(gpa, .sha1, bytes)).?;
    defer split.deinit(gpa);
    try testing.expectEqualStrings(
        "tree 1111111111111111111111111111111111111111\n" ++
            "author A <a@b> 1 +0000\n" ++
            "committer A <a@b> 1 +0000\n" ++
            "\n" ++
            "message\n gpgsig not a header\n",
        split.payload,
    );
    try testing.expectEqualStrings("-----BEGIN PGP SIGNATURE-----\n\nbody\n-----END PGP SIGNATURE-----\n", split.signature);
    try testing.expect((try splitCommit(gpa, .sha1, "tree 1\n\nno signature\n")) == null);
}

test "a tag's signature is the last block that opens one" {
    const gpa = testing.allocator;
    const bytes = "object 1\ntype commit\ntag v1\n\nmessage\n-----BEGIN SSH SIGNATURE-----\nnot this\n-----BEGIN PGP SIGNATURE-----\nthis\n";
    var split = (try splitTag(gpa, bytes)).?;
    defer split.deinit(gpa);
    try testing.expectEqualStrings("object 1\ntype commit\ntag v1\n\nmessage\n-----BEGIN SSH SIGNATURE-----\nnot this\n", split.payload);
    try testing.expectEqualStrings("-----BEGIN PGP SIGNATURE-----\nthis\n", split.signature);
}

test "gpg's status lines read as git reads them" {
    var v: Verdict = .{ .gpa = testing.allocator, .arena = .{} };
    v.status =
        \\[GNUPG:] NEWSIG relic@example.com
        \\[GNUPG:] GOODSIG B945CF259336F221 Relic Test <relic@example.com>
        \\[GNUPG:] VALIDSIG F5E3 2026-09-23 1790200136 0 4 0 22 10 00 A1B2
        \\[GNUPG:] TRUST_ULTIMATE 0 pgp relic@example.com
        \\
    ;
    parseGpgStatus(&v);
    try testing.expectEqual(@as(u8, 'G'), v.letter());
    try testing.expectEqualStrings("B945CF259336F221", v.key.?);
    try testing.expectEqualStrings("Relic Test <relic@example.com>", v.signer.?);
    try testing.expectEqualStrings("F5E3", v.fingerprint.?);
    try testing.expectEqualStrings("A1B2", v.primary_fingerprint.?);
    try testing.expectEqual(Trust.ultimate, v.trust);

    var untrusted: Verdict = .{ .gpa = testing.allocator, .arena = .{} };
    untrusted.status = "[GNUPG:] GOODSIG AB Someone\n[GNUPG:] TRUST_UNDEFINED 0 pgp\n";
    untrusted.accepted = true;
    parseGpgStatus(&untrusted);
    try testing.expectEqual(@as(u8, 'U'), untrusted.letter());
    try testing.expect(untrusted.verified(.undefined));
    try testing.expect(!untrusted.verified(.marginal));

    var twice: Verdict = .{ .gpa = testing.allocator, .arena = .{} };
    twice.status = "[GNUPG:] GOODSIG AB One\n[GNUPG:] BADSIG CD Two\n";
    parseGpgStatus(&twice);
    try testing.expectEqual(@as(u8, 'E'), twice.letter());
    try testing.expect(twice.key == null);

    var missing: Verdict = .{ .gpa = testing.allocator, .arena = .{} };
    missing.status = "[GNUPG:] ERRSIG B945CF259336F221 22 10 00 1790200136 9 F5E3\n[GNUPG:] NO_PUBKEY B945CF259336F221\n";
    parseGpgStatus(&missing);
    try testing.expectEqual(@as(u8, 'E'), missing.letter());
}

test "ssh-keygen's answer reads as git reads it" {
    var good: Verdict = .{ .gpa = testing.allocator, .arena = .{} };
    good.output = "Good \"git\" signature for a with b with ED25519 key SHA256:abc\n";
    parseSshOutput(&good);
    try testing.expectEqual(@as(u8, 'G'), good.letter());
    try testing.expectEqualStrings("a with b", good.signer.?);
    try testing.expectEqualStrings("SHA256:abc", good.key.?);

    var unknown: Verdict = .{ .gpa = testing.allocator, .arena = .{} };
    unknown.output = "Good \"git\" signature with ED25519 key SHA256:abc\n";
    parseSshOutput(&unknown);
    try testing.expectEqual(@as(u8, 'U'), unknown.letter());

    var bad: Verdict = .{ .gpa = testing.allocator, .arena = .{} };
    bad.output = "Signature verification failed\n";
    parseSshOutput(&bad);
    try testing.expectEqual(@as(u8, 'B'), bad.letter());
}

test "the verify time is the moment in UTC, marked so" {
    const gpa = testing.allocator;
    const text = try verifyTime(gpa, 1_700_000_000);
    defer gpa.free(text);
    try testing.expectEqualStrings("-Overify-time=20231114221320Z", text);
}

test "a key command splits into words without a shell" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const words = try splitCommandLine(arena.allocator(), "ssh-add -L 'a b' \"c\\\"d\" e\\ f");
    try testing.expectEqual(@as(usize, 5), words.len);
    try testing.expectEqualStrings("ssh-add", words[0]);
    try testing.expectEqualStrings("a b", words[2]);
    try testing.expectEqualStrings("c\"d", words[3]);
    try testing.expectEqualStrings("e f", words[4]);
}

test "fuzz: any commit bytes split into a payload and a signature or into nothing" {
    try testing.fuzz({}, fuzzSplit, .{});
}

fn fuzzSplit(_: void, smith: *testing.Smith) anyerror!void {
    const gpa = testing.allocator;
    var scratch: [1024]u8 = undefined;
    const bytes = scratch[0..smith.slice(&scratch)];
    if (try splitCommit(gpa, .sha1, bytes)) |value| {
        var split = value;
        defer split.deinit(gpa);
        try testing.expect(split.payload.len + split.signature.len <= bytes.len);
    }
    if (try splitTag(gpa, bytes)) |value| {
        var split = value;
        defer split.deinit(gpa);
        try testing.expect(Format.of(split.signature) != null);
    }
    var v: Verdict = .{ .gpa = gpa, .arena = .{} };
    v.status = bytes;
    parseGpgStatus(&v);
    v.output = bytes;
    parseSshOutput(&v);
}
