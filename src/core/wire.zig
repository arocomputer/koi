//! Koi's protocol between the app (or the `koi` command) and the server,
//! byte for byte what the app speaks: a one-byte kind, a little-endian u32
//! payload length, then the payload; JSON payloads shaped as the app's
//! Swift types encode them.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Bumped on any incompatible change; part of the socket's name.
pub const version = 6;

pub const Kind = enum(u8) {
    // Client to server.
    open = 1, // JSON OpenRequest
    input = 2, // bytes for the PTY
    resize = 3, // GridSize
    kill = 5, // ends the attached pane
    watch = 6, // answered by .state, now and on changes
    command = 7, // JSON Command; answered by .result
    offer = 8, // over the local socket; answered by .offered
    paneControl = 9, // one byte: 1 claims, 0 releases
    keepalive = 10, // empty; sent over SSH, consumed by `koi --stdio`, never reaches the server

    // Server to client.
    attached = 64, // JSON PaneInfo
    snapshot = 65, // libghostty-vt snapshot
    output = 66, // PTY bytes
    resized = 67, // GridSize, once the pane has resized
    exited = 68, // i32 exit status, little-endian
    state = 69, // JSON State
    result = 70, // JSON Result
    offered = 71, // JSON Offer
    ownership = 72, // one byte: whether this client owns the pane
    failure = 73, // JSON {error: string}
};

pub const header_size = 5;
/// The largest payload accepted; a bigger one means a broken peer.
pub const max_payload: usize = 64 << 20;

pub fn frame(gpa: Allocator, kind: Kind, payload: []const u8) ![]u8 {
    if (payload.len > max_payload) return error.PayloadTooLarge;
    const out = try gpa.alloc(u8, header_size + payload.len);
    out[0] = @backingInt(kind);
    std.mem.writeInt(u32, out[1..5], @intCast(payload.len), .little);
    @memcpy(out[5..], payload);
    return out;
}

pub fn frameJson(gpa: Allocator, kind: Kind, value: anytype) ![]u8 {
    const json = try std.json.Stringify.valueAlloc(gpa, value, .{ .emit_null_optional_fields = false });
    defer gpa.free(json);
    return frame(gpa, kind, json);
}

pub fn exitPayload(code: i32) [4]u8 {
    var out: [4]u8 = undefined;
    std.mem.writeInt(i32, &out, code, .little);
    return out;
}

/// A complete `exited` frame carrying `code`, ready to send.
pub fn exitedFrame(code: i32) [header_size + 4]u8 {
    var out: [header_size + 4]u8 = undefined;
    out[0] = @backingInt(Kind.exited);
    std.mem.writeInt(u32, out[1..5], 4, .little);
    @memcpy(out[5..], &exitPayload(code));
    return out;
}

/// A terminal's size in cells and the pixel size of one cell.
pub const GridSize = struct {
    cols: u16,
    rows: u16,
    cell_width: u32,
    cell_height: u32,

    /// Reject pathological grids before the engine allocates cell storage.
    /// Keep this bound aligned with Wire.decodeSize in the app.
    pub fn valid(self: GridSize) bool {
        return self.cols > 0 and self.rows > 0 and @as(u32, self.cols) * self.rows <= 1_048_576;
    }

    pub fn encode(self: GridSize) [16]u8 {
        var out: [16]u8 = undefined;
        std.mem.writeInt(u32, out[0..4], self.cols, .little);
        std.mem.writeInt(u32, out[4..8], self.rows, .little);
        std.mem.writeInt(u32, out[8..12], self.cell_width, .little);
        std.mem.writeInt(u32, out[12..16], self.cell_height, .little);
        return out;
    }

    pub fn decode(p: []const u8) ?GridSize {
        if (p.len != 16) return null;
        const cols = std.mem.readInt(u32, p[0..4], .little);
        const rows = std.mem.readInt(u32, p[4..8], .little);
        if (cols == 0 or rows == 0 or cols > std.math.maxInt(u16) or rows > std.math.maxInt(u16)) return null;
        const size: GridSize = .{
            .cols = @intCast(cols),
            .rows = @intCast(rows),
            .cell_width = std.mem.readInt(u32, p[8..12], .little),
            .cell_height = std.mem.readInt(u32, p[12..16], .little),
        };
        return if (size.valid()) size else null;
    }
};

