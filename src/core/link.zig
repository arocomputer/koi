//! Swift Link's encrypted UDP protocol: independent reliable byte streams.
//! Configure callbacks before exposing a link to its peer. Callbacks run without
//! the state mutex and may use streams.
//!
//! Memory is bounded per stream: at most `max_unsent` queued for sending (past
//! it the stream is reset, see `Stream.send`) and at most `receive_window` of
//! unread plus `receive_window` of out-of-order data received. The advertised
//! receive window follows what the application has *read*, so a peer that is
//! not read from is stalled by flow control instead of growing our buffers.
//! Each link admits at most `max_active_streams` unreclaimed streams (including
//! released streams awaiting FINs). Excess opens fail locally or are dropped
//! remotely for retry. The highest `max_tombstones` retired IDs remain available
//! to ACK late FINs. Evicting a peer ID rejects unknown IDs at or below that
//! watermark, including very late first DATA; existing streams are unaffected.
//! These are stream-count limits, not lifetime or total-transfer limits, so
//! persistent streams and scrollback snapshots use the same buffer budgets.
//!
//! Lifetime contract:
//! - Each `Stream` has one owner (whoever got it from `open` or `on_stream`).
//!   `close` shuts it down and wakes readers; it is idempotent and may be
//!   called, along with `send` and `read`, by any thread while the owner has
//!   not released the stream. `release` is called exactly once, last, after
//!   every thread of the application has stopped using the pointer (readers
//!   returned, broadcasters unregistered); the pointer is dead afterwards. It
//!   implies `close`.
//! - The link frees a stream once it is released, no reader is inside `read`
//!   and both FINs are acknowledged. EOF alone never frees a stream. Streams
//!   whose FIN exchange never completes are freed by `destroy`.
//! - `destroy` must run outside worker threads and callbacks, after every
//!   thread that reads, sends to or closes any of the link's streams has
//!   stopped using them. `destroy` closes the link first, which wakes all
//!   blocked readers (they return 0), so "reader threads joined" is enough.
const std = @import("std");
const sys = @import("sys.zig");
const c = sys.c;
const Transport = @import("transport.zig").Transport;
const Allocator = std.mem.Allocator;
const Aes = std.crypto.aead.aes_gcm.Aes256Gcm;
const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;
const mss = 1150;
const receive_window = 4 << 20;
/// Most bytes a stream queues for sending beyond what is in flight. Above the
/// largest scrollback snapshot (32 MiB); per-stream memory is bounded by this
/// plus `receive_window` in flight, plus up to 2 * `receive_window` received.
pub const max_unsent = 64 << 20;
/// Bookkeeping charged against `receive_window` per out-of-order segment, so
/// many tiny segments cannot cost more memory than their payload suggests.
const out_of_order_overhead = 64;
const data_header = 16;
const max_active_streams = 128;
const max_tombstones = 4096;

/// Share of outgoing packets dropped. Set only while no links are running.
pub var test_loss: f64 = 0;

/// A queue that avoids shifting a stream's entire backlog on every packet.
const Buffer = struct {
    storage: std.ArrayList(u8) = .empty,
    start: usize = 0,

    /// The unconsumed portion; invalidated by append or deinit.
    fn bytes(self: *const Buffer) []const u8 {
        return self.storage.items[self.start..];
    }

    /// Compact only after consuming at least half the storage. Sliding a large
    /// backlog on every 64 KiB append makes streaming work quadratic under
    /// the link mutex, delaying unrelated interactive streams.
    fn append(self: *Buffer, gpa: Allocator, bytes_: []const u8) !void {
        if (self.start == self.storage.items.len or
            (self.start > 64 * 1024 and self.start >= self.storage.items.len / 2))
        {
            const left = self.bytes().len;
            std.mem.copyForwards(u8, self.storage.items[0..left], self.bytes());
            self.storage.shrinkRetainingCapacity(left);
            self.start = 0;
        }
        try self.storage.appendSlice(gpa, bytes_);
    }

    /// Removes a prefix already copied or delivered by the caller, returning
    /// a large backing allocation once the queue drains.
    fn consume(self: *Buffer, gpa: Allocator, n: usize) void {
        self.start += n;
        if (self.start == self.storage.items.len and self.storage.capacity > 256 * 1024) {
            self.storage.clearAndFree(gpa);
            self.start = 0;
        }
    }

    /// Releases the queue's owned storage.
    fn deinit(self: *Buffer, gpa: Allocator) void {
        self.storage.deinit(gpa);
    }
};

/// Owned data retained until acknowledged, including FIN's sequence byte.
const Segment = struct {
    offset: u64,
    data: []u8,
    fin: bool,
    sent_at: i64,
    retransmits: u32 = 0,

    /// Exclusive sequence position; rejects exhaustion instead of wrapping.
    fn end(self: Segment) !u64 {
        const payload_end = try std.math.add(u64, self.offset, self.data.len);
        return std.math.add(u64, payload_end, @intFromBool(self.fin));
    }
};

/// An owned segment waiting for the missing prefix of a stream.
const Received = struct { data: []u8, fin: bool };
const FrameKind = enum(u8) { ack = 1, data = 2, ping = 4, pong = 5, close = 6 };

/// Sorted stream entry; retired entries remember the final ACK after freeing
/// the stream, so retransmitted FINs cannot open the same stream again.
const Slot = struct {
    id: u32,
    stream: ?*Stream,
    recv_next: u64 = 0,
    ack_pending: bool = false,
};

