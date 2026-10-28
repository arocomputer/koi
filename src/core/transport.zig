//! A connection carrying frames: a local socket, or a stream of a link to
//! another machine. `read` blocks until bytes arrive and returns 0 once the
//! peer is gone; on the server side `send` never blocks (see `Socket`).
const std = @import("std");
const sys = @import("sys.zig");
const c = sys.c;
const Allocator = std.mem.Allocator;

pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        send: *const fn (ptr: *anyopaque, bytes: []const u8) void,
        read: *const fn (ptr: *anyopaque, buf: []u8) usize,
        close: *const fn (ptr: *anyopaque) void,
    };

    pub fn send(self: Transport, bytes: []const u8) void {
        self.vtable.send(self.ptr, bytes);
    }

    pub fn read(self: Transport, buf: []u8) usize {
        return self.vtable.read(self.ptr, buf);
    }

    pub fn close(self: Transport) void {
        self.vtable.close(self.ptr);
    }
};

/// The most a server-side socket queues for a peer that is not reading,
/// beyond the frame being sent. Past it the peer is dropped; a client that
/// reattaches gets a fresh snapshot.
pub const max_backlog: usize = 16 * 1024 * 1024;

/// A connected Unix socket in one of two modes.
///
/// Client mode (`init`, `connect`): `send` blocks until the kernel takes the
/// bytes and `close` closes the descriptor.
///
/// Server mode (`initServer`): the descriptor is set `O_NONBLOCK` (on Darwin
/// `MSG_DONTWAIT` alone still blocks a large AF_UNIX send), `read` polls for
/// data, and `send` never blocks, so callers may hold the server's or a
/// pane's lock. Bytes the kernel will not take yet wait in a
/// bounded queue that a lazily started writer thread drains; a peer that
/// leaves more than `max_backlog` unread is hung up. `close` only hangs up
/// (any thread, any number of times); the owner calls `release` once no one
/// else can use the socket, which joins the writer and closes the descriptor,
/// so a reused descriptor number is never touched through a stale socket.
pub const Socket = struct {
    fd: c_int,
    closed: std.atomic.Value(bool) = .init(false),
    /// Set in server mode; allocates the queue.
    gpa: ?Allocator = null,
    mutex: sys.Mutex = undefined,
    cond: sys.Cond = undefined,
    /// Bytes not yet accepted by the kernel: `queue.items[head..]`.
    queue: std.ArrayList(u8) = .empty,
    head: usize = 0,
    writer: ?std.Thread = null,

    pub fn init(fd: c_int) Socket {
        return .{ .fd = fd };
    }

    pub fn initServer(gpa: Allocator, fd: c_int) Socket {
        _ = c.fcntl(fd, c.F_SETFL, c.fcntl(fd, c.F_GETFL) | c.O_NONBLOCK);
        return .{ .fd = fd, .gpa = gpa, .mutex = sys.Mutex.init(), .cond = sys.Cond.init() };
    }

    /// Connects to the socket at `path`; null if nothing listens there.
    pub fn connect(path: []const u8) ?Socket {
        const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (fd < 0) return null;
        var addr = unixAddress(path) orelse {
            _ = c.close(fd);
            return null;
        };
        if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0) {
            _ = c.close(fd);
            return null;
        }
        return .{ .fd = fd };
    }

    pub fn transport(self: *Socket) Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Transport.VTable{ .send = sendImpl, .read = readImpl, .close = closeImpl };

    fn sendImpl(ptr: *anyopaque, bytes: []const u8) void {
        const self: *Socket = @ptrCast(@alignCast(ptr));
        self.send(bytes);
    }

    /// Sends one frame, whole and in order with other frames.
    pub fn send(self: *Socket, bytes: []const u8) void {
        if (self.gpa == null) return self.sendBlocking(bytes);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed.load(.acquire) or bytes.len == 0) return;
        var off: usize = 0;
        if (self.queue.items.len == self.head) {
            self.queue.clearRetainingCapacity();
            self.head = 0;
            // Nothing waits ahead of this frame: give the kernel what it takes.
            while (off < bytes.len) {
                const n = c.send(self.fd, bytes.ptr + off, bytes.len - off, noSigpipe);
                if (n > 0) {
                    off += @intCast(n);
                } else if (n < 0 and sys.errno() == c.EINTR) {
                    continue;
                } else if (n < 0 and (sys.errno() == c.EAGAIN or sys.errno() == c.EWOULDBLOCK)) {
                    break;
                } else {
                    self.hangUp();
                    return;
                }
            }
            if (off == bytes.len) return;
        } else if (self.queue.items.len - self.head >= max_backlog) {
            self.hangUp();
            return;
        }
        if (self.head >= 1024 * 1024) {
            // A slow but steady peer must not make the queue grow forever.
            const rest = self.queue.items.len - self.head;
            std.mem.copyForwards(u8, self.queue.items[0..rest], self.queue.items[self.head..]);
            self.queue.items.len = rest;
            self.head = 0;
        }
        self.queue.appendSlice(self.gpa.?, bytes[off..]) catch {
            self.hangUp();
            return;
        };
        if (self.writer == null) {
            self.writer = std.Thread.spawn(.{}, drain, .{self}) catch {
                self.hangUp();
                return;
            };
        }
        self.cond.signal();
    }

    fn sendBlocking(self: *Socket, bytes: []const u8) void {
        if (self.closed.load(.acquire)) return;
        var off: usize = 0;
        while (off < bytes.len) {
            const n = c.send(self.fd, bytes.ptr + off, bytes.len - off, noSigpipe);
            if (n > 0) {
                off += @intCast(n);
            } else if (n < 0 and sys.errno() == c.EINTR) {
                continue;
            } else {
                self.close();
                return;
            }
        }
    }

    /// The writer thread: pushes the queue to the peer as it takes bytes,
    /// until the socket is hung up. It waits for room without the lock.
    fn drain(self: *Socket) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!self.closed.load(.acquire)) {
            const pending = self.queue.items[self.head..];
            if (pending.len == 0) {
                if (self.queue.capacity > 1024 * 1024) self.queue.clearAndFree(self.gpa.?) else self.queue.clearRetainingCapacity();
                self.head = 0;
                self.cond.wait(&self.mutex);
                continue;
            }
            const n = c.send(self.fd, pending.ptr, pending.len, noSigpipe);
            if (n > 0) {
                self.head += @intCast(n);
            } else if (n < 0 and sys.errno() == c.EINTR) {
                continue;
            } else if (n < 0 and (sys.errno() == c.EAGAIN or sys.errno() == c.EWOULDBLOCK)) {
                self.mutex.unlock();
                var fds = [_]c.struct_pollfd{.{ .fd = self.fd, .events = c.POLLOUT, .revents = 0 }};
                _ = c.poll(&fds, 1, 100);
                self.mutex.lock();
            } else {
                self.hangUp();
            }
        }
    }

    fn readImpl(ptr: *anyopaque, buf: []u8) usize {
        const self: *Socket = @ptrCast(@alignCast(ptr));
        return self.read(buf);
    }

    /// Blocks until bytes arrive; 0 once the peer is gone. A server-mode
    /// descriptor is nonblocking, so this polls (waking at least once a
    /// second to notice a hang-up).
    pub fn read(self: *Socket, buf: []u8) usize {
        while (true) {
            const n = c.read(self.fd, buf.ptr, buf.len);
            if (n > 0) return @intCast(n);
            if (n < 0 and sys.errno() == c.EINTR) continue;
            if (n < 0 and (sys.errno() == c.EAGAIN or sys.errno() == c.EWOULDBLOCK)) {
                if (self.closed.load(.acquire)) return 0;
                var fds = [_]c.struct_pollfd{.{ .fd = self.fd, .events = c.POLLIN, .revents = 0 }};
                _ = c.poll(&fds, 1, 1000);
                continue;
            }
            return 0;
        }
    }

    fn closeImpl(ptr: *anyopaque) void {
        const self: *Socket = @ptrCast(@alignCast(ptr));
        self.close();
    }

    /// Hangs up once: later sends are dropped and a blocked read returns.
    /// A client-mode socket also closes its descriptor; a server-mode one
    /// keeps it until `release`.
    pub fn close(self: *Socket) void {
        if (self.gpa == null) {
            if (self.closed.swap(true, .acq_rel)) return;
            _ = c.shutdown(self.fd, c.SHUT_RDWR);
            _ = c.close(self.fd);
            return;
        }
        self.mutex.lock();
        defer self.mutex.unlock();
        self.hangUp();
    }

    /// Server mode, mutex held.
    fn hangUp(self: *Socket) void {
        if (self.closed.swap(true, .acq_rel)) return;
        _ = c.shutdown(self.fd, c.SHUT_RDWR);
        self.cond.signal();
    }

    /// Server mode: ends the socket for good. The caller must be the last
    /// user; nothing may call into it afterwards.
    pub fn release(self: *Socket) void {
        self.close();
        if (self.writer) |t| t.join();
        self.queue.deinit(self.gpa.?);
        _ = c.close(self.fd);
    }
};