/// Splits a byte stream into frames, however the bytes arrive.
pub const FrameReader = struct {
    buffer: std.ArrayList(u8) = .empty,
    start: usize = 0,
    gpa: Allocator,

    pub const Frame = struct { kind: Kind, payload: []const u8 };

    pub fn init(gpa: Allocator) FrameReader {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *FrameReader) void {
        self.buffer.deinit(self.gpa);
    }

    pub fn append(self: *FrameReader, bytes: []const u8) !void {
        if (self.start == self.buffer.items.len) {
            if (self.buffer.capacity > 1024 * 1024) self.buffer.clearAndFree(self.gpa) else self.buffer.clearRetainingCapacity();
            self.start = 0;
        } else if (self.start > 64 * 1024) {
            std.mem.copyForwards(u8, self.buffer.items, self.buffer.items[self.start..]);
            self.buffer.shrinkRetainingCapacity(self.buffer.items.len - self.start);
            self.start = 0;
        }
        try self.buffer.appendSlice(self.gpa, bytes);
    }

    /// The next whole frame, null if more bytes are needed. The payload
    /// points into the reader and is valid until the next `append`.
    pub fn next(self: *FrameReader) error{Protocol}!?Frame {
        const avail = self.buffer.items[self.start..];
        if (avail.len < header_size) return null;
        const len = std.mem.readInt(u32, avail[1..5], .little);
        if (len > max_payload) return error.Protocol;
        const kind = std.enums.fromInt(Kind, avail[0]) orelse return error.Protocol;
        if (avail.len < header_size + len) return null;
        self.start += header_size + len;
        return .{ .kind = kind, .payload = avail[header_size .. header_size + len] };
    }
};

// JSON shapes, as the app's Swift types encode them.

pub const OpenRequest = struct {
    pane: []const u8,
    cols: u16,
    rows: u16,
    cellWidth: u32,
    cellHeight: u32,
    paneControl: bool = false,
    observer: bool = false,
    controller: ?[]const u8 = null,
};

/// Controller identifiers contain 1...64 UTF-8 code points (at most 256 bytes).
pub fn validController(value: []const u8) bool {
    if (value.len == 0 or value.len > 256 or !std.unicode.utf8ValidateSlice(value)) return false;
    var count: usize = 0;
    for (value) |byte| if (byte & 0xc0 != 0x80) {
        count += 1;
    };
    return count <= 64;
}

pub const Status = enum { idle, working, blocked, done, @"error" };

/// Explicit registration, independent of display-name discovery and the icon catalog.
pub const AgentSession = struct {
    active: bool = true,
    id: []const u8,
    name: []const u8,
    adapter: ?[]const u8 = null,
    run: u64,
    lastReport: i64,
};
pub const AgentEvent = struct {
    sequence: u64,
    session: []const u8,
    run: u64,
    status: Status,
};

pub const PaneInfo = struct {
    id: []const u8,
    pid: i32,
    title: []const u8,
    cwd: []const u8,
    home: ?[]const u8 = null,
    program: []const u8,
    shell: []const u8,
    fullscreen: bool,
    status: Status,
    /// No task state is inferred from terminal output.
    statusSource: ?[]const u8 = null,
    agent: ?AgentSession = null,
    agentEpoch: ?[]const u8 = null,
    agentSequence: u64 = 0,
    agentEvents: []const AgentEvent = &.{},
};

pub const TabInfo = struct {
    id: []const u8,
    /// A name the user gave the tab, or "" to show its program instead.
    name: []const u8 = "",
    panes: []const PaneInfo,
    layout: Layout,
};

pub const Direction = enum { right, down };

