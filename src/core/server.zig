//! The server: `koi --server`. It owns every shell, so tabs keep running
//! while no app is attached, and it holds the tree every client shows: the
//! tabs, the groups the user made of them, and each tab's panes. See
//! `wire.zig` for the protocol.
//!
//! It starts on demand (`connect`), in a process session of its own so it
//! outlives whatever started it, and exits once it has no panes and no
//! connections.
const std = @import("std");
const sys = @import("sys.zig");
const c = sys.c;
const wire = @import("wire.zig");
const paths_mod = @import("paths.zig");
const transport_mod = @import("transport.zig");
const Transport = transport_mod.Transport;
const Socket = transport_mod.Socket;
const Pane = @import("pane.zig").Pane;
const link_mod = @import("link.zig");
const Allocator = std.mem.Allocator;

/// Release plus source/build hash embedded at compilation. Never consults
/// Git, a bundle, or the executable that may have replaced this process on disk.
pub const binary_version = @import("build_options").version;
const capabilities = [_][]const u8{ "serverInfo", "clearPane", "resetPane", "configurePane", "startup", "resizeSplitWeights", "reportStatus", "splitCwd", "paneControl", "ownedCommands" };
const transports = [_][]const u8{ "unix", "encryptedUDP", "sshStdio" };

const Tab = struct {
    id: [8]u8,
    /// A name the user gave the tab, or empty to show its program.
    name: std.ArrayList(u8) = .empty,
    panes: std.ArrayList(*Pane) = .empty,
    layout: LayoutNode,
};

/// A tab's arrangement: a pane, or a split holding two or more children in a
/// row or column. Splits are flat: splitting a pane the same way its parent
/// runs adds an even sibling rather than nesting, so panes stay equal instead
/// of spiralling.
const LayoutNode = union(enum) {
    pane: *Pane,
    split: *SplitNode,
};

/// One child of a split and its share of the split's length, relative to its
/// siblings (normalized when drawn, so equal weights give equal panes).
const Child = struct {
    node: LayoutNode,
    weight: f64 = 1,
};

const SplitNode = struct {
    id: [8]u8,
    direction: wire.Direction,
    children: std.ArrayList(Child) = .empty,
};

const Group = struct {
    id: [8]u8,
    name: std.ArrayList(u8) = .empty,
    tabs: std.ArrayList(*Tab) = .empty,
};

const Node = union(enum) {
    tab: *Tab,
    group: *Group,
};

/// Replaces a split's weights atomically. Scaling by the largest input
/// avoids overflowing the sum; reject an unrepresentable positive share
/// before writing any child. The caller holds the server mutex.
fn normalizeSplitWeights(split: *SplitNode, weights: []const f64) !void {
    if (weights.len != split.children.items.len or weights.len < 2) return error.InvalidWeightCount;
    var largest: f64 = 0;
    for (weights) |weight| {
        if (!std.math.isFinite(weight) or weight <= 0) return error.InvalidWeight;
        largest = @max(largest, weight);
    }
    var sum: f64 = 0;
    for (weights) |weight| sum += weight / largest;
    for (weights) |weight| {
        const normalized = (weight / largest) / sum;
        if (!std.math.isFinite(normalized) or normalized <= 0) return error.UnrepresentableWeight;
    }
    for (split.children.items, weights) |*child, weight| child.weight = (weight / largest) / sum;
}

/// With the server mutex held, lock all targets in tree order and check the
/// current owner. Legacy commands deliberately take no pane locks here.
fn lockOwned(targets: []const *Pane, controller: ?[]const u8) bool {
    const proof = controller orelse return true;
    if (!wire.validController(proof) or targets.len == 0) return false;
    for (targets) |pane| pane.mutex.lock();
    for (targets) |pane| if (!pane.ownsControllerLocked(proof)) {
        for (targets) |locked| locked.mutex.unlock();
        return false;
    };
    return true;
}

/// Releases the locks acquired for a controller-bearing mutation.
fn unlockOwned(targets: []const *Pane, controller: ?[]const u8) void {
    if (controller != null) for (targets) |pane| pane.mutex.unlock();
}

/// Collects each pane affected by a split mutation while the tree is locked.
fn collectLayoutPanes(arena: Allocator, node: LayoutNode, targets: *std.ArrayList(*Pane)) Allocator.Error!void {
    switch (node) {
        .pane => |pane| try targets.append(arena, pane),
        .split => |split| for (split.children.items) |child| try collectLayoutPanes(arena, child.node, targets),
    }
}

/// A UDP link and what the server must know to reclaim it: `readers` counts
/// the connection threads serving its streams, and a link may be destroyed
/// only once it is closed and none is left. `closing` and increments of
/// `readers` are guarded by `server.mutex`: the reaper sets `closing` when it
/// sees no readers, and from then on `onStream` serves nothing, so no reader
/// can start while `destroy` joins the link's receiver.
const LinkEntry = struct {
    server: *Server,
    link: *link_mod.Link,
    readers: std.atomic.Value(usize) = .init(0),
    closing: bool = false,
};

