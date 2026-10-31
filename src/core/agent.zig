//! Explicit agent lifecycle. Names discovered from argv are never consulted here.
//! Bounded replay survives watcher/snapshot coalescing; epoch + sequence expose gaps.
const std = @import("std");
const sys = @import("sys.zig");
const wire = @import("wire.zig");
const Allocator = std.mem.Allocator;

const Key = struct {
    bytes: [128]u8 = undefined,
    len: usize = 0,
    pub fn get(self: *const Key) []const u8 {
        return self.bytes[0..self.len];
    }
    fn set(self: *Key, value: []const u8) !void {
        if (value.len == 0 or value.len > self.bytes.len or !std.unicode.utf8ValidateSlice(value)) return error.InvalidAgentIdentity;
        for (value) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidAgentIdentity;
        @memcpy(self.bytes[0..value.len], value);
        self.len = value.len;
    }
    fn eql(self: *const Key, value: []const u8) bool {
        return std.mem.eql(u8, self.get(), value);
    }
};
const Event = struct { sequence: u64, session: [32]u8, run: u64, status: wire.Status };

pub const Agent = struct {
    pub const capacity = 64;
    epoch: ?[32]u8 = null,
    sequence: u64 = 0,
    events: [capacity]Event = undefined,
    count: usize = 0,
    active: bool = false,
    pid: i32 = 0,
    id: [32]u8 = undefined,
    name: Key = .{},
    adapter: Key = .{},
    source: Key = .{},
    turn: Key = .{},
    retired: [16]Key = @splat(.{}),
    retired_index: usize = 0,
    run: u64 = 0,
    status: wire.Status = .idle,
    last_report: i64 = 0,

    pub fn init() Agent {
        return .{ .epoch = randomID() };
    }

    pub fn invalidate(self: *Agent) void {
        self.active = false;
    }

    /// Caller supplies a freshly verified process identity and serializes mutations.
    /// Validate on a copy: bad reports cannot partially register or advance a run.
    pub fn report(self: *Agent, pid: i32, name: []const u8, adapter: ?[]const u8, source: ?[]const u8, turn: ?[]const u8, status: wire.Status) !void {
        var next = self.*;
        try next.apply(pid, name, adapter, source, turn, status);
        self.* = next;
    }

    fn apply(self: *Agent, pid: i32, name: []const u8, adapter: ?[]const u8, source: ?[]const u8, turn: ?[]const u8, status: wire.Status) !void {
        var valid: Key = .{};
        try valid.set(name);
        if (adapter) |value| try valid.set(value);
        if (source) |value| try valid.set(value);
        if (turn) |value| try valid.set(value);
        const same = self.active and self.pid == pid and self.source.eql(source orelse "");
        if (!same) {
            // A different live provider session must begin with a prompt/session start.
            if (status != .working and status != .idle) return error.StaleAgentSession;
            self.active = true;
            self.pid = pid;
            self.id = randomID();
            try self.name.set(name);
            self.adapter = .{};
            if (adapter) |value| try self.adapter.set(value);
            self.source = .{};
            if (source) |value| try self.source.set(value);
            self.turn = .{};
            self.retired = @splat(.{});
            self.retired_index = 0;
            self.run += 1;
        } else if (!self.name.eql(name) or !self.adapter.eql(adapter orelse "")) return error.AgentIdentityMismatch;
        if (turn) |key| {
            if (self.turn.eql(key) and same and (self.status == .done or self.status == .@"error" or self.status == .idle) and
                (status == .working or status == .blocked)) return error.StaleAgentRun;
            if (!self.turn.eql(key)) {
                for (self.retired) |old| if (old.eql(key)) return error.StaleAgentRun;
                if (self.turn.len > 0) {
                    self.retired[self.retired_index] = self.turn;
                    self.retired_index = (self.retired_index + 1) % self.retired.len;
                }
                try self.turn.set(key);
                if (same) self.run += 1;
            }
        } else if (same and status == .working and (self.status == .done or self.status == .@"error" or self.status == .idle)) {
            self.run += 1;
        }
        self.last_report = @divTrunc(sys.nowMillis(), 1000);
        if (same and status == self.status and (self.count > 0 and self.events[(self.sequence - 1) % capacity].run == self.run)) return;
        self.status = status;
        if (self.epoch == null) self.epoch = randomID();
        self.sequence += 1;
        self.events[(self.sequence - 1) % capacity] = .{ .sequence = self.sequence, .session = self.id, .run = self.run, .status = status };
        self.count = @min(capacity, self.count + 1);
    }

    pub fn session(self: *const Agent, arena: Allocator) !?wire.AgentSession {
        if (self.name.len == 0) return null;
        return .{ .active = self.active, .id = try arena.dupe(u8, &self.id), .name = try arena.dupe(u8, self.name.get()), .adapter = if (self.adapter.len > 0) try arena.dupe(u8, self.adapter.get()) else null, .run = self.run, .lastReport = self.last_report };
    }

    pub fn history(self: *const Agent, arena: Allocator) ![]const wire.AgentEvent {
        const result = try arena.alloc(wire.AgentEvent, self.count);
        const first = self.sequence - self.count + 1;
        for (result, 0..) |*item, index| {
            const event = self.events[(first + index - 1) % capacity];
            item.* = .{ .sequence = event.sequence, .session = try arena.dupe(u8, &event.session), .run = event.run, .status = event.status };
        }
        return result;
    }
};

