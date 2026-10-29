//! Where Koi keeps its files, the same split as the app's: settings in
//! `~/.config/koi`, state in `~/.local/state/koi`, the server's socket in
//! the per-user runtime directory. `KOI_DIR` puts everything under one
//! directory instead, which the tests use.
//!
//! The socket's directory is the only thing authenticating a client, so
//! `ensureDirs` refuses to serve from a directory this user does not solely
//! control, and never places the socket in shared `/tmp`.
const std = @import("std");
const builtin = @import("builtin");
const sys = @import("sys.zig");
const c = sys.c;
const wire = @import("wire.zig");

/// Match Swift's treatment of unset and empty directory overrides.
fn nonemptyEnv(name: [:0]const u8) ?[]const u8 {
    const value = sys.getenv(name.ptr) orelse return null;
    return if (value.len == 0) null else value;
}

pub const Paths = struct {
    state: []const u8,
    runtime: []const u8,
    socket: []const u8,
    lock: []const u8,
    log: []const u8,

    pub fn init(gpa: std.mem.Allocator) !Paths {
        const home = sys.getenv("HOME") orelse "/";
        const override = nonemptyEnv("KOI_DIR");
        const state = if (override) |dir| try gpa.dupe(u8, dir) else if (nonemptyEnv("XDG_STATE_HOME")) |x|
            try std.fs.path.join(gpa, &.{ x, "koi" })
        else
            try std.fs.path.join(gpa, &.{ home, ".local/state/koi" });
        errdefer gpa.free(state);
        // Without a per-user runtime or temporary directory, the fallback in
        // shared /tmp is per user too: a single /tmp/koi would belong to
        // whichever user started first, and `ensureDirs` refuses everyone else.
        var runtime = if (override) |dir| try gpa.dupe(u8, dir) else if (nonemptyEnv("XDG_RUNTIME_DIR")) |x|
            try std.fs.path.join(gpa, &.{ x, "koi" })
        else if (nonemptyEnv("TMPDIR")) |t|
            try std.fs.path.join(gpa, &.{ t, "koi" })
        else
            try std.fmt.allocPrint(gpa, "/tmp/koi-{d}", .{c.getuid()});
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

    /// Creates or verifies the private state and runtime directories, the
    /// socket's included; fails closed rather than serving from a directory
    /// another local user could write to.
    pub fn ensureDirs(self: Paths) !void {
        try ensurePrivateDir(self.state);
        try ensurePrivateDir(self.runtime);
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

/// Walk without following symlinks. Ancestors must be owned by root or this user
/// and not writable by others, except root-owned sticky directories such as /tmp.
/// Existing leaf directories must already be private; never repair permissions.
pub fn ensurePrivateDir(path: []const u8) !void {
    if (path.len == 0 or path[0] != '/' or std.mem.indexOfScalar(u8, path, 0) != null)
        return error.UnsafeDirectory;
    // Darwin's system aliases are root-managed; all subsequent components use O_NOFOLLOW.
    const aliased = builtin.os.tag == .macos and
        (std.mem.startsWith(u8, path, "/tmp/") or std.mem.startsWith(u8, path, "/var/"));
    const actual = if (aliased) path[1..] else path;
    var fd = sys.c.open(if (aliased) "/private" else "/", sys.c.O_RDONLY | sys.c.O_DIRECTORY | sys.c.O_CLOEXEC);
    if (fd < 0) return error.UnsafeDirectory;
    defer _ = sys.c.close(fd);
    var parts = std.mem.tokenizeScalar(u8, actual, '/');
    var found = false;
    while (parts.next()) |part| {
        found = true;
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.UnsafeDirectory;
        var buf: [256]u8 = undefined;
        const name = std.fmt.bufPrintSentinel(&buf, "{s}", .{part}, 0) catch return error.PathTooLong;
        if (sys.c.mkdirat(fd, name, 0o700) != 0 and sys.errno() != sys.c.EEXIST) return error.CreateDirectory;
        const next = sys.c.openat(fd, name, sys.c.O_RDONLY | sys.c.O_DIRECTORY | sys.c.O_NOFOLLOW | sys.c.O_CLOEXEC);
        if (next < 0) return error.UnsafeDirectory;
        _ = sys.c.close(fd);
        fd = next;
        const st = try sys.directoryInfo(fd);
        const leaf = parts.peek() == null;
        if (leaf) {
            if (st.uid != sys.c.getuid() or st.mode & 0o777 != 0o700) return error.UnsafeDirectory;
        } else {
            if (st.uid != 0 and st.uid != sys.c.getuid()) return error.UnsafeDirectory;
            if (st.mode & 0o022 != 0 and !(st.uid == 0 and st.mode & 0o1000 != 0)) return error.UnsafeDirectory;
        }
    }
    if (!found) return error.UnsafeDirectory;
}

test "private directories reject public modes and symlinks without changing them" {
    var template = "/tmp/koi-private-XXXXXXXX".*;
    const root = sys.c.mkdtemp(&template) orelse return error.CreateDirectory;
    defer _ = sys.c.rmdir(root);
    try ensurePrivateDir(std.mem.span(root));
    var buf: [256]u8 = undefined;
    const child = try std.fmt.bufPrintSentinel(&buf, "{s}/child", .{root}, 0);
    try ensurePrivateDir(child);
    defer _ = sys.c.rmdir(child);
    try std.testing.expectEqual(0, sys.c.chmod(child, 0o755));
    try std.testing.expectError(error.UnsafeDirectory, ensurePrivateDir(child));
    const child_fd = sys.c.open(child, sys.c.O_RDONLY | sys.c.O_DIRECTORY | sys.c.O_NOFOLLOW | sys.c.O_CLOEXEC);
    try std.testing.expect(child_fd >= 0);
    defer _ = sys.c.close(child_fd);
    const st = try sys.directoryInfo(child_fd);
    try std.testing.expectEqual(@as(u32, 0o755), st.mode & 0o777);
    var link_buf: [256]u8 = undefined;
    const link = try std.fmt.bufPrintSentinel(&link_buf, "{s}/link", .{root}, 0);
    try std.testing.expectEqual(0, sys.c.symlink(child, link));
    defer _ = sys.c.unlink(link);
    try std.testing.expectError(error.UnsafeDirectory, ensurePrivateDir(link));
    var nested_buf: [256]u8 = undefined;
    const nested = try std.fmt.bufPrintSentinel(&nested_buf, "{s}/nested", .{link}, 0);
    try std.testing.expectError(error.UnsafeDirectory, ensurePrivateDir(nested));
    try std.testing.expectError(error.UnsafeDirectory, ensurePrivateDir("/"));
}