pub const Server = struct {
    gpa: Allocator,
    paths: paths_mod.Paths,
    mutex: sys.Mutex,
    items: std.ArrayList(Node) = .empty,
    panes: std.ArrayList(*Pane) = .empty,
    watchers: std.ArrayList(Transport) = .empty,
    links: std.ArrayList(*LinkEntry) = .empty,
    connections: usize = 0,
    idle_since: i64 = 0,
    started_at: u64 = 0,
    // Changes are batched for watchers; a subscribed command caller also
    // gets the current tree immediately after its successful result.
    notify_mutex: sys.Mutex,
    notify_cond: sys.Cond,
    notify_pending: bool = false,
    last_state: std.ArrayList(u8) = .empty,
    /// Serializes state construction and sending, so an older batched tree
    /// cannot overtake an eager reply. Take before `mutex`, never from a pane.
    state_mutex: sys.Mutex,

    /// Runs the server until it is idle; never returns.
    pub fn run(gpa: Allocator) noreturn {
        _ = c.setsid();
        sys.ignoreSignal(c.SIGPIPE);
        const paths = paths_mod.Paths.init(gpa) catch fail("out of memory");
        paths.ensureDirs();
        const lock_fd = c.open(cstr(paths.lock), c.O_CREAT | c.O_RDWR | c.O_CLOEXEC, @as(c_uint, 0o600));
        if (lock_fd < 0 or c.flock(lock_fd, c.LOCK_EX | c.LOCK_NB) != 0) {
            log("another server runs", .{});
            std.process.exit(0);
        }
        const listener = transport_mod.listenUnix(paths.socket) catch |e| fail(@errorName(e));
        const self = gpa.create(Server) catch fail("out of memory");
        self.* = .{ .gpa = gpa, .paths = paths, .idle_since = sys.nowMillis(), .started_at = sys.monotonicMillis(), .mutex = sys.Mutex.init(), .notify_mutex = sys.Mutex.init(), .notify_cond = sys.Cond.init(), .state_mutex = sys.Mutex.init() };
        log("serving on {s} (pid {d})", .{ paths.socket, c.getpid() });
        _ = std.Thread.spawn(.{}, acceptLoop, .{ self, listener }) catch fail("thread");
        _ = std.Thread.spawn(.{}, notifyLoop, .{self}) catch fail("thread");
        self.idleLoop();
    }

    fn fail(what: []const u8) noreturn {
        log("failed: {s}", .{what});
        std.process.exit(1);
    }

    pub fn log(comptime fmt: []const u8, args: anytype) void {
        std.debug.print("[koi-server] {d} " ++ fmt ++ "\n", .{sys.nowMillis()} ++ args);
    }

    /// Connects to this machine's server, starting one if none runs; null
    /// if it cannot be reached.
    pub fn connect(gpa: Allocator) ?Socket {
        const paths = paths_mod.Paths.init(gpa) catch return null;
        defer paths.deinit(gpa);
        if (Socket.connect(paths.socket)) |s| return s;
        start(gpa, paths) catch return null;
        var i: usize = 0;
        while (i < 100) : (i += 1) {
            sys.sleepMillis(20);
            if (Socket.connect(paths.socket)) |s| return s;
        }
        return null;
    }

    /// Starts a server in the background, its output in the log file.
    fn start(gpa: Allocator, paths: paths_mod.Paths) !void {
        paths.ensureDirs();
        const self_path = try sys.selfPath(gpa);
        defer gpa.free(self_path);
        const pid = c.fork();
        if (pid < 0) return error.Fork;
        if (pid == 0) {
            const devnull = c.open("/dev/null", c.O_RDONLY);
            const logfd = c.open(cstr(paths.log), c.O_CREAT | c.O_WRONLY | c.O_APPEND, @as(c_uint, 0o600));
            if (devnull >= 0) _ = c.dup2(devnull, 0);
            if (logfd >= 0) {
                _ = c.dup2(logfd, 1);
                _ = c.dup2(logfd, 2);
            }
            var exe_buf: [4096]u8 = undefined;
            const exe = std.fmt.bufPrintSentinel(&exe_buf, "{s}", .{self_path}, 0) catch c._exit(127);
            const argv = [_:null]?[*:0]const u8{ exe.ptr, "--server", null };
            _ = c.execv(exe.ptr, @ptrCast(&argv));
            c._exit(127);
        }
    }

    fn acceptLoop(self: *Server, listener: c_int) void {
        while (true) {
            const fd = c.accept(listener, null, null);
            if (fd < 0) {
                const e = sys.errno();
                if (e == c.EINTR or e == c.ECONNABORTED) continue;
                // A dead listener ends the server; running out of descriptors
                // or memory passes, and must not end every session with it.
                if (e == c.EBADF or e == c.EINVAL or e == c.ENOTSOCK) {
                    log("accept failed: {d}", .{e});
                    std.process.exit(1);
                }
                log("accept failed, retrying: {d}", .{e});
                sys.sleepMillis(100);
                continue;
            }
            _ = c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC);
            transport_mod.quietSigpipe(fd);
            const socket = self.gpa.create(Socket) catch {
                _ = c.close(fd);
                continue;
            };
            socket.* = Socket.initServer(self.gpa, fd);
            self.changeConnections(1);
            const t = std.Thread.spawn(.{}, serveSocket, .{ self, socket }) catch {
                socket.release();
                self.gpa.destroy(socket);
                self.changeConnections(-1);
                continue;
            };
            t.detach();
        }
    }

    fn serveSocket(self: *Server, socket: *Socket) void {
        self.serve(socket.transport());
        // `serve` has unregistered the socket everywhere; now no one else can use it.
        socket.release();
        self.gpa.destroy(socket);
        self.changeConnections(-1);
    }

    fn serveStream(entry: *LinkEntry, stream: *link_mod.Stream) void {
        const self = entry.server;
        self.changeConnections(1);
        self.serve(stream.transport());
        self.changeConnections(-1);
        // `serve` has unregistered the stream everywhere; now no one else can use it.
        stream.release();
        // Last: the link may be destroyed as soon as this reaches zero.
        _ = entry.readers.fetchSub(1, .release);
    }

    fn changeConnections(self: *Server, delta: isize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.connections = @intCast(@as(isize, @intCast(self.connections)) + delta);
        self.idle_since = sys.nowMillis();
    }

    // MARK: Connections

    /// Handles one connection: a watcher, a pane, or commands.
    fn serve(self: *Server, t: Transport) void {
        var reader = wire.FrameReader.init(self.gpa);
        defer reader.deinit();
        var buf: [256 * 1024]u8 = undefined;
        var pane: ?*Pane = null;
        var attached = false;
        var negotiated = false;
        var watching = false;
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        outer: while (true) {
            const n = t.read(&buf);
            if (n == 0) break;
            reader.append(buf[0..n]) catch {
                if (negotiated) self.sendFailure(t, arena, "invalid frame");
                break;
            };
            while (reader.next() catch {
                if (negotiated) self.sendFailure(t, arena, "invalid frame");
                break :outer;
            }) |f| {
                switch (f.kind) {
                    .open => {
                        if (pane != null) {
                            if (negotiated) self.sendFailure(t, arena, "already attached");
                            break :outer;
                        }
                        const parsed = wire.parse(wire.OpenRequest, self.gpa, f.payload) catch {
                            // A valid JSON object can negotiate even when other
                            // required open fields are malformed or missing.
                            const probe = wire.parse(struct { paneControl: bool = false }, self.gpa, f.payload) catch null;
                            if (probe) |value| {
                                defer value.deinit();
                                if (value.value.paneControl) self.sendFailure(t, arena, "invalid open request") else self.sendExited(t, -1);
                            } else self.sendExited(t, -1);
                            break :outer;
                        };
                        defer parsed.deinit();
                        negotiated = parsed.value.paneControl;
                        const p = self.findPane(parsed.value.pane) orelse {
                            if (negotiated) self.sendFailure(t, arena, "no such pane") else self.sendExited(t, -1);
                            break :outer;
                        };
                        pane = p; // pinned by findPane until the connection ends
                        _ = arena_state.reset(.retain_capacity);
                        p.attach(t, arena, parsed.value) catch |e| {
                            log("attach failed: {s}", .{@errorName(e)});
                            if (negotiated) self.sendFailure(t, arena, "attach failed");
                            break :outer;
                        };
                        attached = true;
                        // A shell waiting for an attachment can now start.
                        p.releaseExecution() catch {};
                    },
                    .input => if (pane) |p| {
                        p.inputFrom(t, f.payload);
                    },
                    .resize => if (pane) |p| {
                        if (wire.GridSize.decode(f.payload)) |size| {
                            p.resizeFrom(t, size);
                        } else if (negotiated) {
                            self.sendFailure(t, arena, "invalid resize");
                            break :outer;
                        }
                    },
                    .kill => if (pane) |p| {
                        p.killFrom(t);
                    },
                    .paneControl => {
                        if (!negotiated or pane == null) break :outer;
                        if (f.payload.len != 1 or f.payload[0] > 1) {
                            self.sendFailure(t, arena, "invalid pane control");
                            break :outer;
                        }
                        pane.?.control(t, f.payload[0] == 1);
                    },
                    .watch => {
                        if (!self.addWatcher(t)) break :outer;
                        watching = true;
                        self.sendState(t);
                    },
                    .command => {
                        _ = arena_state.reset(.retain_capacity);
                        self.replyCommand(arena, t, f.payload, watching) catch break :outer;
                    },
                    .offer => {
                        _ = arena_state.reset(.retain_capacity);
                        if (self.offer(arena)) |o| {
                            const frame = wire.frameJson(arena, .offered, o) catch break :outer;
                            t.send(frame);
                        } else |_| break :outer;
                    },
                    else => {
                        if (negotiated) self.sendFailure(t, arena, "unexpected frame");
                        break :outer;
                    },
                }
            }
        }
        // Unregister before closing: closing a link stream may let the link
        // free it, and nothing may send to it after that.
        if (pane) |p| {
            if (attached) p.detach(t);
            p.unpin();
        }
        self.removeWatcher(t);
        t.close();
    }

    /// Sends a negotiated protocol failure without using an exit status.
    fn sendFailure(_: *Server, t: Transport, arena: Allocator, message: []const u8) void {
        const frame = wire.frameJson(arena, .failure, .{ .@"error" = message }) catch return;
        t.send(frame);
    }

    /// Registers a watcher once, however often it asks; false if out of memory.
    fn addWatcher(self: *Server, t: Transport) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.watchers.items) |w| if (w.ptr == t.ptr) return true;
        self.watchers.append(self.gpa, t) catch return false;
        return true;
    }

    fn removeWatcher(self: *Server, t: Transport) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.watchers.items, 0..) |w, i| {
            if (w.ptr == t.ptr) {
                _ = self.watchers.swapRemove(i);
                return;
            }
        }
    }

    fn sendExited(self: *Server, t: Transport, code: i32) void {
        _ = self;
        t.send(&wire.exitedFrame(code));
    }

    /// A client on another machine wants in over UDP: a link of its own,
    /// whose streams are served like local connections.
    fn offer(self: *Server, arena: Allocator) !wire.Offer {
        var secret: [32]u8 = undefined;
        sys.randomBytes(&secret);
        const hex = try arena.alloc(u8, 64);
        _ = try std.fmt.bufPrint(hex, "{x}", .{&secret});
        const entry = try self.gpa.create(LinkEntry);
        errdefer self.gpa.destroy(entry);
        self.mutex.lock();
        defer self.mutex.unlock();
        // Everything that can fail comes before the link exists, so none of
        // it has to be undone; `idleLoop` reclaims the link when it closes.
        try self.links.ensureUnusedCapacity(self.gpa, 1);
        const link = try link_mod.Link.listen(self.gpa, secret);
        entry.* = .{ .server = self, .link = link };
        link.on_stream_ctx = entry;
        link.on_stream = &onStream;
        link.on_close_ctx = entry;
        link.on_close = &onLinkClose;
        self.connections += 1;
        self.idle_since = sys.nowMillis();
        self.links.appendAssumeCapacity(entry);
        return .{ .port = link.port, .secret = hex };
    }

    fn onStream(ctx: ?*anyopaque, stream: *link_mod.Stream) void {
        const entry: *LinkEntry = @ptrCast(@alignCast(ctx orelse return));
        const server = entry.server;
        server.mutex.lock();
        const serving = !entry.closing;
        if (serving) _ = entry.readers.fetchAdd(1, .acq_rel);
        server.mutex.unlock();
        // A stream we will not serve is still ours to give back.
        if (!serving) return refuse(stream);
        const t = std.Thread.spawn(.{}, serveStream, .{ entry, stream }) catch {
            refuse(stream);
            _ = entry.readers.fetchSub(1, .release);
            return;
        };
        t.detach();
    }

    fn refuse(stream: *link_mod.Stream) void {
        stream.close();
        stream.release();
    }

    fn onLinkClose(ctx: ?*anyopaque) void {
        const entry: *LinkEntry = @ptrCast(@alignCast(ctx orelse return));
        entry.server.changeConnections(-1);
    }

    // MARK: The tree

    /// Parses once and sends the result before an eager tree to a subscribed
    /// caller. Other watchers keep their debounce; failed commands send no tree.
    fn replyCommand(self: *Server, arena: Allocator, t: Transport, payload: []const u8, watching: bool) !void {
        const parsed = wire.parse(wire.Command, arena, payload) catch {
            t.send(try wire.frameJson(arena, .result, wire.Result{ .@"error" = "malformed command" }));
            return;
        };
        defer parsed.deinit();
        const result = self.command(arena, parsed.value);
        t.send(try wire.frameJson(arena, .result, result));
        if (watching and result.@"error" == null) switch (parsed.value.op) {
            // Nonstructural commands deliver their snapshots on pane streams;
            // serverInfo is read-only and must not publish a tree.
            .newTab, .splitPane, .move, .group, .ungroup, .closeTab, .closeGroup, .closePane, .swapPanes, .resizeSplit, .renameTab, .renameGroup => self.sendState(t),
            .clearPane, .resetPane, .configurePane, .serverInfo, .reportStatus => {},
        };
    }

    /// Executes an already parsed command; returned strings live in `arena`
    /// or in the command, which must survive until the result is encoded.
    fn command(self: *Server, arena: Allocator, cmd: wire.Command) wire.Result {
        const size = wire.GridSize{
            .cols = @max(cmd.cols orelse 80, 1),
            .rows = @max(cmd.rows orelse 24, 1),
            .cell_width = cmd.cellWidth orelse 0,
            .cell_height = cmd.cellHeight orelse 0,
        };
        switch (cmd.op) {
            .serverInfo => return .{
                .serverVersion = binary_version,
                .serverPID = @intCast(c.getpid()),
                .protocolVersion = wire.version,
                .uptimeSeconds = (sys.monotonicMillis() -| self.started_at) / 1000,
                .transports = &transports,
                .capabilities = &capabilities,
                .layoutFormat = "weighted-v1",
                .snapshotFormat = "ghostty-vt-v1",
            },
            .reportStatus => {
                const status = cmd.status orelse return .{ .@"error" = "missing status" };
                const pane = self.findPane(cmd.pane orelse "") orelse return .{ .@"error" = "no such pane" };
                defer pane.unpin();
                pane.reportStatus(status) catch |err| return .{ .@"error" = @errorName(err) };
                return .{ .pane = cmd.pane };
            },
            .clearPane, .resetPane, .configurePane => {
                const pane = self.findPane(cmd.pane orelse "") orelse return .{ .@"error" = "no such pane" };
                defer pane.unpin();
                pane.editOwned(cmd.op, cmd.appearance, arena, cmd.controller) catch |err| return .{ .@"error" = @errorName(err) };
                return .{ .pane = cmd.pane };
            },
            .newTab => return self.newTab(arena, cmd, size),
            .closeTab, .closeGroup, .closePane => return self.closeTargets(arena, cmd),
            .group => {
                const result = self.groupTabs(arena, cmd);
                self.scheduleNotify();
                return result;
            },
            .move => {
                const result = self.moveTab(cmd);
                self.scheduleNotify();
                return result;
            },
            .splitPane => return self.splitPane(arena, cmd, size),
            .swapPanes => {
                // findPane locks the mutex itself, so resolve both panes
                // before taking it for the tree change.
                const a = self.findPane(cmd.pane orelse "") orelse return .{ .@"error" = "no such pane" };
                defer a.unpin();
                const b = self.findPane(cmd.target orelse "") orelse return .{ .@"error" = "no such pane" };
                defer b.unpin();
                self.mutex.lock();
                defer self.mutex.unlock();
                const ta = self.tabOf(a) orelse return .{ .@"error" = "no such tab" };
                if (self.tabOf(b) != ta) return .{ .@"error" = "panes are in different tabs" };
                const la = findLeaf(&ta.layout, a) orelse return .{ .@"error" = "pane not laid out" };
                const lb = findLeaf(&ta.layout, b) orelse return .{ .@"error" = "pane not laid out" };
                const targets: []const *Pane = if (a == b) &[_]*Pane{a} else &[_]*Pane{ a, b };
                if (!lockOwned(targets, cmd.controller)) return .{ .@"error" = "NOTOWNER" };
                defer unlockOwned(targets, cmd.controller);
                std.mem.swap(LayoutNode, la, lb);
                self.scheduleNotify();
                return .{ .pane = cmd.pane };
            },
            .resizeSplit => {
                self.mutex.lock();
                defer self.mutex.unlock();
                const split = self.findSplit(cmd.split orelse "") orelse return .{ .@"error" = "no such split" };
                var targets: std.ArrayList(*Pane) = .empty;
                defer targets.deinit(arena);
                if (cmd.controller != null) {
                    collectLayoutPanes(arena, .{ .split = split }, &targets) catch return .{ .@"error" = "out of memory" };
                }
                if (!lockOwned(targets.items, cmd.controller)) return .{ .@"error" = "NOTOWNER" };
                defer unlockOwned(targets.items, cmd.controller);
                if (cmd.weights) |weights| {
                    if (cmd.ratio != null or cmd.index != null) return .{ .@"error" = "weights cannot be combined with ratio or index" };
                    normalizeSplitWeights(split, weights) catch |err| return .{ .@"error" = @errorName(err) };
                    self.scheduleNotify();
                    return .{};
                }
                if (cmd.ratio) |ratio| if (!std.math.isFinite(ratio)) return .{ .@"error" = "ratio must be finite" };
                const i: usize = @intCast(@max(cmd.index orelse 0, 0));
                if (i >= split.children.items.len or split.children.items.len - i < 2) return .{ .@"error" = "no such divider" };
                // The two children on either side of the divider share their
                // combined weight by the dragged ratio; the rest hold still.
                const ratio = @min(@max(cmd.ratio orelse 0.5, 0.05), 0.95);
                const pair = split.children.items[i].weight + split.children.items[i + 1].weight;
                split.children.items[i].weight = pair * ratio;
                split.children.items[i + 1].weight = pair * (1 - ratio);
                self.scheduleNotify();
                return .{};
            },
            .renameGroup => {
                self.mutex.lock();
                defer self.mutex.unlock();
                const g = self.findGroup(cmd.group orelse "") orelse return .{ .@"error" = "no such group" };
                const name = std.mem.trim(u8, cmd.name orelse "", " ");
                g.name.ensureTotalCapacity(self.gpa, name.len) catch return .{ .@"error" = "out of memory" };
                g.name.clearRetainingCapacity();
                g.name.appendSliceAssumeCapacity(name);
                self.scheduleNotify();
                return .{ .group = cmd.group };
            },
            .renameTab => {
                self.mutex.lock();
                defer self.mutex.unlock();
                const t = self.findTab(cmd.tab orelse "") orelse return .{ .@"error" = "no such tab" };
                const name = std.mem.trim(u8, cmd.name orelse "", " ");
                t.name.ensureTotalCapacity(self.gpa, name.len) catch return .{ .@"error" = "out of memory" };
                t.name.clearRetainingCapacity();
                t.name.appendSliceAssumeCapacity(name);
                self.scheduleNotify();
                return .{ .tab = cmd.tab };
            },
            .ungroup => {
                self.mutex.lock();
                defer self.mutex.unlock();
                const gid = cmd.group orelse "";
                for (self.items.items, 0..) |item, i| {
                    switch (item) {
                        .group => |g| if (std.mem.eql(u8, &g.id, gid)) {
                            // Room for every tab first: the tabs must not be lost.
                            self.items.ensureUnusedCapacity(self.gpa, g.tabs.items.len) catch return .{ .@"error" = "out of memory" };
                            _ = self.items.orderedRemove(i);
                            for (g.tabs.items, 0..) |tb, j| self.items.insertAssumeCapacity(i + j, .{ .tab = tb });
                            g.tabs.deinit(self.gpa);
                            g.name.deinit(self.gpa);
                            self.gpa.destroy(g);
                            self.scheduleNotify();
                            return .{ .group = cmd.group };
                        },
                        .tab => {},
                    }
                }
                return .{ .@"error" = "no such group" };
            },
        }
    }

    /// Pins and validates all close targets before changing the tree. For a
    /// proved close, the nonblocking kill request is committed under the locks.
    fn closeTargets(self: *Server, arena: Allocator, cmd: wire.Command) wire.Result {
        self.mutex.lock();
        const targets = collect: {
            defer self.mutex.unlock();
            const tabs: []const *Tab = switch (cmd.op) {
                .closeTab => if (self.findTab(cmd.tab orelse "")) |t| &.{t} else &.{},
                .closeGroup => if (self.findGroup(cmd.group orelse "")) |g| g.tabs.items else &.{},
                .closePane => &.{},
                else => unreachable,
            };
            var one: ?*Pane = null;
            if (cmd.op == .closePane) {
                for (self.panes.items) |p| {
                    if (std.mem.eql(u8, &p.id, cmd.pane orelse "") and self.tabOf(p) != null) {
                        one = p;
                        break;
                    }
                }
                if (one == null) return .{ .@"error" = if (cmd.controller != null) "NOTOWNER" else "no such pane" };
            }
            var count: usize = if (one != null) 1 else 0;
            for (tabs) |t| count += t.panes.items.len;
            const selected = arena.alloc(*Pane, count) catch return .{ .@"error" = "out of memory" };
            var at: usize = 0;
            for (tabs) |t| for (t.panes.items) |p| {
                selected[at] = p;
                at += 1;
            };
            if (one) |p| selected[0] = p;
            if (!lockOwned(selected, cmd.controller)) {
                arena.free(selected);
                return .{ .@"error" = "NOTOWNER" };
            }
            defer unlockOwned(selected, cmd.controller);
            // Unlinking may free the tab/group slices above: finish collecting
            // first. Pins also cover readers that finish before kill runs.
            for (selected) |p| p.pin();
            for (selected) |p| self.unlinkPane(p);
            // The ownership proof must remain valid through the close commit.
            if (cmd.controller != null) for (selected) |p| p.kill();
            break :collect selected;
        };
        defer arena.free(targets);
        defer for (targets) |p| p.unpin();
        if (cmd.controller == null) for (targets) |p| p.kill();
        self.scheduleNotify();
        return switch (cmd.op) {
            .closeTab => .{ .tab = cmd.tab },
            .closeGroup => .{ .group = cmd.group },
            .closePane => .{ .pane = cmd.pane },
            else => unreachable,
        };
    }

    /// Puts `tab` with `target`: into `target`'s group, or into a new group
    /// of the two where `target` was. All allocation comes before the first
    /// change, so a failure leaves the tree as it was.
    fn groupTabs(self: *Server, arena: Allocator, cmd: wire.Command) wire.Result {
        self.mutex.lock();
        defer self.mutex.unlock();
        const id = cmd.tab orelse return .{ .@"error" = "no such tab" };
        const target = cmd.target orelse return .{ .@"error" = "no such tab" };
        if (std.mem.eql(u8, id, target) or self.findTab(id) == null) return .{ .@"error" = "no such tab" };
        const target_loc = self.locate(target) orelse return .{ .@"error" = "no such tab" };
        const oom: wire.Result = .{ .@"error" = "out of memory" };

        var new_group: ?*Group = null;
        if (target_loc.group) |g| {
            g.tabs.ensureUnusedCapacity(self.gpa, 1) catch return oom;
        } else {
            const g = self.gpa.create(Group) catch return oom;
            g.* = .{ .id = newID() };
            new_group = g;
            const ok = ok: {
                g.name.appendSlice(self.gpa, cmd.name orelse "") catch break :ok false;
                g.tabs.ensureTotalCapacity(self.gpa, 2) catch break :ok false;
                break :ok true;
            };
            if (!ok) {
                g.name.deinit(self.gpa);
                g.tabs.deinit(self.gpa);
                self.gpa.destroy(g);
                return oom;
            }
        }
        const group_id = arena.dupe(u8, &(if (new_group) |g| g.id else target_loc.group.?.id)) catch {
            if (new_group) |g| {
                g.name.deinit(self.gpa);
                g.tabs.deinit(self.gpa);
                self.gpa.destroy(g);
            }
            return oom;
        };

        const tab = self.takeTab(id).?;
        const loc = self.locate(target).?; // moved by the take, still there
        if (new_group) |g| {
            g.tabs.appendAssumeCapacity(self.items.items[loc.index].tab);
            g.tabs.appendAssumeCapacity(tab);
            self.items.items[loc.index] = .{ .group = g };
        } else {
            loc.group.?.tabs.insertAssumeCapacity(loc.index + 1, tab);
        }
        self.pruneGroups();
        return .{ .tab = cmd.tab, .group = group_id };
    }

    /// Moves `tab` into `group` (or to the top level when null) at `index`,
    /// or at the end.
    fn moveTab(self: *Server, cmd: wire.Command) wire.Result {
        self.mutex.lock();
        defer self.mutex.unlock();
        const id = cmd.tab orelse return .{ .@"error" = "no such tab" };
        if (self.findTab(id) == null) return .{ .@"error" = "no such tab" };
        const group = if (cmd.group) |gid| (self.findGroup(gid) orelse return .{ .@"error" = "no such group" }) else null;
        const reserved = if (group) |g| g.tabs.ensureUnusedCapacity(self.gpa, 1) else self.items.ensureUnusedCapacity(self.gpa, 1);
        reserved catch return .{ .@"error" = "out of memory" };
        const tab = self.takeTab(id).?;
        if (group) |g| {
            const at = clampIndex(cmd.index, g.tabs.items.len);
            g.tabs.insertAssumeCapacity(at, tab);
        } else {
            const at = clampIndex(cmd.index, self.items.items.len);
            self.items.insertAssumeCapacity(at, .{ .tab = tab });
        }
        self.pruneGroups();
        return .{ .tab = cmd.tab, .group = cmd.group };
    }

    fn clampIndex(index: ?i64, count: usize) usize {
        const i = index orelse return count;
        if (i < 0) return 0;
        return @min(@as(usize, @intCast(i)), count);
    }

    // These find and change the tree; callers hold `mutex`.

    fn findTab(self: *Server, id: []const u8) ?*Tab {
        for (self.items.items) |item| switch (item) {
            .tab => |t| if (std.mem.eql(u8, &t.id, id)) return t,
            .group => |g| for (g.tabs.items) |t| if (std.mem.eql(u8, &t.id, id)) return t,
        };
        return null;
    }

    fn findGroup(self: *Server, id: []const u8) ?*Group {
        for (self.items.items) |item| switch (item) {
            .group => |g| if (std.mem.eql(u8, &g.id, id)) return g,
            .tab => {},
        };
        return null;
    }

    /// The live pane with this id, pinned: the caller must `unpin` it, and
    /// until then the pane is not destroyed. Ended or hidden panes are not found.
    fn findPane(self: *Server, id: []const u8) ?*Pane {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.panes.items) |p| if (std.mem.eql(u8, &p.id, id) and !p.ended.load(.acquire) and self.tabOf(p) != null) {
            p.pin();
            return p;
        };
        return null;
    }

    const Location = struct { group: ?*Group, index: usize };

    /// The tab's group (null at the top level) and its index there.
    fn locate(self: *Server, id: []const u8) ?Location {
        for (self.items.items, 0..) |item, i| switch (item) {
            .tab => |t| if (std.mem.eql(u8, &t.id, id)) return .{ .group = null, .index = i },
            .group => |g| for (g.tabs.items, 0..) |t, j| if (std.mem.eql(u8, &t.id, id)) return .{ .group = g, .index = j },
        };
        return null;
    }

    /// Removes the tab from wherever it is and returns it.
    fn takeTab(self: *Server, id: []const u8) ?*Tab {
        const loc = self.locate(id) orelse return null;
        if (loc.group) |g| return g.tabs.orderedRemove(loc.index);
        return self.items.orderedRemove(loc.index).tab;
    }

    /// Drops groups that have no tabs left.
    fn pruneGroups(self: *Server) void {
        var i: usize = 0;
        while (i < self.items.items.len) {
            switch (self.items.items[i]) {
                .group => |g| if (g.tabs.items.len == 0) {
                    _ = self.items.orderedRemove(i);
                    g.tabs.deinit(self.gpa);
                    g.name.deinit(self.gpa);
                    self.gpa.destroy(g);
                    continue;
                },
                .tab => {},
            }
            i += 1;
        }
    }

    /// Creates a tab after cmd.tab (in its group), or at the end. The pane
    /// uses cmd.cwd/startup/appearance; omitted startup keeps the login shell.
    /// The child stays gated through allocation, reader prep and publication.
    /// Rejection never executes startup; no server lock spans fork or join.
    fn newTab(self: *Server, arena: Allocator, cmd: wire.Command, size: wire.GridSize) wire.Result {
        if (cmd.controller) |id| if (!wire.validController(id)) return .{ .@"error" = "InvalidController" };
        const after = cmd.tab;
        const oom: wire.Result = .{ .@"error" = "out of memory" };
        const tab = self.gpa.create(Tab) catch return oom;
        tab.* = .{ .id = newID(), .layout = undefined };
        const pane_id = newID();
        const result: wire.Result = .{
            .tab = arena.dupe(u8, &tab.id) catch {
                self.gpa.destroy(tab);
                return oom;
            },
            .pane = arena.dupe(u8, &pane_id) catch {
                self.gpa.destroy(tab);
                return oom;
            },
        };
        const extra = [_][]const u8{
            std.fmt.allocPrint(arena, "KOI_TAB={s}", .{&tab.id}) catch {
                self.gpa.destroy(tab);
                return oom;
            },
            std.fmt.allocPrint(arena, "KOI_PANE={s}", .{&pane_id}) catch {
                self.gpa.destroy(tab);
                return oom;
            },
        };
        const pane = Pane.create(self.gpa, pane_id, size, cmd.cwd, &extra, cmd.startup, cmd.appearance) catch |e| {
            self.gpa.destroy(tab);
            log("pane failed to start: {s}", .{@errorName(e)});
            return .{ .@"error" = @errorName(e) };
        };
        pane.reserveCreation(cmd.controller) catch |err| {
            pane.abort();
            pane.destroy();
            self.gpa.destroy(tab);
            return .{ .@"error" = @errorName(err) };
        };
        pane.ctx = self;
        pane.on_change = &onPaneChange;
        pane.on_close = &onPaneClose;
        tab.layout = .{ .pane = pane };

        pane.start() catch |err| {
            pane.abort();
            pane.destroy();
            self.gpa.destroy(tab);
            return .{ .@"error" = @errorName(err) };
        };
        self.registerTab(tab, pane, after) catch {
            pane.abort();
            pane.destroy();
            tab.panes.deinit(self.gpa);
            self.gpa.destroy(tab);
            return oom;
        };
        defer pane.unpin();
        startShell(pane, cmd) catch |err| {
            // Registered resources belong to the reader/reaper from here.
            pane.kill();
            return .{ .@"error" = @errorName(err) };
        };
        log("pane {s} started (pid {d})", .{ &pane_id, pane.pid });
        self.scheduleNotify();
        return result;
    }

    /// How long a published pane waits for its creator to attach before the
    /// shell starts regardless: generous, since a loaded machine attaches
    /// late and an early start only costs one prompt redraw.
    const attach_grace_ms = 1000;

    /// Lets a published pane's shell run. A client that sizes its panes
    /// (cell sizes present) attaches right away with the grid the pane will
    /// really get, so the shell waits for that, bounded, and draws its prompt
    /// once at the final size. Other creators start the shell at once.
    fn startShell(pane: *Pane, cmd: wire.Command) !void {
        if (cmd.cellWidth != null) {
            pane.deferExecution(sys.nowMillis() + attach_grace_ms);
        } else {
            try pane.releaseExecution();
        }
    }

    /// Reserves then publishes a prepared, gated pane. Success pins the pane
    /// for its caller until execution release; failure changes no visible tree.
    fn registerTab(self: *Server, tab: *Tab, pane: *Pane, after: ?[]const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const loc = if (after) |id| self.locate(id) else null;
        try tab.panes.ensureUnusedCapacity(self.gpa, 1);
        try self.panes.ensureUnusedCapacity(self.gpa, 1);
        if (loc) |l| {
            if (l.group) |g| try g.tabs.ensureUnusedCapacity(self.gpa, 1) else try self.items.ensureUnusedCapacity(self.gpa, 1);
        } else try self.items.ensureUnusedCapacity(self.gpa, 1);
        pane.pin();
        tab.panes.appendAssumeCapacity(pane);
        self.panes.appendAssumeCapacity(pane);
        if (loc) |l| {
            if (l.group) |g| g.tabs.insertAssumeCapacity(l.index + 1, tab) else self.items.insertAssumeCapacity(l.index + 1, .{ .tab = tab });
        } else self.items.appendAssumeCapacity(.{ .tab = tab });
    }

    fn onPaneChange(ctx: *anyopaque) void {
        const self: *Server = @ptrCast(@alignCast(ctx));
        self.scheduleNotify();
    }

    /// Removes a pane from the visible tree, pruning empty tabs and groups.
    /// Idempotent and allocation-free; callers hold the server mutex. This
    /// does not make the pane reclaimable: its reader must finish cleanup.
    fn unlinkPane(self: *Server, pane: *Pane) void {
        if (self.tabOf(pane)) |t| {
            for (t.panes.items, 0..) |p, i| if (p == pane) {
                _ = t.panes.swapRemove(i);
                break;
            };
            _ = self.removeLeaf(&t.layout, pane);
            if (t.panes.items.len == 0) {
                _ = self.takeTab(&t.id);
                t.panes.deinit(self.gpa);
                t.name.deinit(self.gpa);
                self.gpa.destroy(t);
            }
        }
        self.pruneGroups();
    }

    /// Removes a closing reader's pane before child teardown. Explicit close
    /// already removed it; `ended` stays false until cleanup is complete.
    fn onPaneClose(ctx: *anyopaque, pane: *Pane) void {
        const self: *Server = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        if (pane.unlinked) {
            self.mutex.unlock();
            return;
        }
        self.unlinkPane(pane);
        pane.unlinked = true;
        self.idle_since = sys.nowMillis();
        log("pane {s} ended", .{&pane.id});
        self.mutex.unlock();
        self.scheduleNotify();
    }

    fn scheduleNotify(self: *Server) void {
        self.notify_mutex.lock();
        self.notify_pending = true;
        self.notify_cond.signal();
        self.notify_mutex.unlock();
    }

    /// Sends watchers the tree as soon as it changes, then holds further
    /// changes for a short quiet window so a burst costs one more update
    /// rather than one per change.
    fn notifyLoop(self: *Server) void {
        while (true) {
            self.notify_mutex.lock();
            while (!self.notify_pending) self.notify_cond.wait(&self.notify_mutex);
            self.notify_pending = false;
            self.notify_mutex.unlock();
            self.sendChangedState();
            sys.sleepMillis(30);
        }
    }

    /// Sends the batched watchers the tree, if it differs from what they have.
    fn sendChangedState(self: *Server) void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        const json = self.buildState(arena) catch return;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (std.mem.eql(u8, json, self.last_state.items)) return;
        self.last_state.clearRetainingCapacity();
        self.last_state.appendSlice(self.gpa, json) catch {};
        const frame = wire.frame(arena, .state, json) catch return;
        for (self.watchers.items) |w| w.send(frame);
    }

    /// Sends a current tree without changing the batched watchers' cache.
    fn sendState(self: *Server, t: Transport) void {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const json = self.buildState(arena) catch return;
        const frame = wire.frame(arena, .state, json) catch return;
        t.send(frame);
    }

    /// Copies the tree under the mutex, taking each pane's own lock for its
    /// info (server lock first), then encodes the owned copies without it.
    fn buildState(self: *Server, arena: Allocator) ![]const u8 {
        var items: std.ArrayList(wire.Item) = .empty;
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            for (self.items.items) |item| {
                switch (item) {
                    .tab => |t| try items.append(arena, .{ .tab = try tabInfo(arena, t) }),
                    .group => |g| {
                        var tabs: std.ArrayList(wire.TabInfo) = .empty;
                        for (g.tabs.items) |t| try tabs.append(arena, try tabInfo(arena, t));
                        try items.append(arena, .{ .group = .{
                            .id = try arena.dupe(u8, &g.id),
                            .name = try arena.dupe(u8, g.name.items),
                            .tabs = tabs.items,
                        } });
                    },
                }
            }
        }
        return std.json.Stringify.valueAlloc(arena, wire.State{ .items = items.items }, .{ .emit_null_optional_fields = false });
    }

    fn tabInfo(arena: Allocator, t: *Tab) !wire.TabInfo {
        var panes: std.ArrayList(wire.PaneInfo) = .empty;
        for (t.panes.items) |p| try panes.append(arena, try p.info(arena));
        return .{ .id = try arena.dupe(u8, &t.id), .name = try arena.dupe(u8, t.name.items), .panes = panes.items, .layout = try layoutInfo(arena, t.layout) };
    }

    fn layoutInfo(arena: Allocator, node: LayoutNode) !wire.Layout {
        switch (node) {
            .pane => |p| return .{ .pane = try arena.dupe(u8, &p.id) },
            .split => |s| {
                const children = try arena.alloc(wire.Layout.Child, s.children.items.len);
                for (s.children.items, 0..) |child, i| {
                    const sub = try arena.create(wire.Layout);
                    sub.* = try layoutInfo(arena, child.node);
                    children[i] = .{ .layout = sub, .weight = child.weight };
                }
                return .{ .split = .{
                    .id = try arena.dupe(u8, &s.id),
                    .direction = s.direction,
                    .children = children,
                } };
            },
        }
    }

    /// Prepares a gated child/reader without the tree lock, then revalidates
    /// the source and reserves all split resources before publishing/releasing.
    /// Closing the source or allocation failure cannot execute startup source.
    fn splitPane(self: *Server, arena: Allocator, cmd: wire.Command, size: wire.GridSize) wire.Result {
        const pane_id = cmd.pane orelse "";
        const direction = cmd.direction orelse .right;
        const oom: wire.Result = .{ .@"error" = "out of memory" };
        const old = self.findPane(pane_id) orelse return .{ .@"error" = if (cmd.controller != null) "NOTOWNER" else "no such pane" };
        defer old.unpin();
        if (cmd.controller != null) {
            old.mutex.lock();
            const allowed = old.ownsControllerLocked(cmd.controller);
            old.mutex.unlock();
            if (!allowed) return .{ .@"error" = "NOTOWNER" };
        }
        self.mutex.lock();
        const tab_id = (self.tabOf(old) orelse {
            self.mutex.unlock();
            return .{ .@"error" = "no such pane" };
        }).id;
        self.mutex.unlock();
        const cwd = cmd.cwd orelse cwd: {
            old.mutex.lock();
            defer old.mutex.unlock();
            break :cwd arena.dupe(u8, old.cwd.items) catch return oom;
        };
        const new_id = newID();
        const result: wire.Result = .{
            .tab = arena.dupe(u8, &tab_id) catch return oom,
            .pane = arena.dupe(u8, &new_id) catch return oom,
        };
        const extra = [_][]const u8{
            std.fmt.allocPrint(arena, "KOI_TAB={s}", .{&tab_id}) catch return oom,
            std.fmt.allocPrint(arena, "KOI_PANE={s}", .{&new_id}) catch return oom,
        };
        const pane = Pane.create(self.gpa, new_id, size, cwd, &extra, cmd.startup, cmd.appearance) catch |e| {
            log("pane failed to start: {s}", .{@errorName(e)});
            return .{ .@"error" = @errorName(e) };
        };
        pane.reserveCreation(cmd.controller) catch |err| {
            pane.abort();
            pane.destroy();
            return .{ .@"error" = @errorName(err) };
        };
        pane.ctx = self;
        pane.on_change = &onPaneChange;
        pane.on_close = &onPaneClose;

        pane.start() catch |err| {
            pane.abort();
            pane.destroy();
            return .{ .@"error" = @errorName(err) };
        };
        self.registerSplit(old, pane, direction, cmd.controller) catch |err| {
            pane.abort();
            pane.destroy();
            return .{ .@"error" = if (err == error.OutOfMemory) "out of memory" else @errorName(err) };
        };
        defer pane.unpin();
        startShell(pane, cmd) catch |err| {
            pane.kill();
            return .{ .@"error" = @errorName(err) };
        };
        log("pane {s} started (pid {d}) beside {s}", .{ &new_id, pane.pid, &old.id });
        self.scheduleNotify();
        return result;
    }

    /// Revalidates a source after fork/reader preparation, then publishes its
    /// gated sibling without further fallible work. Success returns one pin.
    fn registerSplit(self: *Server, old: *Pane, pane: *Pane, direction: wire.Direction, controller: ?[]const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (controller != null) old.mutex.lock();
        defer if (controller != null) old.mutex.unlock();
        if (!old.ownsControllerLocked(controller)) return error.NOTOWNER;
        if (old.closing.load(.acquire) or old.ended.load(.acquire)) return error.PaneClosed;
        const tab = self.tabOf(old) orelse return error.PaneClosed;
        if (findLeaf(&tab.layout, old) == null) return error.PaneNotLaidOut;
        try self.panes.ensureUnusedCapacity(self.gpa, 1);
        try tab.panes.ensureUnusedCapacity(self.gpa, 1);
        if (parentOf(&tab.layout, old)) |pc| if (pc.split.direction == direction) {
            try pc.split.children.ensureUnusedCapacity(self.gpa, 1);
            const weight = pc.split.children.items[pc.index].weight;
            pane.pin();
            pc.split.children.insertAssumeCapacity(pc.index + 1, .{ .node = .{ .pane = pane }, .weight = weight });
            self.panes.appendAssumeCapacity(pane);
            tab.panes.appendAssumeCapacity(pane);
            return;
        };
        const split = try self.gpa.create(SplitNode);
        errdefer self.gpa.destroy(split);
        split.* = .{ .id = newID(), .direction = direction };
        try split.children.ensureTotalCapacity(self.gpa, 2);
        split.children.appendAssumeCapacity(.{ .node = .{ .pane = old } });
        split.children.appendAssumeCapacity(.{ .node = .{ .pane = pane } });
        pane.pin();
        _ = replaceLeaf(&tab.layout, old, .{ .split = split });
        self.panes.appendAssumeCapacity(pane);
        tab.panes.appendAssumeCapacity(pane);
    }

    /// The tab holding `pane`. Callers hold `mutex`.
    fn tabOf(self: *Server, pane: *Pane) ?*Tab {
        for (self.items.items) |item| {
            const tabs: []const *Tab = switch (item) {
                .tab => |t| &.{t},
                .group => |g| g.tabs.items,
            };
            for (tabs) |t| for (t.panes.items) |p| if (p == pane) return t;
        }
        return null;
    }

    fn findSplit(self: *Server, id: []const u8) ?*SplitNode {
        for (self.items.items) |item| {
            const tabs: []const *Tab = switch (item) {
                .tab => |t| &.{t},
                .group => |g| g.tabs.items,
            };
            for (tabs) |t| if (findSplitIn(t.layout, id)) |s| return s;
        }
        return null;
    }

    fn findSplitIn(node: LayoutNode, id: []const u8) ?*SplitNode {
        switch (node) {
            .pane => return null,
            .split => |s| {
                if (std.mem.eql(u8, &s.id, id)) return s;
                for (s.children.items) |child| if (findSplitIn(child.node, id)) |f| return f;
                return null;
            },
        }
    }

    const ParentChild = struct { split: *SplitNode, index: usize };

    /// The split that holds `pane` directly, and the pane's place in it.
    fn parentOf(node: *LayoutNode, pane: *Pane) ?ParentChild {
        switch (node.*) {
            .pane => return null,
            .split => |s| {
                for (s.children.items, 0..) |child, i| {
                    if (child.node == .pane and child.node.pane == pane) return .{ .split = s, .index = i };
                }
                for (s.children.items) |*child| if (parentOf(&child.node, pane)) |pc| return pc;
                return null;
            },
        }
    }

    /// The leaf node that holds `pane`, for swapping two panes' positions.
    fn findLeaf(node: *LayoutNode, pane: *Pane) ?*LayoutNode {
        switch (node.*) {
            .pane => |p| return if (p == pane) node else null,
            .split => |s| {
                for (s.children.items) |*child| if (findLeaf(&child.node, pane)) |n| return n;
                return null;
            },
        }
    }

    /// Puts `with` where `pane`'s leaf is.
    fn replaceLeaf(node: *LayoutNode, pane: *Pane, with: LayoutNode) bool {
        switch (node.*) {
            .pane => |p| {
                if (p != pane) return false;
                node.* = with;
                return true;
            },
            .split => |s| {
                for (s.children.items) |*child| if (replaceLeaf(&child.node, pane, with)) return true;
                return false;
            },
        }
    }

    /// Takes `pane`'s leaf out of its split; a split left with one child gives
    /// way to that child. A tab whose only pane ends is removed by the caller.
    fn removeLeaf(self: *Server, node: *LayoutNode, pane: *Pane) bool {
        switch (node.*) {
            .pane => return false,
            .split => |s| {
                for (s.children.items, 0..) |child, i| {
                    if (child.node == .pane and child.node.pane == pane) {
                        _ = s.children.orderedRemove(i);
                        if (s.children.items.len == 1) {
                            const only = s.children.items[0].node;
                            s.children.deinit(self.gpa);
                            self.gpa.destroy(s);
                            node.* = only;
                        }
                        return true;
                    }
                }
                for (s.children.items) |*child| if (self.removeLeaf(&child.node, pane)) return true;
                return false;
            },
        }
    }

    /// Exits once there has been nothing to serve for a few seconds, and
    /// frees what ended along the way: unlinked panes nobody holds, and
    /// closed links whose connection threads are done. Frees happen outside
    /// the lock; `destroy` joins the link's receiver, which may be inside
    /// `onStream` waiting for that lock.
    fn idleLoop(self: *Server) noreturn {
        while (true) {
            sys.sleepMillis(5000);
            self.reapPanes();
            self.reapLinks();
            self.mutex.lock();
            const idle = self.panes.items.len == 0 and self.connections == 0 and sys.nowMillis() - self.idle_since > 5000;
            self.mutex.unlock();
            if (idle) {
                log("idle, exiting", .{});
                _ = c.unlink(cstr(self.paths.socket));
                std.process.exit(0);
            }
        }
    }

    fn reapPanes(self: *Server) void {
        while (true) {
            self.mutex.lock();
            var found: ?*Pane = null;
            for (self.panes.items, 0..) |p, i| {
                if (p.unlinked and p.ended.load(.acquire) and p.pins.load(.acquire) == 0) {
                    found = self.panes.swapRemove(i);
                    break;
                }
            }
            self.mutex.unlock();
            (found orelse return).destroy();
        }
    }

    fn reapLinks(self: *Server) void {
        while (true) {
            self.mutex.lock();
            var found: ?*LinkEntry = null;
            for (self.links.items, 0..) |entry, i| {
                if (!entry.link.isClosed() or entry.readers.load(.acquire) != 0) continue;
                entry.closing = true;
                found = self.links.swapRemove(i);
                break;
            }
            self.mutex.unlock();
            const entry = found orelse return;
            entry.link.destroy();
            self.gpa.destroy(entry);
        }
    }
};

