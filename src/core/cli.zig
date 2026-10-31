//! The `koi` command controls the server from a shell or a script. Targets
//! are a tab's id, its last four or more characters, or its position
//! counting from 1. Capture and close default to `$KOI_TAB`; split, clear and
//! reset default to `$KOI_PANE`. Explicit pane ids are accepted by those three;
//! explicit tab targets select their first pane.
const std = @import("std");
const sys = @import("sys.zig");
const c = sys.c;
const wire = @import("wire.zig");
const Server = @import("server.zig").Server;
const binary_version = @import("server.zig").binary_version;
const Socket = @import("transport.zig").Socket;
const Terminal = @import("emulator.zig").Terminal;
const Allocator = std.mem.Allocator;
const api_doc = @import("api.zig");
const script = @import("script.zig");

const usage =
    \\koi: the multiplexer for the shell. Commands:
    \\
    \\  ls [--json]           the tabs, top to bottom
    \\  new [--cwd DIR] [--command SOURCE]  new tab; prints its id
    \\  send TARGET TEXT...   type text into a tab ("\n" for Enter)
    \\  capture [TARGET]      print a tab's screen and scrollback
    \\  split [TARGET] [--down|--right] [--cwd DIR] [--command SOURCE]
    \\                        split a pane; default right; prints its id
    \\  status [PANE] STATE   report working|blocked|done|error|idle
    \\                        PANE defaults to KOI_PANE; accepts an exact pane id
    \\  info [--json]          running server version, pid, uptime and capabilities
    \\  api [OP]              the commands the server accepts, as JSON; needs no server
    \\  do SOURCE             run Lua source that drives koi; see docs/cli.md
    \\  run FILE [ARG...]     run a Lua script file with ARG... as `arg`
    \\  version               this binary's version
    \\  clear [TARGET]        erase scrollback; preserve visible screen and modes
    \\  reset [TARGET]        reset engine screen, history, modes and parser
    \\                        reset keeps the process/PTY, size and appearance
    \\  close [TARGET]        close a pane by id, or the tab's first pane
    \\
    \\--command is shell source passed intact to the login shell with -c;
    \\quote SOURCE as one argument. Without it, start an interactive login shell.
    \\Clear/reset do not run a shell command or change the PTY's termios settings.
    \\Theme and scrollback configuration is available via JSON configurePane.
    \\
    \\Exit status: 0 done, 1 failed, 2 bad command line, 3 no such tab,
    \\4 the server could not be reached.
    \\
;

pub fn run(gpa: Allocator, args: []const [:0]const u8) u8 {
    if (args.len == 0) {
        std.debug.print("{s}", .{usage});
        return 2;
    }
    const cmd = args[0];
    const rest = args[1..];
    if (std.mem.eql(u8, cmd, "status")) return reportStatus(gpa, rest);
    if (std.mem.eql(u8, cmd, "info")) return info(gpa, rest);
    if (std.mem.eql(u8, cmd, "api")) return api(gpa, rest);
    if (std.mem.eql(u8, cmd, "do")) return if (rest.len == 1) script.run(gpa, .{ .source = rest[0] }, &.{}) else 2;
    if (std.mem.eql(u8, cmd, "run")) return if (rest.len >= 1) script.run(gpa, .{ .file = rest[0] }, rest[1..]) else 2;
    if (std.mem.eql(u8, cmd, "version")) {
        _ = sys.writeAll(1, binary_version);
        _ = sys.writeAll(1, "\n");
        return 0;
    }
    if (std.mem.eql(u8, cmd, "clear")) return editPane(gpa, rest, .clearPane);
    if (std.mem.eql(u8, cmd, "reset")) return editPane(gpa, rest, .resetPane);
    if (std.mem.eql(u8, cmd, "ls")) return list(gpa, rest);
    if (std.mem.eql(u8, cmd, "new")) return newTab(gpa, rest);
    if (std.mem.eql(u8, cmd, "send")) return send(gpa, rest);
    if (std.mem.eql(u8, cmd, "capture")) return capture(gpa, rest);
    if (std.mem.eql(u8, cmd, "close")) return closePane(gpa, rest);
    if (std.mem.eql(u8, cmd, "split")) return split(gpa, rest);
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help")) {
        std.debug.print("{s}", .{usage});
        return 0;
    }
    std.debug.print("koi: unknown command '{s}'\n{s}", .{ cmd, usage });
    return 2;
}

