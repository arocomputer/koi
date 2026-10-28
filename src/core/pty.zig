//! Starting a shell on a pseudoterminal.
const std = @import("std");
const sys = @import("sys.zig");
const c = sys.c;

/// Parent owns master and execution_gate; close the gate to cancel, or write
/// one byte (1) and close it after registration to permit exec.
pub const Spawned = struct { master: c_int, pid: c.pid_t, execution_gate: c_int };

/// Starts `path` with `argv` and `envp` in `cwd` on a new PTY of
/// `cols` x `rows`, as its session leader with the PTY as its controlling
/// terminal. The child waits on an owned pipe before exec; cancellation/EOF
/// exits without executing startup. Only async-signal-safe calls run in child.
pub fn spawn(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8, cwd: [*:0]const u8, cols: u16, rows: u16) !Spawned {
    var gate: [2]c_int = undefined;
    if (c.pipe(&gate) != 0) return error.Pipe;
    errdefer for (gate) |fd| {
        _ = c.close(fd);
    };
    for (gate) |fd| if (c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC) < 0) return error.Pipe;
    var ws: c.struct_winsize = std.mem.zeroes(c.struct_winsize);
    ws.ws_row = rows;
    ws.ws_col = cols;
    var master: c_int = -1;
    const pid = c.forkpty(&master, null, null, &ws);
    if (pid < 0) return error.Fork;
    if (pid == 0) {
        _ = c.close(gate[1]);
        // The server ignores SIGPIPE; the shell must not inherit that.
        sys.defaultSignal(c.SIGPIPE);
        var none: c.sigset_t = undefined;
        _ = c.sigemptyset(&none);
        _ = c.sigprocmask(c.SIG_SETMASK, &none, null);
        var token: u8 = 0;
        var n: isize = 0;
        while (true) {
            n = c.read(gate[0], &token, 1);
            if (n >= 0 or sys.errno() != c.EINTR) break;
        }
        _ = c.close(gate[0]);
        if (n != 1 or token != 1) c._exit(125);
        if (c.chdir(cwd) != 0) _ = c.chdir("/");
        _ = c.execve(path, @ptrCast(argv), @ptrCast(envp));
        c._exit(127);
    }
    errdefer {
        _ = c.close(master);
        _ = c.kill(pid, c.SIGKILL);
        var status: c_int = 0;
        while (c.waitpid(pid, &status, 0) < 0 and sys.errno() == c.EINTR) {}
    }
    if (c.fcntl(master, c.F_SETFD, c.FD_CLOEXEC) < 0) return error.Pty;
    const flags = c.fcntl(master, c.F_GETFL);
    if (flags < 0 or c.fcntl(master, c.F_SETFL, flags | c.O_NONBLOCK) < 0) return error.Pty;
    _ = c.close(gate[0]);
    return .{ .master = master, .pid = pid, .execution_gate = gate[1] };
}

pub fn setSize(master: c_int, cols: u16, rows: u16, xpixel: u16, ypixel: u16) void {
    var ws: c.struct_winsize = std.mem.zeroes(c.struct_winsize);
    ws.ws_row = rows;
    ws.ws_col = cols;
    ws.ws_xpixel = xpixel;
    ws.ws_ypixel = ypixel;
    _ = c.ioctl(master, c.TIOCSWINSZ, &ws);
}

/// The user's login shell from the user database: a server started over
/// SSH or from the Finder has no $SHELL to go by.
pub fn loginShell() [*:0]const u8 {
    if (c.getpwuid(c.getuid())) |pw| {
        if (pw.*.pw_shell) |sh| {
            if (sh[0] != 0) return sh;
        }
    }
    return "/bin/zsh";
}