var cstr_buf: [8][512]u8 = undefined;
var cstr_next: usize = 0;

/// A NUL-terminated copy of a short path, from a small rotating pool.
fn cstr(s: []const u8) [*:0]const u8 {
    const buf = &cstr_buf[cstr_next % cstr_buf.len];
    cstr_next += 1;
    const n = @min(s.len, buf.len - 1);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    return @ptrCast(buf);
}

fn newID() [8]u8 {
    var bytes: [4]u8 = undefined;
    sys.randomBytes(&bytes);
    var out: [8]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x}", .{&bytes}) catch unreachable;
    return out;
}

// MARK: Tests

const testing = std.testing;

const NoopTransport = struct {
    var vtable = Transport.VTable{ .send = send, .read = read, .close = close };
    fn send(_: *anyopaque, _: []const u8) void {}
    fn read(_: *anyopaque, _: []u8) usize {
        return 0;
    }
    fn close(_: *anyopaque) void {}
    fn transport(self: *NoopTransport) Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

/// A finite request stream with recorded replies, for serving commands without
/// sockets, reader threads or shells. Tests own and free both byte arrays.
const CommandTransport = struct {
    incoming: std.ArrayList(u8) = .empty,
    sent: std.ArrayList(u8) = .empty,
    read_at: usize = 0,
    var vtable = Transport.VTable{ .send = send, .read = read, .close = close };

    fn transport(self: *CommandTransport) Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn queue(self: *CommandTransport, kind: wire.Kind, payload: []const u8) !void {
        const frame = try wire.frame(testing.allocator, kind, payload);
        defer testing.allocator.free(frame);
        try self.incoming.appendSlice(testing.allocator, frame);
    }

    fn deinit(self: *CommandTransport) void {
        self.incoming.deinit(testing.allocator);
        self.sent.deinit(testing.allocator);
    }

    fn send(ptr: *anyopaque, bytes: []const u8) void {
        const self: *CommandTransport = @ptrCast(@alignCast(ptr));
        self.sent.appendSlice(testing.allocator, bytes) catch unreachable;
    }

    fn read(ptr: *anyopaque, buf: []u8) usize {
        const self: *CommandTransport = @ptrCast(@alignCast(ptr));
        const n = @min(buf.len, self.incoming.items.len - self.read_at);
        @memcpy(buf[0..n], self.incoming.items[self.read_at..][0..n]);
        self.read_at += n;
        return n;
    }

    fn close(_: *anyopaque) void {}
};

fn testServer(gpa: Allocator) Server {
    return .{ .gpa = gpa, .paths = undefined, .mutex = sys.Mutex.init(), .notify_mutex = sys.Mutex.init(), .notify_cond = sys.Cond.init(), .state_mutex = sys.Mutex.init() };
}

/// A shell-less tab, enough for the tree operations.
fn testTab(server: *Server, id: []const u8) !*Tab {
    const tab = try server.gpa.create(Tab);
    tab.* = .{ .id = undefined, .layout = undefined };
    @memcpy(&tab.id, id[0..8]);
    try server.items.append(server.gpa, .{ .tab = tab });
    return tab;
}

fn freeTree(server: *Server) void {
    for (server.items.items) |item| switch (item) {
        .tab => |t| freeTab(server.gpa, t),
        .group => |g| {
            for (g.tabs.items) |t| freeTab(server.gpa, t);
            g.tabs.deinit(server.gpa);
            g.name.deinit(server.gpa);
            server.gpa.destroy(g);
        },
    };
    server.items.deinit(server.gpa);
    server.watchers.deinit(server.gpa);
    server.links.deinit(server.gpa);
    server.panes.deinit(server.gpa);
}

fn freeTab(gpa: Allocator, t: *Tab) void {
    t.panes.deinit(gpa);
    t.name.deinit(gpa);
    gpa.destroy(t);
}

fn hasEmptyGroup(server: *Server) bool {
    for (server.items.items) |item| switch (item) {
        .group => |g| if (g.tabs.items.len == 0) return true,
        .tab => {},
    };
    return false;
}

/// An owned terminal without a reader or child, for deterministic tree and
/// lifetime tests. Tests may install an explicitly owned child themselves.
fn testPane(server: *Server, tab: *Tab, id: [8]u8) !*Pane {
    const pane = try server.gpa.create(Pane);
    errdefer server.gpa.destroy(pane);
    const shell = try server.gpa.dupe(u8, "sh");
    errdefer server.gpa.free(shell);
    const home = try server.gpa.dupe(u8, "/tmp");
    errdefer server.gpa.free(home);
    var terminal = try @import("emulator.zig").Terminal.init(80, 24);
    errdefer terminal.deinit();
    try tab.panes.ensureUnusedCapacity(server.gpa, 1);
    try server.panes.ensureUnusedCapacity(server.gpa, 1);
    pane.* = .{
        .gpa = server.gpa,
        .id = id,
        .pid = -1,
        .master = -1,
        .terminal = terminal,
        .mutex = sys.Mutex.init(),
        .size = .{ .cols = 80, .rows = 24, .cell_width = 8, .cell_height = 16 },
        .shell = shell,
        .home = home,
    };
    tab.panes.appendAssumeCapacity(pane);
    server.panes.appendAssumeCapacity(pane);
    tab.layout = .{ .pane = pane };
    return pane;
}

/// Frees shell-less panes still retained by the test server.
fn freeTestPanes(server: *Server) void {
    for (server.panes.items) |p| p.destroy();
}

/// Attaches a test controller without starting a shell or an external server.
fn attachTestController(pane: *Pane, peer: *CommandTransport, arena: Allocator, id: ?[]const u8, observer: bool) !void {
    try pane.attach(peer.transport(), arena, .{ .pane = &pane.id, .cols = 0, .rows = 0, .cellWidth = 8, .cellHeight = 16, .paneControl = true, .observer = observer, .controller = id });
}

test "controller close validates every target before changing the tree" {
    for ([_]wire.Op{ .closePane, .closeTab, .closeGroup }) |op| {
        var server = testServer(testing.allocator);
        defer freeTree(&server);
        defer freeTestPanes(&server);
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var a_peer = CommandTransport{};
        defer a_peer.deinit();
        var b_peer = CommandTransport{};
        defer b_peer.deinit();
        var other = CommandTransport{};
        defer other.deinit();
        const tab = try testTab(&server, "aaaaaaaa");
        const a = try testPane(&server, tab, "11111111".*);
        const b = try testPane(&server, tab, "22222222".*);
        const split = try server.gpa.create(SplitNode);
        split.* = .{ .id = "split123".*, .direction = .right };
        try split.children.appendSlice(server.gpa, &.{ .{ .node = .{ .pane = a } }, .{ .node = .{ .pane = b } } });
        tab.layout = .{ .split = split };
        const second = try testTab(&server, "bbbbbbbb");
        const c_pane = try testPane(&server, second, "33333333".*);
        const group = server.groupTabs(arena.allocator(), .{ .op = .group, .tab = "bbbbbbbb", .target = "aaaaaaaa" });
        try testing.expect(group.@"error" == null);
        try attachTestController(a, &a_peer, arena.allocator(), "workspace", false);
        try attachTestController(b, &b_peer, arena.allocator(), "workspace", false);
        try attachTestController(c_pane, &other, arena.allocator(), "different", false);
        // A controller with no attachment cannot close even an unvisited pane.
        const unvisited = server.command(arena.allocator(), .{ .op = .closePane, .pane = &a.id, .controller = "unvisited" });
        try testing.expectEqualStrings("NOTOWNER", unvisited.@"error".?);
        const cmd = wire.Command{ .op = op, .pane = &a.id, .tab = &tab.id, .group = group.group, .controller = "workspace" };
        if (op == .closePane) {
            a.control(other.transport(), true); // not attached: no transfer
            try attachTestController(a, &other, arena.allocator(), "different", true);
            a.control(other.transport(), true);
        } else if (op == .closeTab) {
            try attachTestController(b, &other, arena.allocator(), "different", true);
            b.control(other.transport(), true);
        }
        const denied = server.command(arena.allocator(), cmd);
        try testing.expectEqualStrings("NOTOWNER", denied.@"error".?);
        try testing.expect(server.tabOf(a) != null and server.tabOf(b) != null and server.tabOf(c_pane) != null);
        try testing.expect(!a.closing.load(.acquire) and !b.closing.load(.acquire) and !c_pane.closing.load(.acquire));
        // Omitted proof remains the explicit legacy close path.
        var legacy = cmd;
        legacy.controller = null;
        try testing.expect(server.command(arena.allocator(), legacy).@"error" == null);
    }
}

test "split registration and edits recheck ownership after transfer" {
    var server = testServer(testing.allocator);
    defer freeTree(&server);
    defer freeTestPanes(&server);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var first = CommandTransport{};
    defer first.deinit();
    var second = CommandTransport{};
    defer second.deinit();
    const tab = try testTab(&server, "aaaaaaaa");
    const old = try testPane(&server, tab, "11111111".*);
    const prepared = try testPane(&server, tab, "22222222".*);
    tab.layout = .{ .pane = old };
    try attachTestController(old, &first, arena.allocator(), "first", false);
    try attachTestController(old, &second, arena.allocator(), "second", true);
    old.mutex.lock();
    try testing.expect(old.ownsControllerLocked("first"));
    old.mutex.unlock();
    old.control(second.transport(), true);
    try testing.expectError(error.NOTOWNER, server.registerSplit(old, prepared, .right, "first"));
    try testing.expect(tab.layout == .pane and tab.layout.pane == old);
    const edit = server.command(arena.allocator(), .{ .op = .resetPane, .pane = &old.id, .controller = "first" });
    try testing.expectEqualStrings("NOTOWNER", edit.@"error".?);
}

test "controller proof authorizes current owner and rejects legacy owners" {
    var server = testServer(testing.allocator);
    defer freeTree(&server);
    defer freeTestPanes(&server);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var peer = CommandTransport{};
    defer peer.deinit();
    const tab = try testTab(&server, "aaaaaaaa");
    const pane = try testPane(&server, tab, "11111111".*);
    try attachTestController(pane, &peer, arena.allocator(), null, false);
    const cmd = wire.Command{ .op = .closePane, .pane = &pane.id, .controller = "workspace" };
    try testing.expectEqualStrings("NOTOWNER", server.command(arena.allocator(), cmd).@"error".?);
    pane.detach(peer.transport());
    try attachTestController(pane, &peer, arena.allocator(), "workspace", false);
    try testing.expect(server.command(arena.allocator(), cmd).@"error" == null);
    try testing.expect(pane.closing.load(.acquire));
    try testing.expect(server.tabOf(pane) == null);
}

test "creation reservation permits recipe edits splits resize and close before attachment" {
    var server = testServer(testing.allocator);
    defer freeTree(&server);
    defer {
        for (server.panes.items) |pane| pane.kill();
        freeTestPanes(&server);
    }
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const made = server.command(arena.allocator(), .{ .op = .newTab, .cwd = "/", .startup = "exec /bin/cat", .controller = "creator" });
    try testing.expect(made.@"error" == null);
    const pane_id = made.pane orelse return error.MissingPane;
    const tab_id = made.tab orelse return error.MissingTab;
    const foreign = server.command(arena.allocator(), .{ .op = .clearPane, .pane = pane_id, .controller = "foreign" });
    try testing.expectEqualStrings("NOTOWNER", foreign.@"error".?);
    const edit = server.command(arena.allocator(), .{ .op = .clearPane, .pane = pane_id, .controller = "creator" });
    try testing.expect(edit.@"error" == null);
    const denied_split = server.command(arena.allocator(), .{ .op = .splitPane, .pane = pane_id, .controller = "foreign" });
    try testing.expectEqualStrings("NOTOWNER", denied_split.@"error".?);
    const made_split = server.command(arena.allocator(), .{ .op = .splitPane, .pane = pane_id, .cwd = "/", .startup = "exec /bin/cat", .controller = "creator" });
    try testing.expect(made_split.@"error" == null);
    const split_pane = made_split.pane orelse return error.MissingPane;
    const child_edit = server.command(arena.allocator(), .{ .op = .clearPane, .pane = split_pane, .controller = "creator" });
    try testing.expect(child_edit.@"error" == null);
    const tab = server.findTab(tab_id) orelse return error.MissingTab;
    const split_id = tab.layout.split.id;
    const resize = server.command(arena.allocator(), .{ .op = .resizeSplit, .split = &split_id, .ratio = 0.25, .controller = "creator" });
    try testing.expect(resize.@"error" == null);
    const denied_close = server.command(arena.allocator(), .{ .op = .closeTab, .tab = tab_id, .controller = "foreign" });
    try testing.expectEqualStrings("NOTOWNER", denied_close.@"error".?);
    const closed = server.command(arena.allocator(), .{ .op = .closeTab, .tab = tab_id, .controller = "creator" });
    try testing.expect(closed.@"error" == null);
    try testing.expect(server.findTab(tab_id) == null);
}

test "foreign ownership permanently revokes a creation close proof" {
    var server = testServer(testing.allocator);
    defer freeTree(&server);
    defer freeTestPanes(&server);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var peer = CommandTransport{};
    defer peer.deinit();
    const tab = try testTab(&server, "aaaaaaaa");
    const pane = try testPane(&server, tab, "11111111".*);
    try pane.reserveCreation("creator");
    try attachTestController(pane, &peer, arena.allocator(), "foreign", true);
    pane.control(peer.transport(), true);
    pane.detach(peer.transport());
    const closed = server.command(arena.allocator(), .{ .op = .closePane, .pane = &pane.id, .controller = "creator" });
    try testing.expectEqualStrings("NOTOWNER", closed.@"error".?);
    try testing.expect(server.tabOf(pane) != null and !pane.closing.load(.acquire));
}

test "swap and split resize require ownership of all affected panes" {
    var server = testServer(testing.allocator);
    defer freeTree(&server);
    defer freeTestPanes(&server);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var first = CommandTransport{};
    defer first.deinit();
    var second = CommandTransport{};
    defer second.deinit();
    const tab = try testTab(&server, "aaaaaaaa");
    const a = try testPane(&server, tab, "11111111".*);
    const b = try testPane(&server, tab, "22222222".*);
    const split = try server.gpa.create(SplitNode);
    split.* = .{ .id = "split123".*, .direction = .right };
    try split.children.appendSlice(server.gpa, &.{ .{ .node = .{ .pane = a } }, .{ .node = .{ .pane = b } } });
    defer {
        split.children.deinit(server.gpa);
        server.gpa.destroy(split);
    }
    tab.layout = .{ .split = split };
    try attachTestController(a, &first, arena.allocator(), "first", false);
    try attachTestController(b, &second, arena.allocator(), "second", false);
    const swap = server.command(arena.allocator(), .{ .op = .swapPanes, .pane = &a.id, .target = &b.id, .controller = "first" });
    try testing.expectEqualStrings("NOTOWNER", swap.@"error".?);
    const resize = server.command(arena.allocator(), .{ .op = .resizeSplit, .split = &split.id, .ratio = 0.25, .controller = "first" });
    try testing.expectEqualStrings("NOTOWNER", resize.@"error".?);
    try testing.expect(split.children.items[0].node.pane == a and split.children.items[1].node.pane == b);
    try testing.expectEqual(@as(f64, 1), split.children.items[0].weight);
    try testing.expectEqual(@as(f64, 1), split.children.items[1].weight);
}

test "explicit close sends an eager empty tree while its child is still alive" {
    var server = testServer(testing.allocator);
    defer freeTree(&server);
    defer freeTestPanes(&server);
    const tab = try testTab(&server, "aaaaaaaa");
    const pane = try testPane(&server, tab, "bbbbbbbb".*);
    var ready: [2]c_int = undefined;
    try testing.expectEqual(0, c.pipe(&ready));
    defer _ = c.close(ready[0]);
    const pid = c.fork();
    try testing.expect(pid >= 0);
    if (pid == 0) {
        _ = c.close(ready[0]);
        sys.ignoreSignal(c.SIGHUP);
        const byte = [_]u8{1};
        _ = c.write(ready[1], &byte, 1);
        _ = c.close(ready[1]);
        while (true) _ = c.pause();
    }
    _ = c.close(ready[1]);
    pane.pid = pid;
    defer pane.abandon(); // Only this private child; no server or shell lookup.
    var fds = [_]c.struct_pollfd{.{ .fd = ready[0], .events = c.POLLIN, .revents = 0 }};
    try testing.expect(c.poll(&fds, 1, 2000) > 0);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var conn = CommandTransport{};
    defer conn.deinit();
    // Holding the pane mutex also proves close does not wait for it under the
    // tree lock. The reader has deliberately not started, so no EOF can help.
    pane.mutex.lock();
    const reply = server.replyCommand(arena.allocator(), conn.transport(), "{\"op\":\"closeTab\",\"tab\":\"aaaaaaaa\"}", true);
    pane.mutex.unlock();
    try reply;
    var replies = wire.FrameReader.init(testing.allocator);
    defer replies.deinit();
    try replies.append(conn.sent.items);
    try testing.expectEqual(wire.Kind.result, (try replies.next()).?.kind);
    const state = (try replies.next()).?;
    try testing.expectEqual(wire.Kind.state, state.kind);
    try testing.expectEqualStrings("{\"items\":[]}", state.payload);
    var status: c_int = 0;
    try testing.expectEqual(@as(c.pid_t, 0), c.waitpid(pid, &status, c.WNOHANG));
    try testing.expect(pane.closing.load(.acquire));
    try testing.expect(!pane.ended.load(.acquire) and !pane.unlinked);
    try testing.expect(server.findPane("bbbbbbbb") == null);
    server.reapPanes();
    try testing.expectEqual(1, server.panes.items.len);
    try testing.expectEqual(@as(usize, 0), pane.pins.load(.acquire));
}

test "explicit closePane collapses its split and cleanup waits for pins" {
    var server = testServer(testing.allocator);
    defer freeTree(&server);
    defer freeTestPanes(&server);
    const tab = try testTab(&server, "aaaaaaaa");
    const a = try testPane(&server, tab, "bbbbbbbb".*);
    const b = try testPane(&server, tab, "cccccccc".*);
    const split = try server.gpa.create(SplitNode);
    split.* = .{ .id = "dddddddd".*, .direction = .right };
    try split.children.appendSlice(server.gpa, &.{ .{ .node = .{ .pane = a } }, .{ .node = .{ .pane = b } } });
    tab.layout = .{ .split = split };

    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expect(server.command(failing.allocator(), .{ .op = .closePane, .pane = "bbbbbbbb" }).@"error" != null);
    try testing.expectEqual(split, tab.layout.split);
    try testing.expectEqual(2, tab.panes.items.len);
    try testing.expectEqual(@as(usize, 0), a.pins.load(.acquire));
    try testing.expect(!a.closing.load(.acquire));
    try testing.expect(server.command(testing.allocator, .{ .op = .closePane, .pane = "bbbbbbbb" }).@"error" == null);
    try testing.expectEqual(b, tab.layout.pane);
    try testing.expectEqual(1, tab.panes.items.len);
    try testing.expect(!a.unlinked and !a.ended.load(.acquire));
    try testing.expect(!b.closing.load(.acquire));
    try testing.expect(server.command(testing.allocator, .{ .op = .closePane, .pane = "bbbbbbbb" }).@"error" != null);
    a.pin(); // An attached connection outlives both explicit close and EOF.
    Server.onPaneClose(&server, a);
    Server.onPaneClose(&server, a);
    server.reapPanes();
    try testing.expectEqual(2, server.panes.items.len);
    a.ended.store(true, .release);
    server.reapPanes();
    try testing.expectEqual(2, server.panes.items.len);
    try testing.expectEqual(1, tab.panes.items.len);
    a.unpin();
    server.reapPanes();
    try testing.expectEqual(1, server.panes.items.len);
    try testing.expectEqual(b, server.panes.items[0]);
}

test "explicit tab and group close collect targets before pruning their containers" {
    for ([_]wire.Op{ .closeTab, .closeGroup }) |op| {
        var server = testServer(testing.allocator);
        defer freeTree(&server);
        defer freeTestPanes(&server);
        const ta = try testTab(&server, "aaaaaaaa");
        const a = try testPane(&server, ta, "11111111".*);
        const sibling = try testPane(&server, ta, "33333333".*);
        const split = try server.gpa.create(SplitNode);
        split.* = .{ .id = "44444444".*, .direction = .down };
        try split.children.appendSlice(server.gpa, &.{ .{ .node = .{ .pane = a } }, .{ .node = .{ .pane = sibling } } });
        ta.layout = .{ .split = split };
        const tb = try testTab(&server, "bbbbbbbb");
        const b = try testPane(&server, tb, "22222222".*);
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const grouped = server.groupTabs(arena.allocator(), .{ .op = .group, .tab = "bbbbbbbb", .target = "aaaaaaaa" });
        try testing.expect(grouped.@"error" == null);
        const cmd = wire.Command{ .op = op, .tab = "aaaaaaaa", .group = grouped.group };
        // The one required allocation fails before pinning or unlinking.
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
        const failed = server.command(failing.allocator(), cmd);
        try testing.expectEqualStrings("out of memory", failed.@"error".?);
        try testing.expect(server.tabOf(a) != null and server.tabOf(sibling) != null and server.tabOf(b) != null);
        for (server.panes.items) |p| {
            try testing.expect(!p.closing.load(.acquire) and !p.unlinked);
            try testing.expectEqual(@as(usize, 0), p.pins.load(.acquire));
        }
        try testing.expect(server.command(testing.allocator, cmd).@"error" == null);
        try testing.expect(server.tabOf(a) == null and server.tabOf(sibling) == null);
        try testing.expect(sibling.closing.load(.acquire));
        try testing.expectEqual(op == .closeGroup, server.tabOf(b) == null);
        try testing.expectEqual(op == .closeGroup, b.closing.load(.acquire));
        // A repeated close and late end callback cannot detach another tab.
        try testing.expect(server.command(testing.allocator, cmd).@"error" == null);
        a.ended.store(true, .release);
        Server.onPaneClose(&server, a);
        sibling.ended.store(true, .release);
        Server.onPaneClose(&server, sibling);
        if (op == .closeGroup) {
            b.ended.store(true, .release);
            Server.onPaneClose(&server, b);
        }
        server.reapPanes();
        try testing.expectEqual(@as(usize, if (op == .closeGroup) 0 else 1), server.panes.items.len);
        try testing.expectEqual(@as(usize, if (op == .closeGroup) 0 else 1), server.items.items.len);
        try testing.expect(!hasEmptyGroup(&server));
    }
}

test "a watcher that asks twice is registered once and removed completely" {
    var server = testServer(testing.allocator);
    defer freeTree(&server);
    var conn = NoopTransport{};
    try testing.expect(server.addWatcher(conn.transport()));
    try testing.expect(server.addWatcher(conn.transport()));
    try testing.expectEqual(1, server.watchers.items.len);
    server.removeWatcher(conn.transport());
    try testing.expectEqual(0, server.watchers.items.len);
}

test "a subscribed command gets its result then current tree without notifying other watchers" {
    var server = testServer(testing.allocator);
    defer freeTree(&server);
    const tab = try testTab(&server, "aaaaaaaa");
    // This shell-less tab has no pane info; layoutInfo only reads the leaf id.
    var leaf: Pane = undefined;
    leaf.id = "bbbbbbbb".*;
    tab.layout = .{ .pane = &leaf };
    var other = CommandTransport{};
    defer other.deinit();
    try testing.expect(server.addWatcher(other.transport()));
    var conn = CommandTransport{};
    defer conn.deinit();
    try conn.queue(.watch, "");
    try conn.queue(.command, "{\"op\":\"renameTab\",\"tab\":\"aaaaaaaa\",\"name\":\"renamed\"}");

    server.serve(conn.transport());

    var replies = wire.FrameReader.init(testing.allocator);
    defer replies.deinit();
    try replies.append(conn.sent.items);
    try testing.expectEqual(wire.Kind.state, (try replies.next()).?.kind);
    const result = (try replies.next()).?;
    try testing.expectEqual(wire.Kind.result, result.kind);
    const parsed = try wire.parse(wire.Result, testing.allocator, result.payload);
    defer parsed.deinit();
    try testing.expect(parsed.value.@"error" == null);
    const state = (try replies.next()).?;
    try testing.expectEqual(wire.Kind.state, state.kind);
    try testing.expect(std.mem.indexOf(u8, state.payload, "\"name\":\"renamed\"") != null);
    try testing.expect((try replies.next()) == null);
    try testing.expectEqual(0, other.sent.items.len);
    try testing.expect(server.notify_pending);
    try testing.expectEqual(0, server.last_state.items.len);
    try testing.expectEqual(1, server.watchers.items.len);
}

test "a command without a watch subscription receives no eager tree" {
    var server = testServer(testing.allocator);
    defer freeTree(&server);
    var conn = CommandTransport{};
    defer conn.deinit();
    try conn.queue(.command, "{\"op\":\"closeTab\"}");

    server.serve(conn.transport());

    var replies = wire.FrameReader.init(testing.allocator);
    defer replies.deinit();
    try replies.append(conn.sent.items);
    const result = (try replies.next()).?;
    try testing.expectEqual(wire.Kind.result, result.kind);
    const parsed = try wire.parse(wire.Result, testing.allocator, result.payload);
    defer parsed.deinit();
    try testing.expect(parsed.value.@"error" == null);
    try testing.expect((try replies.next()) == null);
}

test "failed and malformed subscribed commands send results without eager trees" {
    var server = testServer(testing.allocator);
    defer freeTree(&server);
    var conn = CommandTransport{};
    defer conn.deinit();
    try conn.queue(.watch, "");
    try conn.queue(.command, "{\"op\":\"renameTab\",\"tab\":\"missing\"}");
    try conn.queue(.command, "{");

    server.serve(conn.transport());

    var replies = wire.FrameReader.init(testing.allocator);
    defer replies.deinit();
    try replies.append(conn.sent.items);
    try testing.expectEqual(wire.Kind.state, (try replies.next()).?.kind);
    for (0..2) |_| {
        const result = (try replies.next()).?;
        try testing.expectEqual(wire.Kind.result, result.kind);
        const parsed = try wire.parse(wire.Result, testing.allocator, result.payload);
        defer parsed.deinit();
        try testing.expect(parsed.value.@"error" != null);
    }
    try testing.expect((try replies.next()) == null);
}

test "a failed state copy releases the tree mutex" {
    var server = testServer(testing.allocator);
    defer freeTree(&server);
    const tab = try testTab(&server, "aaaaaaaa");
    var leaf: Pane = undefined;
    leaf.id = "bbbbbbbb".*;
    tab.layout = .{ .pane = &leaf };
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });

    try testing.expectError(error.OutOfMemory, server.buildState(failing.allocator()));
    try testing.expectEqual(@as(c_int, 0), c.pthread_mutex_trylock(&server.mutex.inner));
    server.mutex.unlock();
}

