//! `koi api`: the server's command vocabulary as JSON, for scripts and agents
//! that would otherwise read the source. It needs no running server.
//!
//! The field list comes from `wire.Command` at compile time, so it cannot drift
//! from what the server accepts. Only the one-line summaries are written by
//! hand; the compiler refuses an `Op` without one, and a test keeps every
//! capability named here real. Which fields an operation reads is not listed:
//! the handlers are the authority, and `docs/cli.md` shows the common cases.
const std = @import("std");
const wire = @import("wire.zig");
const Allocator = std.mem.Allocator;

/// An operation's summary and the `serverInfo` capability to probe for before
/// sending it to a server that may be older, if it was added after protocol 6
/// shipped.
const Entry = struct { summary: []const u8, capability: ?[]const u8 = null };

fn entry(comptime op: wire.Op) Entry {
    return switch (op) {
        .newTab => .{ .summary = "Create a tab with one pane, optionally after another tab, in a group, in a directory or running a startup command." },
        .closeTab => .{ .summary = "Close a tab and end its panes." },
        .group => .{ .summary = "Put a tab with a target tab: into the target's group, or into a new group of the two." },
        .move => .{ .summary = "Move a tab into a group, or to the top level, at an index or the end." },
        .renameGroup => .{ .summary = "Set a group's name." },
        .renameTab => .{ .summary = "Set a tab's name." },
        .ungroup => .{ .summary = "Dissolve a group, leaving its tabs at the top level." },
        .closeGroup => .{ .summary = "Close every tab in a group." },
        .splitPane => .{ .summary = "Split a pane right or down; prints the new pane's id.", .capability = null },
        .closePane => .{ .summary = "Close a pane, ending its process." },
        .swapPanes => .{ .summary = "Swap the positions of two panes." },
        .resizeSplit => .{ .summary = "Move a divider by ratio, or set every weight of a split." },
        .clearPane => .{ .summary = "Erase a pane's scrollback, keeping the visible screen and modes.", .capability = "clearPane" },
        .resetPane => .{ .summary = "Reset a pane's engine screen, history, modes and parser; the process, size and appearance stay.", .capability = "resetPane" },
        .configurePane => .{ .summary = "Apply colors and scrollback size to a pane.", .capability = "configurePane" },
        .serverInfo => .{ .summary = "Report the server's version, process, uptime, transports and capabilities.", .capability = "serverInfo" },
        .reportStatus => .{ .summary = "Report a pane's foreground program as working, blocked, done, error or idle.", .capability = "reportStatus" },
    };
}

fn typeName(comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .optional => |o| typeName(o.child),
        .pointer => |p| if (p.child == u8) "string" else typeName(p.child) ++ "[]",
        .float => "number",
        .int => "integer",
        .bool => "boolean",
        .@"enum" => "enum",
        .@"struct" => "object",
        else => @compileError("describe the wire type " ++ @typeName(T)),
    };
}

fn enumValues(comptime T: type) []const []const u8 {
    const E = switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
    if (@typeInfo(E) != .@"enum") return &.{};
    const names = std.meta.fieldNames(E);
    comptime var out: [names.len][]const u8 = undefined;
    inline for (names, 0..) |name, i| out[i] = name;
    const final = out;
    return &final;
}

const OpDoc = struct { op: []const u8, summary: []const u8, capability: ?[]const u8 };
const FieldDoc = struct { name: []const u8, type: []const u8, values: []const []const u8 = &.{} };

const operations = blk: {
    const names = std.meta.fieldNames(wire.Op);
    var out: [names.len]OpDoc = undefined;
    for (names, 0..) |name, i| {
        const e = entry(@field(wire.Op, name));
        out[i] = .{ .op = name, .summary = e.summary, .capability = e.capability };
    }
    const final = out;
    break :blk final;
};

/// `wire.Command`'s fields. Every field but `op` is optional on the wire.
const fields = blk: {
    const names = std.meta.fieldNames(wire.Command);
    var out: [names.len]FieldDoc = undefined;
    for (names, 0..) |name, i| {
        const T = @FieldType(wire.Command, name);
        out[i] = .{ .name = name, .type = typeName(T), .values = enumValues(T) };
    }
    const final = out;
    break :blk final;
};

/// The whole vocabulary as JSON, or one operation's entry if `op` names one.
/// Null when `op` names none. The caller frees the result.
pub fn describe(gpa: Allocator, op: ?[]const u8, capabilities: []const []const u8) !?[]u8 {
    if (op) |name| {
        for (operations) |o| if (std.mem.eql(u8, o.op, name)) {
            return try std.json.Stringify.valueAlloc(gpa, .{ .protocolVersion = wire.version, .operation = o, .fields = &fields }, .{ .emit_null_optional_fields = false });
        };
        return null;
    }
    return try std.json.Stringify.valueAlloc(gpa, .{
        .protocolVersion = wire.version,
        .capabilities = capabilities,
        .operations = &operations,
        .fields = &fields,
    }, .{ .emit_null_optional_fields = false });
}

test "every operation and every command field is described, and it parses back" {
    const gpa = std.testing.allocator;
    const caps = [_][]const u8{"serverInfo"};
    const text = (try describe(gpa, null, &caps)).?;
    defer gpa.free(text);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqual(@as(i64, wire.version), root.get("protocolVersion").?.integer);
    try std.testing.expectEqual(std.meta.fieldNames(wire.Op).len, root.get("operations").?.array.items.len);
    try std.testing.expectEqual(std.meta.fieldNames(wire.Command).len, root.get("fields").?.array.items.len);
    for (root.get("operations").?.array.items) |o| try std.testing.expect(o.object.get("summary").?.string.len > 10);
}

test "one operation is described alone, and an unknown one is not" {
    const gpa = std.testing.allocator;
    const text = (try describe(gpa, "reportStatus", &.{})).?;
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"op\":\"reportStatus\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"op\":\"newTab\"") == null);
    try std.testing.expect((try describe(gpa, "launchMissiles", &.{})) == null);
}

test "the capability an operation names is one the server advertises" {
    const server = @import("server.zig");
    for (operations) |o| {
        const wanted = o.capability orelse continue;
        var found = false;
        for (server.capabilities) |have| found = found or std.mem.eql(u8, have, wanted);
        try std.testing.expect(found);
    }
}
