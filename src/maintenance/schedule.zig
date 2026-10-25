//! What git's `maintenance start` registers with each scheduler
//! (`builtin/gc.c`, `launchctl_schedule_plist`,
//! `systemd_timer_write_timer_file`, `systemd_timer_write_service_template`,
//! `schtasks_schedule_task`, `crontab_update_schedule`), as data: the
//! files, tasks and crontab lines, byte for byte what git writes, for the
//! caller to install. Nothing here runs a scheduler or writes a file.

const Self = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const Schedule = @import("run.zig").Schedule;

/// git's schedulers, `--scheduler=<scheduler>`.
pub const Scheduler = enum {
    launchctl,
    schtasks,
    cron,
    systemd_timer,

    /// `parse_scheduler` but for `auto`: `cron` or `crontab`, `systemd` or
    /// `systemd-timer`, any case.
    pub fn parse(text: []const u8) ?Scheduler {
        if (std.ascii.eqlIgnoreCase(text, "launchctl")) return .launchctl;
        if (std.ascii.eqlIgnoreCase(text, "schtasks")) return .schtasks;
        if (std.ascii.eqlIgnoreCase(text, "cron") or std.ascii.eqlIgnoreCase(text, "crontab")) return .cron;
        if (std.ascii.eqlIgnoreCase(text, "systemd") or std.ascii.eqlIgnoreCase(text, "systemd-timer")) return .systemd_timer;
        return null;
    }
};

/// What the scheduled command is built from.
pub const Inputs = struct {
    /// git's exec path (`git --exec-path`): the scheduled program is
    /// `<exec_path>/git`, or `headless-git.exe` beside it for `schtasks`.
    exec_path: []const u8,
    /// The minute each run starts at; git picks one at random, 13 under
    /// its tests.
    minute: u6,
};

/// Where a scheduler file lives.
pub const Base = enum {
    /// `~`: launchd's `Library/LaunchAgents/`.
    home,
    /// `$XDG_CONFIG_HOME`, `~/.config` unless set: systemd's
    /// `systemd/user/`.
    xdg_config_home,
    /// Nowhere: a schtasks task, created by its name from the XML.
    none,
};

/// One file, or one schtasks task.
pub const Entry = struct {
    /// Relative to `base`, or for schtasks the task's name.
    path: []const u8,
    contents: []const u8,
};

/// What one scheduler registers. Release it with `deinit`.
pub const Registration = struct {
    pub const Error = Self.Error;

    arena: std.heap.ArenaAllocator,
    base: Base,
    entries: []const Entry,

    pub fn deinit(r: *Registration) void {
        r.arena.deinit();
        r.* = undefined;
    }
};

pub const Error = Allocator.Error || error{
    /// `cron` registers lines in the crontab, not files: `crontab`.
    NotFiles,
};

const frequencies = [_]Schedule{ .hourly, .daily, .weekly };

/// The `-c` settings every scheduled run carries, as git's `extraconfig`.
const extra = [_][]const u8{ "credential.interactive=false", "core.askPass=true" };

/// What `scheduler` registers for the three frequencies: launchd's
/// plists, systemd's service template and timers, schtasks' tasks.
pub fn registration(gpa: Allocator, scheduler: Scheduler, inputs: Inputs) Self.Error!Registration {
    var reg: Registration = .{ .arena = .init(gpa), .base = .none, .entries = &.{} };
    errdefer reg.arena.deinit();
    const arena = reg.arena.allocator();
    var entries: std.ArrayList(Entry) = .empty;
    switch (scheduler) {
        .cron => return error.NotFiles,
        .launchctl => {
            reg.base = .home;
            for (frequencies) |f| {
                const name = try arena.print("org.git-scm.git.{t}", .{f});
                try entries.append(arena, .{ .path = try arena.print("Library/LaunchAgents/{s}.plist", .{name}), .contents = try plist(arena, name, f, inputs) });
            }
        },
        .systemd_timer => {
            reg.base = .xdg_config_home;
            try entries.append(arena, .{ .path = "systemd/user/git-maintenance@.service", .contents = try service(arena, inputs) });
            for (frequencies) |f| try entries.append(arena, .{ .path = try arena.print("systemd/user/git-maintenance@{t}.timer", .{f}), .contents = try timer(arena, f, inputs) });
        },
        .schtasks => for (frequencies) |f| {
            try entries.append(arena, .{ .path = try arena.print("Git Maintenance ({t})", .{f}), .contents = try task(arena, f, inputs) });
        },
    }
    reg.entries = try entries.toOwnedSlice(arena);
    return reg;
}

