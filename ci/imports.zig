//! Source boundaries. Layer data belongs to this package; graph rules belong to gantry.
const std = @import("std");
const gantry = @import("gantry");
const declared = @import("layers.zig");

pub const rules: gantry.rules.Rules = .{
    .required = &.{.{ .name = "named sources", .paths = &declared.required }},
    .nothing_imports = &entry_rules,
    .references = declared.references,
    .tokens = declared.owned,
};

const entry_rules = blk: {
    var result: [declared.entries.len + 1]gantry.rules.EdgeRule = undefined;
    result[0] = .{ .name = "entry files", .to = "**/main.zig" };
    for (declared.entries, 1..) |path, index| result[index] = .{ .name = "entry files", .to = path };
    break :blk result;
};

fn keep(_: void, path: []const u8, kind: std.Io.File.Kind) bool {
    if (kind == .directory) return std.mem.eql(u8, path, "src") or std.mem.startsWith(u8, path, "src/");
    return std.mem.startsWith(u8, path, "src/") and std.mem.endsWith(u8, path, ".zig");
}

fn report(comptime format: []const u8, io: std.Io, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buffer);
    try writer.interface.print(format, args);
    try writer.interface.flush();
}

pub fn main(init: std.process.Init) !void {
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var paths = try gantry.walk(a, init.io, .cwd(), {}, keep);
    defer paths.deinit();
    const reader: gantry.DirReader = .{ .io = init.io, .dir = .cwd() };
    var diagnostic = gantry.ScanDiagnostic.init(a);
    defer diagnostic.deinit();
    var graph = gantry.scanWithDiagnostic(a, paths.items(), reader, gantry.DirReader.read, .{
        .manifests = false,
        .strict_imports = true,
        .named_modules = declared.modules,
        .tokens = declared.owned,
    }, &diagnostic) catch |err| {
        if (diagnostic.failure) |failure| try report("imports: {s}: {s}: {s}\n", init.io, .{ failure.path orelse "<scan>", @tagName(failure.phase), @errorName(failure.cause) });
        return err;
    };
    defer graph.deinit();
    const args = try init.minimal.args.toSlice(a);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--audit")) {
        var buffer: [4096]u8 = undefined;
        var out = std.Io.File.stdout().writer(init.io, &buffer);
        try std.json.Stringify.value(.{ .paths = graph.paths(), .edges = graph.edges(), .references = graph.references() }, .{}, &out.interface);
        try out.interface.writeByte('\n');
        try out.interface.flush();
        return;
    }
    // A namespace now holds both its implementation and public reexports.
    // Check the implementation graph with the same layers and cycle policy;
    // the complete graph still checks entries, names, references and tokens.
    var implementation_edges: std.ArrayList(gantry.Edge) = .empty;
    for (graph.edges()) |edge| {
        var reexport = false;
        for (declared.namespace_exports) |public| {
            if (std.mem.eql(u8, edge.from, public.from) and std.mem.eql(u8, edge.to, public.to)) {
                reexport = true;
                break;
            }
        }
        if (!reexport) try implementation_edges.append(a, edge);
    }
    var implementation = try gantry.Graph.fromEdges(a, graph.paths(), implementation_edges.items);
    defer implementation.deinit();
    const implementation_findings = try implementation.check(a, .{
        .ordered = &.{.{ .name = "layers", .layers = declared.layers }},
        .no_cycles = "cycles",
    });
    defer a.free(implementation_findings);
    for (implementation_findings) |finding| {
        if (finding.edge) |edge| try report("imports: {s}: {s} -> {s} ({s})\n", init.io, .{ finding.rule, edge.from, edge.to, @tagName(finding.reason) });
    }
    const findings = try graph.check(a, rules);
    defer a.free(findings);
    for (graph.paths()) |path| {
        var owners: usize = 0;
        for (declared.required) |source| if (std.mem.eql(u8, path, source)) {
            owners += 1;
        };
        if (owners > 1) {
            try report("imports: {s}: source belongs to multiple layers\n", init.io, .{path});
            return error.AmbiguousSource;
        }
        if (owners == 0) {
            try report("imports: {s}: source has no named layer\n", init.io, .{path});
            return error.UnnamedSource;
        }
    }
    for (graph.unread()) |path| try report("imports: {s}: unread\n", init.io, .{path});
    for (findings) |finding| {
        if (finding.edge) |edge| {
            try report("imports: {s}: {s} -> {s} ({s})\n", init.io, .{ finding.rule, edge.from, edge.to, @tagName(finding.reason) });
        } else if (finding.reference) |ref| {
            try report("imports: {s}: {s}: @import(\"{s}\")\n", init.io, .{ finding.rule, ref.from, ref.name });
        } else if (finding.token) |token| {
            try report("imports: {s}: {s}:{d}:{d}: {t} \"{f}\"\n", init.io, .{ finding.rule, token.path, token.line, token.column, token.kind, std.zig.fmtString(token.text) });
        } else if (finding.path) |path| try report("imports: {s}: {s}\n", init.io, .{ finding.rule, path });
    }
    if (graph.unread().len != 0 or findings.len != 0 or implementation_findings.len != 0) return error.ImportBoundary;
}