test "grouping the last tab out of a group leaves no empty group" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var server = testServer(testing.allocator);
    defer freeTree(&server);
    _ = try testTab(&server, "aaaaaaaa");
    _ = try testTab(&server, "bbbbbbbb");
    _ = try testTab(&server, "cccccccc");

    try testing.expect(server.groupTabs(arena, .{ .op = .group, .tab = "bbbbbbbb", .target = "aaaaaaaa" }).@"error" == null);
    // Take B back out, leaving the group with A alone, then group A with C.
    try testing.expect(server.moveTab(.{ .op = .move, .tab = "bbbbbbbb" }).@"error" == null);
    const result = server.groupTabs(arena, .{ .op = .group, .tab = "aaaaaaaa", .target = "cccccccc" });
    try testing.expect(result.@"error" == null);
    try testing.expect(!hasEmptyGroup(&server));
    try testing.expectEqual(2, server.items.items.len);
    try testing.expectEqualStrings(&server.items.items[0].group.id, result.group.?);
}

test "a grouping that runs out of memory leaves the tree as it was" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fail_index: usize = 0;
    while (fail_index < 12) : (fail_index += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        var server = testServer(failing.allocator());
        defer freeTree(&server);
        _ = try testTab(&server, "aaaaaaaa");
        _ = try testTab(&server, "bbbbbbbb");
        failing.fail_index = failing.alloc_index + fail_index;
        const result = server.groupTabs(arena, .{ .op = .group, .tab = "bbbbbbbb", .target = "aaaaaaaa" });
        failing.fail_index = std.math.maxInt(usize);
        if (result.@"error" != null) {
            try testing.expectEqual(2, server.items.items.len);
            try testing.expect(server.findTab("aaaaaaaa") != null and server.findTab("bbbbbbbb") != null);
            try testing.expect(server.locate("bbbbbbbb").?.group == null);
        } else {
            try testing.expectEqual(1, server.items.items.len);
            try testing.expect(server.locate("bbbbbbbb").?.group != null);
        }
    }
}