/// A connection to the server, with the first frame of a kind read back.
const Client = struct {
    gpa: Allocator,
    socket: Socket,
    reader: wire.FrameReader,

    fn connect(gpa: Allocator) ?Client {
        const socket = Server.connect(gpa) orelse {
            std.debug.print("koi: the server could not be reached\n", .{});
            return null;
        };
        return .{ .gpa = gpa, .socket = socket, .reader = wire.FrameReader.init(gpa) };
    }

    fn deinit(self: *Client) void {
        self.socket.close();
        self.reader.deinit();
    }

    fn send(self: *Client, kind: wire.Kind, payload: []const u8) void {
        const frame = wire.frame(self.gpa, kind, payload) catch return;
        defer self.gpa.free(frame);
        self.socket.send(frame);
    }

    fn sendJson(self: *Client, kind: wire.Kind, value: anytype) void {
        const frame = wire.frameJson(self.gpa, kind, value) catch return;
        defer self.gpa.free(frame);
        self.socket.send(frame);
    }

    /// The next frame of `kind`, its payload copied; null when the server
    /// closes first.
    fn expect(self: *Client, kind: wire.Kind) ?[]u8 {
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            while (self.reader.next() catch return null) |f| {
                if (f.kind == kind) return self.gpa.dupe(u8, f.payload) catch null;
            }
            const n = self.socket.read(&buf);
            if (n == 0) return null;
            self.reader.append(buf[0..n]) catch return null;
        }
    }

    /// One ordered control request; the caller owns the decoded response.
    fn command(self: *Client, cmd: wire.Command) ?std.json.Parsed(wire.Result) {
        self.sendJson(.command, cmd);
        const json = self.expect(.result) orelse return null;
        defer self.gpa.free(json);
        return wire.parse(wire.Result, self.gpa, json) catch null;
    }

    /// Additive v6 options must be probed: old servers ignore unknown fields.
    fn supports(self: *Client, feature: []const u8) bool {
        const result = self.command(.{ .op = .serverInfo }) orelse return false;
        defer result.deinit();
        if (result.value.@"error" == null) {
            for (result.value.capabilities orelse &.{}) |capability| {
                if (std.mem.eql(u8, feature, capability)) return true;
            }
        }
        std.debug.print("koi: running server does not support {s}; sessions were left intact\n", .{feature});
        return false;
    }

    /// Probe additive split options before resolving or sending any mutation.
    /// Archived v6 silently ignores cwd, even when it accepts splitPane.
    fn supportsSplitOptions(self: *Client, cwd: ?[]const u8, startup: ?[]const u8) bool {
        if (startup != null and !self.supports("startup")) return false;
        if (cwd != null and !self.supports("splitCwd")) return false;
        return true;
    }

    fn state(self: *Client) ?std.json.Parsed(wire.ParsedState) {
        self.send(.watch, "");
        const json = self.expect(.state) orelse return null;
        defer self.gpa.free(json);
        return wire.parse(wire.ParsedState, self.gpa, json) catch |e| {
            std.debug.print("koi: cannot read the server's state: {s}\n", .{@errorName(e)});
            return null;
        };
    }
};

const Found = struct { tab: wire.ParsedTab, pane: wire.PaneInfo };

