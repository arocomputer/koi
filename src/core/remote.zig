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
                _ = c.write(1, f.payload.ptr, f.payload.len);
                std.process.exit(0);
            }
        }
    }
}

/// `koi --stdio`: relays stdin and stdout to this machine's server, for a
/// connection carried over an SSH channel. Never returns.
pub fn relay(gpa: std.mem.Allocator) noreturn {
    sys.ignoreSignal(c.SIGPIPE);
    const socket = gpa.create(Socket) catch std.process.exit(1);
    socket.* = Server.connect(gpa) orelse std.process.exit(1);
    const t = std.Thread.spawn(.{}, stdinToSocket, .{socket}) catch std.process.exit(1);
    t.detach();
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = socket.read(&buf);
        if (n == 0) std.process.exit(0);
        var off: usize = 0;
        while (off < n) {
            const w = c.write(1, buf[off..].ptr, n - off);
            if (w <= 0) std.process.exit(0);
            off += @intCast(w);
        }
    }
}

fn stdinToSocket(socket: *Socket) void {
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = c.read(0, &buf, buf.len);
        if (n < 0 and sys.errno() == c.EINTR) continue;
        if (n <= 0) std.process.exit(0);
        socket.send(buf[0..@intCast(n)]);
    }
}
