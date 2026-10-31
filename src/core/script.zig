//! `koi do SOURCE` and `koi run FILE`: Lua scripts that drive the multiplexer.
//!
//! A script gets a global `koi` table. The primitives live here: `koi.run(...)`
//! runs another `koi` command and returns whether it succeeded, what it printed
//! and its exit status; `koi.json(text)` decodes JSON; `koi.sleep(seconds)`
//! waits. `prelude.lua` builds `koi.ls`, `koi.new`, `koi.send`, `koi.wait` and
//! the rest on those, so a script can do exactly what the command line can and
//! nothing here duplicates it. The standard libraries a script has are the
//! plain ones (base, string, table, math, utf8, coroutine, os, io); `require`
//! and C modules are left out. A script runs with the user's own authority,
//! like a shell script they chose to run.
const std = @import("std");
const sys = @import("sys.zig");
const c = sys.c;
const Allocator = std.mem.Allocator;

const prelude = @embedFile("prelude.lua");

/// The allocator the Lua callbacks use; set for the life of one script.
var script_gpa: Allocator = undefined;

/// The program `koi.run` starts. Null means this one; tests name another, since a
/// test binary is not `koi`.
var program: ?[:0]const u8 = null;

/// Runs `source` (or the file at `path`) with `args` as the global `arg`.
/// Returns the exit status: 0 done, 1 the script failed, 2 it could not start.
pub fn run(gpa: Allocator, chunk: Chunk, args: []const [:0]const u8) u8 {
    script_gpa = gpa;
    const L = c.luaL_newstate() orelse return 2;
    defer c.lua_close(L);
    openLibraries(L);
    registerKoi(L);
    setArgs(L, chunk, args);

    if (!load(L, "prelude.lua", prelude, .source)) return reportError(L);
    if (c.lua_pcallk(L, 0, 0, 0, 0, null) != c.LUA_OK) return reportError(L);
    const loaded = switch (chunk) {
        .source => |text| load(L, "=(koi do)", text, .source),
        .file => |path| loadFile(L, path),
    };
    if (!loaded) return reportError(L);
    if (c.lua_pcallk(L, 0, 0, 0, 0, null) != c.LUA_OK) return reportError(L);
    return 0;
}

pub const Chunk = union(enum) { source: []const u8, file: [:0]const u8 };

fn openLibraries(L: *c.lua_State) void {
    const libs = [_]struct { name: [:0]const u8, open: c.lua_CFunction }{
        .{ .name = "_G", .open = c.luaopen_base },
        .{ .name = "coroutine", .open = c.luaopen_coroutine },
        .{ .name = "table", .open = c.luaopen_table },
        .{ .name = "io", .open = c.luaopen_io },
        .{ .name = "os", .open = c.luaopen_os },
        .{ .name = "string", .open = c.luaopen_string },
        .{ .name = "math", .open = c.luaopen_math },
        .{ .name = "utf8", .open = c.luaopen_utf8 },
    };
    for (libs) |lib| {
        c.luaL_requiref(L, lib.name.ptr, lib.open, 1);
        c.lua_settop(L, -2);
    }
}

fn registerKoi(L: *c.lua_State) void {
    c.lua_createtable(L, 0, 8);
    inline for (.{ .{ "run", koiRun }, .{ "json", koiJson }, .{ "sleep", koiSleep } }) |entry| {
        c.lua_pushcclosure(L, entry[1], 0);
        c.lua_setfield(L, -2, entry[0]);
    }
    c.lua_setglobal(L, "koi");
}

fn setArgs(L: *c.lua_State, chunk: Chunk, args: []const [:0]const u8) void {
    c.lua_createtable(L, @intCast(args.len), 1);
    switch (chunk) {
        .file => |path| {
            _ = c.lua_pushstring(L, path.ptr);
            c.lua_rawseti(L, -2, 0);
        },
        .source => {},
    }
    for (args, 1..) |a, i| {
        _ = c.lua_pushstring(L, a.ptr);
        c.lua_rawseti(L, -2, @intCast(i));
    }
    c.lua_setglobal(L, "arg");
}

const Mode = enum { source };

fn load(L: *c.lua_State, name: [:0]const u8, text: []const u8, _: Mode) bool {
    return c.luaL_loadbufferx(L, text.ptr, text.len, name.ptr, "t") == c.LUA_OK;
}

fn loadFile(L: *c.lua_State, path: [:0]const u8) bool {
    return c.luaL_loadfilex(L, path.ptr, "t") == c.LUA_OK;
}