/// How a tab's panes are arranged: one pane, or a split holding two or more
/// children in a row or column. Encoded as `{"pane":"id"}` or `{"split":
/// {"id":…,"direction":…,"children":[{"layout":…,"weight":…},…]}}`.
pub const Layout = union(enum) {
    pane: []const u8,
    split: Split,

    /// A child of a split and its share of the split's length, relative to
    /// its siblings.
    pub const Child = struct {
        layout: *const Layout,
        weight: f64,
    };

    pub const Split = struct {
        id: []const u8,
        direction: Direction,
        children: []const Child,
    };

    pub fn jsonStringify(self: Layout, jw: anytype) !void {
        try jw.beginObject();
        switch (self) {
            .pane => |id| {
                try jw.objectField("pane");
                try jw.write(id);
            },
            .split => |s| {
                try jw.objectField("split");
                try jw.beginObject();
                try jw.objectField("id");
                try jw.write(s.id);
                try jw.objectField("direction");
                try jw.write(s.direction);
                try jw.objectField("children");
                try jw.beginArray();
                for (s.children) |child| {
                    try jw.beginObject();
                    try jw.objectField("layout");
                    try jw.write(child.layout.*);
                    try jw.objectField("weight");
                    try jw.write(child.weight);
                    try jw.endObject();
                }
                try jw.endArray();
                try jw.endObject();
            },
        }
        try jw.endObject();
    }
};

pub const GroupInfo = struct {
    id: []const u8,
    name: []const u8,
    tabs: []const TabInfo,
};

/// A top-level entry of the sidebar. Swift encodes its enum with associated
/// values as `{"tab":{"_0":{…}}}` / `{"group":{"_0":{…}}}`.
pub const Item = union(enum) {
    tab: TabInfo,
    group: GroupInfo,

    pub fn jsonStringify(self: Item, jw: anytype) !void {
        try jw.beginObject();
        switch (self) {
            .tab => |t| {
                try jw.objectField("tab");
                try jw.beginObject();
                try jw.objectField("_0");
                try jw.write(t);
                try jw.endObject();
            },
            .group => |g| {
                try jw.objectField("group");
                try jw.beginObject();
                try jw.objectField("_0");
                try jw.write(g);
                try jw.endObject();
            },
        }
        try jw.endObject();
    }
};

pub const State = struct {
    items: []const Item,
};

/// The same tree as read back: Swift's enum encoding is a one-key object
/// wrapping `_0`, which is parsed as this and inspected with `tab`/`group`.
pub const ParsedState = struct {
    items: []const ParsedItem,
};

pub const ParsedItem = struct {
    tab: ?struct { _0: ParsedTab } = null,
    group: ?struct { _0: ParsedGroup } = null,
};

/// CLI target lookup needs IDs and panes, not the server's layout schema.
/// Skipping layout accepts both binary and weighted protocol-v6 splits.
pub const ParsedTab = struct {
    id: []const u8,
    panes: []const PaneInfo,
};

pub const ParsedGroup = struct {
    id: []const u8,
    name: []const u8,
    tabs: []const ParsedTab,
};

pub const Op = enum { newTab, closeTab, group, move, renameGroup, renameTab, ungroup, closeGroup, splitPane, closePane, swapPanes, resizeSplit, clearPane, resetPane, configurePane, serverInfo, reportStatus, agentReport };

/// Per-pane defaults. Colors are exactly six ASCII hex digits without '#'.
/// Missing scrollbackMB means 32 MiB; zero disables history. Limits are engine
/// page estimates, bounded to 1024 MiB. Snapshots still obey max_payload;
/// an edit or attachment exceeding that frame cap fails without oversize I/O.
/// History defaults require cooperating app/server implementations: old v6
/// mirrors override snapshots with 32 MiB. This is not a cross-client privacy
/// or hard memory guarantee. JSON accepts zero; the Settings UI uses 1...32 MiB.
pub const Appearance = struct {
    foreground: []const u8 = "e6e6ea",
    background: []const u8 = "17171b",
    cursor: []const u8 = "e6e6ea",
    scrollbackMB: i64 = 32,

    pub fn valid(self: Appearance) bool {
        if (self.scrollbackMB < 0 or self.scrollbackMB > 1024) return false;
        for ([_][]const u8{ self.foreground, self.background, self.cursor }) |color| {
            if (color.len != 6) return false;
            for (color) |ch| if (!std.ascii.isHex(ch)) return false;
        }
        return true;
    }
};

