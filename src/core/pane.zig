//! One shell on one PTY, with the headless terminal that mirrors it and the
//! clients attached to it. A reader thread copies the PTY's output into the
//! terminal and to every client, in order, so the snapshot a client gets
//! and the bytes that follow it always agree. The same thread polls what
//! runs in front and its directory.
const std = @import("std");
const builtin = @import("builtin");
const sys = @import("sys.zig");
const c = sys.c;
const vt = sys.vt;
const wire = @import("wire.zig");
const pty = @import("pty.zig");
const foreground = @import("foreground.zig");
const Terminal = @import("emulator.zig").Terminal;
const Transport = @import("transport.zig").Transport;
const Allocator = std.mem.Allocator;

pub const Pane = struct {
    gpa: Allocator,
    id: [8]u8,
    pid: c.pid_t,
    master: c_int,
    /// Only the parent writes/closes this gate, under mutex. The child cannot
    /// exec until registration and reader preparation have both succeeded.
    execution_gate: c_int = -1,
    execution_ready: std.atomic.Value(bool) = .init(true),
    /// With a deadline (ms), the reader opens the gate itself at that time
    /// unless a client attaches first; see deferExecution. Guarded by `mutex`.
    release_deadline: ?i64 = null,
    terminal: Terminal,
    mutex: sys.Mutex,
    clients: std.ArrayList(Transport) = .empty,
    size: wire.GridSize,
    shell: []const u8,
    home: []const u8,
    /// What watchers see; strings owned by `pane`.
    title: std.ArrayList(u8) = .empty,
    cwd: std.ArrayList(u8) = .empty,
    program: std.ArrayList(u8) = .empty,
    /// The command the shell itself reported running (prompt integration),
    /// empty at a prompt. While set it is the program, whatever discovery
    /// finds in front: `make` stays `make` while it runs `cc`.
    shell_command: std.ArrayList(u8) = .empty,
    fullscreen: bool = false,
    status: wire.Status = .idle,
    /// The status last reported by the program (OSC 7501 or reportStatus).
    reported: ?wire.Status = null,
    /// Last accepted process-group identity; a same-name replacement is a
    /// foreground switch too. Program name also detects exec within a group.
    foreground_pid: c.pid_t = 0,
    last_output: i64 = 0,
    /// Last process/cwd discovery; terminal callbacks never advance this clock.
    last_refresh: i64 = 0,
    /// Coalesced activity deadline and generation, guarded by `mutex`.
    refresh_due: ?i64 = null,
    metadata_version: u64 = 0,
    /// Typed input is held until the program takes the terminal (turns off
    /// its line editing or echo, as a shell's line editor does), so keys
    /// pressed while a shell starts are shown once, by the shell, instead of
    /// echoed raw by the terminal and then again by the shell. A program that
    /// reads cooked input gets it after `input_hold_ms` anyway.
    held_input: std.ArrayList(u8) = .empty,
    input_hold_until: ?i64 = null,
    input_hold_ms: i64 = 2000,
    /// Input/close wakes the reader without shortening its idle poll interval.
    wake_pipe: [2]c_int = .{ -1, -1 },
    /// Explicit close asks the reader to reap, even if the PTY stays open.
    closing: std.atomic.Value(bool) = .init(false),
    /// Child teardown and client notification have finished (set under
    /// `mutex`). Closing rejects new work earlier; the descriptor stays open
    /// until `destroy`, so a stale write can never reach a reused number.
    ended: std.atomic.Value(bool) = .init(false),
    exit_code: i32 = -1,
    /// Holders of this pointer outside the server's lists (connections,
    /// commands in flight); the server destroys the pane only at zero.
    pins: std.atomic.Value(usize) = .init(0),
    /// The reader's close callback has finished tree removal, guarded by the
    /// server mutex. Reclamation also requires `ended` and zero pins.
    unlinked: bool = false,
    thread: ?std.Thread = null,
    on_change: ?*const fn (ctx: *anyopaque) void = null,
    /// Removes the visible pane before child teardown; never called under
    /// the pane mutex. `ended` becomes true only after cleanup completes.
    on_close: ?*const fn (ctx: *anyopaque, pane: *Pane) void = null,
    ctx: *anyopaque = undefined,

    /// Prepares a gated child in cwd (home if null), with extra KEY=value
    /// entries. Startup is intact shell source for -c; null uses a login shell.
    /// Call start, register the pane, then releaseExecution; abort on failure.
    pub fn create(gpa: Allocator, id: [8]u8, size: wire.GridSize, cwd: ?[]const u8, extra: []const []const u8, startup: ?[]const u8, appearance: ?wire.Appearance) !*Pane {
        if (!size.valid()) return error.InvalidSize;
        if (startup) |command| if (command.len == 0 or std.mem.indexOfScalar(u8, command, 0) != null) return error.InvalidStartup;
        if (appearance) |a| if (!a.valid()) return error.InvalidAppearance;
        const self = try gpa.create(Pane);
        errdefer gpa.destroy(self);
        const home = sys.getenv("HOME") orelse "/";
        const shell_path = pty.loginShell();
        const shell_name = std.fs.path.basename(std.mem.span(shell_path));

        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const shell_copy = try gpa.dupe(u8, shell_name);
        errdefer gpa.free(shell_copy);
        const home_copy = try gpa.dupe(u8, home);
        errdefer gpa.free(home_copy);
        var cwd_copy: std.ArrayList(u8) = .empty;
        errdefer cwd_copy.deinit(gpa);
        try cwd_copy.appendSlice(gpa, cwd orelse home);
        const argv0 = try std.fmt.allocPrintSentinel(arena, "-{s}", .{shell_name}, 0);
        const argv = try arena.allocSentinel(?[*:0]const u8, if (startup != null) 3 else 1, null);
        argv[0] = argv0;
        if (startup) |command| {
            argv[1] = "-c";
            argv[2] = try arena.dupeSentinel(u8, command, 0);
        }
        const envp = try environment(arena, extra, @ptrCast(environ), shell_name, integrationDirectory(arena));
        const dir = try arena.dupeSentinel(u8, cwd orelse home, 0);

        var terminal = try Terminal.init(size.cols, size.rows);
        errdefer terminal.deinit();
        if (appearance) |a| try terminal.applyAppearance(a);
        terminal.resize(size.cols, size.rows, size.cell_width, size.cell_height);
        const wake_pipe = try wakePipe();
        errdefer for (wake_pipe) |fd| {
            _ = c.close(fd);
        };
        // Transfer all child/gate ownership immediately; execution remains
        // blocked while the server prepares its reader and registration.
        const spawned = try pty.spawn(shell_path, argv, envp, dir, size.cols, size.rows);

        self.* = .{
            .gpa = gpa,
            .id = id,
            .pid = spawned.pid,
            .master = spawned.master,
            .execution_gate = spawned.execution_gate,
            .execution_ready = .init(false),
            .wake_pipe = wake_pipe,
            .terminal = terminal,
            .mutex = sys.Mutex.init(),
            .size = size,
            .shell = shell_copy,
            .home = home_copy,
            .cwd = cwd_copy,
            .input_hold_until = std.math.maxInt(i64),
        };
        self.installCallbacks();
        return self;
    }

    /// Prepares the reader thread; callbacks are set first. A newly created
    /// pane waits for releaseExecution/abort before reading or sampling.
    pub fn start(self: *Pane) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// Final creation commit: permit exec only after tree publication and a
    /// successful reader launch. No allocation; the empty gate takes one byte.
    pub fn releaseExecution(self: *Pane) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closing.load(.acquire) or self.ended.load(.acquire)) return error.PaneClosed;
        if (self.execution_gate < 0) return;
        if (self.thread == null) return error.ReaderNotStarted;
        if (self.input_hold_until != null) self.input_hold_until = sys.nowMillis() + self.input_hold_ms;
        const token = [_]u8{1};
        var n: isize = 0;
        while (true) {
            n = c.write(self.execution_gate, &token, 1);
            if (n >= 0 or sys.errno() != c.EINTR) break;
        }
        self.closeExecutionGateLocked();
        if (n != 1) return error.ExecutionGate;
        self.execution_ready.store(true, .release);
        self.wake();
    }

    /// Keeps a published pane gated until a client attaches, so the shell
    /// starts at the size that client asks for and draws its prompt once,
    /// or until `deadline` (ms), after which the reader releases it anyway.
    pub fn deferExecution(self: *Pane, deadline: i64) void {
        self.mutex.lock();
        self.release_deadline = deadline;
        self.mutex.unlock();
        self.wake();
    }

    /// Cancels an unpublished prepared pane and joins its reader, if any.
    /// Call without server/pane locks. The caller then owns destruction.
    pub fn abort(self: *Pane) void {
        self.mutex.lock();
        self.closeExecutionGateLocked();
        self.mutex.unlock();
        if (self.thread) |thread| {
            self.kill();
            thread.join();
            self.thread = null;
        } else self.abandon();
    }

    /// Caller holds mutex; closing without a token always forbids exec.
    fn closeExecutionGateLocked(self: *Pane) void {
        if (self.execution_gate >= 0) {
            _ = c.close(self.execution_gate);
            self.execution_gate = -1;
        }
    }

    fn installCallbacks(self: *Pane) void {
        self.terminal.setUserdata(self);
        // The server's terminal answers the program's queries (device
        // attributes, cursor position, modes); the apps' terminals do not,
        // so every query gets exactly one answer.
        const write_pty: vt.GhosttyTerminalWritePtyFn = &writePtyCallback;
        self.terminal.setOption(vt.GHOSTTY_TERMINAL_OPT_WRITE_PTY, @ptrCast(write_pty));
        const title: vt.GhosttyTerminalTitleChangedFn = &titleCallback;
        self.terminal.setOption(vt.GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, @ptrCast(title));
        const pwd: vt.GhosttyTerminalPwdChangedFn = &pwdCallback;
        self.terminal.setOption(vt.GHOSTTY_TERMINAL_OPT_PWD_CHANGED, @ptrCast(pwd));
        const status: vt.GhosttyTerminalProgramStatusFn = &statusCallback;
        self.terminal.setOption(vt.GHOSTTY_TERMINAL_OPT_PROGRAM_STATUS, @ptrCast(status));
    }

    fn writePtyCallback(_: vt.GhosttyTerminal, userdata: ?*anyopaque, data: [*c]const u8, len: usize) callconv(.c) void {
        const self: *Pane = @ptrCast(@alignCast(userdata orelse return));
        // Runs inside `terminal.write` with `mutex` held: never wait here. A
        // reply the program is not reading for is dropped, not waited for.
        self.writePtyNow(data[0..len]);
    }

    fn titleCallback(_: vt.GhosttyTerminal, userdata: ?*anyopaque) callconv(.c) void {
        const self: *Pane = @ptrCast(@alignCast(userdata orelse return));
        self.refreshMetadataLocked(false);
    }

    /// OSC 7 updates cwd during parsing, without waiting for process discovery.
    fn pwdCallback(_: vt.GhosttyTerminal, userdata: ?*anyopaque) callconv(.c) void {
        const self: *Pane = @ptrCast(@alignCast(userdata orelse return));
        const uri = std.Uri.parse(self.terminal.pwd()) catch return;
        if (!std.mem.eql(u8, uri.scheme, "file")) return;
        var path_buf: [4096]u8 = undefined;
        const cwd = uri.path.toRaw(&path_buf) catch return;
        if (cwd.len == 0 or cwd[0] != '/' or std.mem.indexOfScalar(u8, cwd, 0) != null or std.mem.eql(u8, cwd, self.cwd.items)) return;
        self.cwd.ensureTotalCapacity(self.gpa, cwd.len) catch return;
        self.cwd.clearRetainingCapacity();
        self.cwd.appendSliceAssumeCapacity(cwd);
        self.metadata_version +%= 1;
        self.refreshMetadataLocked(true);
    }

    fn statusCallback(_: vt.GhosttyTerminal, userdata: ?*anyopaque, report: [*c]const vt.GhosttyTerminalProgramStatus) callconv(.c) void {
        const self: *Pane = @ptrCast(@alignCast(userdata orelse return));
        self.reported = switch (report.*.state) {
            vt.GHOSTTY_PROGRAM_STATUS_STATE_WORKING => .working,
            vt.GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED => .blocked,
            vt.GHOSTTY_PROGRAM_STATUS_STATE_DONE => .done,
            vt.GHOSTTY_PROGRAM_STATUS_STATE_ERROR => .@"error",
            vt.GHOSTTY_PROGRAM_STATUS_STATE_IDLE => .idle,
            else => null,
        };
        self.refreshMetadataLocked(false);
    }

    /// The pane as watchers see it, copied into `arena`.
    pub fn info(self: *Pane, arena: Allocator) !wire.PaneInfo {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.infoLocked(arena);
    }

    /// `info` for a caller holding the mutex (it does not re-enter).
    fn infoLocked(self: *Pane, arena: Allocator) !wire.PaneInfo {
        return .{
            .id = try arena.dupe(u8, &self.id),
            .pid = self.pid,
            .title = try arena.dupe(u8, self.title.items),
            .cwd = try arena.dupe(u8, self.cwd.items),
            .home = try arena.dupe(u8, self.home),
            .program = try arena.dupe(u8, self.program.items),
            .shell = try arena.dupe(u8, self.shell),
            .fullscreen = self.fullscreen,
            .status = self.status,
        };
    }

    /// Refreshes terminal metadata and status without process syscalls, including
    /// from parser callbacks. `changed` includes prior process metadata changes;
    /// the caller holds the mutex and only schedules notification here.
    fn refreshMetadataLocked(self: *Pane, changed: bool) void {
        const now = sys.nowMillis();
        var dirty = changed;

        const title = self.terminal.title();
        if (!std.mem.eql(u8, title, self.title.items)) {
            self.title.clearRetainingCapacity();
            self.title.appendSlice(self.gpa, title) catch {};
            dirty = true;
        }
        const fullscreen = self.terminal.isAlternateScreen();
        if (fullscreen != self.fullscreen) {
            self.fullscreen = fullscreen;
            dirty = true;
        }
        const status: wire.Status = if (self.reported) |r| r else blk: {
            // A command printing within the last couple of seconds is
            // working. Full-screen programs redraw all the time, so only
            // what they report counts for them.
            const printing = now - self.last_output < 2000;
            break :blk if (self.program.items.len > 0 and !self.fullscreen and printing) .working else .idle;
        };
        if (status != self.status) {
            self.status = status;
            dirty = true;
        }
        if (dirty) if (self.on_change) |f| f(self.ctx);
    }

    /// Applies a sampled foreground under the mutex. Reports stay with the
    /// cached program and are discarded when discovery finds a different one.
    fn updateForegroundLocked(self: *Pane, fg: foreground.Foreground) bool {
        var changed = false;
        const at_prompt = fg.pid == self.pid and std.mem.eql(u8, fg.program, self.shell);
        const program: []const u8 = if (at_prompt) "" else fg.program;
        // A failed name query in the same process group is not a switch.
        const switched = self.foreground_pid != fg.pid or
            (fg.program.len > 0 and !std.mem.eql(u8, program, self.program.items));
        self.foreground_pid = fg.pid;
        if (switched and self.shell_command.items.len == 0) {
            self.program.clearRetainingCapacity();
            self.program.appendSlice(self.gpa, program) catch {};
            // A report belongs to the program that made it.
            self.reported = null;
            changed = true;
        }
        if (fg.cwd.len > 0 and !std.mem.eql(u8, fg.cwd, self.cwd.items)) {
            self.cwd.clearRetainingCapacity();
            self.cwd.appendSlice(self.gpa, fg.cwd) catch {};
            changed = true;
        }
        return changed;
    }

    /// Coalesces input/output into a near-term sample, no more than once per
    /// 100 ms. A burst cannot keep postponing its first sample indefinitely.
    /// Returns whether input needs to wake a reader currently in an idle poll.
    fn activityLocked(self: *Pane, now: i64) bool {
        self.metadata_version +%= 1;
        if (self.refresh_due != null) return false;
        self.refresh_due = @max(now + 35, self.last_refresh + 100);
        return true;
    }

    /// Idle discovery remains 500 ms; only pending activity shortens the wait.
    /// The caller holds `mutex`.
    fn pollTimeoutLocked(self: *Pane, now: i64) c_int {
        var due = self.refresh_due orelse (self.last_refresh + 500);
        // Held input watches for the program taking the terminal.
        if (self.input_hold_until) |until| if (self.held_input.items.len > 0) {
            due = @min(due, @min(until, now + 20));
        };
        return @intCast(@max(0, @min(500, due - now)));
    }

    /// Runs only on the reader: destroy joins it before closing the descriptor.
    /// Process discovery may block, so run it outside `mutex`, then reject a
    /// sample invalidated by input/output, OSC cwd, close or a foreground switch.
    fn refresh(self: *Pane) void {
        self.mutex.lock();
        const now = sys.nowMillis();
        if (self.pollTimeoutLocked(now) != 0 or self.closing.load(.acquire)) {
            self.refreshMetadataLocked(false);
            self.mutex.unlock();
            return;
        }
        const version = self.metadata_version;
        self.last_refresh = now;
        self.refresh_due = null;
        self.mutex.unlock();

        var fg_buf: [foreground.Foreground.buffer_size]u8 = undefined;
        const sampled = foreground.Foreground.of(self.master, &fg_buf);
        const current_pid = c.tcgetpgrp(self.master);

        self.mutex.lock();
        defer self.mutex.unlock();
        if (sampled) |fg| {
            if (fg.pid == current_pid) {
                if (self.beforeExec(fg, server_name)) {
                    // The child still carries the server's image: not a program
                    // yet. Look again as soon as it has become the shell.
                    self.refresh_due = sys.nowMillis() + 20;
                } else {
                    self.applyForegroundLocked(version, fg);
                }
            } else {
                // A foreground switch during discovery is activity too.
                _ = self.activityLocked(sys.nowMillis());
            }
        }
        self.refreshMetadataLocked(false);
    }

    /// Applies the shell integration's reports in `chunk`, with `mutex`
    /// held: OSC 7502 `cmd=NAME` as a command starts, and OSC 133 A or D as
    /// the prompt returns. A sequence split across chunks is ignored.
    fn scanShellReports(self: *Pane, chunk: []const u8) void {
        var rest = chunk;
        while (std.mem.indexOf(u8, rest, "\x1b]")) |at| {
            const body = rest[at + 2 ..];
            const stop = std.mem.indexOfAny(u8, body, "\x07\x1b") orelse return;
            const osc = body[0..stop];
            if (std.mem.startsWith(u8, osc, "7502;cmd=")) {
                self.setShellCommandLocked(osc["7502;cmd=".len..]);
            } else if (std.mem.eql(u8, osc, "133;A") or std.mem.startsWith(u8, osc, "133;D")) {
                self.setShellCommandLocked("");
            }
            rest = body[stop..];
        }
    }

    /// The shell's word for what runs becomes the program, or the prompt
    /// returns with an empty name; the caller holds `mutex`.
    fn setShellCommandLocked(self: *Pane, name: []const u8) void {
        const clean = name[0..@min(name.len, 64)];
        for (clean) |b| if (b < 0x20 or b == 0x7f) return;
        if (std.mem.eql(u8, clean, self.shell_command.items)) return;
        self.shell_command.clearRetainingCapacity();
        self.shell_command.appendSlice(self.gpa, clean) catch return;
        self.program.clearRetainingCapacity();
        self.program.appendSlice(self.gpa, clean) catch {};
        self.reported = null;
        self.metadata_version +%= 1;
        self.refreshMetadataLocked(true);
    }

    /// Whether a sample caught the pane's own child between fork and exec,
    /// when its arguments are still the server's (`server`, the server's
    /// program name). Such a sample must never become the pane's program.
    fn beforeExec(self: *Pane, fg: foreground.Foreground, server: []const u8) bool {
        return fg.pid == self.pid and self.program.items.len == 0 and std.mem.eql(u8, fg.program, server);
    }

    /// The server's own program name as process discovery reports it, which a
    /// forked child carries until it execs the shell. Set once at startup.
    pub var server_name: []const u8 = "koi";

    /// Commits only a still-current sample; the caller holds `mutex`.
    fn applyForegroundLocked(self: *Pane, version: u64, fg: foreground.Foreground) void {
        if (version != self.metadata_version or self.closing.load(.acquire) or self.ended.load(.acquire)) return;
        self.refreshMetadataLocked(self.updateForegroundLocked(fg));
    }

    /// A nonblocking byte coalesces arbitrary input/close events in the pipe.
    fn wake(self: *Pane) void {
        if (self.wake_pipe[1] < 0) return;
        const byte = [_]u8{1};
        while (c.write(self.wake_pipe[1], &byte, 1) < 0 and sys.errno() == c.EINTR) {}
    }

    /// Adds `transport` after sending the pane's info and snapshot. On an
    /// ended or closing pane it sends `exited` and closes the transport instead.
    pub fn attach(self: *Pane, transport: Transport, arena: Allocator) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.ended.load(.acquire) or self.closing.load(.acquire)) {
            transport.send(&wire.exitedFrame(self.exit_code));
            transport.close();
            return;
        }
        try self.clients.ensureUnusedCapacity(self.gpa, 1);
        const frame = try wire.frameJson(arena, .attached, try self.infoLocked(arena));
        transport.send(frame);
        const snap = self.terminal.snapshot() orelse return error.Snapshot;
        defer Terminal.freeSnapshot(snap);
        const f = try wire.frame(arena, .snapshot, snap);
        transport.send(f);
        self.clients.appendAssumeCapacity(transport);
    }

    pub fn detach(self: *Pane, transport: Transport) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.clients.items, 0..) |t, i| {
            if (t.ptr == transport.ptr) {
                _ = self.clients.swapRemove(i);
                return;
            }
        }
    }

    /// Types `bytes` into the shell, waiting (without the mutex) for room
    /// when a large paste fills the PTY; gives up once the pane ends.
    pub fn input(self: *Pane, bytes: []const u8) void {
        self.mutex.lock();
        if (self.input_hold_until != null) {
            self.held_input.appendSlice(self.gpa, bytes) catch {};
            self.mutex.unlock();
            self.wake();
            return;
        }
        self.mutex.unlock();
        self.writeToPty(bytes);
    }

    /// Whether the program has taken the terminal: its line editor turned
    /// off the terminal's own line editing or echo, so from here it shows
    /// what it reads itself. A shell prints banners and prompts before that.
    fn programReadsRaw(self: *Pane) bool {
        var attributes: c.struct_termios = undefined;
        if (c.tcgetattr(self.master, &attributes) != 0) return false;
        return attributes.c_lflag & (c.ICANON | c.ECHO) != (c.ICANON | c.ECHO);
    }

    /// Delivers held input once the program reads raw or the hold has run
    /// out; the caller holds `mutex`.
    fn releaseHeldInputLocked(self: *Pane, now: i64) void {
        const until = self.input_hold_until orelse return;
        if (now < until and !self.programReadsRaw()) return;
        self.input_hold_until = null;
        if (self.held_input.items.len > 0) {
            self.writePtyNow(self.held_input.items);
            self.held_input.clearRetainingCapacity();
            _ = self.activityLocked(now);
        }
    }

    /// Resizes the PTY and the terminal, then tells every client, in stream
    /// order, so each resizes at the same point in the output. An invalid
    /// grid (`GridSize.valid`) is ignored.
    pub fn resize(self: *Pane, new: wire.GridSize) void {
        if (!new.valid()) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.ended.load(.acquire) or self.closing.load(.acquire) or std.meta.eql(new, self.size)) return;
        self.size = new;
        pty.setSize(self.master, new.cols, new.rows, pixels(new.cols, new.cell_width), pixels(new.rows, new.cell_height));
        self.terminal.resize(new.cols, new.rows, new.cell_width, new.cell_height);
        var frame: [wire.header_size + 16]u8 = undefined;
        frame[0] = @backingInt(wire.Kind.resized);
        std.mem.writeInt(u32, frame[1..5], 16, .little);
        @memcpy(frame[5..], &new.encode());
        self.broadcast(&frame);
    }

    /// Binds a control/CLI report to a fresh foreground identity. Process
    /// discovery is outside both locks; a changed generation retries instead
    /// of committing stale identity. Close and rapid switches fail explicitly.
    pub fn reportStatus(self: *Pane, status: wire.Status) !void {
        for (0..3) |_| {
            self.mutex.lock();
            const version = self.metadata_version;
            const closed = self.closing.load(.acquire) or self.ended.load(.acquire);
            self.mutex.unlock();
            if (closed) return error.PaneClosed;
            var buffer: [foreground.Foreground.buffer_size]u8 = undefined;
            const sample = foreground.Foreground.of(self.master, &buffer) orelse return error.ForegroundUnavailable;
            if (sample.program.len == 0) return error.ForegroundUnavailable;
            if (sample.pid != c.tcgetpgrp(self.master)) continue;
            self.mutex.lock();
            const accepted = self.reportStatusSampleLocked(version, status, sample);
            self.mutex.unlock();
            if (try accepted) return;
        }
        return error.ForegroundChanged;
    }

    /// Accepts a verified out-of-lock sample while holding mutex. Reconcile
    /// stale cached metadata before setting the report, so discovery of this
    /// same program cannot erase it. Returns false for an invalidated sample.
    fn reportStatusSampleLocked(self: *Pane, version: u64, status: wire.Status, sample: foreground.Foreground) !bool {
        if (self.closing.load(.acquire) or self.ended.load(.acquire)) return error.PaneClosed;
        if (version != self.metadata_version) return false;
        try self.program.ensureTotalCapacity(self.gpa, sample.program.len);
        _ = self.updateForegroundLocked(sample);
        self.reported = status;
        self.metadata_version +%= 1;
        self.refreshMetadataLocked(true);
        return true;
    }

    /// Commits an engine edit and one replacement snapshot under the same lock
    /// as output/attach/resize. All fallible work precedes the swap: a failed
    /// edit leaves the authoritative terminal and every mirror unchanged.
    pub fn edit(self: *Pane, op: wire.Op, appearance: ?wire.Appearance, arena: Allocator) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.ended.load(.acquire) or self.closing.load(.acquire)) return error.PaneClosed;
        if (op == .configurePane and appearance == null) return error.MissingAppearance;
        if (appearance) |a| if (!a.valid()) return error.InvalidAppearance;
        var updated = if (op == .resetPane)
            try Terminal.init(self.size.cols, self.size.rows)
        else copy: {
            const before = self.terminal.snapshot() orelse return error.Snapshot;
            defer Terminal.freeSnapshot(before);
            break :copy Terminal.fromSnapshot(before) orelse return error.Snapshot;
        };
        errdefer updated.deinit();
        updated.defaults = self.terminal.defaults;
        updated.applyDefaults();
        switch (op) {
            .clearPane => updated.clearScrollback(),
            .resetPane => updated.resize(self.size.cols, self.size.rows, self.size.cell_width, self.size.cell_height),
            .configurePane => try updated.applyAppearance(appearance.?),
            else => return error.InvalidOperation,
        }
        const snapshot = updated.snapshot() orelse return error.Snapshot;
        defer Terminal.freeSnapshot(snapshot);
        if (snapshot.len > wire.max_payload) return error.SnapshotTooLarge;
        const frame = try wire.frame(arena, .snapshot, snapshot);
        self.terminal.deinit();
        self.terminal = updated;
        self.installCallbacks();
        if (op == .resetPane) {
            self.reported = null;
            // Reject process samples taken before reset; cwd is process-owned
            // and remains meaningful even though OSC title/pwd were cleared.
            self.metadata_version +%= 1;
        }
        self.refreshMetadataLocked(op == .resetPane);
        self.broadcast(frame);
    }

    /// `cells` of `cell` pixels each, clamped to what a window size holds.
    fn pixels(cells: u16, cell: u32) u16 {
        return @intCast(@min(@as(u64, cells) * cell, std.math.maxInt(u16)));
    }

    /// Requests asynchronous HUP and bounded escalation on the owning reader.
    /// No caller signals a PID: only the reader reaps/signals its owned child.
    pub fn kill(self: *Pane) void {
        if (self.ended.load(.acquire) or self.closing.swap(true, .acq_rel)) return;
        self.wake();
    }

    fn broadcast(self: *Pane, frame: []const u8) void {
        for (self.clients.items) |t| t.send(frame);
    }

    fn run(self: *Pane) void {
        while (!self.execution_ready.load(.acquire) and !self.closing.load(.acquire)) {
            self.mutex.lock();
            const deadline = self.release_deadline;
            self.mutex.unlock();
            const timeout: c_int = if (deadline) |due| @intCast(@max(0, @min(due - sys.nowMillis(), std.math.maxInt(c_int)))) else -1;
            var fds = [_]c.struct_pollfd{.{ .fd = self.wake_pipe[0], .events = c.POLLIN, .revents = 0 }};
            const ready = c.poll(&fds, 1, timeout);
            if (ready > 0) {
                var pending: [128]u8 = undefined;
                _ = c.read(self.wake_pipe[0], &pending, pending.len);
            } else if (ready == 0) {
                // No client attached by the deadline: start the shell as is.
                self.releaseExecution() catch {};
            }
        }
        var buf: [64 * 1024]u8 = undefined;
        var frame_buf: [wire.header_size + 64 * 1024]u8 = undefined;
        frame_buf[0] = @backingInt(wire.Kind.output);
        while (true) {
            if (self.closing.load(.acquire)) {
                self.end();
                return;
            }
            self.mutex.lock();
            self.releaseHeldInputLocked(sys.nowMillis());
            const timeout = self.pollTimeoutLocked(sys.nowMillis());
            self.mutex.unlock();
            var fds = [_]c.struct_pollfd{
                .{ .fd = self.master, .events = c.POLLIN, .revents = 0 },
                .{ .fd = self.wake_pipe[0], .events = c.POLLIN, .revents = 0 },
            };
            const ready = c.poll(&fds, fds.len, timeout);
            if (ready < 0 and sys.errno() == c.EINTR) continue;
            if (fds[1].revents & c.POLLIN != 0) {
                var wake_buf: [128]u8 = undefined;
                // One bounded drain per turn; a full pipe already wakes poll.
                _ = c.read(self.wake_pipe[0], &wake_buf, wake_buf.len);
            }
            if (self.closing.load(.acquire)) continue;
            if (ready > 0 and fds[0].revents & c.POLLIN != 0) {
                // Bound each drain so continuous output cannot starve close or
                // metadata sampling. poll immediately returns for more bytes.
                self.mutex.lock();
                const n = c.read(self.master, &buf, buf.len);
                if (n > 0) {
                    const chunk = buf[0..@intCast(n)];
                    self.last_output = sys.nowMillis();
                    _ = self.activityLocked(self.last_output);
                    self.scanShellReports(chunk);
                    self.terminal.write(chunk);
                    self.releaseHeldInputLocked(self.last_output);
                    if (self.clients.items.len > 0) {
                        std.mem.writeInt(u32, frame_buf[1..5], @intCast(chunk.len), .little);
                        @memcpy(frame_buf[5 .. 5 + chunk.len], chunk);
                        self.broadcast(frame_buf[0 .. 5 + chunk.len]);
                    }
                    self.refreshMetadataLocked(false);
                    self.mutex.unlock();
                } else {
                    const ended = n == 0 or (sys.errno() != c.EAGAIN and sys.errno() != c.EINTR);
                    self.mutex.unlock();
                    if (ended) {
                        self.end();
                        return;
                    }
                }
            } else if (ready > 0 and fds[0].revents & (c.POLLHUP | c.POLLERR | c.POLLNVAL) != 0) {
                self.end();
                return;
            }
            self.refresh();
        }
    }

    /// EOF or explicit close: remove the visible pane, reap its owned child,
    /// then notify attached clients and permit reclamation.
    /// A process that closed its terminal but ignores HUP must not pin the
    /// reader and pane forever.
    fn end(self: *Pane) void {
        self.closing.store(true, .release);
        if (self.on_close) |f| f(self.ctx, self);
        const status = reapChild(self.pid);
        self.mutex.lock();
        const signal = status & 0x7f;
        const code: i32 = if (signal != 0) 128 + signal else (status >> 8) & 0xff;
        self.exit_code = code;
        const frame = wire.exitedFrame(code);
        for (self.clients.items) |t| {
            t.send(&frame);
            t.close();
        }
        self.clients.clearRetainingCapacity();
        self.ended.store(true, .release);
        self.mutex.unlock();
    }

    /// For a pane whose reader never started: ends the child and marks the
    /// pane ended, so the server can unlink and destroy it like any other.
    pub fn abandon(self: *Pane) void {
        self.closing.store(true, .release);
        self.mutex.lock();
        self.closeExecutionGateLocked();
        self.mutex.unlock();
        if (ownsChild(self.pid)) {
            _ = c.kill(-self.pid, c.SIGKILL);
            _ = c.kill(self.pid, c.SIGKILL);
            var status: c_int = 0;
            while (c.waitpid(self.pid, &status, 0) < 0 and sys.errno() == c.EINTR) {}
        }
        self.mutex.lock();
        self.ended.store(true, .release);
        self.mutex.unlock();
    }

    pub fn pin(self: *Pane) void {
        _ = self.pins.fetchAdd(1, .acq_rel);
    }

    pub fn unpin(self: *Pane) void {
        _ = self.pins.fetchSub(1, .acq_rel);
    }

    /// Frees a pane whose shell has ended, once nothing refers to it.
    pub fn destroy(self: *Pane) void {
        if (self.thread) |t| t.join();
        if (self.execution_gate >= 0) _ = c.close(self.execution_gate);
        _ = c.close(self.master);
        for (self.wake_pipe) |fd| if (fd >= 0) {
            _ = c.close(fd);
        };
        self.terminal.deinit();
        self.clients.deinit(self.gpa);
        self.title.deinit(self.gpa);
        self.cwd.deinit(self.gpa);
        self.program.deinit(self.gpa);
        self.shell_command.deinit(self.gpa);
        self.held_input.deinit(self.gpa);
        self.gpa.free(self.shell);
        self.gpa.free(self.home);
        self.gpa.destroy(self);
    }

    /// Writes what the PTY takes right now; the rest is dropped.
    fn writePtyNow(self: *Pane, bytes: []const u8) void {
        var off: usize = 0;
        while (off < bytes.len and !self.ended.load(.acquire) and !self.closing.load(.acquire)) {
            const n = c.write(self.master, bytes.ptr + off, bytes.len - off);
            if (n > 0) {
                off += @intCast(n);
            } else if (n < 0 and sys.errno() == c.EINTR) {
                continue;
            } else return;
        }
    }

    /// Writes to the PTY, waiting for room when a large paste fills it.
    fn writeToPty(self: *Pane, bytes: []const u8) void {
        var off: usize = 0;
        while (off < bytes.len and !self.ended.load(.acquire) and !self.closing.load(.acquire)) {
            const n = c.write(self.master, bytes.ptr + off, bytes.len - off);
            if (n > 0) {
                off += @intCast(n);
                self.mutex.lock();
                const wake_reader = self.activityLocked(sys.nowMillis());
                self.mutex.unlock();
                if (wake_reader) self.wake();
                continue;
            }
            if (n < 0 and sys.errno() == c.EAGAIN) {
                var fds = [_]c.struct_pollfd{.{ .fd = self.master, .events = c.POLLOUT, .revents = 0 }};
                _ = c.poll(&fds, 1, 1000);
                continue;
            }
            if (n < 0 and sys.errno() == c.EINTR) continue;
            return;
        }
    }
};