/// One authenticated peer, two worker threads, and mutex-protected stream state.
pub const Link = struct {
    port: u16,
    on_stream: ?*const fn (ctx: ?*anyopaque, stream: *Stream) void = null,
    on_stream_ctx: ?*anyopaque = null,
    on_close: ?*const fn (ctx: ?*anyopaque) void = null,
    on_close_ctx: ?*anyopaque = null,

    gpa: Allocator,
    fd: c_int,
    is_server: bool,
    seal_key: [32]u8,
    open_key: [32]u8,
    // Zig 0.17 moved Thread.Mutex/Condition and crypto.random to Io. This
    // backend supplies only synchronization/randomness; sockets use libc.
    runtime: std.Io.Threaded = .init_single_threaded,
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    receive_thread: ?std.Thread = null,
    timer_thread: ?std.Thread = null,
    closed: bool = false,
    close_notified: bool = false,
    peer: c.struct_sockaddr_storage = std.mem.zeroes(c.struct_sockaddr_storage),
    peer_len: c.socklen_t = 0,
    send_number: u64 = 0,
    recv_max: u64 = 0,
    recv_seen: u64 = 0,
    streams: std.ArrayList(Slot) = .empty,
    active_streams: usize = 0,
    retired_peer_id: u32 = 0,
    next_stream_id: u32,
    cwnd: usize = 16 * mss,
    /// Resume scheduling after the last stream served, even when an ACK
    /// reopens only enough congestion credit for one segment.
    send_cursor: usize = 0,
    ssthresh: usize = std.math.maxInt(usize),
    in_flight: usize = 0,
    srtt: f64 = 0.1,
    rttvar: f64 = 0.05,
    last_received: i64,
    last_sent: i64,
    pending_pongs: std.ArrayList(u64) = .empty,
    pong_generation: u64 = 0,

    /// Binds a close-on-exec dual-stack UDP socket in 60000...61000.
    pub fn listen(gpa: Allocator, secret: [32]u8) !*Link {
        const fd = try socket(c.AF_INET6);
        errdefer _ = c.close(fd);
        var off: c_int = 0;
        if (c.setsockopt(fd, c.IPPROTO_IPV6, c.IPV6_V6ONLY, &off, @sizeOf(c_int)) != 0) return error.Socket;
        const self = try create(gpa, fd, secret, true);
        errdefer self.free();
        const source = std.Random.IoSource{ .io = self.runtime.io() };
        var ports: [1001]u16 = undefined;
        for (&ports, 60000..) |*port_, value| port_.* = @intCast(value);
        source.interface().shuffle(u16, &ports);
        for (ports[0..50]) |port_| {
            var addr: c.struct_sockaddr_in6 = std.mem.zeroes(c.struct_sockaddr_in6);
            addr.sin6_family = c.AF_INET6;
            addr.sin6_port = std.mem.nativeToBig(u16, port_);
            addr.sin6_addr = c.in6addr_any;
            if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_in6)) != 0) continue;
            self.port = port_;
            try self.start();
            return self;
        }
        return error.Bind;
    }

    /// Resolves UDP addresses and proves each path with pings at 400 ms
    /// intervals, allowing at most 2.5 seconds per candidate address.
    pub fn connect(gpa: Allocator, host: []const u8, port: u16, secret: [32]u8) !*Link {
        const host_z = try gpa.dupeSentinel(u8, host, 0);
        defer gpa.free(host_z);
        var service: [6]u8 = undefined;
        const service_z = try std.mem.printSentinel(&service, "{d}", .{port}, 0);
        var hints = std.mem.zeroes(c.struct_addrinfo);
        hints.ai_socktype = c.SOCK_DGRAM;
        var first: ?*c.struct_addrinfo = null;
        if (c.getaddrinfo(host_z.ptr, service_z.ptr, &hints, &first) != 0) return error.Unreachable;
        defer c.freeaddrinfo(first);
        var candidate = first;
        while (candidate) |ai| : (candidate = ai.ai_next) {
            if (ai.ai_addrlen > @sizeOf(c.struct_sockaddr_storage)) continue;
            const fd = socket(ai.ai_family) catch continue;
            const self = create(gpa, fd, secret, false) catch |err| {
                _ = c.close(fd);
                return err;
            };
            @memcpy(std.mem.asBytes(&self.peer)[0..ai.ai_addrlen], @as([*]const u8, @ptrCast(ai.ai_addr))[0..ai.ai_addrlen]);
            self.peer_len = ai.ai_addrlen;
            self.start() catch |err| {
                _ = c.close(fd);
                self.free();
                return err;
            };
            const deadline = sys.nowMillis() + 2500;
            while (sys.nowMillis() < deadline) {
                self.mutex.lockUncancelable(self.runtime.io());
                const generation = self.pong_generation;
                self.sendPacket(&pingFrame(.ping, sys.nowMicros()));
                const until = @min(deadline, sys.nowMillis() + 400);
                while (!self.closed and self.pong_generation == generation and sys.nowMillis() < until) {
                    self.changed.waitTimeout(self.runtime.io(), &self.mutex, .{ .duration = .{
                        .raw = .fromMilliseconds(@max(until - sys.nowMillis(), 1)),
                        .clock = .awake,
                    } }) catch {};
                }
                const answered = !self.closed and self.pong_generation != generation;
                const closed = self.closed;
                self.unlockAndNotify();
                if (answered) return self;
                if (closed) break;
            }
            self.close();
            self.destroy();
        }
        return error.Unreachable;
    }

    /// Allocates a locally initiated stream (odd client IDs, even server IDs).
    /// Returns StreamLimit while the unreclaimed-stream budget is full.
    pub fn open(self: *Link) !*Stream {
        self.mutex.lockUncancelable(self.runtime.io());
        defer self.mutex.unlock(self.runtime.io());
        if (self.closed) return error.Closed;
        if (self.next_stream_id > std.math.maxInt(u32) - 2) return error.StreamIdsExhausted;
        const stream = try self.newStream(self.next_stream_id);
        self.next_stream_id += 2;
        return stream;
    }

    /// Sends CLOSE once and wakes all readers; descriptor release waits for destroy.
    pub fn close(self: *Link) void {
        self.mutex.lockUncancelable(self.runtime.io());
        if (!self.closed) {
            self.sendPacket(&.{@backingInt(FrameKind.close)});
            self.finish();
        }
        self.unlockAndNotify();
    }

    /// Reads the link's closed state under its mutex.
    pub fn isClosed(self: *Link) bool {
        self.mutex.lockUncancelable(self.runtime.io());
        defer self.mutex.unlock(self.runtime.io());
        return self.closed;
    }

    /// After close and application reader shutdown, joins workers and frees the
    /// link and its remaining streams. Must not be called from either worker.
    pub fn destroy(self: *Link) void {
        self.close();
        if (self.receive_thread) |thread| thread.join();
        if (self.timer_thread) |thread| thread.join();
        _ = c.close(self.fd);
        self.free();
    }

    /// Creates an unstarted link, deriving directional keys without a salt.
    fn create(gpa: Allocator, fd: c_int, secret: [32]u8, is_server: bool) !*Link {
        var c2s: [32]u8 = undefined;
        var s2c: [32]u8 = undefined;
        const prk = Hkdf.extract("", &secret);
        Hkdf.expand(&c2s, "koi c2s", prk);
        Hkdf.expand(&s2c, "koi s2c", prk);
        const self = try gpa.create(Link);
        self.* = .{
            .gpa = gpa,
            .fd = fd,
            .port = 0,
            .is_server = is_server,
            .seal_key = if (is_server) s2c else c2s,
            .open_key = if (is_server) c2s else s2c,
            .next_stream_id = if (is_server) 2 else 1,
            .last_received = sys.nowMillis(),
            .last_sent = sys.nowMillis(),
        };
        return self;
    }

    /// Starts the receiver and 20 ms timer, unwinding a partial start safely.
    fn start(self: *Link) !void {
        self.receive_thread = try std.Thread.spawn(.{}, receiveLoop, .{self});
        self.timer_thread = std.Thread.spawn(.{}, timerLoop, .{self}) catch |err| {
            self.close();
            self.receive_thread.?.join();
            self.receive_thread = null;
            return err;
        };
    }

    /// Releases allocations once no worker or application reader can access them.
    fn free(self: *Link) void {
        for (self.streams.items) |slot| if (slot.stream) |stream| stream.free();
        self.streams.deinit(self.gpa);
        self.pending_pongs.deinit(self.gpa);
        self.runtime.deinit();
        const gpa = self.gpa;
        std.crypto.secureZero(u8, &self.seal_key);
        std.crypto.secureZero(u8, &self.open_key);
        gpa.destroy(self);
    }

    /// Finishes under the state mutex; callbacks are dispatched after unlocking.
    fn finish(self: *Link) void {
        if (self.closed) return;
        self.closed = true;
        for (self.streams.items) |slot| {
            if (slot.stream) |stream| stream.ended = true;
        }
        self.changed.broadcast(self.runtime.io());
        _ = c.shutdown(self.fd, c.SHUT_RDWR);
    }

    /// Drops the state lock and invokes the close callback exactly once.
    fn unlockAndNotify(self: *Link) void {
        const notify = self.closed and !self.close_notified;
        if (notify) self.close_notified = true;
        const callback = if (notify) self.on_close else null;
        const ctx = self.on_close_ctx;
        self.mutex.unlock(self.runtime.io());
        if (callback) |call| call(ctx);
    }

    /// Finds a stream or its tombstone in sorted stream-ID order.
    fn findSlot(self: *Link, id: u32) ?*Slot {
        var lo: usize = 0;
        var hi = self.streams.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const slot = &self.streams.items[mid];
            if (slot.id == id) return slot;
            if (slot.id < id) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    /// Admits stream state within the active budget, in scheduling order.
    fn newStream(self: *Link, id: u32) !*Stream {
        if (self.active_streams >= max_active_streams) return error.StreamLimit;
        const stream = try self.gpa.create(Stream);
        errdefer self.gpa.destroy(stream);
        stream.* = .{ .id = id, .link = self };
        var index: usize = 0;
        while (index < self.streams.items.len and self.streams.items[index].id < id) : (index += 1) {}
        try self.streams.insert(self.gpa, index, .{ .id = id, .stream = stream });
        self.active_streams += 1;
        return stream;
    }

    /// Frees released streams after FIN completion and trims old tombstones.
    fn collect(self: *Link) void {
        for (self.streams.items) |*slot| {
            const stream = slot.stream orelse continue;
            if (stream.peer_finished and stream.fin_sent and stream.unacked.items.len == 0 and
                stream.unsent.bytes().len == 0 and stream.released and
                stream.readers == 0 and !slot.ack_pending)
            {
                slot.recv_next = stream.recv_next;
                slot.stream = null;
                stream.free();
                self.active_streams -= 1;
            }
        }
        // Keep recent final ACKs without accumulating one slot per lifetime
        // open. Only peer-initiated IDs affect admission of unknown streams.
        while (self.streams.items.len - self.active_streams > max_tombstones) {
            for (self.streams.items, 0..) |slot, index| {
                if (slot.stream != null) continue;
                if (self.is_server and slot.id % 2 == 1) self.retired_peer_id = @max(self.retired_peer_id, slot.id);
                _ = self.streams.orderedRemove(index);
                break;
            }
        }
    }

    /// Polls a nonblocking UDP socket so shutdown is bounded on unconnected UDP.
    fn receiveLoop(self: *Link) void {
        var packet: [2048]u8 = undefined;
        while (!self.isClosed()) {
            var pollfd = c.struct_pollfd{ .fd = self.fd, .events = c.POLLIN, .revents = 0 };
            const ready = c.poll(&pollfd, 1, 20);
            if (ready < 0 and sys.errno() == c.EINTR) continue;
            if (ready < 0) break;
            if (ready == 0) continue;
            var from: c.struct_sockaddr_storage = std.mem.zeroes(c.struct_sockaddr_storage);
            var length: c.socklen_t = @sizeOf(c.struct_sockaddr_storage);
            const n = c.recvfrom(self.fd, &packet, packet.len, 0, @ptrCast(&from), &length);
            if (n < 0 and (sys.errno() == c.EINTR or sys.errno() == c.EAGAIN)) continue;
            // A zero-byte UDP datagram is not an EOF on a live socket.
            if (n == 0) continue;
            if (n < 0) break;
            self.mutex.lockUncancelable(self.runtime.io());
            self.handle(packet[0..@intCast(n)], from, length);
            self.unlockAndNotify();
        }
        self.mutex.lockUncancelable(self.runtime.io());
        self.finish();
        self.unlockAndNotify();
    }

    /// Runs retransmission, queued sends, keepalive, and idle expiry every 20 ms.
    fn timerLoop(self: *Link) void {
        while (true) {
            sys.sleepMillis(20);
            self.mutex.lockUncancelable(self.runtime.io());
            if (self.closed) {
                self.unlockAndNotify();
                return;
            }
            self.tick();
            self.unlockAndNotify();
        }
    }

    /// Authenticates before updating the replay window, roaming address, or state.
    fn handle(self: *Link, packet: []const u8, from: c.struct_sockaddr_storage, length: c.socklen_t) void {
        if (self.closed or packet.len <= 26 or packet[0] != 'K' or packet[1] != 1) return;
        const number = get(u64, packet, 2);
        if (number <= self.recv_max) {
            const back = self.recv_max - number;
            if (back >= 64 or self.recv_seen & (@as(u64, 1) << @intCast(back)) != 0) return;
        }
        var plain: [2048]u8 = undefined;
        const body = plain[0 .. packet.len - 26];
        Aes.decrypt(body, packet[10 .. packet.len - 16], packet[packet.len - 16 ..][0..16].*, packet[0..10], nonce(number), self.open_key) catch return;
        if (number > self.recv_max) {
            const shift = number - self.recv_max;
            self.recv_seen = if (shift >= 64) 1 else (self.recv_seen << @intCast(shift)) | 1;
            self.recv_max = number;
        } else self.recv_seen |= @as(u64, 1) << @intCast(self.recv_max - number);
        self.peer = from;
        self.peer_len = length;
        self.last_received = sys.nowMillis();
        var i: usize = 0;
        while (i < body.len) {
            const kind = std.enums.fromInt(FrameKind, body[i]) orelse return;
            i += 1;
            switch (kind) {
                .ack => {
                    if (body.len - i < 20) return;
                    self.acknowledged(get(u32, body, i), get(u64, body, i + 4), get(u64, body, i + 12));
                    i += 20;
                },
                .data => {
                    if (body.len - i < 15) return;
                    const id = get(u32, body, i);
                    const offset = get(u64, body, i + 4);
                    const fin = body[i + 12] & 1 != 0;
                    const len = get(u16, body, i + 13);
                    i += 15;
                    if (body.len - i < len) return;
                    self.received(id, offset, body[i..][0..len], fin);
                    if (self.closed) return;
                    i += len;
                },
                .ping => {
                    if (body.len - i < 8) return;
                    // Dropping a pong under memory pressure only costs the peer an RTT sample.
                    self.pending_pongs.append(self.gpa, get(u64, body, i)) catch {};
                    i += 8;
                },
                .pong => {
                    if (body.len - i < 8) return;
                    const elapsed = sys.nowMicros() -% get(u64, body, i);
                    self.sample(@as(f64, @floatFromInt(elapsed)) / 1_000_000);
                    self.pong_generation +%= 1;
                    self.changed.broadcast(self.runtime.io());
                    i += 8;
                },
                .close => {
                    self.finish();
                    return;
                },
            }
        }
        self.pump();
        self.collect();
    }

    /// Queues ACKs and reassembles complete, nonoverlapping segments inside the
    /// receive window. Anything that cannot be stored (outside the window, over
    /// the out-of-order budget, or out of memory) is dropped unacknowledged, so
    /// the peer retransmits it later; allocation failure never closes the link.
    fn received(self: *Link, id: u32, offset: u64, data: []const u8, fin: bool) void {
        const count = std.math.add(u64, @intCast(data.len), @intFromBool(fin)) catch return;
        const end = std.math.add(u64, offset, count) catch return;
        // An empty non-FIN frame is a window probe: it only solicits an ACK.
        const probe = data.len == 0 and !fin;
        var stream: *Stream = undefined;
        if (self.findSlot(id)) |slot| {
            slot.ack_pending = true;
            if (probe) return;
            stream = slot.stream orelse return;
        } else {
            if (probe or !self.is_server or id % 2 != 1 or id <= self.retired_peer_id) return;
            // Validate the initial window before allocating or exposing a
            // stream to callbacks (which may allocate application workers).
            if (end - @intFromBool(fin) > receive_window) return;
            const callback = self.on_stream orelse return;
            stream = self.newStream(id) catch return;
            self.findSlot(id).?.ack_pending = true;
            const ctx = self.on_stream_ctx;
            self.mutex.unlock(self.runtime.io());
            callback(ctx, stream);
            self.mutex.lockUncancelable(self.runtime.io());
            if (self.closed) return;
        }
        if (stream.peer_finished or end <= stream.recv_next or end - @intFromBool(fin) > stream.windowEdge()) return;
        if (offset == stream.recv_next) {
            stream.deliver(data, fin) catch return;
            while (stream.out_of_order.fetchRemove(stream.recv_next)) |entry| {
                defer self.gpa.free(entry.value.data);
                stream.ooo_charge -= entry.value.data.len + out_of_order_overhead;
                stream.deliver(entry.value.data, entry.value.fin) catch return;
            }
        } else if (offset > stream.recv_next) {
            const old = if (stream.out_of_order.get(offset)) |e| e.data.len + out_of_order_overhead else 0;
            const charge = data.len + out_of_order_overhead;
            if (stream.ooo_charge - old + charge > receive_window) return;
            const copy = self.gpa.dupe(u8, data) catch return;
            const entry = stream.out_of_order.getOrPut(self.gpa, offset) catch {
                self.gpa.free(copy);
                return;
            };
            if (entry.found_existing) self.gpa.free(entry.value_ptr.data);
            entry.value_ptr.* = .{ .data = copy, .fin = fin };
            stream.ooo_charge = stream.ooo_charge - old + charge;
        }
    }

    /// Advances cumulative ACKs, samples unretransmitted segments, and fast-resends.
    fn acknowledged(self: *Link, id: u32, cum: u64, window: u64) void {
        const slot = self.findSlot(id) orelse return;
        const stream = slot.stream orelse return;
        // Acknowledging bytes never sent is a protocol violation: ignore it.
        if (cum > stream.send_offset) return;
        // ACKs may be reordered; the peer's window edge never moves backwards.
        stream.peer_window = @max(stream.peer_window, window);
        if (cum > stream.acked_to) {
            stream.acked_to = cum;
            stream.dup_acks = 0;
            var acked: usize = 0;
            while (stream.unacked.items.len > 0 and (stream.unacked.items[0].end() catch return) <= cum) {
                const first = stream.unacked.orderedRemove(0);
                acked += first.data.len;
                self.in_flight -= first.data.len;
                if (first.retransmits == 0) self.sample(@as(f64, @floatFromInt(@as(i64, @intCast(sys.nowMicros())) - first.sent_at)) / 1_000_000);
                self.gpa.free(first.data);
            }
            if (acked > 0) self.cwnd += if (self.cwnd < self.ssthresh) @min(acked, mss) else @max(mss * acked / self.cwnd, 1);
        } else if (cum == stream.acked_to and stream.unacked.items.len > 0) {
            stream.dup_acks +|= 1;
            if (stream.dup_acks == 3) {
                self.resend(stream, 0);
                self.onLoss();
            }
        }
    }

    /// Updates Swift's smoothed RTT and mean deviation estimators, in seconds.
    fn sample(self: *Link, rtt: f64) void {
        if (rtt < 0 or rtt >= 10) return;
        self.rttvar = self.rttvar * 0.75 + @abs(self.srtt - rtt) * 0.25;
        self.srtt = self.srtt * 0.875 + rtt * 0.125;
    }

    /// Halves the congestion window, with a four-MSS floor.
    fn onLoss(self: *Link) void {
        self.ssthresh = @max(self.cwnd / 2, 4 * mss);
        self.cwnd = self.ssthresh;
    }

    /// Packs ACKs/pongs first, then rotates across streams between passes and
    /// calls. A busy older stream must not starve an interactive newer one.
    /// Running out of memory just ends the pass; queued bytes stay queued and
    /// the next tick tries again.
    fn pump(self: *Link) void {
        if (self.closed) return;
        var packet = PacketBuilder{ .link = self };
        defer packet.flush();
        for (self.streams.items) |*slot| {
            if (!slot.ack_pending) continue;
            var next = slot.recv_next;
            var edge = next +| receive_window;
            if (slot.stream) |stream| {
                next = stream.recv_next;
                edge = stream.windowEdge();
                stream.advertised = edge;
            }
            packet.add(&ackFrame(slot.id, next, edge));
            slot.ack_pending = false;
        }
        for (self.pending_pongs.items) |t| packet.add(&pingFrame(.pong, t));
        self.pending_pongs.clearRetainingCapacity();
        var progress = true;
        while (progress and self.in_flight < self.cwnd) {
            progress = false;
            for (0..self.streams.items.len) |_| {
                if (self.in_flight >= self.cwnd) break;
                const index = self.send_cursor % self.streams.items.len;
                self.send_cursor = (index + 1) % self.streams.items.len;
                const slot = self.streams.items[index];
                const stream = slot.stream orelse continue;
                const unsent = stream.unsent.bytes();
                if (unsent.len == 0 and (!stream.fin_queued or stream.fin_sent)) continue;
                // Headers consume packet space, not payload credit in either
                // the congestion window or the peer's receive window.
                if (mss - packet.size <= data_header) packet.flush();
                const room = @min(mss - packet.size - data_header, self.cwnd - self.in_flight, stream.peer_window -| stream.send_offset);
                const take = @min(unsent.len, room);
                const fin = stream.fin_queued and !stream.fin_sent and take == unsent.len;
                if (take == 0 and !fin) continue;
                const data = self.gpa.dupe(u8, unsent[0..take]) catch return;
                const seg = Segment{ .offset = stream.send_offset, .data = data, .fin = fin, .sent_at = @intCast(sys.nowMicros()) };
                const end = seg.end() catch {
                    self.gpa.free(data);
                    self.finish();
                    return;
                };
                stream.unacked.append(self.gpa, seg) catch {
                    self.gpa.free(data);
                    return;
                };
                stream.unsent.consume(self.gpa, take);
                stream.send_offset = end;
                self.in_flight += take;
                if (fin) stream.fin_sent = true;
                var frame: [mss]u8 = undefined;
                packet.add(dataFrame(&frame, stream.id, seg));
                progress = true;
            }
        }
    }

    /// Retransmits timed-out segments, probes closed windows, sends keepalives,
    /// and expires silent peers.
    fn tick(self: *Link) void {
        const now = sys.nowMillis();
        if (now - self.last_received > 60_000) {
            self.finish();
            return;
        }
        const rto = std.math.clamp(self.srtt + 4 * self.rttvar, 0.05, 2);
        const now_micros: i64 = @intCast(sys.nowMicros());
        var lost = false;
        for (self.streams.items) |slot| {
            const stream = slot.stream orelse continue;
            for (stream.unacked.items, 0..) |seg, i| {
                const backoff: u32 = @as(u32, 1) << @intCast(@min(seg.retransmits, 4));
                if (@as(f64, @floatFromInt(now_micros - seg.sent_at)) > rto * 1_000_000 * @as(f64, @floatFromInt(backoff))) {
                    self.resend(stream, i);
                    lost = true;
                }
            }
        }
        if (lost) self.onLoss();
        for (self.streams.items) |slot| {
            const stream = slot.stream orelse continue;
            // A lost window update would otherwise stall the stream forever:
            // nothing is in flight to retransmit and the receiver has nothing
            // to say. An empty data frame makes it ACK with its current window.
            if (stream.unacked.items.len == 0 and stream.unsent.bytes().len > 0 and
                stream.peer_window <= stream.send_offset and now - stream.probe_at >= 500)
            {
                stream.probe_at = now;
                var none: [0]u8 = .{};
                var frame: [data_header]u8 = undefined;
                self.sendPacket(dataFrame(&frame, stream.id, .{ .offset = stream.send_offset, .data = &none, .fin = false, .sent_at = 0 }));
            }
        }
        if (now - self.last_sent > 3000) self.sendPacket(&pingFrame(.ping, sys.nowMicros()));
        self.pump();
        self.collect();
    }

    /// Retransmits an owned segment with a fresh packet number and timestamp.
    fn resend(self: *Link, stream: *Stream, i: usize) void {
        const seg = &stream.unacked.items[i];
        seg.sent_at = @intCast(sys.nowMicros());
        seg.retransmits +|= 1;
        var frame: [mss]u8 = undefined;
        self.sendPacket(dataFrame(&frame, stream.id, seg.*));
    }

    /// Seals a bounded frame payload, dropping simulated losses before numbering.
    fn sendPacket(self: *Link, body: []const u8) void {
        if (self.peer_len == 0) return;
        std.debug.assert(body.len <= mss);
        self.last_sent = sys.nowMillis();
        const source = std.Random.IoSource{ .io = self.runtime.io() };
        if (test_loss > 0 and source.interface().float(f64) < test_loss) return;
        // Never reuse a GCM nonce if a link exhausts its packet-number space.
        if (self.send_number == std.math.maxInt(u64)) {
            self.finish();
            return;
        }
        self.send_number += 1;
        var packet: [mss + 26]u8 = undefined;
        const len = sealPacket(&packet, body, self.send_number, self.seal_key);
        _ = c.sendto(self.fd, &packet, len, 0, @ptrCast(&self.peer), self.peer_len);
    }
};

