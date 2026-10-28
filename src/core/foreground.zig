//! What runs in the front of a terminal: the process group the TTY belongs
//! to, read from the kernel, so Koi knows `nvim` or `claude` is running
//! without the program telling it.
const std = @import("std");
const builtin = @import("builtin");
const sys = @import("sys.zig");
const c = sys.c;

pub const Foreground = struct {
    /// The program's name: its argv[0] without a path, or for a script run
    /// by an interpreter (`node …/claude`), the script's. Points into the
    /// caller's buffer.
    program: []const u8,
    cwd: []const u8,
    pid: c.pid_t,

    /// Room for the name and a directory of the longest length the kernel
    /// reports (MAXPATHLEN), so a deep path is never silently truncated.
    pub const buffer_size = 512 + 1024;

    /// The foreground of the terminal whose master is `fd`, its strings in
    /// `buf`; null if none.
    pub fn of(master: c_int, buf: *[buffer_size]u8) ?Foreground {
        const pgid = c.tcgetpgrp(master);
        if (pgid <= 0) return null;
        var used: usize = 0;
        return .{
            .program = name(pgid, buf[0..512], &used),
            .cwd = cwd(pgid, buf[512..]),
            .pid = pgid,
        };
    }
};

const interpreters = [_][]const u8{ "node", "bun", "deno", "python", "python3", "ruby", "perl" };
const script_suffixes = [_][]const u8{ ".js", ".mjs", ".cjs", ".py", ".rb", ".ts" };

/// The program name in a path or argv[0]; login shells run as "-zsh".
fn base(path: []const u8) []const u8 {
    const s = std.fs.path.basename(path);
    return if (s.len > 0 and s[0] == '-') s[1..] else s;
}

fn copyInto(buf: []u8, used: *usize, s: []const u8) []const u8 {
    const n = @min(s.len, buf.len - used.*);
    @memcpy(buf[used.* .. used.* + n], s[0..n]);
    const out = buf[used.* .. used.* + n];
    used.* += n;
    return out;
}

/// The program's name from its arguments.
fn name(pid: c.pid_t, buf: []u8, used: *usize) []const u8 {
    var args_buf: [4096]u8 = undefined;
    if (builtin.os.tag == .macos) {
        // macOS can return success with truncated arguments when the buffer
        // is too small. Query the complete snapshot size before reading it.
        var mib = [_]c_int{ c.CTL_KERN, c.KERN_PROCARGS2, pid };
        var size: usize = 0;
        if (c.sysctl(&mib, 3, null, &size, null, 0) == 0 and size > args_buf.len) {
            const storage = std.heap.page_allocator.alloc(u8, size) catch return "";
            defer std.heap.page_allocator.free(storage);
            var args = argumentsMac(pid, storage);
            return nameFrom(&args, buf, used);
        }
    }
    var args = arguments(pid, &args_buf);
    return nameFrom(&args, buf, used);
}

/// The interpreter's script is its first argument that looks like a file:
/// a path or a name with a script suffix. Inline code (`node -e …`) and
/// module names leave the interpreter's own name.
fn nameFrom(args: *Args, buf: []u8, used: *usize) []const u8 {
    const first = args.next() orelse return "";
    const exe = base(first);
    for (interpreters) |interp| {
        if (!std.mem.eql(u8, exe, interp)) continue;
        while (args.next()) |arg| {
            if (arg.len == 0 or arg[0] == '-') continue;
            var script = base(arg);
            const is_path = std.mem.indexOfScalar(u8, arg, '/') != null;
            var has_suffix = false;
            for (script_suffixes) |suffix| {
                if (std.mem.endsWith(u8, script, suffix)) {
                    script = script[0 .. script.len - suffix.len];
                    has_suffix = true;
                    break;
                }
            }
            if (is_path or has_suffix) return copyInto(buf, used, script);
        }
        break;
    }
    return copyInto(buf, used, exe);
}

fn testName(buf: []u8, argv: []const u8, count: usize) []const u8 {
    var args = Args{ .data = argv, .count = count };
    var used: usize = 0;
    return nameFrom(&args, buf, &used);
}

test "an interpreter is named after its script, not its inline code" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("claude", testName(&buf, "node\x00/opt/lib/claude\x00", 2));
    try std.testing.expectEqualStrings("app", testName(&buf, "node\x00app.js\x00", 2));
    try std.testing.expectEqualStrings("node", testName(&buf, "node\x00-e\x00setInterval(()=>{},1000)\x00", 3));
    try std.testing.expectEqualStrings("python3", testName(&buf, "/usr/bin/python3\x00-m\x00http.server\x00", 3));
}