/// Allocates the reader's wake pipe before spawning a child; both ends are
/// nonblocking and close-on-exec, and any setup failure closes both ends.
fn wakePipe() ![2]c_int {
    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) return error.Pipe;
    errdefer for (fds) |fd| {
        _ = c.close(fd);
    };
    for (fds) |fd| {
        if (c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC) < 0) return error.Pipe;
        const flags = c.fcntl(fd, c.F_GETFL);
        if (flags < 0 or c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) < 0) return error.Pipe;
    }
    return fds;
}

/// Checks child ownership without consuming an exit status. Keeping even an
/// exited leader unreaped reserves its PID/PGID through all group signals.
fn ownsChild(pid: c.pid_t) bool {
    if (pid <= 0) return false;
    var info = std.mem.zeroes(c.siginfo_t);
    while (c.waitid(@intCast(c.P_PID), @intCast(pid), &info, c.WEXITED | c.WNOHANG | c.WNOWAIT) != 0) {
        if (sys.errno() != c.EINTR) return false; // Includes ECHILD: never signal.
    }
    return true;
}

/// HUP the owned group, allow up to 250 ms, then KILL before reaping its
/// leader. The grace ends as soon as nothing in the group is left running,
/// so a shell that simply exited is reaped at once. The leader may already
/// be a zombie or exit during grace while descendants retain the PTY. Neither
/// case ends group cleanup or releases PID ownership.
fn reapChild(pid: c.pid_t) c_int {
    if (!ownsChild(pid)) return 0;
    _ = c.kill(-pid, c.SIGHUP);
    _ = c.kill(pid, c.SIGHUP);
    for (0..25) |_| {
        if (groupIdle(pid)) break;
        sys.sleepMillis(10);
    }
    if (!ownsChild(pid)) return 0;
    _ = c.kill(-pid, c.SIGKILL);
    _ = c.kill(pid, c.SIGKILL);
    var status: c_int = 0;
    while (c.waitpid(pid, &status, 0) < 0 and sys.errno() == c.EINTR) {}
    return status;
}