/// Prints the error on top of the stack as `koi: MESSAGE` and returns the status.
fn reportError(L: *c.lua_State) u8 {
    var len: usize = 0;
    const msg = c.lua_tolstring(L, -1, &len);
    if (msg) |m| std.debug.print("koi: {s}\n", .{m[0..len]}) else std.debug.print("koi: script failed\n", .{});
    return 1;
}

/// koi.run(...): runs this program with the given arguments. Returns whether it
/// exited 0, what it printed to standard output, and its exit status.
fn koiRun(state: ?*c.lua_State) callconv(.c) c_int {
    const L = state.?;
    const n = c.lua_gettop(L);
    var arena_state = std.heap.ArenaAllocator.init(script_gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const argv = arena.alloc(?[*:0]const u8, @as(usize, @intCast(n)) + 2) catch return raise(L, "out of memory");
    if (program) |exe| {
        argv[0] = exe.ptr;
    } else {
        const self_path = sys.selfPath(arena) catch return raise(L, "cannot find the koi program");
        argv[0] = (arena.dupeSentinel(u8, self_path, 0) catch return raise(L, "out of memory")).ptr;
    }
    var i: c_int = 1;
    while (i <= n) : (i += 1) {
        var len: usize = 0;
        const s = c.luaL_tolstring(L, i, &len); // numbers and booleans read naturally
        argv[@intCast(i)] = (arena.dupeSentinel(u8, s[0..len], 0) catch return raise(L, "out of memory")).ptr;
        c.lua_settop(L, -2);
    }
    argv[@as(usize, @intCast(n)) + 1] = null;

    var pipe_fds: [2]c_int = undefined;
    if (c.pipe(&pipe_fds) != 0) return raise(L, "cannot create a pipe");
    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(pipe_fds[0]);
        _ = c.close(pipe_fds[1]);
        return raise(L, "cannot start koi");
    }
    if (pid == 0) {
        const devnull = c.open("/dev/null", c.O_RDONLY);
        if (devnull >= 0) _ = c.dup2(devnull, 0);
        _ = c.dup2(pipe_fds[1], 1);
        _ = c.close(pipe_fds[0]);
        _ = c.close(pipe_fds[1]);
        _ = c.execv(argv[0].?, @ptrCast(argv.ptr));
        c._exit(127);
    }
    _ = c.close(pipe_fds[1]);
    var out: std.ArrayList(u8) = .empty;
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const got = c.read(pipe_fds[0], &buf, buf.len);
        if (got < 0 and sys.errno() == c.EINTR) continue;
        if (got <= 0) break;
        out.appendSlice(arena, buf[0..@intCast(got)]) catch break;
    }
    _ = c.close(pipe_fds[0]);
    var status: c_int = 0;
    while (c.waitpid(pid, &status, 0) < 0 and sys.errno() == c.EINTR) {}
    const code: c_int = if (status & 0x7f == 0) (status >> 8) & 0xff else 128 + (status & 0x7f);

    c.lua_pushboolean(L, @intFromBool(code == 0));
    _ = c.lua_pushlstring(L, out.items.ptr, out.items.len);
    c.lua_pushinteger(L, code);
    return 3;
}

/// koi.json(text): decodes JSON into Lua values; `null` becomes nil.
fn koiJson(state: ?*c.lua_State) callconv(.c) c_int {
    const L = state.?;
    var len: usize = 0;
    const text = c.luaL_checklstring(L, 1, &len);
    const parsed = std.json.parseFromSlice(std.json.Value, script_gpa, text[0..len], .{}) catch
        return raise(L, "koi.json: not valid JSON");
    defer parsed.deinit();
    pushValue(L, parsed.value);
    return 1;
}

fn pushValue(L: *c.lua_State, value: std.json.Value) void {
    switch (value) {
        .null => c.lua_pushnil(L),
        .bool => |b| c.lua_pushboolean(L, @intFromBool(b)),
        .integer => |i| c.lua_pushinteger(L, @intCast(i)),
        .float => |f| c.lua_pushnumber(L, f),
        .number_string => |s| _ = c.lua_pushlstring(L, s.ptr, s.len),
        .string => |s| _ = c.lua_pushlstring(L, s.ptr, s.len),
        .array => |a| {
            c.lua_createtable(L, @intCast(a.items.len), 0);
            for (a.items, 1..) |item, i| {
                pushValue(L, item);
                c.lua_rawseti(L, -2, @intCast(i));
            }
        },
        .object => |o| {
            c.lua_createtable(L, 0, @intCast(o.count()));
            var it = o.iterator();
            while (it.next()) |entry| {
                pushValue(L, entry.value_ptr.*);
                _ = c.lua_pushlstring(L, entry.key_ptr.ptr, entry.key_ptr.len);
                c.lua_rotate(L, -2, 1);
                c.lua_settable(L, -3);
            }
        },
    }
}

