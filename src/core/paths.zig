//! Where Koi keeps its files, the same split as the app's: settings in
//! `~/.config/koi`, state in `~/.local/state/koi`, the server's socket in
//! the per-user runtime directory. `KOI_DIR` puts everything under one
//! directory instead, which the tests use.
const std = @import("std");
const sys = @import("sys.zig");
const wire = @import("wire.zig");

pub const Paths = struct {
    state: []const u8,
    runtime: []const u8,
    socket: []const u8,
    lock: []const u8,
    log: []const u8,

    pub fn init(gpa: std.mem.Allocator) !Paths {
        const home = sys.getenv("HOME") orelse "/";
        const override = sys.getenv("KOI_DIR");
        const state = if (override) |dir| try gpa.dupe(u8, dir) else if (sys.getenv("XDG_STATE_HOME")) |x|
            try std.fs.path.join(gpa, &.{ x, "koi" })
        else
            try std.fs.path.join(gpa, &.{ home, ".local/state/koi" });
        errdefer gpa.free(state);
        const runtime = if (override) |dir| try gpa.dupe(u8, dir) else if (sys.getenv("XDG_RUNTIME_DIR")) |x|
            try std.fs.path.join(gpa, &.{ x, "koi" })
        else
            try std.fs.path.join(gpa, &.{ sys.getenv("TMPDIR") orelse "/tmp", "koi" });
        errdefer gpa.free(runtime);
        const name = try std.fmt.allocPrint(gpa, "server-{d}.sock", .{wire.version});
        defer gpa.free(name);
        var socket = try std.fs.path.join(gpa, &.{ runtime, name });
        errdefer gpa.free(socket);
        if (socket.len >= 100) {
            const short = try std.fmt.allocPrint(gpa, "/tmp/koi-{d}-{s}", .{ sys.c.getuid(), name });
            gpa.free(socket);
            socket = short;
        }
        const lock = try std.fs.path.join(gpa, &.{ runtime, "server.lock" });
        errdefer gpa.free(lock);
        return .{
            .state = state,
            .runtime = runtime,
            .socket = socket,
            .lock = lock,
            .log = try std.fs.path.join(gpa, &.{ state, "server.log" }),
        };
    }

    /// Releases the five owned paths; directory contents are untouched.
    pub fn deinit(self: Paths, gpa: std.mem.Allocator) void {
        inline for (.{ self.state, self.runtime, self.socket, self.lock, self.log }) |path| gpa.free(path);
    }

    /// Makes the state and runtime directories, private to the user.
    pub fn ensureDirs(self: Paths) void {
        for ([_][]const u8{ self.state, self.runtime }) |dir| {
            var buf: [512]u8 = undefined;
            if (dir.len >= buf.len) continue;
            @memcpy(buf[0..dir.len], dir);
            buf[dir.len] = 0;
            mkdirAll(buf[0..dir.len :0]);
        }
    }
};

test "path allocation failures release every owned string" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            const paths = try Paths.init(gpa);
            defer paths.deinit(gpa);
            try std.testing.expect(paths.socket.len < 100);
        }
    }.run, .{});
}

/// mkdir -p, with each directory private to the user.
fn mkdirAll(path: [:0]u8) void {
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/') {
            const saved = path[i];
            path[i] = 0;
            _ = sys.c.mkdir(path.ptr, 0o700);
            path[i] = saved;
        }
    }
}