/// Whether every process left in the group `pgid` has exited (a zombie
/// leader awaiting us counts as exited). False whenever that cannot be
/// established, so cleanup never cuts the grace short by mistake.
fn groupIdle(pgid: c.pid_t) bool {
    if (builtin.os.tag == .macos) {
        var pids: [256]c.pid_t = undefined;
        const bytes = c.proc_listpgrppids(pgid, &pids, @sizeOf(@TypeOf(pids)));
        // A full buffer may hide a running member.
        if (bytes < 0 or bytes >= @sizeOf(@TypeOf(pids))) return false;
        for (pids[0 .. @as(usize, @intCast(bytes)) / @sizeOf(c.pid_t)]) |member| {
            var info: c.struct_proc_bsdinfo = undefined;
            const size: c_int = @sizeOf(c.struct_proc_bsdinfo);
            if (c.proc_pidinfo(member, c.PROC_PIDTBSDINFO, 0, &info, size) != size) continue; // gone
            if (info.pbi_status != c.SZOMB) return false;
        }
        return true;
    }
    const dir = c.opendir("/proc") orelse return false;
    defer _ = c.closedir(dir);
    while (c.readdir(dir)) |entry| {
        const name = std.mem.sliceTo(&entry.*.d_name, 0);
        const member = std.fmt.parseInt(c.pid_t, name, 10) catch continue;
        var path: [64]u8 = undefined;
        const p = std.fmt.bufPrintSentinel(&path, "/proc/{d}/stat", .{member}, 0) catch continue;
        const fd = c.open(p.ptr, c.O_RDONLY);
        if (fd < 0) continue;
        defer _ = c.close(fd);
        var stat: [1024]u8 = undefined;
        const n = c.read(fd, &stat, stat.len);
        if (n <= 0) continue;
        // "pid (comm) state ppid pgrp ..."; comm may itself hold spaces or ')'.
        const text = stat[0..@intCast(n)];
        const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse continue;
        var fields = std.mem.tokenizeScalar(u8, text[close + 1 ..], ' ');
        const state = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const group = std.fmt.parseInt(c.pid_t, fields.next() orelse continue, 10) catch continue;
        if (group == pgid and state[0] != 'Z' and state[0] != 'X') return false;
    }
    return true;
}