/// One link-owned byte stream, valid until its owner calls `release` after all
/// application users stop. `close` and EOF preserve the pointer; release lets
/// the link reclaim it once both FINs complete (see the module contract).
pub const Stream = struct {
    id: u32,
    link: *Link,
    unsent: Buffer = .{},
    send_offset: u64 = 0,
    unacked: std.ArrayList(Segment) = .empty,
    acked_to: u64 = 0,
    dup_acks: u32 = 0,
    fin_queued: bool = false,
    fin_sent: bool = false,
    peer_window: u64 = receive_window,
    probe_at: i64 = 0,
    recv_next: u64 = 0,
    /// Window edge last sent to the peer; lags `windowEdge` until the reader
    /// has consumed enough to be worth an update.
    advertised: u64 = receive_window,
    out_of_order: std.AutoHashMapUnmanaged(u64, Received) = .empty,
    ooo_charge: usize = 0,
    peer_finished: bool = false,
    incoming: Buffer = .{},
    ended: bool = false,
    local_closed: bool = false,
    released: bool = false,
    readers: usize = 0,

    /// Adapts this stream to the core's queued-send/blocking-read transport.
    pub fn transport(self: *Stream) Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Copies and pumps under the link mutex without waiting for network credit.
    /// Embedders must keep this work off their UI input thread. If the queue
    /// would pass `max_unsent` (the peer is not
    /// keeping up), exhaust sequence space (reserving one FIN byte), or cannot
    /// grow, the stream is reset instead: queued unsent bytes are dropped,
    /// a FIN follows what is already in flight, and this and
    /// later sends are ignored. The peer sees EOF, `read` here returns 0, and
    /// the owner still must `release` as usual.
    pub fn send(self: *Stream, bytes: []const u8) void {
        const link = self.link;
        link.mutex.lockUncancelable(link.runtime.io());
        if (!link.closed and !self.fin_queued) {
            if (bytes.len > max_unsent - self.unsent.bytes().len or
                bytes.len > (std.math.maxInt(u64) -| self.send_offset -| 1) -| self.unsent.bytes().len)
            {
                self.reset();
            } else self.unsent.append(link.gpa, bytes) catch self.reset();
        }
        // Sent now, not on the next tick: a keystroke must not wait 20 ms.
        link.pump();
        link.unlockAndNotify();
    }

    /// Blocks until bytes or EOF, draining queued bytes before returning zero.
    /// Consuming data may reopen the peer's send window.
    pub fn read(self: *Stream, buf: []u8) usize {
        const link = self.link;
        link.mutex.lockUncancelable(link.runtime.io());
        defer link.mutex.unlock(link.runtime.io());
        if (buf.len == 0) return 0;
        self.readers += 1;
        defer self.readers -= 1;
        while (self.incoming.bytes().len == 0 and !self.ended) link.changed.waitUncancelable(link.runtime.io(), &link.mutex);
        const bytes = self.incoming.bytes();
        const n = @min(buf.len, bytes.len);
        @memcpy(buf[0..n], bytes[0..n]);
        self.incoming.consume(link.gpa, n);
        if (n > 0 and !link.closed and self.windowEdge() - self.advertised >= receive_window / 4) {
            if (link.findSlot(self.id)) |slot| slot.ack_pending = true;
            link.pump();
        }
        return n;
    }

    /// Queues one FIN after pending data and ends local reads: unread bytes are
    /// discarded and blocked readers return 0. Idempotent; the stream stays
    /// valid until `release`.
    pub fn close(self: *Stream) void {
        const link = self.link;
        link.mutex.lockUncancelable(link.runtime.io());
        self.shutdown();
        link.pump();
        link.unlockAndNotify();
    }

    /// Gives the stream back to the link: closes it, and the link frees it as
    /// soon as its FIN exchange completes (or at `destroy`). Call exactly once,
    /// after all application users have stopped; never use the pointer again.
    pub fn release(self: *Stream) void {
        const link = self.link;
        link.mutex.lockUncancelable(link.runtime.io());
        self.shutdown();
        self.released = true;
        link.pump();
        link.collect();
        link.unlockAndNotify();
    }

    /// Link mutex held.
    fn shutdown(self: *Stream) void {
        self.local_closed = true;
        self.fin_queued = true;
        self.ended = true;
        self.incoming.deinit(self.link.gpa);
        self.incoming = .{};
        self.link.changed.broadcast(self.link.runtime.io());
    }

    /// Drops the unsent backlog and queues the FIN. Not `close`: the owner may
    /// still read and must still release. Link mutex held.
    fn reset(self: *Stream) void {
        self.unsent.deinit(self.link.gpa);
        self.unsent = .{};
        self.fin_queued = true;
        self.ended = true;
        self.link.changed.broadcast(self.link.runtime.io());
    }

    /// Absolute sequence position up to which the peer may send: the window
    /// counts only bytes the application has not read yet. Never decreases;
    /// saturates at the final representable position rather than wrapping.
    fn windowEdge(self: *const Stream) u64 {
        return (self.recv_next - self.incoming.bytes().len) +| receive_window;
    }

    const vtable = Transport.VTable{ .send = sendImpl, .read = readImpl, .close = closeImpl };

    /// Dispatches Transport.send to the stream's owned send queue.
    fn sendImpl(ptr: *anyopaque, bytes: []const u8) void {
        const self: *Stream = @ptrCast(@alignCast(ptr));
        self.send(bytes);
    }

    /// Dispatches Transport.read to the stream's blocking reader.
    fn readImpl(ptr: *anyopaque, buf: []u8) usize {
        const self: *Stream = @ptrCast(@alignCast(ptr));
        return self.read(buf);
    }

    /// Dispatches Transport.close to the stream's FIN queue.
    fn closeImpl(ptr: *anyopaque) void {
        const self: *Stream = @ptrCast(@alignCast(ptr));
        self.close();
    }

    /// Delivers a contiguous segment under the link lock; FIN uses one byte.
    /// Bytes arriving after a local close are acknowledged but not kept.
    /// Fails only on allocation, leaving the stream unchanged.
    fn deliver(self: *Stream, data: []const u8, fin: bool) !void {
        if (!self.local_closed) try self.incoming.append(self.link.gpa, data);
        self.recv_next += data.len;
        if (fin) {
            self.recv_next += 1;
            self.peer_finished = true;
            self.ended = true;
            self.clearOutOfOrder();
        }
        self.link.changed.broadcast(self.link.runtime.io());
    }

    /// Releases segments that can no longer be delivered beyond a received FIN.
    fn clearOutOfOrder(self: *Stream) void {
        var it = self.out_of_order.valueIterator();
        while (it.next()) |value| self.link.gpa.free(value.data);
        self.out_of_order.clearRetainingCapacity();
        self.ooo_charge = 0;
    }

    /// Releases all owned buffers once link and application lifetimes permit it.
    fn free(self: *Stream) void {
        const gpa = self.link.gpa;
        self.unsent.deinit(gpa);
        self.incoming.deinit(gpa);
        for (self.unacked.items) |seg| gpa.free(seg.data);
        self.unacked.deinit(gpa);
        self.clearOutOfOrder();
        self.out_of_order.deinit(gpa);
        gpa.destroy(self);
    }
};