test "a closed link is reclaimed once no reader serves it, and not before" {
    var server = testServer(testing.allocator);
    defer freeTree(&server);
    var secret: [32]u8 = undefined;
    sys.randomBytes(&secret);
    const entry = try testing.allocator.create(LinkEntry);
    entry.* = .{ .server = &server, .link = try link_mod.Link.listen(testing.allocator, secret) };
    try server.links.append(testing.allocator, entry);

    server.reapLinks();
    try testing.expectEqual(1, server.links.items.len); // open: kept
    entry.link.close();
    _ = entry.readers.fetchAdd(1, .acq_rel);
    server.reapLinks();
    try testing.expectEqual(1, server.links.items.len); // a reader is still serving a stream
    _ = entry.readers.fetchSub(1, .acq_rel);
    server.reapLinks();
    try testing.expectEqual(0, server.links.items.len);
}

test "a stream that arrives while its link is being reclaimed is closed, not served" {
    const gpa = testing.allocator;
    var server = testServer(gpa);
    defer freeTree(&server);
    const secret: [32]u8 = @splat(0x5a);
    const entry = try gpa.create(LinkEntry);
    defer gpa.destroy(entry);
    entry.* = .{ .server = &server, .link = try link_mod.Link.listen(gpa, secret), .closing = true };
    defer entry.link.destroy();
    entry.link.on_stream_ctx = entry;
    entry.link.on_stream = &Server.onStream;
    const client = try link_mod.Link.connect(gpa, "127.0.0.1", entry.link.port, secret);
    defer client.destroy();
    // Closes the client if the refusal never arrives, so the read below cannot hang.
    const Watchdog = struct {
        link: *link_mod.Link,
        done: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) void {
            var waited: i64 = 0;
            while (!self.done.load(.acquire) and waited < 10_000) : (waited += 10) sys.sleepMillis(10);
            if (!self.done.load(.acquire)) self.link.close();
        }
    };
    var dog = Watchdog{ .link = client };
    const thread = try std.Thread.spawn(.{}, Watchdog.run, .{&dog});
    defer {
        dog.done.store(true, .release);
        thread.join();
    }
    const stream = try client.open();
    stream.send("hello");
    var buf: [1]u8 = undefined;
    try testing.expectEqual(0, stream.read(&buf)); // the server's FIN, not the watchdog's close
    try testing.expect(!client.isClosed());
    try testing.expectEqual(0, entry.readers.load(.acquire));
    stream.release();
}