test "a child that exits on its own is reaped without waiting out the hangup grace" {
    const pid = c.fork();
    try std.testing.expect(pid >= 0);
    if (pid == 0) c._exit(7);
    var info = std.mem.zeroes(c.siginfo_t);
    while (c.waitid(@intCast(c.P_PID), @intCast(pid), &info, c.WEXITED | c.WNOWAIT) < 0) {
        if (sys.errno() != c.EINTR) return error.Wait;
    }
    const started = sys.nowMillis();
    try std.testing.expectEqual(@as(c_int, 7 << 8), reapChild(pid));
    try std.testing.expect(sys.nowMillis() - started < 150);
    try std.testing.expect(!ownsChild(pid));
}

/// A private PTY group with a HUP-ignoring descendant. Two readiness records
/// ensure both processes are configured before close. The descendant alone
/// holds `alive` open; `release` EOF lets cleanup stop it even if reaping fails.
fn testReapProcessGroup(already_exited: bool) !void {
    var ready: [2]c_int = .{ -1, -1 };
    try std.testing.expectEqual(0, c.pipe(&ready));
    defer for (ready) |fd| if (fd >= 0) {
        _ = c.close(fd);
    };
    var release: [2]c_int = .{ -1, -1 };
    try std.testing.expectEqual(0, c.pipe(&release));
    defer for (release) |fd| if (fd >= 0) {
        _ = c.close(fd);
    };
    var alive: [2]c_int = .{ -1, -1 };
    try std.testing.expectEqual(0, c.pipe(&alive));
    defer for (alive) |fd| if (fd >= 0) {
        _ = c.close(fd);
    };
    var master: c_int = -1;
    const leader = c.forkpty(&master, null, null, null);
    try std.testing.expect(leader >= 0);
    if (leader == 0) {
        _ = c.close(ready[0]);
        _ = c.close(release[1]);
        _ = c.close(alive[0]);
        // Inherit ignored HUP before forking: even immediate session-leader
        // exit cannot kill the descendant before it reports readiness.
        sys.ignoreSignal(c.SIGHUP);
        const descendant = c.fork();
        if (descendant < 0) c._exit(127);
        if (descendant == 0) {
            const pid = c.getpid();
            _ = c.write(ready[1], &pid, @sizeOf(c.pid_t));
            _ = c.close(ready[1]);
            var byte: [1]u8 = undefined;
            while (true) {
                const n = c.read(release[0], &byte, 1);
                if (n == 0) c._exit(0);
                if (n < 0 and sys.errno() != c.EINTR) c._exit(1);
            }
        }
        _ = c.close(release[0]);
        _ = c.close(alive[1]);
        if (!already_exited) sys.defaultSignal(c.SIGHUP);
        _ = c.write(ready[1], &descendant, @sizeOf(c.pid_t));
        _ = c.close(ready[1]);
        if (already_exited) c._exit(23);
        while (true) _ = c.pause();
    }
    defer _ = c.close(master);
    _ = c.close(ready[1]);
    ready[1] = -1;
    _ = c.close(release[0]);
    release[0] = -1;
    _ = c.close(alive[1]);
    alive[1] = -1;
    defer {
        // EOF is a cleanup escape hatch independent of the code under test.
        _ = c.close(release[1]);
        release[1] = -1;
        _ = reapChild(leader);
        var fds = [_]c.struct_pollfd{.{ .fd = alive[0], .events = c.POLLIN, .revents = 0 }};
        _ = c.poll(&fds, 1, 2000);
    }
    var pids: [2]c.pid_t = undefined;
    const bytes = std.mem.asBytes(&pids);
    var at: usize = 0;
    while (at < bytes.len) {
        var fds = [_]c.struct_pollfd{.{ .fd = ready[0], .events = c.POLLIN, .revents = 0 }};
        try std.testing.expect(c.poll(&fds, 1, 2000) > 0);
        const n = c.read(ready[0], bytes.ptr + at, bytes.len - at);
        try std.testing.expect(n > 0);
        at += @intCast(n);
    }
    try std.testing.expectEqual(pids[0], pids[1]);
    if (already_exited) {
        // Wait for leader exit without allowing PID/PGID reuse before close.
        var info = std.mem.zeroes(c.siginfo_t);
        while (c.waitid(@intCast(c.P_PID), @intCast(leader), &info, c.WEXITED | c.WNOWAIT) < 0) {
            if (sys.errno() != c.EINTR) return error.Wait;
        }
    }
    var fds = [_]c.struct_pollfd{.{ .fd = alive[0], .events = c.POLLIN, .revents = 0 }};
    try std.testing.expectEqual(@as(c_int, 0), c.poll(&fds, 1, 0));
    const started = sys.nowMillis();
    const status = reapChild(leader);
    if (already_exited) {
        try std.testing.expectEqual(@as(c_int, 23 << 8), status);
    } else {
        try std.testing.expectEqual(@as(c_int, c.SIGHUP), status & 0x7f);
    }
    // The release writer remains open: only termination closes the descendant's
    // alive writer. A surviving HUP-ignoring descendant would time out here.
    try std.testing.expect(c.poll(&fds, 1, 2000) > 0);
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 0), c.read(alive[0], &byte, 1));
    try std.testing.expect(sys.nowMillis() - started < 5000);
    try std.testing.expect(!ownsChild(leader));
}