/// A stack packet accumulator enforcing the frame-payload MSS on every flush.
const PacketBuilder = struct {
    link: *Link,
    body: [mss]u8 = undefined,
    size: usize = 0,

    /// Adds a whole frame, flushing earlier frames if necessary.
    fn add(self: *PacketBuilder, frame: []const u8) void {
        if (self.size + frame.len > mss) self.flush();
        @memcpy(self.body[self.size..][0..frame.len], frame);
        self.size += frame.len;
    }

    /// Sends the accumulated frames, leaving an empty packet.
    fn flush(self: *PacketBuilder) void {
        if (self.size == 0) return;
        self.link.sendPacket(self.body[0..self.size]);
        self.size = 0;
    }
};

/// Creates a nonblocking, close-on-exec libc UDP descriptor.
fn socket(family: c_int) !c_int {
    const fd = c.socket(family, c.SOCK_DGRAM, 0);
    if (fd < 0) return error.Socket;
    errdefer _ = c.close(fd);
    if (c.fcntl(fd, c.F_SETFD, @as(c_int, c.FD_CLOEXEC)) != 0) return error.Socket;
    const flags = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
    if (flags < 0 or c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) != 0) return error.Socket;
    return fd;
}

/// GCM nonce: four zero bytes followed by the big-endian packet number.
fn nonce(number: u64) [12]u8 {
    var out: [12]u8 = @splat(0);
    std.mem.writeInt(u64, out[4..12], number, .big);
    return out;
}