/// The tab a target names: an id, a suffix of one (four characters or
/// more), or a position from 1.
fn resolve(state: wire.ParsedState, target: ?[]const u8) ?Found {
    const wanted = target orelse sys.getenv("KOI_TAB") orelse return null;
    var position: usize = 0;
    var suffix_match: ?Found = null;
    for (state.items) |item| {
        const tabs: []const wire.ParsedTab = if (item.tab) |t| &.{t._0} else if (item.group) |g| g._0.tabs else &.{};
        for (tabs) |t| {
            position += 1;
            if (t.panes.len == 0) continue;
            const found = Found{ .tab = t, .pane = t.panes[0] };
            if (std.mem.eql(u8, t.id, wanted)) return found;
            if (std.fmt.parseInt(usize, wanted, 10)) |n| {
                if (n == position) return found;
            } else |_| {}
            if (wanted.len >= 4 and std.mem.endsWith(u8, t.id, wanted)) suffix_match = found;
        }
    }
    return suffix_match;
}

fn list(gpa: Allocator, args: []const [:0]const u8) u8 {
    var client = Client.connect(gpa) orelse return 4;
    defer client.deinit();
    client.send(.watch, "");
    const json = client.expect(.state) orelse return 1;
    defer gpa.free(json);
    if (args.len > 0 and std.mem.eql(u8, args[0], "--json")) {
        // The server's tree as sent: nothing the parsed shape below leaves
        // out (tab names, future fields) is lost on the way to a script.
        _ = sys.writeAll(1, json);
        _ = sys.writeAll(1, "\n");
        return 0;
    }
    const parsed = wire.parse(wire.ParsedState, gpa, json) catch |e| {
        std.debug.print("koi: cannot read the server's state: {s}\n", .{@errorName(e)});
        return 1;
    };
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var position: usize = 0;
    for (parsed.value.items) |item| {
        if (item.tab) |t| appendTab(gpa, &out, t._0, &position, "");
        if (item.group) |g| {
            out.print(gpa, "{s}\n", .{if (g._0.name.len > 0) g._0.name else "(group)"}) catch {};
            for (g._0.tabs) |t| appendTab(gpa, &out, t, &position, "  ");
        }
    }
    _ = sys.writeAll(1, out.items);
    return 0;
}

fn appendTab(gpa: Allocator, out: *std.ArrayList(u8), t: wire.ParsedTab, position: *usize, indent: []const u8) void {
    position.* += 1;
    if (t.panes.len == 0) return;
    const p = t.panes[0];
    const program = if (p.program.len > 0) p.program else p.shell;
    out.print(gpa, "{s}{d:>2}  {s}  {s:<12} {s}  {s}\n", .{ indent, position.*, t.id, program, p.cwd, @tagName(p.status) }) catch {};
}

fn newTab(gpa: Allocator, args: []const [:0]const u8) u8 {
    var cwd: ?[]const u8 = null;
    var startup: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--cwd") and i + 1 < args.len) {
            i += 1;
            cwd = args[i];
        } else if (std.mem.eql(u8, args[i], "--command") and i + 1 < args.len) {
            i += 1;
            startup = args[i];
        } else {
            std.debug.print("koi new: unexpected '{s}'\n", .{args[i]});
            return 2;
        }
    }
    var client = Client.connect(gpa) orelse return 4;
    defer client.deinit();
    if (startup != null and !client.supports("startup")) return 1;
    client.sendJson(.command, wire.Command{ .op = .newTab, .tab = sys.getenv("KOI_TAB"), .cwd = cwd, .startup = startup });
    const json = client.expect(.result) orelse return 1;
    defer gpa.free(json);
    const parsed = wire.parse(wire.Result, gpa, json) catch return 1;
    defer parsed.deinit();
    if (parsed.value.@"error") |e| {
        std.debug.print("koi: {s}\n", .{e});
        return 1;
    }
    const id = parsed.value.tab orelse return 1;
    _ = sys.writeAll(1, id);
    _ = sys.writeAll(1, "\n");
    return 0;
}