/// MSG_NOSIGNAL where it exists; macOS uses SO_NOSIGPIPE on the socket.
const noSigpipe: c_int = if (@hasDecl(c, "MSG_NOSIGNAL")) c.MSG_NOSIGNAL else 0;

/// Sets what keeps a write to a dead peer from killing the process, on the
/// platforms where that is a socket option.
pub fn quietSigpipe(fd: c_int) void {
    if (@hasDecl(c, "SO_NOSIGPIPE")) {
        var on: c_int = 1;
        _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_NOSIGPIPE, &on, @sizeOf(c_int));
    }
}

pub fn unixAddress(path: []const u8) ?c.struct_sockaddr_un {
    var addr: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
    addr.sun_family = c.AF_UNIX;
    if (path.len >= addr.sun_path.len) return null;
    @memcpy(addr.sun_path[0..path.len], path);
    addr.sun_path[path.len] = 0;
    return addr;
}

/// Binds and listens on a Unix socket at `path`, private to the user.
pub fn listenUnix(path: []const u8) !c_int {
    var pathz: [256]u8 = undefined;
    if (path.len >= pathz.len) return error.PathTooLong;
    @memcpy(pathz[0..path.len], path);
    pathz[path.len] = 0;
    _ = c.unlink(&pathz);
    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return error.Socket;
    errdefer _ = c.close(fd);
    _ = c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC);
    var addr = unixAddress(path) orelse return error.PathTooLong;
    if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0) return error.Bind;
    _ = c.chmod(&pathz, 0o600);
    if (c.listen(fd, 64) != 0) return error.Listen;
    return fd;
}