/// Writes the authenticated 10-byte header, ciphertext, and trailing GCM tag.
fn sealPacket(out: []u8, body: []const u8, number: u64, key: [32]u8) usize {
    out[0] = 'K';
    out[1] = 1;
    std.mem.writeInt(u64, out[2..10], number, .little);
    const tag = out[10 + body.len ..][0..16];
    Aes.encrypt(out[10..][0..body.len], tag, body, out[0..10], nonce(number), key);
    return body.len + 26;
}

/// Reads an integer from a previously bounds-checked frame field.
fn get(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}

/// Encodes the cumulative receive position and absolute receive-window edge.
fn ackFrame(id: u32, cum: u64, window: u64) [21]u8 {
    var out: [21]u8 = undefined;
    out[0] = @backingInt(FrameKind.ack);
    std.mem.writeInt(u32, out[1..5], id, .little);
    std.mem.writeInt(u64, out[5..13], cum, .little);
    std.mem.writeInt(u64, out[13..21], window, .little);
    return out;
}

/// Encodes a segment with its stream ID, offset, FIN flag, and u16 length.
fn dataFrame(out: []u8, id: u32, seg: Segment) []const u8 {
    out[0] = @backingInt(FrameKind.data);
    std.mem.writeInt(u32, out[1..5], id, .little);
    std.mem.writeInt(u64, out[5..13], seg.offset, .little);
    out[13] = @intFromBool(seg.fin);
    std.mem.writeInt(u16, out[14..16], @intCast(seg.data.len), .little);
    @memcpy(out[16..][0..seg.data.len], seg.data);
    return out[0 .. data_header + seg.data.len];
}

/// Encodes a timestamp ping or its verbatim echoed pong.
fn pingFrame(kind: FrameKind, micros: u64) [9]u8 {
    var out: [9]u8 = undefined;
    out[0] = @backingInt(kind);
    std.mem.writeInt(u64, out[1..9], micros, .little);
    return out;
}

/// Test server workers are joined before their link-owned streams are destroyed.
const TestEcho = struct {
    threads: [3]?std.Thread = @splat(null),
    count: usize = 0,
    failed: std.atomic.Value(bool) = .init(false),

    /// Starts one blocking echo reader for each remotely opened stream.
    fn opened(ctx: ?*anyopaque, stream: *Stream) void {
        const self: *TestEcho = @ptrCast(@alignCast(ctx.?));
        if (self.count == self.threads.len) {
            self.failed.store(true, .release);
            stream.release();
            return;
        }
        self.threads[self.count] = std.Thread.spawn(.{}, echo, .{stream}) catch {
            self.failed.store(true, .release);
            stream.release();
            return;
        };
        self.count += 1;
    }

    /// Echoes bytes through Transport and closes its sending half after peer FIN.
    fn echo(stream: *Stream) void {
        const transport = stream.transport();
        var buf: [8192]u8 = undefined;
        while (true) {
            const n = transport.read(&buf);
            if (n == 0) break;
            transport.send(buf[0..n]);
        }
        transport.close();
        stream.release();
    }

    /// Joins workers after the receive thread has stopped invoking opened.
    fn join(self: *TestEcho) void {
        for (self.threads) |thread| if (thread) |t| t.join();
    }
};

/// Caps the lossy integration test even if reliability or FIN handling regresses.
const TestDeadline = struct {
    client: *Link,
    server: *Link,
    done: std.atomic.Value(bool) = .init(false),
    expired: std.atomic.Value(bool) = .init(false),

    /// Closes both links after 22 seconds to wake every blocked test reader.
    fn run(self: *TestDeadline) void {
        const deadline = sys.nowMillis() + 22_000;
        while (!self.done.load(.acquire)) {
            if (sys.nowMillis() >= deadline) {
                self.expired.store(true, .release);
                self.client.close();
                self.server.close();
                return;
            }
            sys.sleepMillis(10);
        }
    }
};

/// A distinct reproducible byte pattern for every stream, frame, and position.
fn testByte(stream: usize, frame: usize, index: usize) u8 {
    return @truncate(stream * 73 + frame * 29 + index * 17 + index / 251);
}

