//! A thin wrapper over the engine's C API for the headless terminal the
//! server keeps per pane: the screen, scrollback and parser state, from
//! which an attaching client gets its snapshot.
const std = @import("std");
const sys = @import("sys.zig");
const vt = sys.c;
const wire = @import("wire.zig");

/// Scrollback kept per terminal, in bytes of terminal pages.
pub const scrollback_bytes: usize = 32 << 20;

pub const Terminal = struct {
    raw: vt.GhosttyTerminal,
    /// Owned values, independent of a command's JSON arena.
    defaults: Defaults = .{},

    pub const Defaults = struct {
        foreground: vt.GhosttyColorRgb = .{ .r = 0xe6, .g = 0xe6, .b = 0xea },
        background: vt.GhosttyColorRgb = .{ .r = 0x17, .g = 0x17, .b = 0x1b },
        cursor: vt.GhosttyColorRgb = .{ .r = 0xe6, .g = 0xe6, .b = 0xea },
        scrollback: usize = scrollback_bytes,
    };

    pub fn init(cols: u16, rows: u16) !Terminal {
        var t: vt.GhosttyTerminal = null;
        if (vt.ghostty_terminal_new(null, &t, cols, rows) != vt.GHOSTTY_SUCCESS) return error.Engine;
        var self = Terminal{ .raw = t };
        self.configure();
        return self;
    }

    /// Restores a terminal from a snapshot made by `snapshot`; null if the
    /// bytes are not a complete snapshot.
    pub fn fromSnapshot(bytes: []const u8) ?Terminal {
        var decoder: vt.GhosttySnapshotDecoder = null;
        if (vt.ghostty_snapshot_decoder_new_buf(null, &decoder, bytes.ptr, bytes.len) != vt.GHOSTTY_SUCCESS) return null;
        defer vt.ghostty_snapshot_decoder_free(decoder);
        var retain = true;
        var limit: usize = 64 * 1024;
        _ = vt.ghostty_snapshot_decoder_set(decoder, vt.GHOSTTY_SNAPSHOT_DECODER_OPT_MAX_CONTINUATION_BYTES, &limit);
        _ = vt.ghostty_snapshot_decoder_set(decoder, vt.GHOSTTY_SNAPSHOT_DECODER_OPT_RETAIN_CONTINUATION, &retain);
        var t: vt.GhosttyTerminal = null;
        if (vt.ghostty_snapshot_decoder_decode(decoder, &t) != vt.GHOSTTY_SUCCESS or t == null) return null;
        var self = Terminal{ .raw = t };
        // The snapshot restores the mode's current value but not what a
        // reset returns it to. Setting the default also sets the current
        // value, so put back what the program had left.
        var current = vt.GhosttyTerminalModeConfig{ .mode = vt.ghostty_mode_new(2027, false), .value = true };
        _ = vt.ghostty_terminal_get(self.raw, vt.GHOSTTY_TERMINAL_DATA_MODE, &current);
        self.graphemeClusteringDefault();
        _ = vt.ghostty_terminal_set(self.raw, vt.GHOSTTY_TERMINAL_OPT_MODE, &current);
        return self;
    }

    pub fn deinit(self: *Terminal) void {
        vt.ghostty_terminal_free(self.raw);
    }

    fn configure(self: *Terminal) void {
        self.applyDefaults();
        // Snapshots need the parser's unfinished input, so track it.
        var continuation: usize = 64 * 1024;
        _ = vt.ghostty_terminal_set(self.raw, vt.GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES, &continuation);
        self.graphemeClusteringDefault();
    }

    /// Joins multi-codepoint graphemes into one cell, as Ghostty does, now
    /// and after every terminal reset.
    fn graphemeClusteringDefault(self: *Terminal) void {
        var grapheme = vt.GhosttyTerminalModeConfig{ .mode = vt.ghostty_mode_new(2027, false), .value = true };
        _ = vt.ghostty_terminal_set(self.raw, vt.GHOSTTY_TERMINAL_OPT_MODE_DEFAULT, &grapheme);
    }

    /// Applies validated JSON appearance without retaining borrowed strings.
    pub fn applyAppearance(self: *Terminal, appearance: wire.Appearance) !void {
        if (!appearance.valid()) return error.InvalidAppearance;
        self.defaults = .{
            .foreground = color(appearance.foreground),
            .background = color(appearance.background),
            .cursor = color(appearance.cursor),
            .scrollback = @as(usize, @intCast(appearance.scrollbackMB)) << 20,
        };
        self.applyDefaults();
    }

    fn color(hex: []const u8) vt.GhosttyColorRgb {
        const rgb = std.fmt.parseInt(u32, hex, 16) catch unreachable;
        return .{ .r = @intCast(rgb >> 16), .g = @intCast((rgb >> 8) & 255), .b = @intCast(rgb & 255) };
    }

    /// Restores embedder defaults, retaining any program's OSC overrides.
    pub fn applyDefaults(self: *Terminal) void {
        _ = vt.ghostty_terminal_set(self.raw, vt.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &self.defaults.scrollback);
        _ = vt.ghostty_terminal_set(self.raw, vt.GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &self.defaults.foreground);
        _ = vt.ghostty_terminal_set(self.raw, vt.GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &self.defaults.background);
        _ = vt.ghostty_terminal_set(self.raw, vt.GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &self.defaults.cursor);
    }

    /// Erases retained history using the engine option, without feeding bytes
    /// through a possibly unfinished escape sequence or resetting modes/screen.
    pub fn clearScrollback(self: *Terminal) void {
        var zero: usize = 0;
        _ = vt.ghostty_terminal_set(self.raw, vt.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &zero);
        _ = vt.ghostty_terminal_set(self.raw, vt.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &self.defaults.scrollback);
    }

    pub fn write(self: *Terminal, bytes: []const u8) void {
        vt.ghostty_terminal_vt_write(self.raw, bytes.ptr, bytes.len);
    }

    pub fn resize(self: *Terminal, cols: u16, rows: u16, cell_width: u32, cell_height: u32) void {
        _ = vt.ghostty_terminal_resize(self.raw, cols, rows, cell_width, cell_height);
    }

    /// The complete state: screen, modes, scrollback and unfinished input.
    /// Free with `freeSnapshot`.
    pub fn snapshot(self: *Terminal) ?[]u8 {
        var ptr: [*c]u8 = null;
        var len: usize = 0;
        if (vt.ghostty_snapshot_encode_alloc(self.raw, null, &ptr, &len) != vt.GHOSTTY_SUCCESS or ptr == null) return null;
        return ptr[0..len];
    }

    pub fn freeSnapshot(bytes: []u8) void {
        vt.ghostty_free(null, bytes.ptr, bytes.len);
    }

    /// The screen and scrollback as plain text, for `koi capture`. Free with
    /// `freeSnapshot`.
    pub fn text(self: *Terminal) ?[]u8 {
        var opts: vt.GhosttyFormatterTerminalOptions = std.mem.zeroes(vt.GhosttyFormatterTerminalOptions);
        opts.size = @sizeOf(vt.GhosttyFormatterTerminalOptions);
        opts.emit = vt.GHOSTTY_FORMATTER_FORMAT_PLAIN;
        opts.trim = true;
        opts.extra.size = @sizeOf(vt.GhosttyFormatterTerminalExtra);
        opts.extra.screen.size = @sizeOf(vt.GhosttyFormatterScreenExtra);
        var formatter: vt.GhosttyFormatter = null;
        if (vt.ghostty_formatter_terminal_new(null, &formatter, self.raw, opts) != vt.GHOSTTY_SUCCESS) return null;
        defer vt.ghostty_formatter_free(formatter);
        var ptr: [*c]u8 = null;
        var len: usize = 0;
        if (vt.ghostty_formatter_format_alloc(formatter, null, &ptr, &len) != vt.GHOSTTY_SUCCESS or ptr == null) return null;
        return ptr[0..len];
    }

    /// The window title the program set (OSC 0/2), or "".
    pub fn title(self: *Terminal) []const u8 {
        return self.string(vt.GHOSTTY_TERMINAL_DATA_TITLE);
    }

    /// The raw working-directory URI the shell reported (OSC 7), or "".
    pub fn pwd(self: *Terminal) []const u8 {
        return self.string(vt.GHOSTTY_TERMINAL_DATA_PWD);
    }

    fn string(self: *Terminal, key: c_uint) []const u8 {
        var s: vt.GhosttyString = std.mem.zeroes(vt.GhosttyString);
        if (vt.ghostty_terminal_get(self.raw, key, &s) != vt.GHOSTTY_SUCCESS or s.ptr == null or s.len == 0) return "";
        return s.ptr[0..s.len];
    }

    pub fn isAlternateScreen(self: *Terminal) bool {
        var screen: c_uint = vt.GHOSTTY_TERMINAL_SCREEN_PRIMARY;
        _ = vt.ghostty_terminal_get(self.raw, vt.GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen);
        return screen == vt.GHOSTTY_TERMINAL_SCREEN_ALTERNATE;
    }

    pub fn setUserdata(self: *Terminal, ptr: *anyopaque) void {
        _ = vt.ghostty_terminal_set(self.raw, vt.GHOSTTY_TERMINAL_OPT_USERDATA, ptr);
    }

    pub fn setOption(self: *Terminal, option: c_uint, value: ?*const anyopaque) void {
        _ = vt.ghostty_terminal_set(self.raw, option, value);
    }
};