test "process-group close kills descendants of an already-exited unreaped leader" {
    try testReapProcessGroup(true);
}

test "process-group close kills descendants when their leader exits on HUP" {
    try testReapProcessGroup(false);
}

extern var environ: [*:null]?[*:0]u8;

/// The shell's environment: ours, with the terminal's identity, `koi` on
/// the PATH, `extra` added, and, when the app carries the shell integration
/// (`integration`, its directory), zsh and fish arranged to load it: zsh by
/// starting in Koi's ZDOTDIR, which restores the user's own, and fish by a
/// vendor configuration directory on XDG_DATA_DIRS. Claude Code's session markers are dropped:
/// the server is long-lived and may have been started from inside an agent
/// session, and a shell that inherits them makes every `claude` launched in
/// it think it is a nested child session (no transcripts, no hooks). Only
/// the markers go; settings such as `CLAUDE_CONFIG_DIR` or
/// `CLAUDE_CODE_USE_BEDROCK` are the user's and stay.
fn environment(arena: Allocator, extra: []const []const u8, inherited: [*:null]const ?[*:0]const u8, shell: []const u8, integration: ?[]const u8) ![*:null]?[*:0]const u8 {
    var list: std.ArrayList(?[*:0]const u8) = .empty;
    const overridden = [_][]const u8{
        "TERM=",                 "COLORTERM=",            "TERM_PROGRAM=",         "KOI_TAB=",
        "KOI_PANE=",             "KOI_BIN_DIR=",          "PATH=",                 "ZDOTDIR=",
        "KOI_ZDOTDIR=",          "XDG_DATA_DIRS=",        "KOI_SHELL_INTEGRATION=",
        // What a running Claude Code session puts in its children's environment.
        "CLAUDECODE=",           "CLAUDE_PID=",           "CLAUDE_EFFORT=",        "CLAUDE_CODE_ENTRYPOINT=",
        "CLAUDE_CODE_EXECPATH=", "CLAUDE_CODE_SESSION",   "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_MESSAGING_",
    };
    var path: []const u8 = "/usr/bin:/bin:/usr/sbin:/sbin";
    var has_lang = false;
    var zdotdir: ?[]const u8 = null;
    var data_dirs: ?[]const u8 = null;
    var i: usize = 0;
    while (inherited[i]) |entry| : (i += 1) {
        const e = std.mem.span(entry);
        if (std.mem.startsWith(u8, e, "PATH=")) path = e[5..];
        if (std.mem.startsWith(u8, e, "LANG=")) has_lang = true;
        if (std.mem.startsWith(u8, e, "ZDOTDIR=")) zdotdir = e["ZDOTDIR=".len..];
        if (std.mem.startsWith(u8, e, "XDG_DATA_DIRS=")) data_dirs = e["XDG_DATA_DIRS=".len..];
        var skip = false;
        for (overridden) |o| if (std.mem.startsWith(u8, e, o)) {
            skip = true;
        };
        if (!skip) try list.append(arena, entry);
    }
    try list.append(arena, "TERM=xterm-256color");
    try list.append(arena, "COLORTERM=truecolor");
    try list.append(arena, "TERM_PROGRAM=Koi");
    if (!has_lang) try list.append(arena, "LANG=en_US.UTF-8");
    // The shell always gets a PATH, with `koi` in front when the binary's
    // directory is known.
    if (selfDirectory(arena)) |dir| {
        try list.append(arena, try std.fmt.allocPrintSentinel(arena, "KOI_BIN_DIR={s}", .{dir}, 0));
        try list.append(arena, try std.fmt.allocPrintSentinel(arena, "PATH={s}:{s}", .{ dir, path }, 0));
    } else {
        try list.append(arena, try std.fmt.allocPrintSentinel(arena, "PATH={s}", .{path}, 0));
    }
    if (integration) |dir| {
        try list.append(arena, try std.fmt.allocPrintSentinel(arena, "KOI_SHELL_INTEGRATION={s}", .{dir}, 0));
        if (std.mem.eql(u8, shell, "zsh")) {
            try list.append(arena, try std.fmt.allocPrintSentinel(arena, "ZDOTDIR={s}/zsh", .{dir}, 0));
            if (zdotdir) |own| try list.append(arena, try std.fmt.allocPrintSentinel(arena, "KOI_ZDOTDIR={s}", .{own}, 0));
            zdotdir = null;
        } else if (std.mem.eql(u8, shell, "fish")) {
            try list.append(arena, try std.fmt.allocPrintSentinel(arena, "XDG_DATA_DIRS={s}/fish:{s}", .{ dir, data_dirs orelse "/usr/local/share:/usr/share" }, 0));
            data_dirs = null;
        }
    }
    if (zdotdir) |own| try list.append(arena, try std.fmt.allocPrintSentinel(arena, "ZDOTDIR={s}", .{own}, 0));
    if (data_dirs) |own| try list.append(arena, try std.fmt.allocPrintSentinel(arena, "XDG_DATA_DIRS={s}", .{own}, 0));
    for (extra) |e| try list.append(arena, try arena.dupeSentinel(u8, e, 0));
    const out = try arena.allocSentinel(?[*:0]const u8, list.items.len, null);
    @memcpy(out, list.items);
    return out;
}

/// The directory of the running binary, where `koi` is.
pub fn selfDirectory(arena: Allocator) ?[]const u8 {
    const path = sys.selfPath(arena) catch return null;
    return std.fs.path.dirname(path);
}

/// The shell integration files the app bundle carries beside this binary,
/// or null when run from elsewhere (tests, a remote install).
fn integrationDirectory(arena: Allocator) ?[]const u8 {
    const dir = selfDirectory(arena) orelse return null;
    const shell = std.fmt.allocPrintSentinel(arena, "{s}/shell", .{dir}, 0) catch return null;
    if (c.access(shell.ptr, c.F_OK) != 0) return null;
    return shell;
}