/// Attaches to a target's pane and runs `body` with the client; the first
/// frames are the pane's info and snapshot.
fn withPane(gpa: Allocator, target: ?[]const u8, ctx: anytype, body: fn (@TypeOf(ctx), *Client, []const u8) u8) u8 {
    var client = Client.connect(gpa) orelse return 4;
    defer client.deinit();
    const parsed = client.state() orelse return 1;
    defer parsed.deinit();
    const pane = exactPane(parsed.value, target) orelse (resolve(parsed.value, target) orelse {
        std.debug.print("koi: no such pane or tab\n", .{});
        return 3;
    }).pane.id;
    // Zero size: attach to read or send without resizing the pane the
    // interactive client has sized (see the server's open handler).
    client.sendJson(.open, wire.OpenRequest{ .pane = pane, .cols = 0, .rows = 0, .cellWidth = 8, .cellHeight = 16 });
    const attached = client.expect(.attached) orelse return 1;
    gpa.free(attached);
    const snapshot = client.expect(.snapshot) orelse return 1;
    defer gpa.free(snapshot);
    return body(ctx, &client, snapshot);
}

fn send(gpa: Allocator, args: []const [:0]const u8) u8 {
    if (args.len < 2) {
        std.debug.print("usage: koi send TARGET TEXT...\n", .{});
        return 2;
    }
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (args[1..], 0..) |a, i| {
        if (i > 0) text.append(gpa, ' ') catch {};
        // "\n" in the text is Enter.
        var rest: []const u8 = a;
        while (std.mem.indexOf(u8, rest, "\\n")) |j| {
            text.appendSlice(gpa, rest[0..j]) catch {};
            text.append(gpa, '\r') catch {};
            rest = rest[j + 2 ..];
        }
        text.appendSlice(gpa, rest) catch {};
    }
    const Ctx = struct { bytes: []const u8 };
    return withPane(gpa, args[0], Ctx{ .bytes = text.items }, struct {
        fn f(ctx: Ctx, client: *Client, _: []const u8) u8 {
            client.send(.input, ctx.bytes);
            // Give the server the bytes before the socket closes.
            sys.sleepMillis(20);
            return 0;
        }
    }.f);
}

fn capture(gpa: Allocator, args: []const [:0]const u8) u8 {
    const target: ?[]const u8 = if (args.len > 0) args[0] else null;
    return withPane(gpa, target, gpa, struct {
        fn f(alloc: Allocator, _: *Client, snapshot: []const u8) u8 {
            _ = alloc;
            var t = Terminal.fromSnapshot(snapshot) orelse return 1;
            defer t.deinit();
            const text = t.text() orelse return 1;
            defer Terminal.freeSnapshot(text);
            _ = sys.writeAll(1, text);
            if (text.len == 0 or text[text.len - 1] != '\n') _ = sys.writeAll(1, "\n");
            return 0;
        }
    }.f);
}

fn split(gpa: Allocator, args: []const [:0]const u8) u8 {
    var target: ?[]const u8 = null;
    var direction: wire.Direction = .right;
    var cwd: ?[]const u8 = null;
    var startup: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--down")) {
            direction = .down;
        } else if (std.mem.eql(u8, arg, "--right")) {
            direction = .right;
        } else if ((std.mem.eql(u8, arg, "--cwd") or std.mem.eql(u8, arg, "--command")) and i + 1 < args.len) {
            i += 1;
            if (std.mem.eql(u8, arg, "--cwd")) cwd = args[i] else startup = args[i];
        } else if (!std.mem.startsWith(u8, arg, "--") and target == null) {
            target = arg;
        } else {
            std.debug.print("koi split: unexpected '{s}'\n", .{arg});
            return 2;
        }
    }
    var client = Client.connect(gpa) orelse return 4;
    defer client.deinit();
    if (!client.supportsSplitOptions(cwd, startup)) return 1;
    const pane_id = paneTarget(&client, target) orelse return 3;
    defer gpa.free(pane_id);
    client.sendJson(.command, wire.Command{ .op = .splitPane, .pane = pane_id, .direction = direction, .cwd = cwd, .startup = startup });
    const json = client.expect(.result) orelse return 1;
    defer gpa.free(json);
    const parsed = wire.parse(wire.Result, gpa, json) catch return 1;
    defer parsed.deinit();
    if (parsed.value.@"error") |e| {
        std.debug.print("koi: {s}\n", .{e});
        return 1;
    }
    const id = parsed.value.pane orelse return 1;
    _ = sys.writeAll(1, id);
    _ = sys.writeAll(1, "\n");
    return 0;
}