fn plist(arena: Allocator, name: []const u8, f: Schedule, inputs: Inputs) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena,
        \\<?xml version="1.0"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0"><dict>
        \\<key>Label</key><string>{s}</string>
        \\<key>ProgramArguments</key>
        \\<array>
        \\<string>{s}/git</string>
        \\<string>--exec-path={s}</string>
        \\
    , .{ name, inputs.exec_path, inputs.exec_path });
    for (extra) |setting| try out.print(arena, "<string>-c</string>\n<string>{s}</string>\n", .{setting});
    try out.print(arena,
        \\<string>for-each-repo</string>
        \\<string>--keep-going</string>
        \\<string>--config=maintenance.repo</string>
        \\<string>maintenance</string>
        \\<string>run</string>
        \\<string>--schedule={t}</string>
        \\</array>
        \\<key>StartCalendarInterval</key>
        \\<array>
        \\
    , .{f});
    switch (f) {
        .hourly => for (1..24) |hour| try out.print(arena, "<dict>\n<key>Hour</key><integer>{d}</integer>\n<key>Minute</key><integer>{d}</integer>\n</dict>\n", .{ hour, inputs.minute }),
        .daily => for (1..7) |day| try out.print(arena, "<dict>\n<key>Weekday</key><integer>{d}</integer>\n<key>Hour</key><integer>0</integer>\n<key>Minute</key><integer>{d}</integer>\n</dict>\n", .{ day, inputs.minute }),
        .weekly => try out.print(arena, "<dict>\n<key>Weekday</key><integer>0</integer>\n<key>Hour</key><integer>0</integer>\n<key>Minute</key><integer>{d}</integer>\n</dict>\n", .{inputs.minute}),
    }
    try out.appendSlice(arena, "</array>\n</dict>\n</plist>\n");
    return out.items;
}

/// `get_extra_config_parameters`: `-c <setting> ` for each. git's formats put a space
/// after it too, so the command has two before `for-each-repo`.
fn extraParameters(arena: Allocator) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (extra) |setting| try out.print(arena, "-c {s} ", .{setting});
    return out.items;
}

const unit_preamble =
    \\# This file was created and is maintained by Git.
    \\# Any edits made in this file might be replaced in the future
    \\# by a Git command.
    \\
    \\[Unit]
    \\Description=Optimize Git repositories data
    \\
    \\
;

fn service(arena: Allocator, inputs: Inputs) Allocator.Error![]const u8 {
    return arena.print(unit_preamble ++
        \\[Service]
        \\Type=oneshot
        \\ExecStart="{s}/git" --exec-path="{s}" {s} for-each-repo --keep-going --config=maintenance.repo maintenance run --schedule=%i
        \\LockPersonality=yes
        \\MemoryDenyWriteExecute=yes
        \\NoNewPrivileges=yes
        \\RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_VSOCK
        \\RestrictNamespaces=yes
        \\RestrictRealtime=yes
        \\RestrictSUIDSGID=yes
        \\SystemCallArchitectures=native
        \\SystemCallFilter=@system-service
        \\
    , .{ inputs.exec_path, inputs.exec_path, try extraParameters(arena) });
}

fn timer(arena: Allocator, f: Schedule, inputs: Inputs) Allocator.Error![]const u8 {
    const pattern = switch (f) {
        .hourly => try arena.print("*-*-* 1..23:{d:0>2}:00", .{inputs.minute}),
        .daily => try arena.print("Tue..Sun *-*-* 0:{d:0>2}:00", .{inputs.minute}),
        .weekly => try arena.print("Mon 0:{d:0>2}:00", .{inputs.minute}),
    };
    return arena.print(unit_preamble ++
        \\[Timer]
        \\OnCalendar={s}
        \\Persistent=true
        \\
        \\[Install]
        \\WantedBy=timers.target
        \\
    , .{pattern});
}