test "serverInfo reports the answering process without changing the tree" {
    var server = testServer(testing.allocator);
    defer freeTree(&server);
    server.started_at = sys.monotonicMillis() -| 2000;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var peer = CommandTransport{};
    defer peer.deinit();
    try server.replyCommand(arena_state.allocator(), peer.transport(), "{\"op\":\"serverInfo\"}", true);
    var frames = wire.FrameReader.init(testing.allocator);
    defer frames.deinit();
    try frames.append(peer.sent.items);
    const frame = (try frames.next()).?;
    try testing.expectEqual(wire.Kind.result, frame.kind);
    const result = try wire.parse(wire.Result, testing.allocator, frame.payload);
    defer result.deinit();
    try testing.expectEqualStrings(binary_version, result.value.serverVersion.?);
    try testing.expectEqual(@as(i32, @intCast(c.getpid())), result.value.serverPID.?);
    try testing.expectEqual(@as(u32, 6), result.value.protocolVersion.?);
    try testing.expect(result.value.uptimeSeconds.? >= 2);
    try testing.expectEqual(capabilities.len, result.value.capabilities.?.len);
    try testing.expectEqual(transports.len, result.value.transports.?.len);
    try testing.expectEqualStrings("weighted-v1", result.value.layoutFormat.?);
    try testing.expectEqualStrings("ghostty-vt-v1", result.value.snapshotFormat.?);
    try testing.expect((try frames.next()) == null);
    try testing.expectEqual(@as(usize, 0), server.items.items.len);
}

