//! The operating system, through its own C headers, so every struct and
//! constant is exactly the platform's.
const std = @import("std");
const builtin = @import("builtin");

pub const c = @import("c");
/// The terminal engine's C API lives in the same module.
pub const vt = c;

pub fn errno() c_int {
    return std.c._errno().*;
}

/// `struct timespec`, declared here because musl's has bitfields that
/// translate-c cannot express; this layout holds on every 64-bit target.
const Timespec = extern struct { sec: i64, nsec: i64 };
extern "c" fn clock_gettime(clock: c_int, ts: *Timespec) c_int;

/// Milliseconds since the Unix epoch.
pub fn nowMillis() i64 {
    var ts: Timespec = undefined;
    _ = clock_gettime(c.CLOCK_REALTIME, &ts);
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

/// Monotonic elapsed milliseconds, unaffected by wall-clock adjustments.
pub fn monotonicMillis() u64 {
    var ts: Timespec = undefined;
    _ = clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(@divTrunc(ts.nsec, 1_000_000)));
}

/// Microseconds since the epoch, for the link's pings.
pub fn nowMicros() u64 {
    var ts: Timespec = undefined;
    _ = clock_gettime(c.CLOCK_REALTIME, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000 + @as(u64, @intCast(@divTrunc(ts.nsec, 1000)));
}

/// SIG_IGN and SIG_DFL are casts translate-c cannot express, so `signal`
/// is declared here with its handler as the integer it is.
extern "c" fn signal(sig: c_int, handler: usize) usize;

pub fn ignoreSignal(sig: c_int) void {
    _ = signal(sig, 1);
}

pub fn defaultSignal(sig: c_int) void {
    _ = signal(sig, 0);
}

/// A mutex and a condition over pthreads: the standard library's need an
/// `Io` for every lock, which the core has no use for otherwise.
pub const Mutex = struct {
    inner: c.pthread_mutex_t,

    pub fn init() Mutex {
        var m: Mutex = undefined;
        _ = c.pthread_mutex_init(&m.inner, null);
        return m;
    }

    pub fn lock(self: *Mutex) void {
        _ = c.pthread_mutex_lock(&self.inner);
    }

    pub fn unlock(self: *Mutex) void {
        _ = c.pthread_mutex_unlock(&self.inner);
    }
};

pub const Cond = struct {
    inner: c.pthread_cond_t,

    pub fn init() Cond {
        var cv: Cond = undefined;
        _ = c.pthread_cond_init(&cv.inner, null);
        return cv;
    }

    pub fn wait(self: *Cond, mutex: *Mutex) void {
        _ = c.pthread_cond_wait(&self.inner, &mutex.inner);
    }

    pub fn signal(self: *Cond) void {
        _ = c.pthread_cond_signal(&self.inner);
    }
};

/// Cryptographically secure random bytes, from the system (getentropy is
/// in sys/random.h on Linux, unistd.h on macOS; declared here for both).
extern "c" fn getentropy(buf: [*]u8, len: usize) c_int;

pub fn randomBytes(buf: []u8) void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = @min(buf.len - off, 256);
        if (getentropy(buf[off..].ptr, n) != 0) @panic("getentropy failed");
        off += n;
    }
}

pub fn getenv(name: [*:0]const u8) ?[]const u8 {
    const p = c.getenv(name) orelse return null;
    return std.mem.span(p);
}

pub fn sleepMillis(ms: u32) void {
    _ = c.usleep(ms * 1000);
}

/// The path of the running binary.
pub fn selfPath(gpa: std.mem.Allocator) ![]const u8 {
    var buf: [4096]u8 = undefined;
    if (builtin.os.tag == .macos) {
        var size: u32 = buf.len;
        if (c._NSGetExecutablePath(&buf, &size) != 0) return error.NoPath;
        return gpa.dupe(u8, std.mem.sliceTo(&buf, 0));
    }
    const n = c.readlink("/proc/self/exe", &buf, buf.len);
    if (n <= 0) return error.NoPath;
    return gpa.dupe(u8, buf[0..@intCast(n)]);
}

/// Authenticate a connected Unix peer using kernel credentials, never socket-file metadata.
pub fn sameUserPeer(fd: c_int) bool {
    if (builtin.os.tag == .macos) {
        var uid: c.uid_t = undefined;
        var gid: c.gid_t = undefined;
        return c.getpeereid(fd, &uid, &gid) == 0 and uid == c.getuid();
    } else {
        // `struct ucred` is only visible to C with _GNU_SOURCE, which also
        // turns glibc's sockaddr arguments into transparent unions; its
        // layout is the same on every Linux architecture.
        const Ucred = extern struct { pid: i32, uid: u32, gid: u32 };
        var cred: Ucred = undefined;
        var len: c.socklen_t = @sizeOf(Ucred);
        return c.getsockopt(fd, c.SOL_SOCKET, std.os.linux.SO.PEERCRED, &cred, &len) == 0 and
            len == @sizeOf(Ucred) and cred.uid == c.getuid();
    }
}

/// Read ownership and mode from an opened directory. Linux statx avoids musl's
/// opaque translated stat/timespec layout and validates the returned field mask.
pub fn directoryInfo(fd: c_int) !struct { uid: c.uid_t, mode: u32 } {
    if (builtin.os.tag == .macos) {
        var st: c.struct_stat = undefined;
        if (c.fstat(fd, &st) != 0) return error.UnsafeDirectory;
        return .{ .uid = st.st_uid, .mode = st.st_mode };
    } else {
        const linux = std.os.linux;
        var st: linux.Statx = undefined;
        if (linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .UID = true, .MODE = true }, &st) != 0 or
            !st.mask.UID or !st.mask.MODE) return error.UnsafeDirectory;
        return .{ .uid = st.uid, .mode = st.mode };
    }
}