test "shell environment drops Claude Code session markers but keeps its settings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A fabricated inheritance: changing the test process's own environment
    // would also change what the standard library scans for stderr.
    const markers = [_][]const u8{ "CLAUDE_CODE_CHILD_SESSION=1", "CLAUDECODE=1", "CLAUDE_CODE_ENTRYPOINT=cli", "CLAUDE_CODE_SESSION_ID=s", "CLAUDE_CODE_MESSAGING_SOCKET=/s", "CLAUDE_PID=1" };
    const settings = [_][]const u8{ "CLAUDE_CONFIG_DIR=/cfg", "CLAUDE_CODE_USE_BEDROCK=1", "HOME=/tmp" };
    const inherited = [_:null]?[*:0]const u8{
        "CLAUDE_CODE_CHILD_SESSION=1", "CLAUDECODE=1",            "CLAUDE_CODE_ENTRYPOINT=cli", "CLAUDE_CODE_SESSION_ID=s",
        "CLAUDE_CODE_MESSAGING_SOCKET=/s", "CLAUDE_PID=1",        "CLAUDE_CONFIG_DIR=/cfg",     "CLAUDE_CODE_USE_BEDROCK=1",
        "HOME=/tmp",                   "PATH=/usr/bin:/bin",      "TERM=dumb",
    };
    const envp = try environment(arena, &.{}, &inherited, "zsh", null);
    var i: usize = 0;
    var saw_term = false;
    var saw_path = false;
    var kept: usize = 0;
    while (envp[i]) |entry| : (i += 1) {
        const e = std.mem.span(entry);
        for (markers) |marker| try std.testing.expect(!std.mem.eql(u8, e, marker));
        for (settings) |setting| if (std.mem.eql(u8, e, setting)) {
            kept += 1;
        };
        if (std.mem.eql(u8, e, "TERM_PROGRAM=Koi")) saw_term = true;
        if (std.mem.startsWith(u8, e, "PATH=") and std.mem.endsWith(u8, e, ":/usr/bin:/bin")) saw_path = true;
    }
    try std.testing.expect(saw_term);
    try std.testing.expect(saw_path);
    try std.testing.expectEqual(settings.len, kept);
}

test "shells the app carries integration for start with it; others keep their own directories" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const inherited = [_:null]?[*:0]const u8{ "HOME=/tmp", "ZDOTDIR=/home/u/.config/zsh", "XDG_DATA_DIRS=/opt/share" };
    const cases = [_]struct { shell: []const u8, integration: ?[]const u8, expect: []const []const u8, absent: []const []const u8 }{
        .{ .shell = "zsh", .integration = "/app/shell", .expect = &.{ "KOI_SHELL_INTEGRATION=/app/shell", "ZDOTDIR=/app/shell/zsh", "KOI_ZDOTDIR=/home/u/.config/zsh", "XDG_DATA_DIRS=/opt/share" }, .absent = &.{"ZDOTDIR=/home/u/.config/zsh"} },
        .{ .shell = "fish", .integration = "/app/shell", .expect = &.{ "XDG_DATA_DIRS=/app/shell/fish:/opt/share", "ZDOTDIR=/home/u/.config/zsh" }, .absent = &.{"KOI_ZDOTDIR=/home/u/.config/zsh"} },
        .{ .shell = "bash", .integration = "/app/shell", .expect = &.{ "KOI_SHELL_INTEGRATION=/app/shell", "ZDOTDIR=/home/u/.config/zsh", "XDG_DATA_DIRS=/opt/share" }, .absent = &.{"ZDOTDIR=/app/shell/zsh"} },
        .{ .shell = "zsh", .integration = null, .expect = &.{ "ZDOTDIR=/home/u/.config/zsh", "XDG_DATA_DIRS=/opt/share" }, .absent = &.{ "KOI_SHELL_INTEGRATION=/app/shell", "ZDOTDIR=/app/shell/zsh" } },
    };
    for (cases) |case| {
        const envp = try environment(arena, &.{}, &inherited, case.shell, case.integration);
        for (case.expect) |want| {
            var found = false;
            var i: usize = 0;
            while (envp[i]) |entry| : (i += 1) if (std.mem.eql(u8, std.mem.span(entry), want)) {
                found = true;
            };
            try std.testing.expect(found);
        }
        for (case.absent) |unwanted| {
            var i: usize = 0;
            while (envp[i]) |entry| : (i += 1) try std.testing.expect(!std.mem.eql(u8, std.mem.span(entry), unwanted));
        }
    }
}

test "pixel sizes clamp instead of overflowing" {
    try std.testing.expectEqual(@as(u16, 65535), Pane.pixels(65535, 4_000_000_000));
    try std.testing.expectEqual(@as(u16, 640), Pane.pixels(80, 8));
}

test "a grid past the protocol bound is refused before any shell starts" {
    const huge = wire.GridSize{ .cols = 65535, .rows = 65535, .cell_width = 8, .cell_height = 16 };
    try std.testing.expectError(error.InvalidSize, Pane.create(std.testing.allocator, "hugepane".*, huge, "/tmp", &.{}, null, null));
    const zero = wire.GridSize{ .cols = 0, .rows = 24, .cell_width = 8, .cell_height = 16 };
    try std.testing.expectError(error.InvalidSize, Pane.create(std.testing.allocator, "zeropane".*, zero, "/tmp", &.{}, null, null));
}

test "a terminal reply to a PTY nobody reads is dropped, not waited for" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(0, c.pipe(&fds));
    defer _ = c.close(fds[0]);
    defer _ = c.close(fds[1]);
    _ = c.fcntl(fds[1], c.F_SETFL, c.fcntl(fds[1], c.F_GETFL) | c.O_NONBLOCK);
    var pane: Pane = undefined;
    pane.master = fds[1];
    pane.ended = .init(false);
    pane.closing = .init(false);
    const reply: [4096]u8 = @splat('x');
    // Far more than a pipe holds: a blocking write would never return.
    for (0..100) |_| pane.writePtyNow(&reply);
}

/// A terminal and metadata without a PTY or child. Callers install callbacks
/// after placing it at its final address and free the terminal and lists.
fn testMetadataPane() !Pane {
    return .{
        .gpa = std.testing.allocator,
        .id = "metadata".*,
        .pid = 100,
        .master = -1,
        .terminal = try Terminal.init(80, 24),
        .mutex = sys.Mutex.init(),
        .size = .{ .cols = 80, .rows = 24, .cell_width = 8, .cell_height = 16 },
        .shell = "zsh",
        .home = "/tmp",
    };
}

test "metadata input wakes once per pending sample and keeps the idle fallback" {
    var pane = try testMetadataPane();
    defer pane.terminal.deinit();
    pane.wake_pipe = try wakePipe();
    defer for (pane.wake_pipe) |fd| {
        _ = c.close(fd);
    };
    var input_pipe: [2]c_int = undefined;
    try std.testing.expectEqual(0, c.pipe(&input_pipe));
    defer for (input_pipe) |fd| {
        _ = c.close(fd);
    };
    pane.master = input_pipe[1];
    const now = sys.nowMillis();
    pane.last_refresh = now;
    try std.testing.expectEqual(@as(c_int, 500), pane.pollTimeoutLocked(now));
    pane.input("x"); // No PTY output is needed to interrupt the reader's poll.
    var fds = [_]c.struct_pollfd{.{ .fd = pane.wake_pipe[0], .events = c.POLLIN, .revents = 0 }};
    try std.testing.expectEqual(@as(c_int, 1), c.poll(&fds, 1, 0));
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 1), c.read(pane.wake_pipe[0], &byte, 1));
    const due = pane.refresh_due.?;
    for (0..20) |_| pane.input("x");
    try std.testing.expectEqual(due, pane.refresh_due.?);
    try std.testing.expectEqual(@as(c_int, 0), c.poll(&fds, 1, 0));
    try std.testing.expect(due >= now + 100 and due < now + 500);

    // Model the completed sample and another burst using a fixed clock.
    pane.last_refresh = 1000;
    pane.refresh_due = null;
    try std.testing.expect(pane.activityLocked(1010));
    try std.testing.expectEqual(@as(?i64, 1100), pane.refresh_due);
    for (1011..1099) |tick| try std.testing.expect(!pane.activityLocked(@intCast(tick)));
    try std.testing.expectEqual(@as(c_int, 0), pane.pollTimeoutLocked(1100));
    pane.last_refresh = 1100;
    pane.refresh_due = null;
    try std.testing.expectEqual(@as(c_int, 500), pane.pollTimeoutLocked(1100));
    try std.testing.expect(pane.activityLocked(1300));
    try std.testing.expectEqual(@as(?i64, 1335), pane.refresh_due);
}

test "metadata discovery rejects input-invalidated and closing samples" {
    var pane = try testMetadataPane();
    defer pane.terminal.deinit();
    defer pane.program.deinit(pane.gpa);
    defer pane.cwd.deinit(pane.gpa);
    const fg = foreground.Foreground{ .pid = 200, .program = "worker", .cwd = "/tmp/work" };
    const stale = pane.metadata_version;
    _ = pane.activityLocked(1000);
    pane.applyForegroundLocked(stale, fg);
    try std.testing.expectEqualStrings("", pane.program.items);
    pane.applyForegroundLocked(pane.metadata_version, fg);
    try std.testing.expectEqualStrings("worker", pane.program.items);
    pane.kill();
    pane.applyForegroundLocked(pane.metadata_version, .{ .pid = pane.pid, .program = "sh", .cwd = "/other" });
    try std.testing.expectEqualStrings("worker", pane.program.items);
    try std.testing.expectEqualStrings("/tmp/work", pane.cwd.items);
    try std.testing.expect(!pane.ended.load(.acquire));
}

test "the shell's own report names the program until its prompt returns" {
    var pane = try testMetadataPane();
    defer pane.terminal.deinit();
    defer pane.program.deinit(pane.gpa);
    defer pane.cwd.deinit(pane.gpa);
    defer pane.shell_command.deinit(pane.gpa);
    pane.scanShellReports("\x1b]133;C\x07\x1b]7502;cmd=make\x07output");
    try std.testing.expectEqualStrings("make", pane.program.items);
    // Discovery sees make's child; the header keeps what the user ran.
    pane.applyForegroundLocked(pane.metadata_version, .{ .pid = 200, .program = "cc", .cwd = "/tmp/work" });
    try std.testing.expectEqualStrings("make", pane.program.items);
    try std.testing.expectEqualStrings("/tmp/work", pane.cwd.items);
    pane.scanShellReports("\x1b]133;D;0\x07\x1b]133;A\x07");
    try std.testing.expectEqualStrings("", pane.program.items);
    pane.applyForegroundLocked(pane.metadata_version, .{ .pid = 300, .program = "vim", .cwd = "/tmp/work" });
    try std.testing.expectEqualStrings("vim", pane.program.items);
    // Control bytes and a split sequence never become a name.
    pane.scanShellReports("\x1b]7502;cmd=bad\x01name\x07\x1b]7502;cmd=cut");
    try std.testing.expectEqualStrings("vim", pane.program.items);
}