test "a terminal snapshots and formats" {
    var t = try Terminal.init(20, 4);
    defer t.deinit();
    t.write("hello\r\nkoi");
    const text = t.text() orelse return error.NoText;
    defer Terminal.freeSnapshot(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "hello") != null);
    const snap = t.snapshot() orelse return error.NoSnapshot;
    defer Terminal.freeSnapshot(snap);
    try std.testing.expect(snap.len > 10);
}

test "a restored terminal returns to grapheme clustering on reset" {
    var source = try Terminal.init(20, 4);
    defer source.deinit();
    source.write("\x1b[?2027l");
    const snap = source.snapshot() orelse return error.NoSnapshot;
    defer Terminal.freeSnapshot(snap);
    var mirror = Terminal.fromSnapshot(snap) orelse return error.NoSnapshot;
    defer mirror.deinit();
    var mode = vt.GhosttyTerminalModeConfig{ .mode = vt.ghostty_mode_new(2027, false), .value = true };
    _ = vt.ghostty_terminal_get(mirror.raw, vt.GHOSTTY_TERMINAL_DATA_MODE, &mode);
    try std.testing.expect(!mode.value);
    mirror.write("\x1bc");
    _ = vt.ghostty_terminal_get(mirror.raw, vt.GHOSTTY_TERMINAL_DATA_MODE, &mode);
    try std.testing.expect(mode.value);
}