fn task(arena: Allocator, f: Schedule, inputs: Inputs) Allocator.Error![]const u8 {
    const trigger = switch (f) {
        .hourly => try arena.print(
            \\<StartBoundary>2020-01-01T01:{d:0>2}:00</StartBoundary>
            \\<Enabled>true</Enabled>
            \\<ScheduleByDay>
            \\<DaysInterval>1</DaysInterval>
            \\</ScheduleByDay>
            \\<Repetition>
            \\<Interval>PT1H</Interval>
            \\<Duration>PT23H</Duration>
            \\<StopAtDurationEnd>false</StopAtDurationEnd>
            \\</Repetition>
            \\
        , .{inputs.minute}),
        .daily => try arena.print(
            \\<StartBoundary>2020-01-01T00:{d:0>2}:00</StartBoundary>
            \\<Enabled>true</Enabled>
            \\<ScheduleByWeek>
            \\<DaysOfWeek>
            \\<Monday />
            \\<Tuesday />
            \\<Wednesday />
            \\<Thursday />
            \\<Friday />
            \\<Saturday />
            \\</DaysOfWeek>
            \\<WeeksInterval>1</WeeksInterval>
            \\</ScheduleByWeek>
            \\
        , .{inputs.minute}),
        .weekly => try arena.print(
            \\<StartBoundary>2020-01-01T00:{d:0>2}:00</StartBoundary>
            \\<Enabled>true</Enabled>
            \\<ScheduleByWeek>
            \\<DaysOfWeek>
            \\<Sunday />
            \\</DaysOfWeek>
            \\<WeeksInterval>1</WeeksInterval>
            \\</ScheduleByWeek>
            \\
        , .{inputs.minute}),
    };
    return arena.print(
        \\<?xml version="1.0" ?>
        \\<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
        \\<Triggers>
        \\<CalendarTrigger>
        \\{s}</CalendarTrigger>
        \\</Triggers>
        \\<Principals>
        \\<Principal id="Author">
        \\<LogonType>InteractiveToken</LogonType>
        \\<RunLevel>LeastPrivilege</RunLevel>
        \\</Principal>
        \\</Principals>
        \\<Settings>
        \\<MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
        \\<Enabled>true</Enabled>
        \\<Hidden>true</Hidden>
        \\<UseUnifiedSchedulingEngine>true</UseUnifiedSchedulingEngine>
        \\<WakeToRun>false</WakeToRun>
        \\<ExecutionTimeLimit>PT72H</ExecutionTimeLimit>
        \\<Priority>7</Priority>
        \\</Settings>
        \\<Actions Context="Author">
        \\<Exec>
        \\<Command>"{s}\headless-git.exe"</Command>
        \\<Arguments>--exec-path="{s}" {s} for-each-repo --keep-going --config=maintenance.repo maintenance run --schedule={t}</Arguments>
        \\</Exec>
        \\</Actions>
        \\</Task>
        \\
    , .{ trigger, inputs.exec_path, inputs.exec_path, try extraParameters(arena), f });
}

const begin_line = "# BEGIN GIT MAINTENANCE SCHEDULE";
const end_line = "# END GIT MAINTENANCE SCHEDULE";

/// `crontab_update_schedule`: `existing` (what `crontab -l` printed) with
/// git's region taken out, and with `inputs` a new one at the end; in
/// `gpa`.
pub fn crontab(gpa: Allocator, existing: []const u8, inputs: ?Inputs) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var in_old_region = false;
    var lines = std.mem.splitScalar(u8, existing, '\n');
    while (lines.next()) |line| {
        // `strbuf_getline_lf`: the text after the last newline is a line
        // only when there is some.
        if (lines.index == null and line.len == 0) break;
        if (!in_old_region and std.mem.eql(u8, line, begin_line)) {
            in_old_region = true;
        } else if (in_old_region and std.mem.eql(u8, line, end_line)) {
            in_old_region = false;
        } else if (!in_old_region) try out.print(gpa, "{s}\n", .{line});
    }
    const given = inputs orelse return out.toOwnedSlice(gpa);
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const parameters = try extraParameters(arena_instance.allocator());
    try out.print(gpa, "{s}\n# The following schedule was created by Git\n# Any edits made in this region might be\n# replaced in the future by a Git command.\n\n", .{begin_line});
    for ([_]struct { []const u8, []const u8, Schedule }{ .{ "1-23", "*", .hourly }, .{ "0", "1-6", .daily }, .{ "0", "0", .weekly } }) |row| {
        try out.print(gpa, "{d} {s} * * {s} \"{s}/git\" --exec-path=\"{s}\" {s} for-each-repo --keep-going --config=maintenance.repo maintenance run --schedule={t}\n", .{ given.minute, row[0], row[1], given.exec_path, given.exec_path, parameters, row[2] });
    }
    try out.print(gpa, "\n{s}\n", .{end_line});
    return out.toOwnedSlice(gpa);
}
