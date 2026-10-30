//! One binary: `koi --server` is the server; `koi --offer` and `koi --stdio`
//! are what the app runs on another machine over SSH to reach it (see
//! remote.zig); anything else is the `koi` command (see cli.zig).
const std = @import("std");
const sys = @import("sys.zig");

test {
    _ = @import("wire.zig");
    _ = @import("transport.zig");
    _ = @import("link.zig");
    _ = @import("paths.zig");
    _ = @import("pty.zig");
    _ = @import("foreground.zig");
    _ = @import("emulator.zig");
    _ = @import("pane.zig");
    _ = @import("server.zig");
    _ = @import("remote.zig");
    _ = @import("cli.zig");
    _ = @import("api.zig");
    _ = @import("script.zig");
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.c_allocator;
    var args: std.ArrayList([:0]const u8) = .empty;
    defer args.deinit(gpa);
    var it = init.minimal.args.iterate();
    if (it.next()) |program| @import("pane.zig").Pane.server_name = std.fs.path.basename(program);
    while (it.next()) |a| try args.append(gpa, a);

    if (args.items.len > 0) {
        const first = args.items[0];
        if (std.mem.eql(u8, first, "--server")) @import("server.zig").Server.run(gpa);
        if (std.mem.eql(u8, first, "--offer")) @import("remote.zig").printOffer(gpa);
        if (std.mem.eql(u8, first, "--stdio")) @import("remote.zig").relay(gpa);
    }
    std.process.exit(@import("cli.zig").run(gpa, args.items));
}