pub const Command = struct {
    op: Op,
    controller: ?[]const u8 = null,
    tab: ?[]const u8 = null,
    pane: ?[]const u8 = null,
    direction: ?Direction = null,
    split: ?[]const u8 = null,
    ratio: ?f64 = null,
    /// Full split weights; exactly one finite positive value per child.
    /// Mutually exclusive with ratio/index; normalized before committing.
    weights: ?[]const f64 = null,
    target: ?[]const u8 = null,
    group: ?[]const u8 = null,
    index: ?i64 = null,
    name: ?[]const u8 = null,
    /// Explicit split cwd requires splitCwd; old v6 servers silently ignore it.
    cwd: ?[]const u8 = null,
    /// Shell source passed intact to the login shell with -c, never tokenized.
    /// Null starts the normal interactive login shell; empty/NUL is rejected.
    startup: ?[]const u8 = null,
    appearance: ?Appearance = null,
    /// Explicit foreground-program status for reportStatus (pane required).
    status: ?Status = null,
    /// agentReport: explicit role declaration, with optional provider session/turn keys.
    agentSession: ?[]const u8 = null,
    agentRun: ?[]const u8 = null,
    /// Provider prompt boundary when no public turn key exists.
    agentNewRun: bool = false,
    adapter: ?[]const u8 = null,
    cols: ?u16 = null,
    rows: ?u16 = null,
    cellWidth: ?u32 = null,
    cellHeight: ?u32 = null,
};

/// Optional serverInfo fields describe the answering process, never a bundle
/// on disk. Probe capabilities before sending additive v6 commands/options.
pub const Result = struct {
    tab: ?[]const u8 = null,
    pane: ?[]const u8 = null,
    group: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
    serverVersion: ?[]const u8 = null,
    serverPID: ?i32 = null,
    protocolVersion: ?u32 = null,
    uptimeSeconds: ?u64 = null,
    transports: ?[]const []const u8 = null,
    capabilities: ?[]const []const u8 = null,
    layoutFormat: ?[]const u8 = null,
    snapshotFormat: ?[]const u8 = null,
};

pub const Offer = struct {
    port: u16,
    secret: []const u8,
};

