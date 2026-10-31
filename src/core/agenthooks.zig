//! Provider-specific hook contracts. Only identity fields are read; prompt and
//! transcript contents are neither retained nor sent to the Koi server.
const std = @import("std");
const wire = @import("wire.zig");

pub const Report = struct { name: []const u8, adapter: []const u8, session: []const u8, run: ?[]const u8, status: wire.Status };

pub fn statusFor(provider: []const u8, event: []const u8) ?wire.Status {
    if (std.mem.eql(u8, provider, "claude")) {
        if (std.mem.eql(u8, event, "StopFailure")) return .@"error";
    } else if (std.mem.eql(u8, provider, "codex")) {
        if (std.mem.eql(u8, event, "Interrupt")) return .idle;
    } else return null;
    if (std.mem.eql(u8, event, "SessionStart") or std.mem.eql(u8, event, "SessionEnd")) return .idle;
    if (std.mem.eql(u8, event, "UserPromptSubmit") or std.mem.eql(u8, event, "PostToolUse")) return .working;
    if (std.mem.eql(u8, event, "PermissionRequest")) return .blocked;
    if (std.mem.eql(u8, event, "Stop")) return .done;
    return null;
}

pub fn decode(provider: []const u8, event: []const u8, value: std.json.Value) !Report {
    const status = statusFor(provider, event) orelse return error.UnsupportedHook;
    if (value != .object) return error.InvalidHookPayload;
    const actual = value.object.get("hook_event_name") orelse return error.InvalidHookPayload;
    if (actual != .string or !std.mem.eql(u8, actual.string, event)) return error.InvalidHookPayload;
    const session = value.object.get("session_id") orelse return error.InvalidHookPayload;
    if (session != .string or session.string.len == 0) return error.InvalidHookPayload;
    var run: ?[]const u8 = null;
    if (std.mem.eql(u8, provider, "codex") and status != .idle) {
        // Codex's command-input schemas require turn_id on turn-scoped events.
        const turn = value.object.get("turn_id") orelse return error.UnsupportedHookSchema;
        if (turn != .string or turn.string.len == 0) return error.InvalidHookPayload;
        run = turn.string;
    }
    // Claude has no public turn ID: the server advances a run on each new prompt
    // after idle/done/error. Subagent hooks must never complete the parent pane.
    if (value.object.get("agent_id")) |agent| if (agent == .string and agent.string.len > 0) return error.SubagentHook;
    return .{ .name = provider, .adapter = if (std.mem.eql(u8, provider, "claude")) "claude-hooks-v1" else "codex-hooks-v1", .session = session.string, .run = run, .status = status };
}

test "hook adapters validate provider schema and preserve session and turn identity" {
    const t = std.testing;
    const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, "{\"hook_event_name\":\"Stop\",\"session_id\":\"session\",\"turn_id\":\"turn\"}", .{});
    defer parsed.deinit();
    const codex = try decode("codex", "Stop", parsed.value);
    try t.expectEqualStrings("turn", codex.run.?);
    try t.expectError(error.InvalidHookPayload, decode("codex", "PermissionRequest", parsed.value));
    try t.expect(statusFor("codex", "StopFailure") == null);
    try t.expect(statusFor("claude", "Interrupt") == null);
    try t.expectEqual(wire.Status.done, (try decode("claude", "Stop", parsed.value)).status);
    const old = try std.json.parseFromSlice(std.json.Value, t.allocator, "{\"hook_event_name\":\"Stop\",\"session_id\":\"s\"}", .{});
    defer old.deinit();
    try t.expectError(error.UnsupportedHookSchema, decode("codex", "Stop", old.value));
}