test "negotiated invalid and missing opens report failures while legacy opens exit" {
    var server = testServer(testing.allocator);
    defer freeTree(&server);
    const cases = [_]struct { payload: []const u8, kind: wire.Kind }{
        .{ .payload = "{\"paneControl\":true}", .kind = .failure },
        .{ .payload = "{\"pane\":\"missing\",\"cols\":0,\"rows\":0,\"cellWidth\":0,\"cellHeight\":0,\"paneControl\":true}", .kind = .failure },
        .{ .payload = "{\"pane\":\"missing\",\"cols\":0,\"rows\":0,\"cellWidth\":0,\"cellHeight\":0}", .kind = .exited },
    };
    for (cases) |case| {
        var peer = CommandTransport{};
        defer peer.deinit();
        try peer.queue(.open, case.payload);
        server.serve(peer.transport());
        var frames = wire.FrameReader.init(testing.allocator);
        defer frames.deinit();
        try frames.append(peer.sent.items);
        const frame = (try frames.next()).?;
        try testing.expectEqual(case.kind, frame.kind);
        if (case.kind == .failure) {
            const result = try wire.parse(struct { @"error": []const u8 }, testing.allocator, frame.payload);
            defer result.deinit();
            try testing.expect(result.value.@"error".len > 0);
        }
        try testing.expect((try frames.next()) == null);
    }
}