/// Parses JSON into `T`, copying every string, so the result outlives the
/// bytes it came from.
pub fn parse(comptime T: type, gpa: Allocator, bytes: []const u8) !std.json.Parsed(T) {
    return std.json.parseFromSlice(T, gpa, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

test "frames reassemble across arbitrary reads" {
    const gpa = std.testing.allocator;
    const size = GridSize{ .cols = 80, .rows = 24, .cell_width = 9, .cell_height = 18 };
    const big = try gpa.alloc(u8, 70_000);
    defer gpa.free(big);
    @memset(big, 7);
    const frames = [_][]const u8{
        try frame(gpa, .output, "hello"),
        try frame(gpa, .resized, &size.encode()),
        try frame(gpa, .output, ""),
        try frame(gpa, .output, big),
    };
    defer for (frames) |f| gpa.free(f);
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(gpa);
    for (frames) |f| try stream.appendSlice(gpa, f);

    for ([_]usize{ 1, 3, 4096, stream.items.len }) |chunk| {
        var reader = FrameReader.init(gpa);
        defer reader.deinit();
        var got: usize = 0;
        var i: usize = 0;
        while (i < stream.items.len) {
            const end = @min(i + chunk, stream.items.len);
            try reader.append(stream.items[i..end]);
            while (try reader.next()) |f| {
                const expected = frames[got];
                try std.testing.expectEqual(@as(Kind, @fromBackingInt(@intCast(expected[0]))), f.kind);
                try std.testing.expectEqualSlices(u8, expected[header_size..], f.payload);
                got += 1;
            }
            i = end;
        }
        try std.testing.expectEqual(frames.len, got);
    }
    try std.testing.expectEqual(size, GridSize.decode(&size.encode()).?);
}

test "oversized headers and pathological grids are rejected before allocation" {
    var reader = FrameReader.init(std.testing.allocator);
    defer reader.deinit();
    var header: [header_size]u8 = .{ @backingInt(Kind.input), 0, 0, 0, 0 };
    std.mem.writeInt(u32, header[1..5], max_payload + 1, .little);
    try reader.append(&header);
    try std.testing.expectError(error.Protocol, reader.next());
    const huge = GridSize{ .cols = 65535, .rows = 65535, .cell_width = 1, .cell_height = 1 };
    try std.testing.expect(GridSize.decode(&huge.encode()) == null);
    const edge = GridSize{ .cols = 1024, .rows = 1024, .cell_width = 1, .cell_height = 1 };
    try std.testing.expectEqual(edge, GridSize.decode(&edge.encode()).?);
}

test "items encode as the app expects" {
    const gpa = std.testing.allocator;
    const items = [_]Item{
        .{ .tab = .{ .id = "t1", .panes = &.{}, .layout = .{ .pane = "p1" } } },
        .{ .group = .{ .id = "g1", .name = "work", .tabs = &.{} } },
    };
    const json = try std.json.Stringify.valueAlloc(gpa, State{ .items = &items }, .{ .emit_null_optional_fields = false });
    defer gpa.free(json);
    try std.testing.expectEqualStrings(
        \\{"items":[{"tab":{"_0":{"id":"t1","name":"","panes":[],"layout":{"pane":"p1"}}}},{"group":{"_0":{"id":"g1","name":"work","tabs":[]}}}]}
    , json);
    const back = try parse(ParsedState, gpa, json);
    defer back.deinit();
    try std.testing.expectEqualStrings("t1", back.value.items[0].tab.?._0.id);
}

test "CLI target trees accept legacy v6 split layouts" {
    const json =
        \\{"items":[{"tab":{"_0":{"id":"remote-tab","panes":[{"id":"pane-a","pid":42,"title":"","cwd":"/","program":"","shell":"zsh","fullscreen":false,"status":"idle"}],"layout":{"split":{"id":"legacy","direction":"right","ratio":0.4,"first":{"pane":"pane-a"},"second":{"pane":"pane-b"}}}}}}]}
    ;
    const state = try parse(ParsedState, std.testing.allocator, json);
    defer state.deinit();
    const tab = state.value.items[0].tab.?._0;
    try std.testing.expectEqualStrings("remote-tab", tab.id);
    try std.testing.expectEqualStrings("pane-a", tab.panes[0].id);
}

test "additive v6 commands retain startup source and default appearance limits" {
    const gpa = std.testing.allocator;
    const old = try parse(Command, gpa, "{\"op\":\"newTab\"}");
    defer old.deinit();
    try std.testing.expect(old.value.startup == null and old.value.appearance == null);
    const command = try parse(Command, gpa,
        \\{"op":"splitPane","startup":"printf '%s' 'two words' | cat","appearance":{"foreground":"Aa11ff","background":"000000","cursor":"ffffff"}}
    );
    defer command.deinit();
    try std.testing.expectEqualStrings("printf '%s' 'two words' | cat", command.value.startup.?);
    try std.testing.expectEqual(@as(i64, 32), command.value.appearance.?.scrollbackMB);
    try std.testing.expect(command.value.appearance.?.valid());
    try std.testing.expect(!(Appearance{ .foreground = "#112233" }).valid());
    try std.testing.expect(!(Appearance{ .cursor = "11223g" }).valid());
    try std.testing.expect(!(Appearance{ .scrollbackMB = -1 }).valid());
    try std.testing.expect(!(Appearance{ .scrollbackMB = 1025 }).valid());
    const result = try parse(Result, gpa, "{\"pane\":\"original\"}");
    defer result.deinit();
    try std.testing.expect(result.value.serverVersion == null and result.value.capabilities == null);
}

test "weights and reportStatus are optional typed additive JSON" {
    const old = try parse(Command, std.testing.allocator, "{\"op\":\"resizeSplit\",\"ratio\":0.5,\"index\":0}");
    defer old.deinit();
    try std.testing.expect(old.value.weights == null and old.value.status == null);
    const weighted = try parse(Command, std.testing.allocator, "{\"op\":\"resizeSplit\",\"weights\":[1,2,3]}");
    defer weighted.deinit();
    try std.testing.expectEqualSlices(f64, &.{ 1, 2, 3 }, weighted.value.weights.?);
    const status = try parse(Command, std.testing.allocator, "{\"op\":\"reportStatus\",\"pane\":\"status01\",\"status\":\"blocked\"}");
    defer status.deinit();
    try std.testing.expectEqual(Op.reportStatus, status.value.op);
    try std.testing.expectEqual(@as(?Status, .blocked), status.value.status);
    try std.testing.expectError(error.InvalidEnumTag, parse(Command, std.testing.allocator, "{\"op\":\"reportStatus\",\"status\":\"unknown\"}"));
}