/// Ends the first pane of the resolved tab; its last pane also ends the tab.
fn closePane(gpa: Allocator, args: []const [:0]const u8) u8 {
    const target: ?[]const u8 = if (args.len > 0) args[0] else null;
    return withPane(gpa, target, gpa, struct {
        fn f(_: Allocator, client: *Client, _: []const u8) u8 {
            client.send(.kill, "");
            sys.sleepMillis(20);
            return 0;
        }
    }.f);
}

/// The id of the pane `target` names exactly, if it names one.
fn exactPane(state: wire.ParsedState, target: ?[]const u8) ?[]const u8 {
    const id = target orelse return null;
    for (state.items) |item| {
        const tabs: []const wire.ParsedTab = if (item.tab) |t| &.{t._0} else if (item.group) |g| g._0.tabs else &.{};
        for (tabs) |tab| for (tab.panes) |pane| {
            if (std.mem.eql(u8, pane.id, id)) return pane.id;
        };
    }
    return null;
}

/// Resolves an exact pane id or tab target, copying it out of the state arena.
/// With no target, KOI_PANE wins over the tab fallback.
fn paneTarget(client: *Client, target: ?[]const u8) ?[]u8 {
    if (target == null) if (sys.getenv("KOI_PANE")) |id| return client.gpa.dupe(u8, id) catch null;
    const parsed = client.state() orelse return null;
    defer parsed.deinit();
    if (exactPane(parsed.value, target)) |id| return client.gpa.dupe(u8, id) catch null;
    const found = resolve(parsed.value, target) orelse {
        std.debug.print("koi: no such pane or tab\n", .{});
        return null;
    };
    return client.gpa.dupe(u8, found.pane.id) catch null;
}

/// `koi api [OP]`: the command vocabulary as JSON, from the binary alone.
fn api(gpa: Allocator, args: []const [:0]const u8) u8 {
    if (args.len > 1) return 2;
    const text = (api_doc.describe(gpa, if (args.len == 1) args[0] else null, &@import("server.zig").capabilities) catch return 1) orelse {
        std.debug.print("koi: no such operation: {s}\n", .{args[0]});
        return 2;
    };
    defer gpa.free(text);
    return if (sys.writeAll(1, text) and sys.writeAll(1, "\n")) 0 else 1;
}

/// Reports the answering server, even when its on-disk binary was replaced.
fn info(gpa: Allocator, args: []const [:0]const u8) u8 {
    if (args.len > 1 or (args.len == 1 and !std.mem.eql(u8, args[0], "--json"))) return 2;
    var client = Client.connect(gpa) orelse return 4;
    defer client.deinit();
    const result = client.command(.{ .op = .serverInfo }) orelse return 1;
    defer result.deinit();
    if (result.value.@"error" != null or result.value.serverVersion == null) {
        std.debug.print("koi: running server does not support serverInfo; sessions were left intact\n", .{});
        return 1;
    }
    const value = result.value;
    const out = if (args.len == 1)
        std.json.Stringify.valueAlloc(gpa, value, .{ .emit_null_optional_fields = false }) catch return 1
    else
        std.fmt.allocPrint(gpa, "koi {s} pid {d} protocol {d} uptime {d}s", .{ value.serverVersion.?, value.serverPID orelse 0, value.protocolVersion orelse 0, value.uptimeSeconds orelse 0 }) catch return 1;
    defer gpa.free(out);
    _ = sys.writeAll(1, out);
    _ = sys.writeAll(1, "\n");
    if (args.len == 0) {
        for ([_]struct { label: []const u8, values: []const []const u8 }{
            .{ .label = "transports", .values = value.transports orelse &.{} },
            .{ .label = "capabilities", .values = value.capabilities orelse &.{} },
        }) |entry| {
            _ = sys.writeAll(1, entry.label);
            for (entry.values) |v| {
                _ = sys.writeAll(1, " ");
                _ = sys.writeAll(1, v);
            }
            _ = sys.writeAll(1, "\n");
        }
    }
    return 0;
}