test "split weights normalize large values and reject invalid or ambiguous edits atomically" {
    var server = testServer(testing.allocator);
    defer freeTree(&server);
    const tab = try testTab(&server, "weighted");
    var leaf: Pane = undefined;
    leaf.id = "leafpane".*;
    var children = [_]Child{
        .{ .node = .{ .pane = &leaf }, .weight = 1 },
        .{ .node = .{ .pane = &leaf }, .weight = 2 },
        .{ .node = .{ .pane = &leaf }, .weight = 3 },
    };
    var split = SplitNode{ .id = "split123".*, .direction = .right, .children = .initBuffer(&children) };
    split.children.items.len = children.len;
    tab.layout = .{ .split = &split };
    const success = server.command(testing.allocator, .{ .op = .resizeSplit, .split = &split.id, .weights = &.{ 1e308, 1e308, 1e308 } });
    try testing.expect(success.@"error" == null);
    for (children) |child| try testing.expectApproxEqAbs(@as(f64, 1.0 / 3.0), child.weight, 1e-15);
    try testing.expect(server.notify_pending);
    const invalid = [_]wire.Command{
        .{ .op = .resizeSplit, .split = &split.id, .weights = &.{} },
        .{ .op = .resizeSplit, .split = &split.id, .weights = &.{ 1, 2 } },
        .{ .op = .resizeSplit, .split = &split.id, .weights = &.{ 1, 2, 0 } },
        .{ .op = .resizeSplit, .split = &split.id, .weights = &.{ 1, -2, 3 } },
        .{ .op = .resizeSplit, .split = &split.id, .weights = &.{ 1, std.math.nan(f64), 3 } },
        .{ .op = .resizeSplit, .split = &split.id, .weights = &.{ 1, 2, std.math.inf(f64) } },
        .{ .op = .resizeSplit, .split = &split.id, .weights = &.{ 1e308, 1, 0x1p-1074 } },
        .{ .op = .resizeSplit, .split = &split.id, .ratio = 0.5, .weights = &.{ 1, 2, 3 } },
        .{ .op = .resizeSplit, .split = &split.id, .weights = &.{ 1, 2, 3 }, .index = 0 },
        .{ .op = .resizeSplit, .split = &split.id, .ratio = std.math.nan(f64) },
    };
    for (invalid) |cmd| {
        server.notify_pending = false;
        try testing.expect(server.command(testing.allocator, cmd).@"error" != null);
        for (children) |child| try testing.expectEqual(@as(f64, 1.0 / 3.0), child.weight);
        try testing.expect(!server.notify_pending);
    }
    // The original divider ratio/index path still edits just its two children.
    try testing.expect(server.command(testing.allocator, .{ .op = .resizeSplit, .split = &split.id, .ratio = 0.25, .index = 1 }).@"error" == null);
    try testing.expectApproxEqAbs(@as(f64, 1.0 / 3.0), children[0].weight, 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 1.0 / 6.0), children[1].weight, 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 0.5), children[2].weight, 1e-15);
}

test "reportStatus validates targets and schedules watcher metadata without terminal output" {
    var server = testServer(testing.allocator);
    defer freeTree(&server);
    defer {
        for (server.panes.items) |p| p.kill();
        freeTestPanes(&server);
    }
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const made = server.command(arena.allocator(), .{ .op = .newTab, .startup = "exec /bin/cat" });
    try testing.expect(made.@"error" == null);
    const pane = server.findPane(made.pane.?) orelse return error.MissingPane;
    defer pane.unpin();
    var ready = false;
    for (0..500) |_| {
        var buffer: [@import("foreground.zig").Foreground.buffer_size]u8 = undefined;
        if (@import("foreground.zig").Foreground.of(pane.master, &buffer)) |fg| {
            if (std.mem.eql(u8, fg.program, "cat")) {
                ready = true;
                break;
            }
        }
        sys.sleepMillis(10);
    }
    try testing.expect(ready);
    for ([_]wire.Status{ .working, .blocked, .done, .@"error", .idle }) |status| {
        server.notify_mutex.lock();
        server.notify_pending = false;
        server.notify_mutex.unlock();
        const reply = server.command(testing.allocator, .{ .op = .reportStatus, .pane = &pane.id, .status = status });
        try testing.expect(reply.@"error" == null);
        try testing.expectEqualStrings(&pane.id, reply.pane.?);
        {
            pane.mutex.lock();
            defer pane.mutex.unlock();
            try testing.expectEqual(@as(?wire.Status, status), pane.reported);
            try testing.expectEqual(status, pane.status);
        }
        {
            server.notify_mutex.lock();
            defer server.notify_mutex.unlock();
            try testing.expect(server.notify_pending);
        }
    }
    try testing.expect(server.command(testing.allocator, .{ .op = .reportStatus, .pane = &pane.id }).@"error" != null);
    try testing.expect(server.command(testing.allocator, .{ .op = .reportStatus, .pane = "missing", .status = .blocked }).@"error" != null);
    pane.kill();
    try testing.expect(server.command(testing.allocator, .{ .op = .reportStatus, .pane = &pane.id, .status = .blocked }).@"error" != null);
}

/// Private marker source for startup atomicity tests; cleanup never touches a
/// live server. The command writes only after the execution gate is released.
const StartupMarker = struct {
    directory: [:0]u8,
    path: [:0]u8,
    command: []u8,

    fn init() !StartupMarker {
        const gpa = testing.allocator;
        var template = "/tmp/koi-startup-XXXXXX".*;
        const dir = c.mkdtemp(&template) orelse return error.TemporaryDirectory;
        errdefer _ = c.rmdir(dir);
        const directory = try gpa.dupeSentinel(u8, std.mem.span(dir), 0);
        errdefer gpa.free(directory);
        const path = try std.fmt.allocPrintSentinel(gpa, "{s}/executed", .{directory}, 0);
        errdefer gpa.free(path);
        const command = try std.fmt.allocPrint(gpa, "printf executed > '{s}'; exec /bin/cat", .{path});
        return .{ .directory = directory, .path = path, .command = command };
    }

    fn deinit(self: StartupMarker) void {
        _ = c.unlink(self.path);
        _ = c.rmdir(self.directory);
        testing.allocator.free(self.command);
        testing.allocator.free(self.path);
        testing.allocator.free(self.directory);
    }
};

test "postspawn new tab OOM and closed split target never execute startup" {
    const marker = try StartupMarker.init();
    defer marker.deinit();
    for ([_]bool{ false, true }) |split_closed| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        var server = testServer(failing.allocator());
        defer freeTree(&server);
        defer freeTestPanes(&server);
        const child = try Pane.create(testing.allocator, "gatednew".*, .{ .cols = 80, .rows = 24, .cell_width = 8, .cell_height = 16 }, "/", &.{}, marker.command, null);
        defer {
            if (!child.ended.load(.acquire)) child.abort();
            child.destroy();
        }
        try child.start();
        const pid = child.pid;
        if (split_closed) {
            const tab = try testTab(&server, "oldtab01");
            const old = try testPane(&server, tab, "oldpane1".*);
            // Deterministically model source close after fork/reader prep and
            // before the same revalidation used by splitPane.
            const closed = server.closeTargets(testing.allocator, .{ .op = .closePane, .pane = &old.id });
            try testing.expect(closed.@"error" == null);
            try testing.expectError(error.PaneClosed, server.registerSplit(old, child, .right, null));
        } else {
            var tab = Tab{ .id = "newtab01".*, .layout = .{ .pane = child } };
            defer tab.panes.deinit(server.gpa);
            // The actual child and reader already exist. Fail the first
            // post-spawn tree allocation, never an earlier preparation step.
            failing.fail_index = failing.alloc_index;
            try testing.expectError(error.OutOfMemory, server.registerTab(&tab, child, null));
            failing.fail_index = std.math.maxInt(usize);
        }
        child.abort();
        try testing.expectEqual(@as(c_int, -1), child.execution_gate);
        try testing.expect(child.ended.load(.acquire));
        try testing.expect(c.access(marker.path, c.F_OK) != 0);
        try testing.expectEqual(@as(c_int, c.ENOENT), sys.errno());
        var status: c_int = 0;
        try testing.expectEqual(@as(c.pid_t, -1), c.waitpid(pid, &status, c.WNOHANG));
        try testing.expectEqual(@as(c_int, c.ECHILD), sys.errno());
        try testing.expect(server.findPane(&child.id) == null);
    }
}

test "typed input waits for the program to take the terminal, or a bounded hold" {
    const gpa = testing.allocator;
    for ([_]bool{ true, false }) |takes| {
        const marker = try StartupMarker.init();
        defer marker.deinit();
        // A program that reads raw like a shell's line editor, or one that stays cooked.
        const command = try std.fmt.allocPrint(gpa, "printf executed > '{s}'; echo banner; {s}; exec /bin/cat", .{ marker.path, if (takes) "stty -echo -icanon" else "true" });
        defer gpa.free(command);
        const child = try Pane.create(gpa, "inputhld".*, .{ .cols = 80, .rows = 24, .cell_width = 8, .cell_height = 16 }, "/", &.{}, command, null);
        defer {
            if (!child.ended.load(.acquire)) child.abort();
            child.destroy();
        }
        child.input_hold_ms = 800;
        try child.start();
        child.input("hello\n");
        try child.releaseExecution();
        var shown_at: ?i64 = null;
        const released = sys.nowMillis();
        while (sys.nowMillis() - released < 2000) : (sys.sleepMillis(10)) {
            child.mutex.lock();
            const text = child.terminal.text();
            child.mutex.unlock();
            if (text) |t| {
                defer @import("emulator.zig").Terminal.freeSnapshot(t);
                if (std.mem.indexOf(u8, t, "hello") != null) {
                    shown_at = sys.nowMillis() - released;
                    break;
                }
            }
        }
        const elapsed = shown_at orelse return error.InputNeverDelivered;
        // The banner alone does not release it; taking the terminal does,
        // and a cooked reader waits out the hold.
        if (takes) try testing.expect(elapsed < 600) else try testing.expect(elapsed >= 700);
    }
}

test "startup remains gated until reader preparation and pane discovery succeed" {
    const marker = try StartupMarker.init();
    defer marker.deinit();
    var server = testServer(testing.allocator);
    defer freeTree(&server);
    defer {
        for (server.panes.items) |p| p.kill();
        freeTestPanes(&server);
    }
    const child = try Pane.create(testing.allocator, "gatedyes".*, .{ .cols = 80, .rows = 24, .cell_width = 8, .cell_height = 16 }, "/", &.{}, marker.command, null);
    var published = false;
    defer if (!published) {
        child.abort();
        child.destroy();
    };
    try testing.expectError(error.ReaderNotStarted, child.releaseExecution());
    try child.start();
    const tab = try testing.allocator.create(Tab);
    tab.* = .{ .id = "newtab02".*, .layout = .{ .pane = child } };
    errdefer if (!published) {
        tab.panes.deinit(testing.allocator);
        testing.allocator.destroy(tab);
    };
    try server.registerTab(tab, child, null);
    published = true;
    defer child.unpin();
    const found = server.findPane(&child.id) orelse return error.MissingPane;
    found.unpin();
    try testing.expect(c.access(marker.path, c.F_OK) != 0);
    try testing.expectEqual(@as(c_int, c.ENOENT), sys.errno());
    try child.releaseExecution();
    var executed = false;
    for (0..500) |_| {
        if (c.access(marker.path, c.F_OK) == 0) {
            executed = true;
            break;
        }
        sys.sleepMillis(10);
    }
    try testing.expect(executed);
}

test "a shell deferred for its client starts on attach, or by the deadline alone" {
    for ([_]bool{ true, false }) |attaches| {
        const marker = try StartupMarker.init();
        defer marker.deinit();
        var server = testServer(testing.allocator);
        defer freeTree(&server);
        defer {
            for (server.panes.items) |p| p.kill();
            freeTestPanes(&server);
        }
        const child = try Pane.create(testing.allocator, "deferred".*, .{ .cols = 80, .rows = 24, .cell_width = 8, .cell_height = 16 }, "/", &.{}, marker.command, null);
        var published = false;
        defer if (!published) {
            child.abort();
            child.destroy();
        };
        try child.start();
        const tab = try testing.allocator.create(Tab);
        tab.* = .{ .id = "deftab01".*, .layout = .{ .pane = child } };
        errdefer if (!published) {
            tab.panes.deinit(testing.allocator);
            testing.allocator.destroy(tab);
        };
        try server.registerTab(tab, child, null);
        published = true;
        defer child.unpin();
        // macOS can coalesce a 20 ms sleep past a short expiry. Check the
        // closed gate with ample grace, then explicitly exercise expiration.
        child.deferExecution(sys.nowMillis() + 60_000);
        sys.sleepMillis(20);
        try testing.expect(c.access(marker.path, c.F_OK) != 0);
        // What the open handler does once the client's size is applied.
        if (attaches) try child.releaseExecution() else child.deferExecution(sys.nowMillis());
        var executed = false;
        for (0..300) |_| {
            if (c.access(marker.path, c.F_OK) == 0) {
                executed = true;
                break;
            }
            sys.sleepMillis(10);
        }
        try testing.expect(executed);
    }
}
