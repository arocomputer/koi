//! One shell on one PTY, with the headless terminal that mirrors it and the
//! clients attached to it. A reader thread copies the PTY's output into the
//! terminal and to every client, in order, so the snapshot a client gets
//! and the bytes that follow it always agree. The same thread polls what
//! runs in front and its directory.
const std = @import("std");
const builtin = @import("builtin");
const sys = @import("sys.zig");
const c = sys.c;
const vt = sys.c;
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
    /// With a monotonic deadline (ms), the reader opens the gate at that time
    /// unless a client attaches first; see deferExecution. Guarded by `mutex`.
    release_deadline: ?i64 = null,
    terminal: Terminal,
    mutex: sys.Mutex,
    clients: std.ArrayList(Client) = .empty,
    owner: ?*anyopaque = null,
    /// Creator's temporary command proof, consumed by the first actual owner.
    creationController: ?[]u8 = null,
    /// Another client claimed the pane over its creator's reservation: from
    /// then on, only a current owner may close or edit it.
    reservationRevoked: bool = false,
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
    agent: @import("agent.zig").Agent = .{},
    output_active: bool = false,
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
    /// reads cooked input gets it after `input_hold_ms` anyway. The reader
    /// retains unwritten bytes after the hold expires. Guarded by `mutex`;
    /// a full queue applies backpressure to input callers.
    held_input: std.ArrayList(u8) = .empty,
    /// Up to 4096 contiguous input ranges, tagged only for negotiated clients;
    /// null is legacy or server input and survives another client's revocation.
    held_segments: std.ArrayList(HeldSegment) = .empty,
    input_hold_until: ?i64 = null,
    input_hold_ms: i64 = 2000,
    /// Serializes whole input calls across queue waits and direct PTY writes.
    /// The reader never takes this lock; callers take it before `mutex`.
    input_mutex: sys.Mutex = undefined,
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

    const max_held_input = 64 * 1024;

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
            .agent = @import("agent.zig").Agent.init(),
            .gpa = gpa,
            .id = id,
            .pid = spawned.pid,
            .master = spawned.master,
            .execution_gate = spawned.execution_gate,
            .execution_ready = .init(false),
            .wake_pipe = wake_pipe,
            .terminal = terminal,
            .mutex = sys.Mutex.init(),
            .input_mutex = sys.Mutex.init(),
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
        if (self.input_hold_until != null) self.input_hold_until = sys.elapsedMillis() + self.input_hold_ms;
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
    /// or until `deadline` (monotonic ms), when the reader releases it anyway.
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
        const unknown: vt.GhosttyTerminalUnknownSequenceFn = &shellCommandCallback;
        var limit: usize = 1024;
        self.terminal.setOption(vt.GHOSTTY_TERMINAL_OPT_UNKNOWN_MAX_BYTES, &limit);
        self.terminal.setOption(vt.GHOSTTY_TERMINAL_OPT_UNKNOWN_SEQUENCE, @ptrCast(unknown));
        const prompt: vt.GhosttyTerminalSemanticPromptFn = &promptCallback;
        self.terminal.setOption(vt.GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT, @ptrCast(prompt));
    }

    fn writePtyCallback(_: vt.GhosttyTerminal, userdata: ?*anyopaque, data: [*c]const u8, len: usize) callconv(.c) void {
        const self: *Pane = @ptrCast(@alignCast(userdata orelse return));
        // Runs inside `terminal.write` with `mutex` held: never wait here. A
        // reply the program is not reading for is dropped, not waited for.
        _ = self.writePtyNow(data[0..len]);
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
            .program = try arena.dupe(u8, if (self.agent.active) self.agent.name.get() else self.program.items),
            .shell = try arena.dupe(u8, self.shell),
            .fullscreen = self.fullscreen,
            .status = self.status,
            .statusSource = if (self.agent.active) "agent" else if (self.reported != null) "reported" else null,
            .outputActive = self.output_active,
            .agent = try self.agent.session(arena),
            .agentEpoch = if (self.agent.epoch) |epoch| try arena.dupe(u8, &epoch) else null,
            .agentSequence = self.agent.sequence,
            .agentEvents = try self.agent.history(arena),
        };
    }

    /// Refreshes terminal metadata and status without process syscalls, including
    /// from parser callbacks. `changed` includes prior process metadata changes;
    /// the caller holds the mutex and only schedules notification here.
    fn refreshMetadataLocked(self: *Pane, changed: bool) void {
        const now = sys.elapsedMillis();
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
        const output_active = self.last_output > 0 and now - self.last_output < 2000;
        if (output_active != self.output_active) {
            self.output_active = output_active;
            dirty = true;
        }
        const status: wire.Status = if (self.agent.active) self.agent.status else self.reported orelse .idle;
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
        if (self.foreground_pid != fg.pid or at_prompt) self.agent.invalidate();
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
        const now = sys.elapsedMillis();
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
                    self.refresh_due = sys.elapsedMillis() + 20;
                } else {
                    self.applyForegroundLocked(version, fg);
                }
            } else {
                // A foreground switch during discovery is activity too.
                _ = self.activityLocked(sys.elapsedMillis());
            }
        }
        self.refreshMetadataLocked(false);
    }

    /// The engine owns framing across PTY reads, cancellation and terminators.
    /// Only complete bounded OSC 7502 reports can name the foreground program.
    fn shellCommandCallback(_: vt.GhosttyTerminal, userdata: ?*anyopaque, sequence: [*c]const vt.GhosttyTerminalUnknownSequence) callconv(.c) void {
        const self: *Pane = @ptrCast(@alignCast(userdata orelse return));
        if (sequence.*.tag != vt.GHOSTTY_TERMINAL_UNKNOWN_SEQUENCE_OSC) return;
        const osc = sequence.*.value.osc;
        if (osc.truncated or osc.content.ptr == null) return;
        const content = osc.content.ptr[0..osc.content.len];
        if (std.mem.startsWith(u8, content, "7502;cmd=")) self.setShellCommandLocked(content["7502;cmd=".len..]);
    }

    /// A completed command or primary prompt releases shell-reported identity.
    /// Secondary/continuation prompts do not end a running command.
    fn promptCallback(_: vt.GhosttyTerminal, userdata: ?*anyopaque, event: [*c]const vt.GhosttyTerminalSemanticPrompt) callconv(.c) void {
        const self: *Pane = @ptrCast(@alignCast(userdata orelse return));
        if (event.*.kind == vt.GHOSTTY_SEMANTIC_PROMPT_COMMAND_END or
            (event.*.kind == vt.GHOSTTY_SEMANTIC_PROMPT_PROMPT_START and
                event.*.prompt_kind == vt.GHOSTTY_SEMANTIC_PROMPT_PROMPT_PRIMARY)) self.setShellCommandLocked("");
    }

    /// The shell's word for what runs becomes the program, or the prompt
    /// returns with an empty name; the caller holds `mutex`.
    fn setShellCommandLocked(self: *Pane, name: []const u8) void {
        if (name.len > 64 or !std.unicode.utf8ValidateSlice(name)) return;
        const clean = name;
        for (clean) |b| if (b < 0x20 or b == 0x7f) return;
        if (clean.len == 0) self.agent.invalidate();
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

    const Client = struct { transport: Transport, negotiated: bool = false, controller: ?[]u8 = null };
    const HeldSegment = struct { len: usize, owner: ?*anyopaque };

    /// Reserve an unpublished pane for its creator; the pane owns the copy.
    pub fn reserveCreation(self: *Pane, controller: ?[]const u8) !void {
        const id = controller orelse return;
        if (!wire.validController(id)) return error.InvalidController;
        self.creationController = try self.gpa.dupe(u8, id);
    }

    /// Assign an interactive owner and permanently consume creation authority.
    /// `controller` is the new owner's, null for a legacy client. The caller
    /// holds the pane mutex.
    fn assignOwnerLocked(self: *Pane, owner: *anyopaque, controller: ?[]const u8) void {
        if (self.creationController) |id| {
            const creator = if (controller) |c_id| std.mem.eql(u8, c_id, id) else false;
            if (!creator) self.reservationRevoked = true;
            self.gpa.free(id);
        }
        self.creationController = null;
        self.owner = owner;
    }

    /// Adds `transport` after sending the pane's info and snapshot. On an
    /// ended or closing pane it sends `exited` and closes the transport instead.
    pub fn attach(self: *Pane, transport: Transport, arena: Allocator, request: wire.OpenRequest) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (request.controller) |id| if (!wire.validController(id)) return error.InvalidController;
        if (self.ended.load(.acquire) or self.closing.load(.acquire)) {
            transport.send(&wire.exitedFrame(self.exit_code));
            transport.close();
            return;
        }
        try self.clients.ensureUnusedCapacity(self.gpa, 1);
        const controller = if (request.paneControl) if (request.controller) |id| try self.gpa.dupe(u8, id) else null else null;
        errdefer if (controller) |id| self.gpa.free(id);
        const frame = try wire.frameJson(arena, .attached, try self.infoLocked(arena));
        transport.send(frame);
        const snap = self.terminal.snapshot() orelse return error.Snapshot;
        defer Terminal.freeSnapshot(snap);
        const f = try wire.frame(arena, .snapshot, snap);
        transport.send(f);
        self.clients.appendAssumeCapacity(.{ .transport = transport, .negotiated = request.paneControl, .controller = controller });
        // A negotiated interactive view may attach before layout; claiming an
        // unowned pane does not require a placeholder resize. Legacy zero-grid
        // CLI watchers remain passive.
        if (!request.observer and (self.owner == null or self.reconnectsOwnerLocked(controller)) and
            (request.paneControl or (request.cols > 0 and request.rows > 0)))
        {
            self.assignOwnerLocked(transport.ptr, controller);
            self.resizeLocked(.{ .cols = request.cols, .rows = request.rows, .cell_width = request.cellWidth, .cell_height = request.cellHeight });
        }
        self.notifyOwnershipLocked();
    }

    /// Whether `controller` is the current owner's own, reattaching on a new
    /// connection before the server has noticed the old one is gone (a relay
    /// that outlives its network). It takes over rather than observing itself.
    /// The old connection's held input stays queued in order.
    fn reconnectsOwnerLocked(self: *Pane, controller: ?[]const u8) bool {
        const id = controller orelse return false;
        const owner = self.owner orelse return false;
        for (self.clients.items) |client| {
            if (client.transport.ptr == owner and client.negotiated) {
                const current = client.controller orelse return false;
                return std.mem.eql(u8, current, id);
            }
        }
        return false;
    }

    pub fn detach(self: *Pane, transport: Transport) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.clients.items, 0..) |client, i| {
            if (client.transport.ptr == transport.ptr) {
                _ = self.clients.swapRemove(i);
                if (client.controller) |id| self.gpa.free(id);
                if (self.owner == transport.ptr) {
                    self.owner = null;
                    if (client.negotiated) self.discardHeldLocked(transport.ptr);
                    self.notifyOwnershipLocked();
                }
                return;
            }
        }
    }

    /// Explicitly transfers or releases ownership; never promotes another client.
    pub fn control(self: *Pane, transport: Transport, claim: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.clients.items) |client| {
            if (client.transport.ptr == transport.ptr and client.negotiated) {
                if (claim) {
                    if (self.owner != transport.ptr) if (self.owner) |previous| self.discardHeldLocked(previous);
                    self.assignOwnerLocked(transport.ptr, client.controller);
                } else if (self.owner == transport.ptr) {
                    self.owner = null;
                    self.discardHeldLocked(transport.ptr);
                }
                self.notifyOwnershipLocked();
                return;
            }
        }
    }

    /// Checks client permissions while holding the pane mutex.
    fn canActLocked(self: *Pane, transport: Transport) bool {
        for (self.clients.items) |client| {
            if (client.transport.ptr == transport.ptr) return !client.negotiated or self.owner == transport.ptr;
        }
        return false;
    }

    /// Checks the current owner or an unclaimed creation reservation. Null is
    /// the intentional legacy command path; caller holds the pane mutex. A pane
    /// nobody controls (not opened since a relaunch, or its owner left) is
    /// anyone's to close or edit, unless its reservation was taken over.
    pub fn ownsControllerLocked(self: *Pane, controller: ?[]const u8) bool {
        const proof = controller orelse return true;
        if (!wire.validController(proof)) return false;
        const owner = self.owner orelse {
            const creator = self.creationController orelse return !self.reservationRevoked;
            return std.mem.eql(u8, creator, proof);
        };
        for (self.clients.items) |client| {
            if (client.transport.ptr == owner and client.negotiated) {
                const id = client.controller orelse return false;
                return std.mem.eql(u8, id, proof);
            }
        }
        return false;
    }

    /// Removes only a revoked negotiated client's held ranges, preserving order.
    fn discardHeldLocked(self: *Pane, owner: *anyopaque) void {
        var read: usize = 0;
        var write: usize = 0;
        var kept: usize = 0;
        for (self.held_segments.items) |segment| {
            if (segment.owner != owner) {
                std.mem.copyForwards(u8, self.held_input.items[write..][0..segment.len], self.held_input.items[read..][0..segment.len]);
                write += segment.len;
                self.held_segments.items[kept] = segment;
                kept += 1;
            }
            read += segment.len;
        }
        self.held_input.items.len = write;
        self.held_segments.items.len = kept;
    }

    /// Sends ownership only to clients that negotiated the extension.
    fn notifyOwnershipLocked(self: *Pane) void {
        for (self.clients.items) |client| {
            if (!client.negotiated) continue;
            const frame = [6]u8{ @backingInt(wire.Kind.ownership), 1, 0, 0, 0, if (self.owner == client.transport.ptr) 1 else 0 };
            client.transport.send(&frame);
        }
    }

    /// Resizes only for the current owner, under the same lock as transfers.
    pub fn resizeFrom(self: *Pane, transport: Transport, size: wire.GridSize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!size.valid()) return;
        if (self.owner == null) {
            // Old interactive clients cannot send an explicit claim. A resize
            // may reacquire an unowned pane, but never displace its current owner.
            for (self.clients.items) |client| {
                if (client.transport.ptr == transport.ptr and !client.negotiated) {
                    self.assignOwnerLocked(transport.ptr, null);
                    self.notifyOwnershipLocked();
                    break;
                }
            }
        }
        if (self.owner == transport.ptr) self.resizeLocked(size);
    }

    /// Types `bytes` in call order, waiting without the pane mutex when the
    /// startup queue or PTY fills. Close cancels blocked input callers.
    pub fn input(self: *Pane, bytes: []const u8) void {
        self.inputFromClient(null, bytes);
    }

    /// Accepts client input only while the client has permission to send it.
    pub fn inputFrom(self: *Pane, transport: Transport, bytes: []const u8) void {
        self.inputFromClient(transport, bytes);
    }

    /// Rechecks permission after every queue wait, retaining ownership tags
    /// until bytes reach the PTY or their negotiated owner is revoked.
    fn inputFromClient(self: *Pane, transport: ?Transport, bytes: []const u8) void {
        self.input_mutex.lock();
        defer self.input_mutex.unlock();
        var off: usize = 0;
        while (off < bytes.len) {
            self.mutex.lock();
            if (self.closing.load(.acquire) or self.ended.load(.acquire)) {
                self.mutex.unlock();
                return;
            }
            if (transport) |client| {
                if (!self.canActLocked(client)) {
                    self.mutex.unlock();
                    return;
                }
            }
            if (self.input_hold_until == null and self.held_input.items.len == 0) {
                self.mutex.unlock();
                self.writeToPty(transport, bytes[off..]);
                return;
            }
            var source: ?*anyopaque = null;
            if (transport) |client| for (self.clients.items) |entry| {
                if (entry.transport.ptr == client.ptr and entry.negotiated) source = client.ptr;
            };
            const last = if (self.held_segments.items.len > 0) &self.held_segments.items[self.held_segments.items.len - 1] else null;
            const merge = if (last) |segment| segment.owner == source else false;
            const count = @min(bytes.len - off, max_held_input - self.held_input.items.len);
            if (count > 0 and (merge or self.held_segments.items.len < 4096)) {
                if (!merge) self.held_segments.ensureUnusedCapacity(self.gpa, 1) catch {
                    self.mutex.unlock();
                    self.wake();
                    sys.sleepMillis(10);
                    continue;
                };
                self.held_input.appendSlice(self.gpa, bytes[off .. off + count]) catch {
                    // Keep the caller's bytes alive until the queue drains or
                    // startup ends and they can be written without allocation.
                    self.mutex.unlock();
                    self.wake();
                    sys.sleepMillis(10);
                    continue;
                };
                if (merge) last.?.len += count else self.held_segments.appendAssumeCapacity(.{ .len = count, .owner = source });
                off += count;
            }
            self.mutex.unlock();
            self.wake();
            if (off < bytes.len) sys.sleepMillis(10);
        }
    }

    /// Requests a close only if the attached client currently has permission.
    pub fn killFrom(self: *Pane, transport: Transport) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.canActLocked(transport)) self.kill();
    }

    /// Whether the program has taken the terminal: its line editor turned
    /// off the terminal's own line editing or echo, so from here it shows
    /// what it reads itself. A shell prints banners and prompts before that.
    fn programReadsRaw(self: *Pane) bool {
        var attributes: c.struct_termios = undefined;
        if (c.tcgetattr(self.master, &attributes) != 0) return false;
        return attributes.c_lflag & (c.ICANON | c.ECHO) != (c.ICANON | c.ECHO);
    }

    /// Makes nonblocking progress after exec and startup readiness. Retains
    /// unwritten bytes and ownership tags for POLLOUT; caller holds `mutex`.
    fn releaseHeldInputLocked(self: *Pane, now: i64) void {
        if (!self.execution_ready.load(.acquire) or self.closing.load(.acquire) or self.ended.load(.acquire)) return;
        if (self.input_hold_until) |until| {
            if (now < until and !self.programReadsRaw()) return;
            self.input_hold_until = null;
        }
        if (self.held_input.items.len > 0) {
            const n = self.writePtyNow(self.held_input.items);
            if (n > 0) {
                const remaining = self.held_input.items.len - n;
                std.mem.copyForwards(u8, self.held_input.items[0..remaining], self.held_input.items[n..]);
                self.held_input.items.len = remaining;
                var consumed = n;
                var removed: usize = 0;
                for (self.held_segments.items) |*segment| {
                    if (consumed < segment.len) {
                        segment.len -= consumed;
                        break;
                    }
                    consumed -= segment.len;
                    removed += 1;
                }
                const segments = self.held_segments.items;
                std.mem.copyForwards(HeldSegment, segments[0 .. segments.len - removed], segments[removed..]);
                self.held_segments.items.len -= removed;
                _ = self.activityLocked(now);
            }
        }
    }

    /// Resizes the PTY and the terminal, then tells every client, in stream
    /// order, so each resizes at the same point in the output. An invalid
    /// grid (`GridSize.valid`) is ignored.
    pub fn resize(self: *Pane, new: wire.GridSize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.resizeLocked(new);
    }

    fn resizeLocked(self: *Pane, new: wire.GridSize) void {
        if (!new.valid()) return;
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

    /// Explicit role declaration, bound to a fresh foreground process, never an argv guess.
    pub fn reportAgent(self: *Pane, name: []const u8, adapter: ?[]const u8, session: ?[]const u8, turn: ?[]const u8, status: wire.Status) !void {
        for (0..3) |_| {
            self.mutex.lock();
            const version = self.metadata_version;
            self.mutex.unlock();
            var buffer: [foreground.Foreground.buffer_size]u8 = undefined;
            const sample = foreground.Foreground.of(self.master, &buffer) orelse return error.ForegroundUnavailable;
            if (sample.pid != c.tcgetpgrp(self.master)) continue;
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.closing.load(.acquire) or self.ended.load(.acquire)) return error.PaneClosed;
            if (version != self.metadata_version) continue;
            if (sample.pid == self.pid and std.mem.eql(u8, sample.program, self.shell) and self.shell_command.items.len == 0) return error.NoForegroundAgent;
            _ = self.updateForegroundLocked(sample);
            try self.agent.report(sample.pid, name, adapter, session, turn, status);
            self.metadata_version +%= 1;
            self.refreshMetadataLocked(true);
            return;
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
    /// as output/attach/resize. All fallible work precedes the commit: a failed
    /// edit leaves the authoritative terminal and every mirror unchanged.
    /// Non-reset edits retain the live parser and its embedder callbacks.
    pub fn edit(self: *Pane, op: wire.Op, appearance: ?wire.Appearance, arena: Allocator) !void {
        return self.editOwned(op, appearance, arena, null);
    }

    /// Applies an edit only while its optional controller still owns the pane.
    pub fn editOwned(self: *Pane, op: wire.Op, appearance: ?wire.Appearance, arena: Allocator, controller: ?[]const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.ownsControllerLocked(controller)) return error.NOTOWNER;
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
        defer updated.deinit();
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
        switch (op) {
            .clearPane => self.terminal.clearScrollback(),
            .configurePane => self.terminal.applyAppearance(appearance.?) catch unreachable,
            .resetPane => {
                std.mem.swap(Terminal, &self.terminal, &updated);
                self.installCallbacks();
            },
            else => unreachable,
        }
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
        for (self.clients.items) |client| client.transport.send(frame);
    }

    fn run(self: *Pane) void {
        while (!self.execution_ready.load(.acquire) and !self.closing.load(.acquire)) {
            self.mutex.lock();
            const deadline = self.release_deadline;
            self.mutex.unlock();
            const timeout: c_int = if (deadline) |due| @intCast(@max(0, @min(due - sys.elapsedMillis(), std.math.maxInt(c_int)))) else -1;
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
            self.releaseHeldInputLocked(sys.elapsedMillis());
            const timeout = self.pollTimeoutLocked(sys.elapsedMillis());
            const pending_input = self.input_hold_until == null and self.held_input.items.len > 0;
            self.mutex.unlock();
            var fds = [_]c.struct_pollfd{
                .{ .fd = self.master, .events = @intCast(if (pending_input) c.POLLIN | c.POLLOUT else c.POLLIN), .revents = 0 },
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
                    self.last_output = sys.elapsedMillis();
                    _ = self.activityLocked(self.last_output);
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
        for (self.clients.items) |client| {
            client.transport.send(&frame);
            client.transport.close();
            if (client.controller) |id| self.gpa.free(id);
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
        if (self.creationController) |id| self.gpa.free(id);
        for (self.clients.items) |client| if (client.controller) |id| self.gpa.free(id);
        self.clients.deinit(self.gpa);
        self.title.deinit(self.gpa);
        self.cwd.deinit(self.gpa);
        self.program.deinit(self.gpa);
        self.shell_command.deinit(self.gpa);
        self.held_input.deinit(self.gpa);
        self.held_segments.deinit(self.gpa);
        self.gpa.free(self.shell);
        self.gpa.free(self.home);
        self.gpa.destroy(self);
    }

    /// Returns the prefix accepted immediately. Held input retains the rest;
    /// terminal replies discard it rather than stall parsing.
    fn writePtyNow(self: *Pane, bytes: []const u8) usize {
        var off: usize = 0;
        while (off < bytes.len and !self.ended.load(.acquire) and !self.closing.load(.acquire)) {
            const n = c.write(self.master, bytes.ptr + off, bytes.len - off);
            if (n > 0) {
                off += @intCast(n);
            } else if (n < 0 and sys.errno() == c.EINTR) {
                continue;
            } else break;
        }
        return off;
    }

    /// Writes under the permission lock, waiting outside it for PTY room.
    fn writeToPty(self: *Pane, transport: ?Transport, bytes: []const u8) void {
        var off: usize = 0;
        while (off < bytes.len and !self.ended.load(.acquire) and !self.closing.load(.acquire)) {
            self.mutex.lock();
            if (transport) |client| {
                if (!self.canActLocked(client)) {
                    self.mutex.unlock();
                    return;
                }
            }
            const n = c.write(self.master, bytes.ptr + off, bytes.len - off);
            const err = if (n < 0) sys.errno() else 0;
            const wake_reader = if (n > 0) self.activityLocked(sys.elapsedMillis()) else false;
            self.mutex.unlock();
            if (n > 0) {
                off += @intCast(n);
                if (wake_reader) self.wake();
                continue;
            }
            if (n < 0 and err == c.EAGAIN) {
                var fds = [_]c.struct_pollfd{.{ .fd = self.master, .events = c.POLLOUT, .revents = 0 }};
                _ = c.poll(&fds, 1, 1000);
                continue;
            }
            if (n < 0 and err == c.EINTR) continue;
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
    const started = sys.elapsedMillis();
    try std.testing.expectEqual(@as(c_int, 7 << 8), reapChild(pid));
    try std.testing.expect(sys.elapsedMillis() - started < 150);
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
    const started = sys.elapsedMillis();
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
    try std.testing.expect(sys.elapsedMillis() - started < 5000);
    try std.testing.expect(!ownsChild(leader));
}

test "process-group close kills descendants of an already-exited unreaped leader" {
    try testReapProcessGroup(true);
}

test "process-group close kills descendants when their leader exits on HUP" {
    try testReapProcessGroup(false);
}

extern var environ: [*:null]?[*:0]u8;

/// Build a pane environment from the daemon's portable login baseline, explicitly
/// forwarded user settings, and the pane's own terminal/shell integration values.
fn environment(arena: Allocator, extra: []const []const u8, inherited: [*:null]const ?[*:0]const u8, shell: []const u8, integration: ?[]const u8) ![*:null]?[*:0]const u8 {
    var list: std.ArrayList(?[*:0]const u8) = .empty;
    const overridden = [_][]const u8{
        "TERM=",        "COLORTERM=",     "TERM_PROGRAM=",          "KOI_TAB=",
        "KOI_PANE=",    "KOI_BIN_DIR=",   "PATH=",                  "ZDOTDIR=",
        "KOI_ZDOTDIR=", "XDG_DATA_DIRS=", "KOI_SHELL_INTEGRATION=",
    };
    var forwarded: ?[]const u8 = null;
    var scan: usize = 0;
    while (inherited[scan]) |entry| : (scan += 1) {
        const value = std.mem.span(entry);
        if (std.mem.startsWith(u8, value, "KOI_INHERIT_ENV=")) forwarded = value["KOI_INHERIT_ENV=".len..];
    }
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
        if (!skip and @import("environment.zig").inherit(e, forwarded)) try list.append(arena, entry);
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

test "pane environment drops arbitrary daemon sessions and forwards explicit user settings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A fabricated inheritance: changing the test process's own environment
    // would also change what the standard library scans for stderr.
    const markers = [_][]const u8{ "CLAUDE_CODE_CHILD_SESSION=1", "CLAUDECODE=1", "CLAUDE_CODE_ENTRYPOINT=cli", "CLAUDE_CODE_SESSION_ID=s", "CLAUDE_CODE_MESSAGING_SOCKET=/s", "CLAUDE_PID=1" };
    const settings = [_][]const u8{ "CLAUDE_CONFIG_DIR=/cfg", "CLAUDE_CODE_USE_BEDROCK=1", "HOME=/tmp" };
    const inherited = [_:null]?[*:0]const u8{
        "CLAUDE_CODE_CHILD_SESSION=1",     "CLAUDECODE=1",       "CLAUDE_CODE_ENTRYPOINT=cli", "CLAUDE_CODE_SESSION_ID=s",
        "CLAUDE_CODE_MESSAGING_SOCKET=/s", "CLAUDE_PID=1",       "CLAUDE_CONFIG_DIR=/cfg",     "CLAUDE_CODE_USE_BEDROCK=1",
        "HOME=/tmp",                       "PATH=/usr/bin:/bin", "TERM=dumb",                  "KOI_INHERIT_ENV=CLAUDE_CONFIG_DIR,CLAUDE_CODE_USE_BEDROCK",
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
    for (0..100) |_| _ = pane.writePtyNow(&reply);
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
        .input_mutex = sys.Mutex.init(),
        .size = .{ .cols = 80, .rows = 24, .cell_width = 8, .cell_height = 16 },
        .shell = "zsh",
        .home = "/tmp",
    };
}

/// A private, nonblocking duplex PTY substitute with a deliberately small
/// send buffer. Start the pane reader only after the fixture's final move.
const StartupInputFixture = struct {
    pane: Pane,
    peer: c_int,

    /// Holds startup input until the test expires the hold or starts closing.
    fn init() !StartupInputFixture {
        var pane = try testMetadataPane();
        errdefer freeMetadataPane(&pane);
        pane.wake_pipe = try wakePipe();
        errdefer for (pane.wake_pipe) |fd| {
            _ = c.close(fd);
        };
        var fds: [2]c_int = undefined;
        if (c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &fds) != 0) return error.Socket;
        errdefer for (fds) |fd| {
            _ = c.close(fd);
        };
        for (fds) |fd| {
            const flags = c.fcntl(fd, c.F_GETFL);
            if (flags < 0 or c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) < 0) return error.Socket;
        }
        const capacity: c_int = 4096;
        if (c.setsockopt(fds[0], c.SOL_SOCKET, c.SO_SNDBUF, &capacity, @sizeOf(c_int)) != 0) return error.Socket;
        pane.master = fds[0];
        pane.pid = -1; // No child is owned or signalled by this fixture.
        pane.input_hold_until = std.math.maxInt(i64);
        return .{ .pane = pane, .peer = fds[1] };
    }

    /// Stops the reader before releasing its socket, wake pipe and terminal.
    fn deinit(self: *StartupInputFixture) void {
        self.pane.kill();
        if (self.pane.thread) |thread| thread.join();
        _ = c.close(self.peer);
        _ = c.close(self.pane.master);
        for (self.pane.wake_pipe) |fd| {
            _ = c.close(fd);
        }
        freeMetadataPane(&self.pane);
    }

    /// Reads an exact ordered stream with a deadline, including no extra bytes.
    fn expectInput(self: *StartupInputFixture, expected: []const u8) !void {
        const deadline = sys.monotonicMillis() + 5000;
        var off: usize = 0;
        var buf: [8192]u8 = undefined;
        while (off < expected.len and sys.monotonicMillis() < deadline) {
            const n = c.read(self.peer, &buf, @min(buf.len, expected.len - off));
            if (n > 0) {
                const count: usize = @intCast(n);
                try std.testing.expectEqualSlices(u8, expected[off .. off + count], buf[0..count]);
                off += count;
            } else {
                if (n == 0 or (sys.errno() != c.EAGAIN and sys.errno() != c.EINTR)) return error.Read;
                var fds = [_]c.struct_pollfd{.{ .fd = self.peer, .events = c.POLLIN, .revents = 0 }};
                _ = c.poll(&fds, 1, 10);
            }
        }
        try std.testing.expectEqual(expected.len, off);
        try std.testing.expectEqual(@as(isize, -1), c.read(self.peer, &buf, buf.len));
        try std.testing.expectEqual(@as(c_int, c.EAGAIN), sys.errno());
    }

    /// Waits for a producer to fill the startup queue, without draining it.
    fn expectFullQueue(self: *StartupInputFixture) !void {
        const deadline = sys.monotonicMillis() + 2000;
        while (sys.monotonicMillis() < deadline) {
            self.pane.mutex.lock();
            const count = self.pane.held_input.items.len;
            self.pane.mutex.unlock();
            try std.testing.expect(count <= Pane.max_held_input);
            if (count == Pane.max_held_input) return;
            sys.sleepMillis(1);
        }
        return error.QueueNotFilled;
    }
};

/// Owns a test input call until completion or fixture close releases it.
const StartupInputWriter = struct {
    pane: *Pane,
    bytes: []const u8,
    transport: ?Transport = null,
    done: std.atomic.Value(bool) = .init(false),

    /// Publishes completion only after the input call has released its locks.
    fn run(self: *StartupInputWriter) void {
        if (self.transport) |client| self.pane.inputFrom(client, self.bytes) else self.pane.input(self.bytes);
        self.done.store(true, .release);
    }
};

test "startup held input survives partial writes and drains before later input without output" {
    var fixture = try StartupInputFixture.init();
    defer fixture.deinit();
    const pane = &fixture.pane;
    var expected: [64 * 1024 + 4]u8 = undefined;
    for (&expected, 0..) |*byte, i| byte.* = @intCast(i % 251);
    @memcpy(expected[expected.len - 4 ..], "tail");
    pane.input(expected[0 .. expected.len - 4]);
    pane.input_hold_until = 0;
    pane.releaseHeldInputLocked(sys.elapsedMillis());
    const pending = pane.held_input.items.len;
    try std.testing.expect(pending > 0 and pending < expected.len - 4);
    try std.testing.expectEqualSlices(u8, expected[expected.len - 4 - pending .. expected.len - 4], pane.held_input.items);
    pane.input("tail");
    try pane.start();
    try fixture.expectInput(&expected);
}

test "startup held input backpressure preserves a large paste before concurrent later input" {
    var fixture = try StartupInputFixture.init();
    defer fixture.deinit();
    const pane = &fixture.pane;
    var expected: [3 * Pane.max_held_input + 4]u8 = undefined;
    for (&expected, 0..) |*byte, i| byte.* = @intCast(i % 251);
    @memcpy(expected[expected.len - 4 ..], "tail");
    var first = StartupInputWriter{ .pane = pane, .bytes = expected[0 .. expected.len - 4] };
    const first_thread = try std.Thread.spawn(.{}, StartupInputWriter.run, .{&first});
    defer {
        pane.kill();
        first_thread.join();
    }
    try fixture.expectFullQueue();
    try std.testing.expect(!first.done.load(.acquire));
    var later = StartupInputWriter{ .pane = pane, .bytes = "tail" };
    const later_thread = try std.Thread.spawn(.{}, StartupInputWriter.run, .{&later});
    defer {
        pane.kill();
        later_thread.join();
    }
    try pane.start();

    // A blocked paste must leave the reader free to parse program output.
    const output = "\x1b]2;reader responsive\x07";
    try std.testing.expectEqual(@as(isize, output.len), c.write(fixture.peer, output.ptr, output.len));
    const deadline = sys.monotonicMillis() + 2000;
    var responsive = false;
    while (sys.monotonicMillis() < deadline) {
        pane.mutex.lock();
        responsive = std.mem.eql(u8, pane.title.items, "reader responsive");
        pane.mutex.unlock();
        if (responsive) break;
        sys.sleepMillis(1);
    }
    try std.testing.expect(responsive);
    pane.mutex.lock();
    pane.input_hold_until = 0;
    pane.mutex.unlock();
    pane.wake();
    try fixture.expectInput(&expected);
}

test "startup held input close cancels a blocked writer and rejects input before and after reader exit" {
    for ([_]bool{ false, true }) |draining| {
        var fixture = try StartupInputFixture.init();
        defer fixture.deinit();
        const pane = &fixture.pane;
        pane.execution_ready.store(draining, .release);
        const bytes: [2 * Pane.max_held_input]u8 = @splat('x');
        var writer = StartupInputWriter{ .pane = pane, .bytes = &bytes };
        const thread = try std.Thread.spawn(.{}, StartupInputWriter.run, .{&writer});
        defer {
            pane.kill();
            thread.join();
        }
        try fixture.expectFullQueue();
        if (draining) {
            // Let the live reader fill the socket before requesting close.
            pane.mutex.lock();
            pane.input_hold_until = 0;
            pane.mutex.unlock();
            try pane.start();
            var fds = [_]c.struct_pollfd{.{ .fd = fixture.peer, .events = c.POLLIN, .revents = 0 }};
            try std.testing.expect(c.poll(&fds, 1, 2000) > 0);
        }
        pane.kill();
        const deadline = sys.monotonicMillis() + 2000;
        while (!writer.done.load(.acquire) and sys.monotonicMillis() < deadline) sys.sleepMillis(1);
        try std.testing.expect(writer.done.load(.acquire));
        pane.mutex.lock();
        const pending = pane.held_input.items.len;
        pane.mutex.unlock();
        try std.testing.expect(pending > 0);
        pane.input("after close");
        pane.mutex.lock();
        pane.releaseHeldInputLocked(std.math.maxInt(i64));
        const after_close = pane.held_input.items.len;
        pane.mutex.unlock();
        try std.testing.expectEqual(pending, after_close);
        if (!draining) try pane.start();
        while (!pane.ended.load(.acquire) and sys.monotonicMillis() < deadline) sys.sleepMillis(1);
        try std.testing.expect(pane.ended.load(.acquire));
        pane.input("after exit");
        try std.testing.expectEqual(pending, pane.held_input.items.len);
        if (!draining) try fixture.expectInput("");
    }
}

test "startup held input waits through allocation failure then writes without losing bytes" {
    var fixture = try StartupInputFixture.init();
    defer fixture.deinit();
    const pane = &fixture.pane;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    pane.gpa = failing.allocator();
    var writer = StartupInputWriter{ .pane = pane, .bytes = "preserved input" };
    const thread = try std.Thread.spawn(.{}, StartupInputWriter.run, .{&writer});
    defer {
        pane.kill();
        thread.join();
    }
    // Taking the pane mutex synchronizes with the failed queue allocation.
    const deadline = sys.monotonicMillis() + 2000;
    var failed = false;
    while (sys.monotonicMillis() < deadline) {
        pane.mutex.lock();
        failed = failing.has_induced_failure;
        pane.mutex.unlock();
        if (failed) break;
        sys.sleepMillis(1);
    }
    try std.testing.expect(failed);
    try std.testing.expect(!writer.done.load(.acquire));
    pane.mutex.lock();
    pane.input_hold_until = 0;
    pane.releaseHeldInputLocked(sys.elapsedMillis());
    pane.mutex.unlock();
    try fixture.expectInput(writer.bytes);
}

test "startup held input keeps ownership tags after a partial write crosses segments" {
    var rec = Recorder{};
    defer rec.sent.deinit(std.testing.allocator);
    var fixture = try StartupInputFixture.init();
    defer fixture.deinit();
    const pane = &fixture.pane;
    const client = Transport{ .ptr = &rec, .vtable = &Recorder.vtable };
    try pane.clients.append(pane.gpa, .{ .transport = client, .negotiated = true });
    pane.owner = client.ptr;
    var expected: [Pane.max_held_input + 4]u8 = @splat('x');
    expected[0] = 'a';
    pane.input(expected[0..1]);
    pane.inputFrom(client, expected[1..Pane.max_held_input]);
    pane.input_hold_until = 0;
    pane.releaseHeldInputLocked(sys.elapsedMillis());
    const pending = pane.held_input.items.len;
    const written = Pane.max_held_input - pending;
    try std.testing.expect(written > 1 and pending > 0);
    try std.testing.expectEqual(@as(usize, 1), pane.held_segments.items.len);
    try std.testing.expectEqual(pending, pane.held_segments.items[0].len);
    try std.testing.expect(pane.held_segments.items[0].owner == client.ptr);
    pane.input("tail");
    pane.control(client, false);
    try std.testing.expectEqualStrings("tail", pane.held_input.items);
    @memcpy(expected[written..][0..4], "tail");
    try pane.start();
    try fixture.expectInput(expected[0 .. written + 4]);
}

test "startup held input revocation cancels a backpressured owner" {
    var rec = Recorder{};
    defer rec.sent.deinit(std.testing.allocator);
    var fixture = try StartupInputFixture.init();
    defer fixture.deinit();
    const pane = &fixture.pane;
    const client = Transport{ .ptr = &rec, .vtable = &Recorder.vtable };
    try pane.clients.append(pane.gpa, .{ .transport = client, .negotiated = true });
    pane.owner = client.ptr;
    const bytes: [2 * Pane.max_held_input]u8 = @splat('x');
    var writer = StartupInputWriter{ .pane = pane, .bytes = &bytes, .transport = client };
    const thread = try std.Thread.spawn(.{}, StartupInputWriter.run, .{&writer});
    defer {
        pane.kill();
        thread.join();
    }
    try fixture.expectFullQueue();
    pane.control(client, false);
    const deadline = sys.monotonicMillis() + 2000;
    while (!writer.done.load(.acquire) and sys.monotonicMillis() < deadline) sys.sleepMillis(1);
    try std.testing.expect(writer.done.load(.acquire));
    pane.mutex.lock();
    const pending = pane.held_input.items.len;
    pane.mutex.unlock();
    try std.testing.expectEqual(@as(usize, 0), pending);
    try fixture.expectInput("");
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
    const now = sys.elapsedMillis();
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
    pane.installCallbacks();
    pane.terminal.write("\x1b]133;C\x07\x1b]7502;cmd=make\x07output");
    try std.testing.expectEqualStrings("make", pane.program.items);
    // Discovery sees make's child; the header keeps what the user ran.
    pane.applyForegroundLocked(pane.metadata_version, .{ .pid = 200, .program = "cc", .cwd = "/tmp/work" });
    try std.testing.expectEqualStrings("make", pane.program.items);
    try std.testing.expectEqualStrings("/tmp/work", pane.cwd.items);
    pane.terminal.write("\x1b]133;D;0\x07\x1b]133;A\x07");
    try std.testing.expectEqualStrings("", pane.program.items);
    pane.applyForegroundLocked(pane.metadata_version, .{ .pid = 300, .program = "vim", .cwd = "/tmp/work" });
    try std.testing.expectEqualStrings("vim", pane.program.items);
    // Cancelled and unfinished reports never become a name.
    pane.terminal.write("\x1b]7502;cmd=bad\x18name\x07\x1b]7502;cmd=cut");
    try std.testing.expectEqualStrings("vim", pane.program.items);
    pane.terminal.write("\x07");
    try std.testing.expectEqualStrings("cut", pane.program.items);
}

test "shell identity and prompt reports survive every PTY split" {
    const command = "\x1b]7502;cmd=opencode\x1b\\";
    const prompt = "\x1b]133;A\x07";
    for (0..command.len + 1) |split| {
        var pane = try testMetadataPane();
        defer pane.terminal.deinit();
        defer pane.program.deinit(pane.gpa);
        defer pane.cwd.deinit(pane.gpa);
        defer pane.shell_command.deinit(pane.gpa);
        pane.installCallbacks();
        pane.terminal.write(command[0..split]);
        pane.terminal.write(command[split..]);
        try std.testing.expectEqualStrings("opencode", pane.program.items);
        for (0..prompt.len + 1) |at| {
            pane.terminal.write(command);
            pane.terminal.write(prompt[0..at]);
            pane.terminal.write(prompt[at..]);
            try std.testing.expectEqualStrings("", pane.program.items);
        }
    }
}

test "pane edits preserve an unfinished shell identity report" {
    for ([_]wire.Op{ .clearPane, .configurePane }) |op| {
        var pane = try testMetadataPane();
        defer freeMetadataPane(&pane);
        defer pane.shell_command.deinit(pane.gpa);
        pane.installCallbacks();
        pane.terminal.write("\x1b]7502;cmd=open");
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try pane.edit(op, if (op == .configurePane) wire.Appearance{} else null, arena.allocator());
        pane.terminal.write("code\x07");
        try std.testing.expectEqualStrings("opencode", pane.program.items);
    }
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
    const deadline = sys.elapsedMillis() + 5000;
    while (!pane.ended.load(.acquire) and sys.elapsedMillis() < deadline) sys.sleepMillis(10);
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

    pane.last_output = sys.elapsedMillis();
    const replaced = pane.updateForegroundLocked(.{ .pid = 300, .program = "other", .cwd = "" });
    pane.refreshMetadataLocked(replaced);
    try std.testing.expect(pane.reported == null);
    try std.testing.expectEqual(wire.Status.idle, pane.status);
    try std.testing.expect(pane.output_active);
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
    try pane.attach(.{ .ptr = &rec, .vtable = &Recorder.vtable }, arena_state.allocator(), .{ .pane = "testpane", .cols = 0, .rows = 0, .cellWidth = 0, .cellHeight = 0 });
    try std.testing.expectEqual(@as(usize, wire.header_size + 4), rec.sent.items.len);
    try std.testing.expectEqual(@backingInt(wire.Kind.exited), rec.sent.items[0]);
    try std.testing.expect(rec.closed);
    try std.testing.expectEqual(@as(usize, 0), pane.clients.items.len);
    pane.destroy();
}

/// Frees only the fields owned by a shell-less engine fixture.
fn freeMetadataPane(pane: *Pane) void {
    pane.terminal.deinit();
    if (pane.creationController) |id| pane.gpa.free(id);
    for (pane.clients.items) |client| if (client.controller) |id| pane.gpa.free(id);
    pane.clients.deinit(pane.gpa);
    pane.title.deinit(pane.gpa);
    pane.cwd.deinit(pane.gpa);
    pane.program.deinit(pane.gpa);
    pane.held_input.deinit(pane.gpa);
    pane.held_segments.deinit(pane.gpa);
}

test "revoking an owner preserves interleaved legacy held input" {
    var pane = try testMetadataPane();
    defer freeMetadataPane(&pane);
    pane.input_hold_until = 1;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var first = Recorder{};
    defer first.sent.deinit(std.testing.allocator);
    var legacy = Recorder{};
    defer legacy.sent.deinit(std.testing.allocator);
    var second = Recorder{};
    defer second.sent.deinit(std.testing.allocator);
    const a = Transport{ .ptr = &first, .vtable = &Recorder.vtable };
    const cli = Transport{ .ptr = &legacy, .vtable = &Recorder.vtable };
    const b = Transport{ .ptr = &second, .vtable = &Recorder.vtable };
    try pane.attach(a, arena.allocator(), .{ .pane = "metadata", .cols = 0, .rows = 0, .cellWidth = 8, .cellHeight = 16, .paneControl = true, .controller = "first" });
    try pane.attach(cli, arena.allocator(), .{ .pane = "metadata", .cols = 0, .rows = 0, .cellWidth = 8, .cellHeight = 16 });
    try pane.attach(b, arena.allocator(), .{ .pane = "metadata", .cols = 0, .rows = 0, .cellWidth = 8, .cellHeight = 16, .paneControl = true, .observer = true, .controller = "second" });
    pane.inputFrom(cli, "a");
    pane.inputFrom(a, "discard");
    pane.inputFrom(cli, "b");
    pane.control(a, false);
    try std.testing.expectEqualStrings("ab", pane.held_input.items);
    pane.control(b, true);
    pane.inputFrom(b, "discard too");
    pane.inputFrom(cli, "c");
    pane.detach(b);
    try std.testing.expectEqualStrings("abc", pane.held_input.items);
    pane.control(a, true);
    pane.inputFrom(a, "discard on transfer");
    pane.inputFrom(cli, "d");
    try pane.attach(b, arena.allocator(), .{ .pane = "metadata", .cols = 0, .rows = 0, .cellWidth = 8, .cellHeight = 16, .paneControl = true, .observer = true, .controller = "second" });
    pane.control(b, true);
    try std.testing.expectEqualStrings("abcd", pane.held_input.items);
}

test "controller identity is bounded and copied for negotiated owners" {
    var pane = try testMetadataPane();
    defer freeMetadataPane(&pane);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rec = Recorder{};
    defer rec.sent.deinit(std.testing.allocator);
    const client = Transport{ .ptr = &rec, .vtable = &Recorder.vtable };
    var id: [64]u8 = undefined;
    @memset(&id, 'x');
    const original = id;
    try pane.attach(client, arena.allocator(), .{ .pane = "metadata", .cols = 0, .rows = 0, .cellWidth = 8, .cellHeight = 16, .paneControl = true, .controller = &id });
    id[0] = 'y';
    try std.testing.expect(pane.ownsControllerLocked(&original));
    try std.testing.expect(!pane.ownsControllerLocked(&id));
    pane.detach(client);
    // Nobody controls it now and no reservation was taken over, so a pane not
    // yet reopened after a relaunch can still be closed.
    try std.testing.expect(pane.ownsControllerLocked(&id));
    try std.testing.expectError(error.InvalidController, pane.attach(client, arena.allocator(), .{ .pane = "metadata", .cols = 0, .rows = 0, .cellWidth = 8, .cellHeight = 16, .paneControl = true, .controller = "" }));
    var too_long: [65]u8 = undefined;
    @memset(&too_long, 'x');
    try std.testing.expectError(error.InvalidController, pane.attach(client, arena.allocator(), .{ .pane = "metadata", .cols = 0, .rows = 0, .cellWidth = 8, .cellHeight = 16, .paneControl = true, .controller = &too_long }));
}

test "creation reservation survives observation but not an owner claim or detach" {
    for ([_]bool{ false, true }) |legacy| {
        var pane = try testMetadataPane();
        defer freeMetadataPane(&pane);
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var observer = Recorder{};
        defer observer.sent.deinit(std.testing.allocator);
        const client = Transport{ .ptr = &observer, .vtable = &Recorder.vtable };
        var id = [_]u8{ 'm', 'i', 'n', 'e' };
        try pane.reserveCreation(&id);
        id[0] = 'X';
        try std.testing.expect(pane.ownsControllerLocked("mine"));
        try std.testing.expect(!pane.ownsControllerLocked("foreign"));
        try pane.attach(client, arena.allocator(), .{ .pane = "metadata", .cols = 0, .rows = 0, .cellWidth = 8, .cellHeight = 16, .paneControl = !legacy, .observer = true, .controller = if (legacy) null else "foreign" });
        try std.testing.expect(pane.ownsControllerLocked("mine"));
        if (legacy) {
            pane.resizeFrom(client, .{ .cols = 80, .rows = 24, .cell_width = 8, .cell_height = 16 });
        } else {
            pane.control(client, true);
            try std.testing.expect(pane.ownsControllerLocked("foreign"));
        }
        try std.testing.expect(pane.creationController == null);
        try std.testing.expect(!pane.ownsControllerLocked("mine"));
        pane.detach(client);
        try std.testing.expect(!pane.ownsControllerLocked("mine"));
        try std.testing.expect(!pane.ownsControllerLocked("foreign"));
    }
}

test "interactive attachment consumes creation reservation immediately" {
    var pane = try testMetadataPane();
    defer freeMetadataPane(&pane);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var peer = Recorder{};
    defer peer.sent.deinit(std.testing.allocator);
    const client = Transport{ .ptr = &peer, .vtable = &Recorder.vtable };
    try pane.reserveCreation("creator");
    try pane.attach(client, arena.allocator(), .{ .pane = "metadata", .cols = 0, .rows = 0, .cellWidth = 8, .cellHeight = 16, .paneControl = true, .controller = "foreign" });
    try std.testing.expect(pane.creationController == null);
    try std.testing.expect(!pane.ownsControllerLocked("creator"));
    try std.testing.expect(pane.ownsControllerLocked("foreign"));
    pane.detach(client);
    try std.testing.expect(!pane.ownsControllerLocked("creator"));
}

test "pane control requires explicit transfer and never promotes detached clients" {
    var pane = try testMetadataPane();
    defer freeMetadataPane(&pane);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var first = Recorder{};
    defer first.sent.deinit(std.testing.allocator);
    var second = Recorder{};
    defer second.sent.deinit(std.testing.allocator);
    const a = Transport{ .ptr = &first, .vtable = &Recorder.vtable };
    const b = Transport{ .ptr = &second, .vtable = &Recorder.vtable };
    const request = wire.OpenRequest{ .pane = "metadata", .cols = 80, .rows = 24, .cellWidth = 8, .cellHeight = 16, .paneControl = true };
    try pane.attach(a, arena_state.allocator(), request);
    var observer = request;
    observer.observer = true;
    try pane.attach(b, arena_state.allocator(), observer);
    const larger = wire.GridSize{ .cols = 100, .rows = 30, .cell_width = 8, .cell_height = 16 };
    pane.resizeFrom(b, larger);
    try std.testing.expectEqual(@as(u16, 80), pane.size.cols);
    try std.testing.expect(!pane.canActLocked(b));
    pane.control(b, true);
    try std.testing.expect(pane.canActLocked(b));
    try std.testing.expect(!pane.canActLocked(a));
    pane.resizeFrom(b, larger);
    try std.testing.expectEqual(@as(u16, 100), pane.size.cols);
    pane.resizeFrom(a, requestToSize(request));
    try std.testing.expectEqual(@as(u16, 100), pane.size.cols);
    pane.control(b, false);
    try std.testing.expect(pane.owner == null);
    try std.testing.expect(!pane.canActLocked(b));
    pane.control(a, true);
    pane.detach(a);
    try std.testing.expect(pane.owner == null);
    try std.testing.expect(!pane.canActLocked(b));

    var frames = wire.FrameReader.init(std.testing.allocator);
    defer frames.deinit();
    try frames.append(second.sent.items);
    try std.testing.expectEqual(wire.Kind.attached, (try frames.next()).?.kind);
    try std.testing.expectEqual(wire.Kind.snapshot, (try frames.next()).?.kind);
    const initial = (try frames.next()).?;
    try std.testing.expectEqual(wire.Kind.ownership, initial.kind);
    try std.testing.expectEqualSlices(u8, &.{0}, initial.payload);
}

test "the owner's own controller reattaching takes over; another controller still observes" {
    var pane = try testMetadataPane();
    defer freeMetadataPane(&pane);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var stale = Recorder{};
    defer stale.sent.deinit(std.testing.allocator);
    var fresh = Recorder{};
    defer fresh.sent.deinit(std.testing.allocator);
    var other = Recorder{};
    defer other.sent.deinit(std.testing.allocator);
    const a = Transport{ .ptr = &stale, .vtable = &Recorder.vtable };
    const b = Transport{ .ptr = &fresh, .vtable = &Recorder.vtable };
    const d = Transport{ .ptr = &other, .vtable = &Recorder.vtable };
    const request = wire.OpenRequest{ .pane = "metadata", .cols = 80, .rows = 24, .cellWidth = 8, .cellHeight = 16, .paneControl = true, .controller = "app" };
    try pane.attach(a, arena_state.allocator(), request);
    try std.testing.expect(pane.owner == a.ptr);
    // The same app on a new connection while the old one lingers.
    try pane.attach(b, arena_state.allocator(), request);
    try std.testing.expect(pane.owner == b.ptr);
    var foreign = request;
    foreign.controller = "another";
    try pane.attach(d, arena_state.allocator(), foreign);
    try std.testing.expect(pane.owner == b.ptr);
    // The lingering connection leaving does not disturb the new owner.
    pane.detach(a);
    try std.testing.expect(pane.owner == b.ptr);
    pane.detach(b);
    pane.detach(d);
}

/// Converts an open grid to the resize payload used in ownership tests.
fn requestToSize(request: wire.OpenRequest) wire.GridSize {
    return .{ .cols = request.cols, .rows = request.rows, .cell_width = request.cellWidth, .cell_height = request.cellHeight };
}

test "legacy zero grid attachment stays passive until resizing an unowned pane" {
    var pane = try testMetadataPane();
    defer freeMetadataPane(&pane);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var legacy = Recorder{};
    defer legacy.sent.deinit(std.testing.allocator);
    var modern = Recorder{};
    defer modern.sent.deinit(std.testing.allocator);
    var later = Recorder{};
    defer later.sent.deinit(std.testing.allocator);
    const old = Transport{ .ptr = &legacy, .vtable = &Recorder.vtable };
    const new = Transport{ .ptr = &modern, .vtable = &Recorder.vtable };
    const other = Transport{ .ptr = &later, .vtable = &Recorder.vtable };
    try pane.attach(old, arena_state.allocator(), .{ .pane = "metadata", .cols = 0, .rows = 0, .cellWidth = 0, .cellHeight = 0 });
    try std.testing.expect(pane.owner == null);
    try std.testing.expect(pane.canActLocked(old));
    try pane.attach(new, arena_state.allocator(), .{ .pane = "metadata", .cols = 0, .rows = 0, .cellWidth = 8, .cellHeight = 16, .paneControl = true });
    try std.testing.expect(pane.owner == new.ptr);
    try pane.attach(other, arena_state.allocator(), .{ .pane = "metadata", .cols = 120, .rows = 40, .cellWidth = 8, .cellHeight = 16 });
    pane.resizeFrom(other, .{ .cols = 120, .rows = 40, .cell_width = 8, .cell_height = 16 });
    try std.testing.expectEqual(@as(u16, 80), pane.size.cols);
    pane.control(new, false);
    pane.resizeFrom(old, .{ .cols = 100, .rows = 30, .cell_width = 8, .cell_height = 16 });
    try std.testing.expectEqual(@as(u16, 100), pane.size.cols);
    var frames = wire.FrameReader.init(std.testing.allocator);
    defer frames.deinit();
    try frames.append(legacy.sent.items);
    try std.testing.expectEqual(wire.Kind.attached, (try frames.next()).?.kind);
    try std.testing.expectEqual(wire.Kind.snapshot, (try frames.next()).?.kind);
    try std.testing.expectEqual(wire.Kind.resized, (try frames.next()).?.kind);
    try std.testing.expect((try frames.next()) == null);
}

test "observer input and kill require current ownership" {
    var pane = try testMetadataPane();
    defer freeMetadataPane(&pane);
    pane.input_hold_until = 1;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var rec = Recorder{};
    defer rec.sent.deinit(std.testing.allocator);
    const client = Transport{ .ptr = &rec, .vtable = &Recorder.vtable };
    try pane.attach(client, arena_state.allocator(), .{ .pane = "metadata", .cols = 80, .rows = 24, .cellWidth = 8, .cellHeight = 16, .paneControl = true, .observer = true });
    pane.inputFrom(client, "denied");
    pane.killFrom(client);
    try std.testing.expectEqualStrings("", pane.held_input.items);
    try std.testing.expect(!pane.closing.load(.acquire));
    pane.control(client, true);
    pane.inputFrom(client, "accepted");
    try std.testing.expectEqualStrings("accepted", pane.held_input.items);
    pane.control(client, false);
    try std.testing.expectEqualStrings("", pane.held_input.items);
    pane.inputFrom(client, "denied");
    pane.killFrom(client);
    try std.testing.expectEqualStrings("", pane.held_input.items);
    try std.testing.expect(!pane.closing.load(.acquire));
    pane.control(client, true);
    pane.killFrom(client);
    try std.testing.expect(pane.closing.load(.acquire));
}

test "detaching an observer leaves its shell alive" {
    const pane = try Pane.create(std.testing.allocator, "testpane".*, .{ .cols = 80, .rows = 24, .cell_width = 8, .cell_height = 16 }, "/tmp", &.{}, null, null);
    try pane.start();
    try pane.releaseExecution();
    defer {
        pane.kill();
        while (!pane.ended.load(.acquire)) sys.sleepMillis(10);
        pane.destroy();
    }
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var rec = Recorder{};
    defer rec.sent.deinit(std.testing.allocator);
    const transport = Transport{ .ptr = &rec, .vtable = &Recorder.vtable };
    try pane.attach(transport, arena_state.allocator(), .{ .pane = "testpane", .cols = 80, .rows = 24, .cellWidth = 8, .cellHeight = 16, .paneControl = true, .observer = true });
    pane.detach(transport);
    try std.testing.expect(!pane.closing.load(.acquire));
    try std.testing.expectEqual(@as(c_int, 0), c.kill(pane.pid, 0));
}

test "clear snapshots preserve active screen modes and unfinished parser input" {
    var pane = try testMetadataPane();
    defer freeMetadataPane(&pane);
    pane.installCallbacks();
    for (0..100) |_| pane.terminal.write("old history\r\n");
    pane.terminal.write("visible\x1b[?2004h\x1b]2;unfinished");
    var rec = Recorder{};
    defer rec.sent.deinit(std.testing.allocator);
    try pane.clients.append(pane.gpa, .{ .transport = .{ .ptr = &rec, .vtable = &Recorder.vtable } });
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
    try pane.clients.append(pane.gpa, .{ .transport = .{ .ptr = &first, .vtable = &Recorder.vtable } });
    try pane.clients.append(pane.gpa, .{ .transport = .{ .ptr = &second, .vtable = &Recorder.vtable } });
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

test "registered agent identity survives display hints and completion survives returning to prompt" {
    var pane = try testMetadataPane();
    defer pane.terminal.deinit();
    defer pane.title.deinit(pane.gpa);
    defer pane.cwd.deinit(pane.gpa);
    defer pane.program.deinit(pane.gpa);
    _ = pane.updateForegroundLocked(.{ .pid = 200, .program = "node", .cwd = "/tmp" });
    try pane.agent.report(200, "new-agent", null, "session", null, .working);
    _ = pane.updateForegroundLocked(.{ .pid = 200, .program = "helper", .cwd = "/tmp" });
    pane.last_output = 1;
    pane.refreshMetadataLocked(false);
    try std.testing.expect(pane.agent.active);
    try std.testing.expectEqual(wire.Status.working, pane.status);
    try std.testing.expect(!pane.output_active);
    try pane.agent.report(200, "new-agent", null, "session", null, .done);
    _ = pane.updateForegroundLocked(.{ .pid = pane.pid, .program = "zsh", .cwd = "/tmp" });
    pane.refreshMetadataLocked(true);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const info = try pane.infoLocked(arena.allocator());
    try std.testing.expectEqual(wire.Status.idle, info.status);
    try std.testing.expect(!info.agent.?.active);
    try std.testing.expectEqualStrings("new-agent", info.agent.?.name);
    try std.testing.expectEqual(wire.Status.done, info.agentEvents[1].status);
}