test "packet encoding matches Swift CryptoKit including every frame kind" {
    const gpa = std.testing.allocator;
    var secret: [32]u8 = undefined;
    for (&secret, 0..) |*byte, i| byte.* = @intCast(i);
    const client = try Link.create(gpa, -1, secret, false);
    defer client.free();
    const server = try Link.create(gpa, -1, secret, true);
    defer server.free();
    var data = [_]u8{ 'k', 'o', 'i' };
    var data_frame: [19]u8 = undefined;
    var body: [59]u8 = undefined;
    var size: usize = 0;
    for ([_][]const u8{
        &ackFrame(1, 4, 4 + receive_window),
        dataFrame(&data_frame, 1, .{ .offset = 0, .data = &data, .fin = true, .sent_at = 0 }),
        &pingFrame(.ping, 123456789),
        &pingFrame(.pong, 123456789),
        &.{@backingInt(FrameKind.close)},
    }) |frame| {
        @memcpy(body[size..][0..frame.len], frame);
        size += frame.len;
    }
    // Generated independently with Swift's HKDF<SHA256> and AES.GCM, using
    // secret bytes 0...31, packet 0x0102030405060708, and the frames above.
    const vectors = [_]struct { hex: []const u8, sender: *Link, receiver: *Link }{
        .{
            .hex = "4b01080706050403020163bd7bc2ab0c66f23489e2f7539efdf6415ba3e0d46bdd6030fcb5cf8a354571b882b39ece56a08b42b8768e184ce3fa1b7ab49bfe9684a74abc5de15e1f73e7707c42358d7a67aa8f2dbb",
            .sender = client,
            .receiver = server,
        },
        .{
            .hex = "4b010807060504030201c244e6741f8770f9678683fd6fa4b896787938281547406309f103c12c323728a4b05bf459832c0ee9abc2c52576d4632ba30659bd0a343fcb92009d4db4404535215b17f32f9878a964f7",
            .sender = server,
            .receiver = client,
        },
    };
    for (vectors) |vector| {
        var expected: [85]u8 = undefined;
        _ = try std.fmt.hexToBytes(&expected, vector.hex);
        var packet: [85]u8 = undefined;
        try std.testing.expectEqual(packet.len, sealPacket(&packet, &body, 0x0102030405060708, vector.sender.seal_key));
        try std.testing.expectEqualSlices(u8, &expected, &packet);
        var plain: [59]u8 = undefined;
        try Aes.decrypt(&plain, packet[10..69], packet[69..85].*, packet[0..10], nonce(0x0102030405060708), vector.receiver.open_key);
        try std.testing.expectEqualSlices(u8, &body, &plain);
    }
}

test "only authenticated unreplayed packets roam within a 64-number window" {
    const gpa = std.testing.allocator;
    const server = try Link.create(gpa, -1, @splat(0x31), true);
    defer server.free();
    var a = std.mem.zeroes(c.struct_sockaddr_storage);
    a.ss_family = c.AF_INET6;
    var b = a;
    std.mem.asBytes(&b)[@sizeOf(c.struct_sockaddr_storage) - 1] = 1;
    const addr_len = @sizeOf(c.struct_sockaddr_storage);
    const body = ackFrame(1, 0, receive_window);
    var packet: [47]u8 = undefined;
    _ = sealPacket(&packet, &body, 100, server.open_key);
    packet[packet.len - 1] ^= 1;
    server.handle(&packet, a, addr_len);
    try std.testing.expectEqual(@as(c.socklen_t, 0), server.peer_len);
    try std.testing.expectEqual(@as(u64, 0), server.recv_seen);
    packet[packet.len - 1] ^= 1;
    server.handle(&packet, a, addr_len);
    server.handle(&packet, b, addr_len); // Replay cannot move the peer.
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&a), std.mem.asBytes(&server.peer));
    _ = sealPacket(&packet, &body, 101, server.seal_key); // Wrong direction.
    server.handle(&packet, b, addr_len);
    try std.testing.expectEqual(@as(u64, 100), server.recv_max);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&a), std.mem.asBytes(&server.peer));
    _ = sealPacket(&packet, &body, 101, server.open_key);
    server.handle(&packet, b, addr_len);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&b), std.mem.asBytes(&server.peer));
    _ = sealPacket(&packet, &body, 38, server.open_key); // 63 behind: accepted once.
    server.handle(&packet, a, addr_len);
    server.handle(&packet, b, addr_len);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&a), std.mem.asBytes(&server.peer));
    _ = sealPacket(&packet, &body, 37, server.open_key); // 64 behind: too old.
    server.handle(&packet, b, addr_len);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&a), std.mem.asBytes(&server.peer));
    _ = sealPacket(&packet, &body, 200, server.open_key); // Discards the old bitmap.
    server.handle(&packet, b, addr_len);
    try std.testing.expectEqual(@as(u64, 1), server.recv_seen);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&b), std.mem.asBytes(&server.peer));
}

test "UDP streams echo wire frames in order through 15 percent packet loss" {
    const wire = @import("wire.zig");
    const gpa = std.testing.allocator;
    test_loss = 0.15;
    defer test_loss = 0;
    const secret: [32]u8 = @splat(0x37);
    var echo = TestEcho{};
    const server = try Link.listen(gpa, secret);
    defer {
        server.close();
        // Callbacks run on the receiver, which must stop before we inspect
        // its thread list. Application echo workers must stop before destroy.
        if (server.receive_thread) |thread| {
            thread.join();
            server.receive_thread = null;
        }
        echo.join();
        server.destroy();
    }
    server.on_stream = TestEcho.opened;
    server.on_stream_ctx = &echo;
    const client = try Link.connect(gpa, "127.0.0.1", server.port, secret);
    defer client.destroy();
    var deadline = TestDeadline{ .client = client, .server = server };
    const watchdog = try std.Thread.spawn(.{}, TestDeadline.run, .{&deadline});
    defer {
        deadline.done.store(true, .release);
        watchdog.join();
    }
    const sizes = [_]usize{ 1, 7, 1000, 1149, 1150, 1151, 5000, 70000, 300000, 3 };
    var streams: [3]*Stream = undefined;
    for (&streams, 0..) |*stream, index| {
        stream.* = try client.open();
        try std.testing.expectEqual(@as(u32, @intCast(1 + index * 2)), stream.*.id);
    }
    for (sizes, 0..) |size, frame_index| {
        const payload = try gpa.alloc(u8, size);
        defer gpa.free(payload);
        for (streams, 0..) |stream, stream_index| {
            for (payload, 0..) |*byte, index| byte.* = testByte(stream_index, frame_index, index);
            const frame = try wire.frame(gpa, .output, payload);
            defer gpa.free(frame);
            stream.transport().send(frame);
        }
    }
    for (streams, 0..) |stream, stream_index| {
        var reader = wire.FrameReader.init(gpa);
        defer reader.deinit();
        var buf: [4093]u8 = undefined;
        var got: usize = 0;
        while (got < sizes.len) {
            const n = stream.transport().read(&buf);
            try std.testing.expect(n > 0);
            try reader.append(buf[0..n]);
            while (try reader.next()) |frame| {
                try std.testing.expect(got < sizes.len);
                try std.testing.expectEqual(wire.Kind.output, frame.kind);
                try std.testing.expectEqual(sizes[got], frame.payload.len);
                for (frame.payload, 0..) |byte, index| try std.testing.expectEqual(testByte(stream_index, got, index), byte);
                got += 1;
            }
        }
        stream.transport().close();
        try std.testing.expectEqual(@as(usize, 0), stream.transport().read(&buf));
        stream.release();
    }
    // Wait for remote FINs and their ACKs as well as local close's immediate EOF.
    while (true) {
        client.mutex.lockUncancelable(client.runtime.io());
        var finished = true;
        for (client.streams.items) |slot| if (slot.stream != null) {
            finished = false;
        };
        client.mutex.unlock(client.runtime.io());
        if (finished or deadline.expired.load(.acquire)) break;
        sys.sleepMillis(10);
    }
    try std.testing.expect(!deadline.expired.load(.acquire));
    try std.testing.expect(!echo.failed.load(.acquire));
}

test "UDP connect with a wrong secret is unreachable" {
    const gpa = std.testing.allocator;
    defer test_loss = 0;
    const server = try Link.listen(gpa, @splat(0x11));
    defer server.destroy();
    try std.testing.expectError(error.Unreachable, Link.connect(gpa, "127.0.0.1", server.port, @splat(0x22)));
    try std.testing.expectEqual(@as(c.socklen_t, 0), server.peer_len);
}

/// A link with no socket: packets are dropped, so unacknowledged state stays put.
fn testLink(gpa: Allocator, is_server: bool) !*Link {
    return Link.create(gpa, -1, @splat(0x5a), is_server);
}

/// Feeds data to a stream as the receiver thread would.
fn testReceive(link: *Link, id: u32, offset: u64, data: []const u8, fin: bool) void {
    link.mutex.lockUncancelable(link.runtime.io());
    defer link.mutex.unlock(link.runtime.io());
    link.received(id, offset, data, fin);
}

fn testAccept(_: ?*anyopaque, _: *Stream) void {}