test "a sample of the child before exec is never the pane's program" {
    var pane = try testMetadataPane();
    defer pane.terminal.deinit();
    defer pane.program.deinit(pane.gpa);
    defer pane.cwd.deinit(pane.gpa);
    pane.pid = 300;
    const forked = foreground.Foreground{ .pid = 300, .program = "koi", .cwd = "/tmp" };
    try std.testing.expect(pane.beforeExec(forked, "koi"));
    try std.testing.expect(!pane.beforeExec(.{ .pid = 300, .program = "zsh", .cwd = "/tmp" }, "koi"));
    try std.testing.expect(!pane.beforeExec(.{ .pid = 301, .program = "koi", .cwd = "/tmp" }, "koi"));
    // A program really named like the server, run from the shell, still counts.
    pane.applyForegroundLocked(pane.metadata_version, .{ .pid = 300, .program = "vim", .cwd = "/tmp" });
    try std.testing.expect(!pane.beforeExec(forked, "koi"));
}

/// Checks both reader exit paths against a private HUP-ignoring child.
/// Visible removal precedes teardown; `ended` guarantees reaping is complete.
fn testReaderClose(eof: bool) !void {
    var pane = try testMetadataPane();
    defer pane.terminal.deinit();
    defer pane.clients.deinit(pane.gpa);
    defer pane.title.deinit(pane.gpa);
    defer pane.cwd.deinit(pane.gpa);
    defer pane.program.deinit(pane.gpa);
    pane.wake_pipe = try wakePipe();
    defer for (pane.wake_pipe) |fd| {
        _ = c.close(fd);
    };
    var ready: [2]c_int = undefined;
    try std.testing.expectEqual(0, c.pipe(&ready));
    defer _ = c.close(ready[0]);
    var master: c_int = -1;
    const pid = c.forkpty(&master, null, null, null);
    try std.testing.expect(pid >= 0);
    if (pid == 0) {
        _ = c.close(ready[0]);
        sys.ignoreSignal(c.SIGHUP);
        const byte = [_]u8{1};
        _ = c.write(ready[1], &byte, 1);
        _ = c.close(ready[1]);
        if (eof) for (0..3) |fd| {
            _ = c.close(@intCast(fd));
        };
        while (true) _ = c.pause();
    }
    _ = c.close(ready[1]);
    defer _ = c.close(master);
    pane.master = master;
    pane.pid = pid;
    var started = false;
    defer {
        if (started) {
            pane.kill();
            pane.thread.?.join();
        } else pane.abandon();
    }
    _ = c.fcntl(master, c.F_SETFL, c.fcntl(master, c.F_GETFL) | c.O_NONBLOCK);
    var fds = [_]c.struct_pollfd{.{ .fd = ready[0], .events = c.POLLIN, .revents = 0 }};
    try std.testing.expect(c.poll(&fds, 1, 2000) > 0);
    pane.installCallbacks();
    var removed_before_reaping = std.atomic.Value(bool).init(false);
    const Close = struct {
        fn notify(ctx: *anyopaque, closing_pane: *Pane) void {
            const flag: *std.atomic.Value(bool) = @ptrCast(@alignCast(ctx));
            flag.store(closing_pane.closing.load(.acquire) and !closing_pane.ended.load(.acquire) and ownsChild(closing_pane.pid), .release);
        }
    };
    pane.ctx = &removed_before_reaping;
    pane.on_close = &Close.notify;
    try pane.start();
    started = true;
    if (!eof) {
        pane.kill();
        pane.kill();
    }
    const deadline = sys.nowMillis() + 5000;
    while (!pane.ended.load(.acquire) and sys.nowMillis() < deadline) sys.sleepMillis(10);
    try std.testing.expect(pane.ended.load(.acquire));
    try std.testing.expect(removed_before_reaping.load(.acquire));
    try std.testing.expectEqual(@as(i32, 128 + c.SIGKILL), pane.exit_code);
    var status: c_int = 0;
    try std.testing.expectEqual(@as(c.pid_t, -1), c.waitpid(pid, &status, c.WNOHANG));
    try std.testing.expectEqual(@as(c_int, c.ECHILD), sys.errno());
}

test "explicit close reaps a HUP-ignoring child while its PTY remains open" {
    try testReaderClose(false);
}

test "PTY EOF removes the pane before waiting for child cleanup" {
    try testReaderClose(true);
}

test "title cwd and status callbacks update immediately without advancing process discovery" {
    var pane = try testMetadataPane();
    defer pane.terminal.deinit();
    defer pane.title.deinit(pane.gpa);
    defer pane.cwd.deinit(pane.gpa);
    defer pane.program.deinit(pane.gpa);
    try pane.program.appendSlice(pane.gpa, "worker");
    pane.last_refresh = 1;
    pane.installCallbacks();

    pane.terminal.write("\x1b]2;ready\x07");
    try std.testing.expectEqualStrings("ready", pane.title.items);
    try std.testing.expectEqual(@as(i64, 1), pane.last_refresh);

    pane.terminal.write("\x1b]7;file://localhost/tmp/my%20work\x07");
    try std.testing.expectEqualStrings("/tmp/my work", pane.cwd.items);
    try std.testing.expectEqual(@as(i64, 1), pane.last_refresh);

    pane.terminal.write("\x1b]7501;state=blocked\x07");
    try std.testing.expectEqual(wire.Status.blocked, pane.status);
    try std.testing.expectEqual(@as(?wire.Status, .blocked), pane.reported);
    try std.testing.expectEqualStrings("worker", pane.program.items);
    try std.testing.expectEqual(@as(i64, 1), pane.last_refresh);

    pane.terminal.write("\x1b]7501;state=clear\x07");
    try std.testing.expect(pane.reported == null);
    try std.testing.expectEqual(wire.Status.idle, pane.status);
}

test "foreground discovery retains reports for cwd changes and clears them for a new program" {
    var pane = try testMetadataPane();
    defer pane.terminal.deinit();
    defer pane.title.deinit(pane.gpa);
    defer pane.cwd.deinit(pane.gpa);
    defer pane.program.deinit(pane.gpa);
    try pane.program.appendSlice(pane.gpa, "worker");
    pane.foreground_pid = 200;
    pane.reported = .blocked;

    const moved = pane.updateForegroundLocked(.{ .pid = 200, .program = "worker", .cwd = "/tmp/work" });
    pane.refreshMetadataLocked(moved);
    try std.testing.expectEqualStrings("/tmp/work", pane.cwd.items);
    try std.testing.expectEqual(wire.Status.blocked, pane.status);
    try std.testing.expectEqual(@as(?wire.Status, .blocked), pane.reported);

    pane.last_output = sys.nowMillis();
    const replaced = pane.updateForegroundLocked(.{ .pid = 300, .program = "other", .cwd = "" });
    pane.refreshMetadataLocked(replaced);
    try std.testing.expect(pane.reported == null);
    try std.testing.expectEqual(wire.Status.working, pane.status);
    try std.testing.expectEqualStrings("/tmp/work", pane.cwd.items);

    pane.terminal.write("\x1b[?1049h");
    pane.refreshMetadataLocked(false);
    try std.testing.expectEqual(wire.Status.idle, pane.status);
    pane.reported = .done;
    pane.refreshMetadataLocked(false);
    try std.testing.expectEqual(wire.Status.done, pane.status);

    const prompt = pane.updateForegroundLocked(.{ .pid = pane.pid, .program = "zsh", .cwd = "/tmp" });
    pane.refreshMetadataLocked(prompt);
    try std.testing.expect(pane.reported == null);
    try std.testing.expectEqualStrings("", pane.program.items);
    try std.testing.expectEqual(wire.Status.idle, pane.status);
}

/// A transport that records what it was sent and whether it was closed.
const Recorder = struct {
    sent: std.ArrayList(u8) = .empty,
    closed: bool = false,
    var vtable = Transport.VTable{ .send = send, .read = read, .close = close };
    fn send(ptr: *anyopaque, bytes: []const u8) void {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
        self.sent.appendSlice(std.testing.allocator, bytes) catch {};
    }
    fn read(_: *anyopaque, _: []u8) usize {
        return 0;
    }
    fn close(ptr: *anyopaque) void {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
        self.closed = true;
    }
};

test "attaching to an ended pane gets exited and a closed transport" {
    var pane = try Pane.create(std.testing.allocator, "testpane".*, .{ .cols = 80, .rows = 24, .cell_width = 8, .cell_height = 16 }, "/tmp", &.{}, null, null);
    try pane.start();
    try pane.releaseExecution();
    pane.kill();
    while (!pane.ended.load(.acquire)) sys.sleepMillis(10);
    // Input, resize and kill on an ended pane are no-ops.
    pane.input("echo hi\r");
    pane.resize(.{ .cols = 100, .rows = 30, .cell_width = 8, .cell_height = 16 });
    pane.kill();
    try std.testing.expectEqual(@as(u16, 80), pane.size.cols);

    var rec = Recorder{};
    defer rec.sent.deinit(std.testing.allocator);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try pane.attach(.{ .ptr = &rec, .vtable = &Recorder.vtable }, arena_state.allocator());
    try std.testing.expectEqual(@as(usize, wire.header_size + 4), rec.sent.items.len);
    try std.testing.expectEqual(@backingInt(wire.Kind.exited), rec.sent.items[0]);
    try std.testing.expect(rec.closed);
    try std.testing.expectEqual(@as(usize, 0), pane.clients.items.len);
    pane.destroy();
}

/// Frees only the fields owned by a shell-less engine fixture.
fn freeMetadataPane(pane: *Pane) void {
    pane.terminal.deinit();
    pane.clients.deinit(pane.gpa);
    pane.title.deinit(pane.gpa);
    pane.cwd.deinit(pane.gpa);
    pane.program.deinit(pane.gpa);
}