/// The process's arguments, NUL-separated in `buf`.
const Args = struct {
    data: []const u8,
    count: usize,

    fn next(self: *Args) ?[]const u8 {
        if (self.count == 0 or self.data.len == 0) return null;
        const end = std.mem.indexOfScalar(u8, self.data, 0) orelse self.data.len;
        const arg = self.data[0..end];
        self.data = if (end < self.data.len) self.data[end + 1 ..] else self.data[end..];
        self.count -= 1;
        return arg;
    }
};

fn arguments(pid: c.pid_t, buf: []u8) Args {
    if (builtin.os.tag == .macos) return argumentsMac(pid, buf);
    return argumentsLinux(pid, buf);
}

/// KERN_PROCARGS2: argc, the executable path, padding, then argv.
fn argumentsMac(pid: c.pid_t, buf: []u8) Args {
    if (builtin.os.tag != .macos) unreachable;
    var mib = [_]c_int{ c.CTL_KERN, c.KERN_PROCARGS2, pid };
    var size: usize = buf.len;
    if (c.sysctl(&mib, 3, buf.ptr, &size, null, 0) != 0 or size < 4) return .{ .data = "", .count = 0 };
    const argc: usize = @intCast(std.mem.readInt(i32, buf[0..4], .little));
    var i: usize = 4;
    while (i < size and buf[i] != 0) : (i += 1) {} // the executable path
    while (i < size and buf[i] == 0) : (i += 1) {} // its padding
    return .{ .data = buf[i..size], .count = argc };
}

fn argumentsLinux(pid: c.pid_t, buf: []u8) Args {
    var path: [64]u8 = undefined;
    const p = std.fmt.bufPrintSentinel(&path, "/proc/{d}/cmdline", .{pid}, 0) catch return .{ .data = "", .count = 0 };
    const fd = c.open(p.ptr, c.O_RDONLY);
    if (fd < 0) return .{ .data = "", .count = 0 };
    defer _ = c.close(fd);
    const n = c.read(fd, buf.ptr, buf.len);
    if (n <= 0) return .{ .data = "", .count = 0 };
    return .{ .data = buf[0..@intCast(n)], .count = std.math.maxInt(usize) };
}

test "a foreground directory longer than 512 bytes is reported whole" {
    // Eight nested directories of 80 characters, well past the 512 bytes
    // the directory half of the buffer used to hold.
    var dir: [2048]u8 = undefined;
    var len = (try std.fmt.bufPrint(&dir, "/tmp/koi-cwd-{d}", .{c.getpid()})).len;
    var ends: [8]usize = undefined;
    var made: usize = 0;
    defer while (made > 0) {
        made -= 1;
        dir[ends[made]] = 0;
        _ = c.rmdir(&dir);
    };
    var saved: [4096]u8 = undefined;
    try std.testing.expect(c.getcwd(&saved, saved.len) != null);
    defer _ = c.chdir(&saved);
    for (0..ends.len) |_| {
        if (made > 0) {
            dir[len] = '/';
            @memset(dir[len + 1 .. len + 81], 'd');
            len += 81;
        }
        dir[len] = 0;
        try std.testing.expectEqual(@as(c_int, 0), c.mkdir(&dir, 0o700));
        ends[made] = len;
        made += 1;
    }
    try std.testing.expect(len > 512);
    try std.testing.expectEqual(@as(c_int, 0), c.chdir(&dir));
    var buf: [Foreground.buffer_size]u8 = undefined;
    const got = cwd(c.getpid(), buf[512..]);
    // /tmp may be a link (macOS resolves it to /private/tmp): compare the tail.
    try std.testing.expect(std.mem.endsWith(u8, got, dir[4..len]));
}

fn cwd(pid: c.pid_t, buf: []u8) []const u8 {
    if (builtin.os.tag == .macos) {
        var info: c.struct_proc_vnodepathinfo = undefined;
        const size: c_int = @sizeOf(c.struct_proc_vnodepathinfo);
        if (c.proc_pidinfo(pid, c.PROC_PIDVNODEPATHINFO, 0, &info, size) != size) return "";
        const path = std.mem.sliceTo(&info.pvi_cdir.vip_path, 0);
        const n = @min(path.len, buf.len);
        @memcpy(buf[0..n], path[0..n]);
        return buf[0..n];
    }
    var path: [64]u8 = undefined;
    const p = std.fmt.bufPrintSentinel(&path, "/proc/{d}/cwd", .{pid}, 0) catch return "";
    const n = c.readlink(p.ptr, buf.ptr, buf.len);
    if (n <= 0) return "";
    return buf[0..@intCast(n)];
}