test "appending to a large link backlog amortizes compaction" {
    const gpa = std.testing.allocator;
    var buffer: Buffer = .{};
    defer buffer.deinit(gpa);
    const data = try gpa.alloc(u8, 1024 * 1024);
    defer gpa.free(data);
    @memset(data, 'x');
    try buffer.append(gpa, data);
    buffer.consume(gpa, 128 * 1024);
    try buffer.append(gpa, "y");
    try std.testing.expectEqual(@as(usize, 128 * 1024), buffer.start);
    try std.testing.expectEqual(@as(u8, 'y'), buffer.bytes()[buffer.bytes().len - 1]);
    buffer.consume(gpa, 512 * 1024);
    try buffer.append(gpa, "z");
    try std.testing.expectEqual(@as(usize, 0), buffer.start);
    try std.testing.expectEqualStrings("yz", buffer.bytes()[buffer.bytes().len - 2 ..]);
}

test "a busy older stream cannot consume every reopened byte of congestion credit" {
    const link = try testLink(std.testing.allocator, false);
    defer link.free();
    const bulk = try link.open();
    const interactive = try link.open();
    link.cwnd = 1;
    bulk.send("bulk output keeps arriving");
    interactive.send("key");
    try std.testing.expectEqual(@as(u64, 0), interactive.send_offset);
    link.acknowledged(bulk.id, bulk.send_offset, receive_window);
    link.cwnd = 1;
    link.pump();
    try std.testing.expectEqual(@as(u64, 1), interactive.send_offset);
    try std.testing.expectEqual(@as(u64, 1), bulk.send_offset);
}

test "a snapshot-size burst is accepted and a slow backlog past max_unsent resets the stream" {
    const link = try testLink(std.testing.allocator, false);
    defer link.free();
    const stream = try link.open();
    const chunk = try std.testing.allocator.alloc(u8, 1 << 20);
    defer std.testing.allocator.free(chunk);
    @memset(chunk, 'x');
    for (0..32) |_| stream.send(chunk); // The largest Koi scrollback snapshot.
    try std.testing.expect(!stream.fin_queued);
    try std.testing.expect(stream.unsent.bytes().len > 31 << 20);
    // Never-touched pages: only the length matters to the reset path.
    const big = try std.heap.page_allocator.alloc(u8, 33 << 20);
    defer std.heap.page_allocator.free(big);
    stream.send(big);
    try std.testing.expect(stream.fin_queued);
    try std.testing.expectEqual(@as(usize, 0), stream.unsent.bytes().len);
    stream.send(chunk); // Ignored, not buffered.
    try std.testing.expectEqual(@as(usize, 0), stream.unsent.bytes().len);
    var buf: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), stream.read(&buf)); // Owner sees EOF at once.
    try std.testing.expect(!stream.local_closed); // Still the owner's to close and release.
}

test "unread data closes the receive window and reading reopens and advertises it" {
    const link = try testLink(std.testing.allocator, true);
    defer link.free();
    link.on_stream = testAccept;
    const chunk = try std.testing.allocator.alloc(u8, 1 << 20);
    defer std.testing.allocator.free(chunk);
    @memset(chunk, 'y');
    for (0..receive_window / chunk.len) |i| testReceive(link, 1, i * chunk.len, chunk, false);
    const stream = link.findSlot(1).?.stream.?;
    try std.testing.expectEqual(@as(usize, receive_window), stream.incoming.bytes().len);
    testReceive(link, 1, receive_window, "z", false); // Past the window: dropped.
    testReceive(link, 1, receive_window + 5, "z", false); // Not parked out of order either.
    try std.testing.expectEqual(@as(usize, receive_window), stream.incoming.bytes().len);
    try std.testing.expectEqual(@as(usize, 0), stream.out_of_order.count());

    const buf = try std.testing.allocator.alloc(u8, 2 << 20);
    defer std.testing.allocator.free(buf);
    try std.testing.expectEqual(buf.len, stream.read(buf));
    try std.testing.expectEqual(@as(u64, receive_window + buf.len), stream.advertised);
    testReceive(link, 1, receive_window, "z", false);
    try std.testing.expectEqual(@as(u64, receive_window + 1), stream.recv_next);
}

test "16 bytes of payload credit drain then a lost window update probes and resumes" {
    const sender = try testLink(std.testing.allocator, false);
    defer sender.free();
    const receiver = try testLink(std.testing.allocator, true);
    defer receiver.free();
    receiver.on_stream = testAccept;
    const stream = try sender.open();
    // Model a fully ACKed prefix with exactly the old header-sized credit
    // left. No packet is outstanding to rescue a lost window advertisement.
    stream.send_offset = receive_window - data_header;
    stream.acked_to = stream.send_offset;
    sender.cwnd = data_header; // Congestion credit also counts only payload.
    stream.send("0123456789abcdefmore");
    try std.testing.expectEqual(@as(u64, receive_window), stream.send_offset);
    try std.testing.expectEqual(@as(usize, data_header), sender.in_flight);
    sender.acknowledged(stream.id, stream.send_offset, receive_window);
    try std.testing.expectEqual(@as(usize, 0), stream.unacked.items.len);
    try std.testing.expectEqualStrings("more", stream.unsent.bytes());

    testReceive(receiver, stream.id, 0, "read", false);
    const remote = receiver.findSlot(stream.id).?.stream.?;
    remote.recv_next = receive_window; // The same already delivered prefix.
    var buf: [4]u8 = undefined;
    try std.testing.expectEqual(buf.len, remote.read(&buf));
    receiver.pump(); // This reopening update is deliberately never delivered.
    try std.testing.expectEqual(@as(u64, 2 * receive_window), remote.advertised);
    sender.tick();
    try std.testing.expect(stream.probe_at > 0);
    const first_probe = stream.probe_at;
    sender.tick();
    try std.testing.expectEqual(first_probe, stream.probe_at); // Rate limited.

    testReceive(receiver, stream.id, stream.send_offset, "", false);
    try std.testing.expect(receiver.findSlot(stream.id).?.ack_pending);
    receiver.pump();
    sender.acknowledged(stream.id, remote.recv_next, remote.advertised);
    sender.pump();
    try std.testing.expectEqual(@as(u64, receive_window + 4), stream.send_offset);
    try std.testing.expectEqual(@as(usize, 0), stream.unsent.bytes().len);
    try std.testing.expectEqualStrings("more", stream.unacked.items[0].data);
}

test "out-of-order segments are charged against the receive window" {
    const link = try testLink(std.testing.allocator, true);
    defer link.free();
    link.on_stream = testAccept;
    testReceive(link, 1, 0, "a", false);
    const stream = link.findSlot(1).?.stream.?;
    // One-byte segments with gaps: only the overhead charge limits them.
    var offset: u64 = 2;
    while (offset < receive_window) : (offset += 2) testReceive(link, 1, offset, "b", false);
    try std.testing.expect(stream.ooo_charge <= receive_window);
    try std.testing.expect(stream.out_of_order.count() <= receive_window / out_of_order_overhead);
    const kept = stream.out_of_order.count();
    testReceive(link, 1, 1, "c", false); // Filling the gap drains the adjacent segment.
    try std.testing.expectEqual(@as(u64, 3), stream.recv_next);
    try std.testing.expectEqual(kept - 1, stream.out_of_order.count());
    try std.testing.expectEqual(kept - 1, stream.ooo_charge / (1 + out_of_order_overhead));
}

/// Completes both FINs using positions captured before the owner releases.
fn testFinish(link: *Link, id: u32, recv_next: u64, send_end: u64) void {
    testReceive(link, id, recv_next, "", true);
    link.mutex.lockUncancelable(link.runtime.io());
    defer link.mutex.unlock(link.runtime.io());
    link.acknowledged(id, send_end, receive_window);
    link.findSlot(id).?.ack_pending = false;
}

fn testFreed(link: *Link, id: u32) bool {
    link.mutex.lockUncancelable(link.runtime.io());
    defer link.mutex.unlock(link.runtime.io());
    return link.findSlot(id).?.stream == null;
}

test "close wakes a blocked reader; only release lets the link free the stream" {
    const link = try testLink(std.testing.allocator, true);
    defer link.free();
    const stream = try link.open();
    const id = stream.id;
    const Reader = struct {
        fn run(s: *Stream, got: *std.atomic.Value(usize)) void {
            var buf: [8]u8 = undefined;
            got.store(s.read(&buf), .release);
        }
    };
    var got = std.atomic.Value(usize).init(99);
    const thread = try std.Thread.spawn(.{}, Reader.run, .{ stream, &got });
    var waited: usize = 0;
    while (waited < 2000) : (waited += 1) {
        link.mutex.lockUncancelable(link.runtime.io());
        const waiting = stream.readers == 1;
        link.mutex.unlock(link.runtime.io());
        if (waiting) break;
        sys.sleepMillis(1);
    }
    stream.close();
    thread.join();
    try std.testing.expectEqual(@as(usize, 0), got.load(.acquire));
    testFinish(link, id, stream.recv_next, stream.send_offset);
    link.mutex.lockUncancelable(link.runtime.io());
    link.collect();
    link.mutex.unlock(link.runtime.io());
    try std.testing.expect(!testFreed(link, id)); // Closed and at EOF, but not released.
    stream.close(); // Idempotent, and still valid.
    var buf: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), stream.read(&buf));
    try std.testing.expect(!testFreed(link, id));
    stream.release();
    try std.testing.expect(testFreed(link, id));
}