test "a peer that never reads cannot block send, and is dropped past the backlog" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(0, c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var socket = Socket.initServer(std.testing.allocator, fds[0]);
    defer socket.release();
    const chunk = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(chunk);
    @memset(chunk, 'x');
    var sent: usize = 0;
    while (!socket.closed.load(.acquire) and sent < 4 * max_backlog) : (sent += chunk.len) socket.send(chunk);
    try std.testing.expect(socket.closed.load(.acquire));
    try std.testing.expect(sent > max_backlog);
}

test "queued frames reach a slow reader whole and in order" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(0, c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var socket = Socket.initServer(std.testing.allocator, fds[0]);
    defer socket.release();
    // One frame larger than the socket buffer, then a small one.
    const big = try std.testing.allocator.alloc(u8, 3 * 1024 * 1024);
    defer std.testing.allocator.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i);
    socket.send(big);
    socket.send("tail");
    var got = try std.testing.allocator.alloc(u8, big.len + 4);
    defer std.testing.allocator.free(got);
    var n: usize = 0;
    while (n < got.len) {
        const r = c.read(fds[1], got.ptr + n, got.len - n);
        try std.testing.expect(r > 0);
        n += @intCast(r);
    }
    try std.testing.expectEqualSlices(u8, big, got[0..big.len]);
    try std.testing.expectEqualStrings("tail", got[big.len..]);
}

test "a server socket reads what arrives after it started waiting" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(0, c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var socket = Socket.initServer(std.testing.allocator, fds[0]);
    defer socket.release();
    const writer = try std.Thread.spawn(.{}, struct {
        fn run(fd: c_int) void {
            sys.sleepMillis(100);
            _ = c.write(fd, "late", 4);
        }
    }.run, .{fds[1]});
    defer writer.join();
    var buf: [8]u8 = undefined;
    const n = socket.read(&buf);
    try std.testing.expectEqualStrings("late", buf[0..n]);
}

test "hanging up a server socket keeps its descriptor until release" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(0, c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var socket = Socket.initServer(std.testing.allocator, fds[0]);
    socket.close();
    socket.close();
    try std.testing.expect(c.fcntl(fds[0], c.F_GETFD) >= 0);
    socket.release();
    try std.testing.expect(c.fcntl(fds[0], c.F_GETFD) < 0);
}
