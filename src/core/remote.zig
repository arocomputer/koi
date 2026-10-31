//! What `koi` does on a machine reached from the app: answers `--offer`
//! with a UDP link to this machine's server, and relays a connection over
//! SSH with `--stdio` when UDP cannot get through. Both start the server
//! if none runs.
const std = @import("std");
const sys = @import("sys.zig");
const c = sys.c;
const wire = @import("wire.zig");
const Server = @import("server.zig").Server;
const Socket = @import("transport.zig").Socket;

/// `koi --offer`: prints the server's offer (a UDP port and secret for one
/// client) as JSON and exits. The secret travels only inside the SSH
/// session that ran this.
pub fn printOffer(gpa: std.mem.Allocator) noreturn {
    var socket = Server.connect(gpa) orelse std.process.exit(1);
    var frame: [wire.header_size]u8 = .{ @backingInt(wire.Kind.offer), 0, 0, 0, 0 };
    socket.send(&frame);
    var reader = wire.FrameReader.init(gpa);
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = socket.read(&buf);
        if (n == 0) std.process.exit(1);
        reader.append(buf[0..n]) catch std.process.exit(1);
        while (reader.next() catch std.process.exit(1)) |f| {
            if (f.kind == .offered) {
                // A short write here would hand the app truncated JSON, so the
                // exit status has to reflect whether the whole offer went out.
                std.process.exit(if (sys.writeAll(1, f.payload)) 0 else 1);
            }
        }
    }
}

/// How often the app sends a keepalive over an SSH connection. Mirrored in
/// src/app/remote.swift; the deadline below leaves room for three to be lost.
pub const keepalive_interval_ms = 20_000;
pub const keepalive_deadline_ms = 75_000;

/// What stands between an SSH channel and the server. An app that wants dead
/// channels noticed sends `keepalive` frames; the filter swallows them, since
/// the server has no use for them and an older one would reject the kind, and
/// from the first on treats a silence longer than the deadline as a channel
/// whose far end is gone. A peer that never sends one is never timed out, so
/// older apps behave as before. Everything else passes through frame by frame.
const Filter = struct {
    reader: wire.FrameReader,
    armed: bool = false,
    last_heard: i64,

    fn init(gpa: std.mem.Allocator, now: i64) Filter {
        return .{ .reader = wire.FrameReader.init(gpa), .last_heard = now };
    }

    fn deinit(self: *Filter) void {
        self.reader.deinit();
    }

    /// Takes bytes from the channel and appends the frames to forward to `out`.
    /// Fails on a frame no peer should send, as the server would.
    fn feed(self: *Filter, gpa: std.mem.Allocator, bytes: []const u8, now: i64, out: *std.ArrayList(u8)) !void {
        self.last_heard = now;
        try self.reader.append(bytes);
        while (try self.reader.next()) |f| {
            if (f.kind == .keepalive) {
                if (f.payload.len != 0) return error.Protocol;
                self.armed = true;
                continue;
            }
            var header: [wire.header_size]u8 = undefined;
            header[0] = @backingInt(f.kind);
            std.mem.writeInt(u32, header[1..5], @intCast(f.payload.len), .little);
            try out.appendSlice(gpa, &header);
            try out.appendSlice(gpa, f.payload);
        }
    }

    fn expired(self: Filter, now: i64) bool {
        return self.armed and now - self.last_heard > keepalive_deadline_ms;
    }
};

/// `koi --stdio`: relays stdin and stdout to this machine's server, for a
/// connection carried over an SSH channel. Never returns.
pub fn relay(gpa: std.mem.Allocator) noreturn {
    sys.ignoreSignal(c.SIGPIPE);
    const socket = gpa.create(Socket) catch std.process.exit(1);
    socket.* = Server.connect(gpa) orelse std.process.exit(1);
    const t = std.Thread.spawn(.{}, stdinToSocket, .{ gpa, socket }) catch std.process.exit(1);
    t.detach();
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = socket.read(&buf);
        if (n == 0) std.process.exit(0);
        if (!sys.writeAll(1, buf[0..n])) std.process.exit(0);
    }
}

