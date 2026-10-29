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
/// Symlinks among the existing ancestors (`/home` on an image-based system,
/// `/tmp` on macOS) are resolved first, and every resolved directory is checked.
pub fn ensurePrivateDir(path: []const u8) !void {
    if (path.len == 0 or path[0] != '/' or std.mem.indexOfScalar(u8, path, 0) != null)
        return error.UnsafeDirectory;
    const trimmed = std.mem.trimEnd(u8, path, "/");
    const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return error.UnsafeDirectory;
    const leaf = trimmed[slash + 1 ..];
    var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
    const parent = try resolveExisting(if (slash == 0) "/" else trimmed[0..slash], &resolved_buf);
    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
    const full = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ parent, leaf }) catch return error.PathTooLong;
    var fd = sys.c.open("/", sys.c.O_RDONLY | sys.c.O_DIRECTORY | sys.c.O_CLOEXEC);
    if (fd < 0) return error.UnsafeDirectory;
    defer _ = sys.c.close(fd);
    var parts = std.mem.tokenizeScalar(u8, full, '/');
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
        if (parts.peek() == null) {
            if (st.uid != sys.c.getuid() or st.mode & 0o777 != 0o700) return error.UnsafeDirectory;
        } else if (!safeAncestor(st.uid, st.gid, st.mode)) {
            return error.UnsafeDirectory;
        }
    }
    if (!found) return error.UnsafeDirectory;
}

/// Owned by root or this user, and writable by no one else: other users only
/// through a root-owned sticky directory such as /tmp. On Linux a directory
/// this user owns may also be writable by the user's own primary group, which
/// `umask 002` systems give every new directory (user private groups); macOS
/// users share `staff`, so there it still counts as writable by others.
fn safeAncestor(uid: c.uid_t, gid: c.gid_t, mode: u32) bool {
    const me = sys.c.getuid();
    if (uid != 0 and uid != me) return false;
    const sticky_root = uid == 0 and mode & 0o1000 != 0;
    if (mode & 0o002 != 0 and !sticky_root) return false;
    if (mode & 0o020 != 0 and !sticky_root) {
        const private_group = builtin.os.tag == .linux and uid == me and gid == sys.c.getgid();
        if (!private_group) return false;
    }
    return true;
}

/// The longest existing prefix of `path` with its symlinks resolved, followed
/// by the components that do not exist yet.
fn resolveExisting(path: []const u8, out: *[std.fs.max_path_bytes]u8) ![]const u8 {
    var prefix = path;
    while (true) {
        var zbuf: [std.fs.max_path_bytes]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&zbuf, "{s}", .{prefix}, 0) catch return error.PathTooLong;
        var real: [std.fs.max_path_bytes]u8 = undefined;
        if (sys.c.realpath(z.ptr, &real) != null) {
            const head = std.mem.sliceTo(&real, 0);
            const rest = path[prefix.len..];
            const joined = std.fmt.bufPrint(out, "{s}{s}", .{ if (head.len == 1) "" else head, rest }) catch return error.PathTooLong;
            return if (joined.len == 0) "/" else joined;
        }
        if (sys.errno() != sys.c.ENOENT) return error.UnsafeDirectory;
        const slash = std.mem.lastIndexOfScalar(u8, prefix, '/') orelse return error.UnsafeDirectory;
        prefix = if (slash == 0) "/" else prefix[0..slash];
    }
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
    // A symlinked ancestor is followed, and its target is checked like any other.
    var nested_buf: [256]u8 = undefined;
    const nested = try std.fmt.bufPrintSentinel(&nested_buf, "{s}/nested", .{link}, 0);
    try ensurePrivateDir(nested);
    var nested_real_buf: [256]u8 = undefined;
    const nested_real = try std.fmt.bufPrintSentinel(&nested_real_buf, "{s}/nested", .{child}, 0);
    try std.testing.expectEqual(0, sys.c.rmdir(nested_real));
    try std.testing.expectEqual(0, sys.c.chmod(child, 0o757));
    try std.testing.expectError(error.UnsafeDirectory, ensurePrivateDir(nested));
    // `umask 002` leaves new directories writable by the user's primary group,
    // private on Linux and shared (`staff`) on macOS.
    try std.testing.expectEqual(0, sys.c.chmod(child, 0o775));
    if (builtin.os.tag == .linux) {
        try ensurePrivateDir(nested);
        try std.testing.expectEqual(0, sys.c.rmdir(nested_real));
    } else {
        try std.testing.expectError(error.UnsafeDirectory, ensurePrivateDir(nested));
    }
    try std.testing.expectEqual(0, sys.c.chmod(child, 0o755));
    try std.testing.expectError(error.UnsafeDirectory, ensurePrivateDir("/"));
}
