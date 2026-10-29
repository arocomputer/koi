//! Where Koi keeps its files, the same split as the app's: settings in
//! `~/.config/koi`, state in `~/.local/state/koi`, the server's socket in
//! the per-user runtime directory. `KOI_DIR` puts everything under one
//! directory instead, which the tests use.
//!
//! The socket's directory is the only thing authenticating a client, so
//! `ensureDirs` refuses to serve from a directory this user does not solely
//! control, and never places the socket in shared `/tmp`.
const std = @import("std");
const sys = @import("sys.zig");
const c = sys.c;
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
        var runtime = if (override) |dir| try gpa.dupe(u8, dir) else if (sys.getenv("XDG_RUNTIME_DIR")) |x|
            try std.fs.path.join(gpa, &.{ x, "koi" })
        else
            try std.fs.path.join(gpa, &.{ sys.getenv("TMPDIR") orelse "/tmp", "koi" });
        errdefer gpa.free(runtime);
        const name = try std.fmt.allocPrint(gpa, "server-{d}.sock", .{wire.version});
        defer gpa.free(name);
        // `sun_path` is 104 bytes. A long TMPDIR moves the whole runtime
        // directory to a per-user one, rather than dropping the socket alone
        // into shared /tmp where another local user could pre-empt the path.
        if (runtime.len + name.len + 1 >= 100) {
            const private = try std.fmt.allocPrint(gpa, "/tmp/koi-{d}", .{c.getuid()});
            gpa.free(runtime);
            runtime = private;
        }
        const socket = try std.fs.path.join(gpa, &.{ runtime, name });
        errdefer gpa.free(socket);
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

    /// Makes the state and runtime directories, private to the user. Fails
    /// rather than serving from a directory another local user could write to:
    /// the socket's permissions are the only thing authenticating a client.
    pub fn ensureDirs(self: Paths) !void {
        try mkdirAll(self.state);
        try mkdirAll(self.runtime);
        try requirePrivate(self.runtime);
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

/// A NUL-terminated copy of `path` in `buf`, for the libc calls that need one.
fn cstr(buf: []u8, path: []const u8) ![:0]u8 {
    if (path.len == 0 or path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

/// mkdir -p, with each directory private to the user. An existing directory
/// keeps its own mode, so `requirePrivate` checks the result separately.
fn mkdirAll(path: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = try cstr(&buf, path);
    var i: usize = 1;
    while (i <= z.len) : (i += 1) {
        if (i != z.len and z[i] != '/') continue;
        const saved = z[i];
        z[i] = 0;
        const rc = c.mkdir(z.ptr, 0o700);
        z[i] = saved;
        if (rc != 0 and sys.errno() != c.EEXIST) return error.MakeDir;
    }
}

/// Fails unless `dir` is a directory this user owns and no other user can
/// create or replace entries in it. Writing to the directory is what would let
/// another local user bind or answer for the socket, and the socket is what
/// authorizes driving panes; reading it only lists a name that is predictable
/// anyway, so `/tmp` itself is still refused for being writable.
fn requirePrivate(dir: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = try cstr(&buf, dir);
    var st: c.struct_stat = undefined;
    if (c.stat(z.ptr, &st) != 0) return error.Stat;
    if ((st.st_mode & c.S_IFMT) != c.S_IFDIR) return error.NotDirectory;
    if (st.st_uid != c.getuid()) return error.NotOwned;
    if ((st.st_mode & 0o022) != 0) return error.InsecureDirectory;
}

test "ensureDirs refuses a runtime directory other users can write to" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // testing.tmpDir lives under .zig-cache/tmp in the working directory, so the
    // paths here stay relative and the libc calls resolve them the same way.
    var subbuf: [64]u8 = undefined;
    const root = try std.fmt.bufPrint(&subbuf, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    const gpa = std.testing.allocator;
    const state = try std.fs.path.join(gpa, &.{ root, "state" });
    const runtime = try std.fs.path.join(gpa, &.{ root, "runtime" });
    const paths = Paths{
        .state = state,
        .runtime = runtime,
        .socket = try std.fs.path.join(gpa, &.{ runtime, "server-1.sock" }),
        .lock = try std.fs.path.join(gpa, &.{ runtime, "server.lock" }),
        .log = try std.fs.path.join(gpa, &.{ state, "server.log" }),
    };
    defer paths.deinit(gpa);

    // A fresh directory is created private and accepted.
    try paths.ensureDirs();

    // Anything the group or other bits can reach is refused: the socket inside
    // it would no longer be the boundary between this server and other users.
    var pathbuf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.chmod(try cstr(&pathbuf, runtime), 0o777));
    try std.testing.expectError(error.InsecureDirectory, paths.ensureDirs());
}