/// Copies the channel to the server until it closes, or goes quiet after
/// the app has asked for that to be noticed.
fn stdinToSocket(gpa: std.mem.Allocator, socket: *Socket) void {
    var filter = Filter.init(gpa, sys.elapsedMillis());
    var out: std.ArrayList(u8) = .empty;
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        var fds = [_]c.struct_pollfd{.{ .fd = 0, .events = c.POLLIN, .revents = 0 }};
        const ready = c.poll(&fds, 1, 5000);
        if (ready < 0 and sys.errno() == c.EINTR) continue;
        if (ready < 0) std.process.exit(0);
        if (ready == 0) {
            if (filter.expired(sys.elapsedMillis())) std.process.exit(0);
            continue;
        }
        const n = c.read(0, &buf, buf.len);
        if (n < 0 and sys.errno() == c.EINTR) continue;
        if (n <= 0) std.process.exit(0);
        out.clearRetainingCapacity();
        filter.feed(gpa, buf[0..@intCast(n)], sys.elapsedMillis(), &out) catch std.process.exit(1);
        if (out.items.len > 0) socket.send(out.items);
    }
}

fn frameBytes(gpa: std.mem.Allocator, kind: wire.Kind, payload: []const u8) ![]u8 {
    return wire.frame(gpa, kind, payload);
}

test "relay swallows keepalives and forwards the rest" {
    const gpa = std.testing.allocator;
    const open = try frameBytes(gpa, .open, "{\"pane\":\"a\"}");
    defer gpa.free(open);
    const beat = try frameBytes(gpa, .keepalive, "");
    defer gpa.free(beat);
    const input = try frameBytes(gpa, .input, "ls\n");
    defer gpa.free(input);
    const stream = try std.mem.concat(gpa, u8, &.{ open, beat, input, beat });
    defer gpa.free(stream);
    const want = try std.mem.concat(gpa, u8, &.{ open, input });
    defer gpa.free(want);
    // One piece, then one byte at a time: frames split anywhere.
    for ([_]usize{ stream.len, 1, 3 }) |chunk| {
        var filter = Filter.init(gpa, 0);
        defer filter.deinit();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        var at: usize = 0;
        while (at < stream.len) : (at += chunk) try filter.feed(gpa, stream[at..@min(at + chunk, stream.len)], 0, &out);
        try std.testing.expectEqualSlices(u8, want, out.items);
        try std.testing.expect(filter.armed);
    }
}

test "relay times out only a peer that sent a keepalive" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var quiet = Filter.init(gpa, 0);
    defer quiet.deinit();
    const input = try frameBytes(gpa, .input, "x");
    defer gpa.free(input);
    try quiet.feed(gpa, input, 0, &out);
    try std.testing.expect(!quiet.expired(10 * keepalive_deadline_ms));

    var asked = Filter.init(gpa, 0);
    defer asked.deinit();
    const beat = try frameBytes(gpa, .keepalive, "");
    defer gpa.free(beat);
    try asked.feed(gpa, beat, 1000, &out);
    try std.testing.expect(!asked.expired(1000 + keepalive_deadline_ms));
    try std.testing.expect(asked.expired(1000 + keepalive_deadline_ms + 1));
    try asked.feed(gpa, input, 2000 + keepalive_deadline_ms, &out);
    try std.testing.expect(!asked.expired(2000 + keepalive_deadline_ms + 1));
}

test "relay rejects a bad frame" {
    const gpa = std.testing.allocator;
    var filter = Filter.init(gpa, 0);
    defer filter.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try std.testing.expectError(error.Protocol, filter.feed(gpa, &.{ 200, 0, 0, 0, 0 }, 0, &out));
    var malformed = Filter.init(gpa, 0);
    defer malformed.deinit();
    const beat = try frameBytes(gpa, .keepalive, "not empty");
    defer gpa.free(beat);
    try std.testing.expectError(error.Protocol, malformed.feed(gpa, beat, 0, &out));
}