fn randomID() [32]u8 {
    var bytes: [16]u8 = undefined;
    sys.randomBytes(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

test "agent events retain fast transitions and distinguish same-name sessions and turns" {
    const t = std.testing;
    var agent: Agent = .{};
    try agent.report(200, "custom", null, "session", "turn1", .working);
    const first_id = agent.id;
    const first_run = agent.run;
    try agent.report(200, "custom", null, "session", "turn1", .done);
    try agent.report(200, "custom", null, "session", "turn1", .done);
    try t.expectEqual(@as(u64, 2), agent.sequence);
    try agent.report(200, "custom", null, "session", "turn2", .working);
    try t.expect(agent.run > first_run);
    try t.expectError(error.StaleAgentRun, agent.report(200, "custom", null, "session", "turn1", .done));
    agent.invalidate();
    try agent.report(201, "custom", null, "session2", null, .working);
    try t.expect(!std.mem.eql(u8, &first_id, &agent.id));
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const events = try agent.history(arena.allocator());
    try t.expectEqual(@as(usize, 4), events.len);
    try t.expectEqual(wire.Status.done, events[1].status);
}

test "agent journal is bounded and exposes an exact replay gap" {
    var agent: Agent = .{};
    for (0..80) |i| try agent.report(200, "anything", null, null, null, if (i % 2 == 0) .working else .done);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const events = try agent.history(arena.allocator());
    try std.testing.expectEqual(@as(usize, Agent.capacity), events.len);
    try std.testing.expectEqual(@as(u64, 17), events[0].sequence);
    try std.testing.expectEqual(@as(u64, 80), events[events.len - 1].sequence);
}

test "malformed and late terminal reports cannot register or revive a completed turn" {
    var agent: Agent = .{};
    try std.testing.expectError(error.StaleAgentSession, agent.report(200, "new", null, "s", "t", .done));
    try std.testing.expect(!agent.active);
    try agent.report(200, "new", null, "s", "t", .working);
    try agent.report(200, "new", null, "s", "t", .done);
    const sequence = agent.sequence;
    try std.testing.expectError(error.StaleAgentRun, agent.report(200, "new", null, "s", "t", .working));
    try std.testing.expectError(error.InvalidAgentIdentity, agent.report(200, "bad\nname", null, "s", "t", .working));
    try std.testing.expectEqual(sequence, agent.sequence);
    try std.testing.expectEqual(wire.Status.done, agent.status);
}