test "clear snapshots preserve active screen modes and unfinished parser input" {
    var pane = try testMetadataPane();
    defer freeMetadataPane(&pane);
    pane.installCallbacks();
    for (0..100) |_| pane.terminal.write("old history\r\n");
    pane.terminal.write("visible\x1b[?2004h\x1b]2;unfinished");
    var rec = Recorder{};
    defer rec.sent.deinit(std.testing.allocator);
    try pane.clients.append(pane.gpa, .{ .ptr = &rec, .vtable = &Recorder.vtable });
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try pane.edit(.clearPane, null, arena_state.allocator());
    var frames = wire.FrameReader.init(std.testing.allocator);
    defer frames.deinit();
    try frames.append(rec.sent.items);
    const frame = (try frames.next()).?;
    try std.testing.expectEqual(wire.Kind.snapshot, frame.kind);
    var mirror = Terminal.fromSnapshot(frame.payload) orelse return error.Snapshot;
    defer mirror.deinit();
    pane.terminal.write(" title\x07after-clear");
    mirror.write(" title\x07after-clear");
    try std.testing.expectEqualStrings("unfinished title", pane.terminal.title());
    try std.testing.expectEqualStrings(pane.terminal.title(), mirror.title());
    const actual = pane.terminal.text() orelse return error.NoText;
    defer Terminal.freeSnapshot(actual);
    const replay = mirror.text() orelse return error.NoText;
    defer Terminal.freeSnapshot(replay);
    try std.testing.expectEqualStrings(actual, replay);
    try std.testing.expect(std.mem.indexOf(u8, actual, "visibleafter-clear") != null);
    var bar: vt.GhosttyTerminalScrollbar = undefined;
    try std.testing.expectEqual(vt.GHOSTTY_SUCCESS, vt.ghostty_terminal_get(pane.terminal.raw, vt.GHOSTTY_TERMINAL_DATA_SCROLLBAR, &bar));
    try std.testing.expectEqual(bar.len, bar.total);
    var mode = vt.GhosttyTerminalModeConfig{ .mode = vt.ghostty_mode_new(2004, false), .value = false };
    _ = vt.ghostty_terminal_get(mirror.raw, vt.GHOSTTY_TERMINAL_DATA_MODE, &mode);
    try std.testing.expect(mode.value);
    // Tracking survives repeated snapshots even while the parser is unfinished.
    mirror.write("\x1b]2;still pending");
    const again = mirror.snapshot() orelse return error.Snapshot;
    defer Terminal.freeSnapshot(again);
}

test "reset replaces parser and alternate screen with the same configured defaults on every mirror" {
    var pane = try testMetadataPane();
    defer freeMetadataPane(&pane);
    pane.installCallbacks();
    var first = Recorder{};
    defer first.sent.deinit(std.testing.allocator);
    var second = Recorder{};
    defer second.sent.deinit(std.testing.allocator);
    try pane.clients.append(pane.gpa, .{ .ptr = &first, .vtable = &Recorder.vtable });
    try pane.clients.append(pane.gpa, .{ .ptr = &second, .vtable = &Recorder.vtable });
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try pane.edit(.configurePane, .{ .foreground = "123456", .background = "789abc", .cursor = "abcdef", .scrollbackMB = 1 }, arena);
    pane.terminal.write("\x1b]10;#ff0000\x07\x1b[?1049h\x1b[?2004h\x1b]2;pending");
    first.sent.clearRetainingCapacity();
    second.sent.clearRetainingCapacity();
    try pane.edit(.resetPane, null, arena);
    try std.testing.expectEqualSlices(u8, first.sent.items, second.sent.items);
    var frames = wire.FrameReader.init(std.testing.allocator);
    defer frames.deinit();
    try frames.append(first.sent.items);
    const frame = (try frames.next()).?;
    try std.testing.expectEqual(wire.Kind.snapshot, frame.kind);
    try std.testing.expect((try frames.next()) == null);
    var mirror = Terminal.fromSnapshot(frame.payload) orelse return error.Snapshot;
    defer mirror.deinit();
    try std.testing.expect(!mirror.isAlternateScreen());
    var mode = vt.GhosttyTerminalModeConfig{ .mode = vt.ghostty_mode_new(2004, false), .value = true };
    _ = vt.ghostty_terminal_get(mirror.raw, vt.GHOSTTY_TERMINAL_DATA_MODE, &mode);
    try std.testing.expect(!mode.value);
    var color: vt.GhosttyColorRgb = undefined;
    _ = vt.ghostty_terminal_get(mirror.raw, vt.GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND, &color);
    try std.testing.expectEqual(@as(u8, 0x12), color.r);
    try std.testing.expectEqual(@as(u8, 0x34), color.g);
    try std.testing.expectEqual(@as(u8, 0x56), color.b);
    try std.testing.expectEqual(@as(usize, 1 << 20), pane.terminal.defaults.scrollback);
    pane.terminal.write("after-reset");
    mirror.write("after-reset");
    const actual = pane.terminal.text() orelse return error.NoText;
    defer Terminal.freeSnapshot(actual);
    const replay = mirror.text() orelse return error.NoText;
    defer Terminal.freeSnapshot(replay);
    try std.testing.expectEqualStrings(actual, replay);
    try std.testing.expectEqualStrings("after-reset", actual);
    // Invalid configuration commits neither engine state nor a snapshot.
    const sent = first.sent.items.len;
    try std.testing.expectError(error.InvalidAppearance, pane.edit(.configurePane, .{ .cursor = "bad" }, arena));
    try std.testing.expectEqual(sent, first.sent.items.len);
}

test "startup shell source preserves quoted arguments pipelines and cwd on a real PTY" {
    const command = "printf '<%s>\\n' 'two words'; printf '%s' 'a b' | tr ' ' '_'; printf '\\n'; pwd -P; exec /bin/cat";
    var pane = try Pane.create(std.testing.allocator, "startup1".*, .{ .cols = 80, .rows = 24, .cell_width = 8, .cell_height = 16 }, "/", &.{}, command, .{ .foreground = "123456" });
    defer pane.destroy();
    try pane.start();
    try pane.releaseExecution();
    defer {
        pane.kill();
        while (!pane.ended.load(.acquire)) sys.sleepMillis(10);
    }
    var matched = false;
    for (0..500) |_| {
        pane.mutex.lock();
        if (pane.terminal.text()) |text| {
            matched = std.mem.indexOf(u8, text, "<two words>\na_b\n/") != null;
            Terminal.freeSnapshot(text);
        }
        pane.mutex.unlock();
        if (matched) break;
        sys.sleepMillis(10);
    }
    try std.testing.expect(matched);
    try std.testing.expectError(error.InvalidStartup, Pane.create(std.testing.allocator, "startup2".*, pane.size, "/", &.{}, "", null));
    try std.testing.expectError(error.InvalidStartup, Pane.create(std.testing.allocator, "startup3".*, pane.size, "/", &.{}, "echo\x00bad", null));
}

test "configurePane color queries use new defaults and retain program overrides until reset" {
    var pane = try testMetadataPane();
    defer freeMetadataPane(&pane);
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(0, c.pipe(&fds));
    defer for (fds) |fd| {
        _ = c.close(fd);
    };
    _ = c.fcntl(fds[0], c.F_SETFL, c.O_NONBLOCK);
    pane.master = fds[1];
    pane.installCallbacks();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try pane.edit(.configurePane, .{ .foreground = "123456", .background = "789abc", .cursor = "abcdef", .scrollbackMB = 64 }, arena);
    pane.terminal.write("\x1b]10;?\x1b\\\x1b]11;?\x1b\\\x1b]12;?\x1b\\");
    var buf: [256]u8 = undefined;
    const n = c.read(fds[0], &buf, buf.len);
    try std.testing.expect(n > 0);
    try std.testing.expectEqualStrings("\x1b]10;rgb:1212/3434/5656\x1b\\\x1b]11;rgb:7878/9a9a/bcbc\x1b\\\x1b]12;rgb:abab/cdcd/efef\x1b\\", buf[0..@intCast(n)]);
    pane.terminal.write("\x1b]10;#ff0000\x07");
    try pane.edit(.configurePane, .{ .foreground = "111111" }, arena);
    var fg: vt.GhosttyColorRgb = undefined;
    _ = vt.ghostty_terminal_get(pane.terminal.raw, vt.GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND, &fg);
    try std.testing.expectEqual(@as(u8, 255), fg.r);
    try std.testing.expectEqual(@as(u8, 0), fg.g);
    try pane.edit(.resetPane, null, arena);
    _ = vt.ghostty_terminal_get(pane.terminal.raw, vt.GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND, &fg);
    try std.testing.expectEqual(@as(u8, 0x11), fg.r);
}

test "control status binds uncached foreground and survives discovery until a real switch" {
    var pane = try testMetadataPane();
    defer freeMetadataPane(&pane);
    _ = pane.updateForegroundLocked(.{ .pid = 200, .program = "old", .cwd = "/tmp" });
    const actual = foreground.Foreground{ .pid = 300, .program = "worker", .cwd = "/tmp" };
    const stale = pane.metadata_version;
    try std.testing.expect(try pane.reportStatusSampleLocked(stale, .blocked, actual));
    try std.testing.expectEqualStrings("worker", pane.program.items);
    pane.applyForegroundLocked(pane.metadata_version, actual);
    try std.testing.expectEqual(@as(?wire.Status, .blocked), pane.reported);
    try std.testing.expectEqual(wire.Status.blocked, pane.status);
    pane.applyForegroundLocked(pane.metadata_version, .{ .pid = actual.pid, .program = "", .cwd = "/tmp" });
    try std.testing.expectEqual(@as(?wire.Status, .blocked), pane.reported);
    try std.testing.expect(!try pane.reportStatusSampleLocked(stale, .done, .{ .pid = 200, .program = "old", .cwd = "/tmp" }));
    try std.testing.expectEqual(@as(?wire.Status, .blocked), pane.reported);
    // A different process running the same executable is still a switch.
    pane.applyForegroundLocked(pane.metadata_version, .{ .pid = 301, .program = "worker", .cwd = "/tmp" });
    try std.testing.expect(pane.reported == null);
    // Startup exec can keep the original shell PID but replace its program.
    const startup = foreground.Foreground{ .pid = pane.pid, .program = "cat", .cwd = "/tmp" };
    try std.testing.expect(try pane.reportStatusSampleLocked(pane.metadata_version, .done, startup));
    pane.applyForegroundLocked(pane.metadata_version, startup);
    try std.testing.expectEqualStrings("cat", pane.program.items);
    try std.testing.expectEqual(@as(?wire.Status, .done), pane.reported);
    pane.applyForegroundLocked(pane.metadata_version, .{ .pid = pane.pid, .program = pane.shell, .cwd = "/tmp" });
    try std.testing.expect(pane.reported == null);
}
