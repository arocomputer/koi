//! libkoi: the link's client side with a C ABI, for the Mac app. See
//! include/koi.h.
//!
//! Lifetime, enforced by the caller (see link.zig for the full contract):
//! - A stream has one owner. `koi_stream_close` is idempotent and, with
//!   `koi_stream_send` and `koi_stream_read`, may be called until the owner
//!   calls `koi_stream_release`, exactly once and last, after every thread
//!   using the stream has stopped. The pointer is dead afterwards.
//! - `koi_link_destroy` frees every stream and the link. Call it only after
//!   all threads using the link or its streams have returned. `koi_link_close`
//!   first wakes blocked readers (they return 0), so close, join readers, then
//!   destroy. The owner of a stream must keep its link alive until then.
//! - `koi_stream_send` never blocks; a peer too slow to drain 64 MiB of queued
//!   output has that stream ended (reads return 0) rather than buffered further.
const std = @import("std");
const link_mod = @import("link.zig");

/// The embedding app owns signal handling, including sanitizer signal stacks.
/// Link worker threads must not replace the host's per-thread alternate stack.
pub const std_options: std.Options = .{ .signal_stack_size = null };

const gpa = std.heap.c_allocator;

export fn koi_link_connect(host: [*:0]const u8, port: u16, secret: *const [32]u8) ?*link_mod.Link {
    return link_mod.Link.connect(gpa, std.mem.span(host), port, secret.*) catch null;
}

export fn koi_link_open(link: *link_mod.Link) ?*link_mod.Stream {
    return link.open() catch null;
}

export fn koi_link_closed(link: *link_mod.Link) c_int {
    return @intFromBool(link.isClosed());
}

export fn koi_link_close(link: *link_mod.Link) void {
    link.close();
}

export fn koi_link_destroy(link: *link_mod.Link) void {
    link.destroy();
}

export fn koi_stream_send(stream: *link_mod.Stream, bytes: [*]const u8, len: usize) void {
    stream.send(bytes[0..len]);
}

export fn koi_stream_read(stream: *link_mod.Stream, buf: [*]u8, cap: usize) usize {
    return stream.read(buf[0..cap]);
}

export fn koi_stream_close(stream: *link_mod.Stream) void {
    stream.close();
}

export fn koi_stream_release(stream: *link_mod.Stream) void {
    stream.release();
}