/// Mutates engine state, never the child process or its terminal driver.
fn editPane(gpa: Allocator, args: []const [:0]const u8, op: wire.Op) u8 {
    if (args.len > 1) return 2;
    var client = Client.connect(gpa) orelse return 4;
    defer client.deinit();
    if (!client.supports(@tagName(op))) return 1;
    const id = paneTarget(&client, if (args.len == 1) args[0] else null) orelse return 3;
    defer gpa.free(id);
    const result = client.command(.{ .op = op, .pane = id }) orelse return 1;
    defer result.deinit();
    if (result.value.@"error") |err| {
        std.debug.print("koi: {s}\n", .{err});
        return 1;
    }
    return 0;
}

/// Reports a program's status without terminal output or environment discovery.
/// A single state argument uses KOI_PANE; two arguments use an exact pane id.
fn reportStatus(gpa: Allocator, args: []const [:0]const u8) u8 {
    if (args.len != 1 and args.len != 2) {
        std.debug.print("usage: koi status [PANE] working|blocked|done|error|idle\n", .{});
        return 2;
    }
    const status = std.meta.stringToEnum(wire.Status, args[args.len - 1]) orelse {
        std.debug.print("koi status: expected working, blocked, done, error or idle\n", .{});
        return 2;
    };
    const pane = if (args.len == 2) args[0] else sys.getenv("KOI_PANE") orelse {
        std.debug.print("koi status: provide PANE or set KOI_PANE\n", .{});
        return 2;
    };
    if (pane.len == 0) return 2;
    var client = Client.connect(gpa) orelse return 4;
    defer client.deinit();
    if (!client.supports("reportStatus")) return 1;
    const result = client.command(.{ .op = .reportStatus, .pane = pane, .status = status }) orelse return 1;
    defer result.deinit();
    if (result.value.@"error") |err| {
        std.debug.print("koi: {s}\n", .{err});
        return 1;
    }
    return 0;
}

test "explicit split cwd rejects archived v6 before sending a split mutation" {
    const gpa = std.testing.allocator;
    for ([_]wire.Result{
        .{ .@"error" = "malformed command" },
        .{ .capabilities = &.{ "serverInfo", "startup" } },
    }) |response| {
        var fds: [2]c_int = undefined;
        try std.testing.expectEqual(0, c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &fds));
        var client = Client{ .gpa = gpa, .socket = Socket.init(fds[0]), .reader = wire.FrameReader.init(gpa) };
        defer client.deinit();
        var peer = Socket.init(fds[1]);
        defer peer.close();
        const frame = try wire.frameJson(gpa, .result, response);
        defer gpa.free(frame);
        peer.send(frame);
        try std.testing.expect(!client.supportsSplitOptions("/requested", null));
        var buffer: [4096]u8 = undefined;
        const n = peer.read(&buffer);
        var frames = wire.FrameReader.init(gpa);
        defer frames.deinit();
        try frames.append(buffer[0..n]);
        const probe = (try frames.next()).?;
        try std.testing.expectEqual(wire.Kind.command, probe.kind);
        const command = try wire.parse(wire.Command, gpa, probe.payload);
        defer command.deinit();
        try std.testing.expectEqual(wire.Op.serverInfo, command.value.op);
        try std.testing.expect((try frames.next()) == null);
    }
}
