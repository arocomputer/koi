//! A daemon is not a parent shell. Carry portable login/desktop settings into
//! new panes, not arbitrary session state from whichever process started it.
const std = @import("std");

pub fn inherit(entry: []const u8, forwarded: ?[]const u8) bool {
    const end = std.mem.indexOfScalar(u8, entry, '=') orelse return false;
    const name = entry[0..end];
    const baseline = [_][]const u8{
        "HOME",     "USER",            "LOGNAME",                  "SHELL",          "PATH",           "TMPDIR",            "TMP",           "TEMP",          "LANG",            "TZ",
        "ZDOTDIR",  "XDG_CONFIG_HOME", "XDG_DATA_HOME",            "XDG_CACHE_HOME", "XDG_STATE_HOME", "XDG_RUNTIME_DIR",   "XDG_DATA_DIRS", "SSH_AUTH_SOCK", "SSH_AGENT_PID",   "SSH_ASKPASS",
        "DISPLAY",  "WAYLAND_DISPLAY", "DBUS_SESSION_BUS_ADDRESS", "http_proxy",     "https_proxy",    "all_proxy",         "no_proxy",      "HTTP_PROXY",    "HTTPS_PROXY",     "ALL_PROXY",
        "NO_PROXY", "SSL_CERT_FILE",   "SSL_CERT_DIR",             "CURL_CA_BUNDLE", "NIX_PROFILES",   "NIX_SSL_CERT_FILE", "SDKROOT",       "DEVELOPER_DIR", "KOI_INHERIT_ENV", "KOI_DIR",
    };
    for (baseline) |key| if (std.mem.eql(u8, name, key)) return true;
    if (std.mem.startsWith(u8, name, "LC_")) return true;
    // Explicit exact names, no wildcard/provider lists and no values in diagnostics.
    if (forwarded) |names| {
        var items = std.mem.splitScalar(u8, names, ',');
        while (items.next()) |item| if (std.mem.eql(u8, name, std.mem.trim(u8, item, " \t"))) return true;
    }
    return false;
}

test "pane inheritance is provider independent and custom configuration is opt in" {
    const t = std.testing;
    for ([_][]const u8{ "HOME=/home/test", "PATH=/bin", "LC_CTYPE=en_US.UTF-8", "SSH_AUTH_SOCK=/tmp/socket" }) |entry| try t.expect(inherit(entry, null));
    for ([_][]const u8{ "ANY_AGENT_SESSION=old", "CLAUDECODE=1", "NEW_TOOL_PARENT=42", "CUSTOM_CONFIG_DIR=/cfg" }) |entry| try t.expect(!inherit(entry, null));
    try t.expect(inherit("CUSTOM_CONFIG_DIR=/cfg", "CUSTOM_CONFIG_DIR, MY_API_KEY"));
    try t.expect(!inherit("CUSTOM_CONFIG_DIR_EXTRA=bad", "CUSTOM_CONFIG_DIR"));
    try t.expect(!inherit("MALFORMED", "MALFORMED"));
}