/// koi.sleep(seconds)
fn koiSleep(state: ?*c.lua_State) callconv(.c) c_int {
    const L = state.?;
    const seconds = c.luaL_checknumber(L, 1);
    if (seconds > 0) sys.sleepMillis(@intFromFloat(@min(seconds * 1000, 3_600_000)));
    return 0;
}

fn raise(L: *c.lua_State, message: [:0]const u8) c_int {
    _ = c.lua_pushstring(L, message.ptr);
    return c.lua_error(L);
}

// MARK: Tests

const testing = std.testing;

/// Runs `source` and expects it to finish; a failed `assert` in it fails the test.
fn expectScript(source: []const u8) !void {
    try testing.expectEqual(@as(u8, 0), run(testing.allocator, .{ .source = source }, &.{}));
}

test "script gets json, sleep and plain libraries" {
    try expectScript(
        \\local t = koi.json('{"a":[1,2.5,"x",true,null,{"k":"v"}],"n":null,"s":"\\u00e9"}')
        \\assert(t.a[1] == 1 and t.a[2] == 2.5 and t.a[3] == "x" and t.a[4] == true and t.a[6].k == "v")
        \\assert(t.n == nil and utf8.len(t.s) == 1)
        \\koi.sleep(0.01)
        \\assert(string.rep("ab", 2) == "abab" and math.floor(2.7) == 2 and os.time() > 0)
        \\assert(require == nil and package == nil and debug == nil)
        \\assert(not pcall(koi.json, "{nope"))
    );
}

test "koi.run reports output and exit status" {
    program = "/bin/echo";
    defer program = null;
    try expectScript(
        \\local ok, out, code = koi.run("hello", 42, true)
        \\assert(ok and out == "hello 42 true\n" and code == 0)
    );
    program = "/usr/bin/false";
    try expectScript(
        \\local ok, out, code = koi.run("anything")
        \\assert(ok == false and out == "" and code == 1)
        \\local good, err = pcall(koi.send, "t", "x")
        \\assert(not good and err:find("koi send failed %(exit 1%)"), err)
        \\-- a pane that cannot be captured yet is waited for, not an error
        \\assert(koi.wait("t", "x", 0) == nil)
    );
}

test "helpers build the right commands" {
    program = "/bin/echo";
    defer program = null;
    try expectScript(
        \\assert(koi.new { cwd = "/tmp", command = "ls" } == "new --cwd /tmp --command ls")
        \\assert(koi.new() == "new")
        \\assert(koi.split("abc", { direction = "down", cwd = "/x" }) == "split abc --down --cwd /x")
        \\assert(koi.capture("t") == "capture t\n")
        \\assert(koi.wait("t", "captu(re)", 5) == "re")
        \\assert(koi.wait("t", "never appears", 0) == nil)
    );
}

test "script failures exit 1, files get args" {
    try testing.expectEqual(@as(u8, 1), run(testing.allocator, .{ .source = "error('boom')" }, &.{}));
    try testing.expectEqual(@as(u8, 1), run(testing.allocator, .{ .source = "this is not lua" }, &.{}));
    try testing.expectEqual(@as(u8, 1), run(testing.allocator, .{ .file = "/nonexistent/script.lua" }, &.{}));

    var template = "/tmp/koi-script-XXXXXX".*;
    const dir = std.mem.span(c.mkdtemp(&template) orelse return error.CreateDirectory);
    defer {
        var cmd: [96]u8 = undefined;
        _ = c.system((std.fmt.bufPrintSentinel(&cmd, "rm -rf {s}", .{dir}, 0) catch unreachable).ptr);
    }
    var path_buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buf, "{s}/args.lua", .{dir}, 0);
    const fd = c.open(path.ptr, c.O_CREAT | c.O_WRONLY, @as(c_uint, 0o600));
    try testing.expect(fd >= 0);
    const body = "assert(arg[0] and arg[1] == 'one' and arg[2] == 'two' and arg[3] == nil)";
    try testing.expectEqual(@as(isize, body.len), c.write(fd, body, body.len));
    _ = c.close(fd);
    const args = [_][:0]const u8{ "one", "two" };
    try testing.expectEqual(@as(u8, 0), run(testing.allocator, .{ .file = path }, &args));
}