test "release frees a never-read stream once its FINs complete, and not before" {
    const link = try testLink(std.testing.allocator, true);
    defer link.free();
    link.on_stream = testAccept;
    testReceive(link, 1, 0, "unread", false);
    const stream = link.findSlot(1).?.stream.?;
    const id = stream.id;
    const recv_next = stream.recv_next;
    const send_end = stream.send_offset + 1; // release queues our FIN.
    stream.release(); // Our FIN is queued; the peer's is still missing.
    try std.testing.expect(!testFreed(link, id));
    testFinish(link, id, recv_next, send_end);
    link.mutex.lockUncancelable(link.runtime.io());
    link.collect();
    link.mutex.unlock(link.runtime.io());
    try std.testing.expect(testFreed(link, id));
}

test "invalid first DATA cannot allocate a stream or invoke its callback" {
    var allocations = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const link = try testLink(allocations.allocator(), true);
    defer link.free();
    const Callback = struct {
        fn opened(ctx: ?*anyopaque, _: *Stream) void {
            const count: *usize = @ptrCast(@alignCast(ctx.?));
            count.* += 1;
        }
    };
    var callbacks: usize = 0;
    link.on_stream = Callback.opened;
    link.on_stream_ctx = &callbacks;
    const before = allocations.alloc_index;
    for (0..100) |i| {
        const id: u32 = @intCast(2 * i + 1);
        testReceive(link, id, std.math.maxInt(u64), "x", false);
        testReceive(link, id, std.math.maxInt(u64), "", true);
        testReceive(link, id, std.math.maxInt(u64) - 1, "", true);
        testReceive(link, id, receive_window - 1, "xy", false);
        testReceive(link, id, receive_window + 1, "", true);
    }
    try std.testing.expectEqual(before, allocations.alloc_index);
    try std.testing.expectEqual(@as(usize, 0), callbacks);
    try std.testing.expectEqual(@as(usize, 0), link.streams.items.len);
    testReceive(link, 1, 0, "valid", false);
    try std.testing.expectEqual(@as(usize, 1), callbacks);
}

test "hostile offsets and ACKs are rejected without corrupting existing stream state" {
    const link = try testLink(std.testing.allocator, true);
    defer link.free();
    link.on_stream = testAccept;
    testReceive(link, 1, 0, "a", false);
    testReceive(link, 1, std.math.maxInt(u64), "x", false); // Offset + length overflows.
    testReceive(link, 1, std.math.maxInt(u64) - 1, "", true);
    testReceive(link, 1, receive_window - 1, "xy", false); // Straddles the window edge.
    const stream = link.findSlot(1).?.stream.?;
    try std.testing.expectEqual(@as(u64, 1), stream.recv_next);
    try std.testing.expectEqual(@as(usize, 0), stream.out_of_order.count());

    const own = try link.open();
    own.send("abc");
    link.mutex.lockUncancelable(link.runtime.io());
    defer link.mutex.unlock(link.runtime.io());
    link.acknowledged(own.id, own.send_offset + 1, receive_window); // Acks unsent bytes.
    try std.testing.expectEqual(@as(u64, 0), own.acked_to);
    try std.testing.expectEqual(@as(usize, 1), own.unacked.items.len);
    link.acknowledged(own.id, 0, 10 * receive_window);
    link.acknowledged(own.id, 0, 5); // Reordered, older window.
    try std.testing.expectEqual(@as(u64, 10 * receive_window), own.peer_window);
}

test "active stream budget drops excess opens and recovers after release" {
    const link = try testLink(std.testing.allocator, true);
    defer link.free();
    link.on_stream = testAccept;
    for (0..max_active_streams) |i| testReceive(link, @intCast(2 * i + 1), 0, "", true);
    const next_id = 2 * max_active_streams + 1;
    testReceive(link, next_id, 0, "", true);
    try std.testing.expect(link.findSlot(next_id) == null);
    try std.testing.expectError(error.StreamLimit, link.open());
    try std.testing.expectEqual(@as(usize, max_active_streams), link.active_streams);

    link.findSlot(1).?.stream.?.release();
    link.acknowledged(1, 1, receive_window);
    link.collect();
    try std.testing.expectEqual(@as(usize, max_active_streams - 1), link.active_streams);
    testReceive(link, next_id, 0, "", true);
    try std.testing.expect(link.findSlot(next_id).?.stream != null);
    try std.testing.expectEqual(@as(usize, max_active_streams), link.active_streams);
}

test "tombstones stay bounded without retiring persistent streams or reopening old IDs" {
    const link = try testLink(std.testing.allocator, true);
    defer link.free();
    link.on_stream = testAccept;
    testReceive(link, 1, 0, "persistent", false);
    const persistent = link.findSlot(1).?.stream.?;
    var last_id: u32 = 0;
    for (0..max_tombstones + 4) |i| {
        const id: u32 = @intCast(2 * i + 3);
        testReceive(link, id, 0, "", true);
        link.findSlot(id).?.stream.?.release();
        link.acknowledged(id, 1, receive_window);
        link.collect();
        last_id = id;
    }
    try std.testing.expectEqual(@as(usize, max_tombstones + 1), link.streams.items.len);
    try std.testing.expectEqual(@as(usize, 1), link.active_streams);
    try std.testing.expect(link.retired_peer_id >= 3);
    testReceive(link, 3, 0, "replay", false);
    try std.testing.expect(link.findSlot(3) == null);
    testReceive(link, last_id, 0, "", true);
    try std.testing.expect(link.findSlot(last_id).?.ack_pending);
    try std.testing.expect(link.findSlot(last_id).?.stream == null);
    testReceive(link, 1, persistent.recv_next, " still alive", false);
    try std.testing.expectEqualStrings("persistent still alive", persistent.incoming.bytes());
    testReceive(link, last_id + 2, 0, "new", false);
    try std.testing.expectEqual(@as(usize, 2), link.active_streams);
}

test "sequence exhaustion reserves FIN and saturates the receive window" {
    const link = try testLink(std.testing.allocator, true);
    defer link.free();
    const limit = std.math.maxInt(u64);
    const stream = try link.open();
    stream.send_offset = limit - 3;
    stream.acked_to = stream.send_offset;
    stream.peer_window = limit;
    stream.send("xy");
    stream.close();
    try std.testing.expectEqual(limit, stream.send_offset);
    link.acknowledged(stream.id, limit, limit);
    try std.testing.expectEqual(@as(usize, 0), stream.unacked.items.len);

    const exhausted = try link.open();
    exhausted.send_offset = limit - 1;
    exhausted.peer_window = limit;
    exhausted.send("x"); // No room for both data and FIN: reset, preserving FIN.
    try std.testing.expect(exhausted.fin_sent);
    try std.testing.expectEqual(limit, exhausted.send_offset);
    try std.testing.expectEqual(@as(usize, 0), exhausted.unsent.bytes().len);
    try std.testing.expect(!link.closed);

    const incoming = try link.open();
    incoming.recv_next = limit - 2;
    incoming.advertised = limit;
    try std.testing.expectEqual(limit, incoming.windowEdge());
    testReceive(link, incoming.id, limit - 2, "z", true);
    try std.testing.expectEqual(limit, incoming.recv_next);
    try std.testing.expect(incoming.peer_finished);
    var buf: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), incoming.read(&buf));
    try std.testing.expectEqualStrings("z", &buf);
    try std.testing.expectEqual(@as(usize, 0), incoming.read(&buf));
    try std.testing.expectEqual(limit, incoming.windowEdge());
    try std.testing.expectError(error.Overflow, (Segment{ .offset = limit, .data = &.{}, .fin = true, .sent_at = 0 }).end());
}

/// Drives every allocation site on the send and receive paths.
fn exerciseAllocations(gpa: Allocator) !void {
    const link = try testLink(gpa, true);
    defer link.free();
    link.on_stream = testAccept;
    const stream = try link.open();
    stream.send("hello");
    stream.send("world");
    defer stream.release();
    testReceive(link, 1, 0, "in", false);
    testReceive(link, 1, 4, "order", false);
    testReceive(link, 1, 2, "xx", false);
    testReceive(link, 1, 9, "", true);
}

test "allocation failure on the send and receive paths drops data without leaks" {
    var baseline = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    try exerciseAllocations(baseline.allocator());
    try std.testing.expectEqual(baseline.allocated_bytes, baseline.freed_bytes);
    // Runtime send/receive deliberately drop an allocation failure rather
    // than returning it. Inject each failure and check ownership directly.
    for (0..baseline.alloc_index) |index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = index });
        exerciseAllocations(failing.allocator()) catch |err| switch (err) {
            error.OutOfMemory => {},
            else => return err,
        };
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}
