import Foundation

/// Where Koi keeps its files, split the way Ghostty and the XDG convention
/// do: what a person edits or a Linux machine shares goes in the dotfile
/// directories; only what macOS manages itself goes in `~/Library`.
///
/// - `config`: `~/.config/koi/config`, the settings file.
/// - `state`: `~/.local/state/koi`, what Koi remembers (`layout.json`) and
///   the server's log.
/// - `runtime`: the server's socket and lock, in the per-user temporary
///   directory (`$XDG_RUNTIME_DIR/koi` on Linux).
/// - `~/.local/share/koi/koi` is the binary on a machine without the app
///   (see `Remote`).
///
/// `KOI_DIR` puts everything under one directory instead, which the tests
/// use so they never touch the sessions of the Koi you use; Koid (see
/// `isDev`) does the same with `~/.local/state/koid`.
enum Paths {
    /// Whether this is Koid: a build for working on Koi, with its own
    /// state, that stays out of the way of the Koi you use.
    #if KOID
    static let isDev = true
    #else
    static let isDev = false
    #endif

    /// The repository root when running from the package rather than an app
    /// bundle (tests, `swift run`, Koid): found by walking up from this file
    /// to the directory holding `Package.swift`, so it doesn't care how the
    /// sources are foldered. Omitted from release builds of Koi.
    static let repoRoot: URL? = {
        #if DEBUG || KOID
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) { return dir }
            dir = dir.deletingLastPathComponent()
        }
        #endif
        return nil
    }()

    /// `path` with `home` shortened to `~`, the way directories are shown.
    static func tilde(_ path: String, home: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private static var override: URL? {
        if let d = ProcessInfo.processInfo.environment["KOI_DIR"], !d.isEmpty { return URL(fileURLWithPath: d) }
        if Bundle.main.bundleURL.pathExtension == "xctest" {
            // A test process never reaches a daily or development server: it
            // gets its own directory, which any server it starts inherits.
            let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("koi-tests-\(getpid())")
            setenv("KOI_DIR", dir.path, 1)
            return dir
        }
        if isDev {
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/koid")
            // The server the app starts inherits this and keeps to the same place.
            setenv("KOI_DIR", dir.path, 1)
            return dir
        }
        return nil
    }

    private static func xdg(_ variable: String, default fallback: String) -> URL {
        let env = ProcessInfo.processInfo.environment
        let base = env[variable].flatMap { $0.isEmpty ? nil : $0 }.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(fallback)
        return base.appendingPathComponent("koi")
    }

    static var config: URL { (override ?? xdg("XDG_CONFIG_HOME", default: ".config")).appendingPathComponent("config") }
    static var state: URL { override ?? xdg("XDG_STATE_HOME", default: ".local/state") }

    /// The same choice as the server (paths.zig). With TMPDIR unset,
    /// NSTemporaryDirectory would pick a per-user directory the server does
    /// not know about, and the app would never find its socket. A directory
    /// too long for a socket path moves, lock and all, to a per-user one in
    /// /tmp, never to a bare name in shared /tmp.
    static var runtime: URL {
        let env = ProcessInfo.processInfo.environment
        let privateTmp = URL(fileURLWithPath: "/tmp/koi-\(getuid())")
        let dir = override
            ?? env["XDG_RUNTIME_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0).appendingPathComponent("koi") }
            ?? env["TMPDIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0).appendingPathComponent("koi") }
            ?? privateTmp
        return dir.appendingPathComponent(socketName).path.utf8.count < 100 ? dir : privateTmp
    }

    private static var socketName: String { "server-\(Wire.version).sock" }

    static var layout: URL { state.appendingPathComponent("layout.json") }
    static var serverLog: URL { state.appendingPathComponent("server.log") }
    static var serverLock: URL { runtime.appendingPathComponent("server.lock") }

    /// The server's socket. Its name carries the protocol version, so an app
    /// never talks to a server that speaks another one.
    static var socket: String { runtime.appendingPathComponent(socketName).path }

    /// Makes the state and runtime directories, private to the user, and
    /// moves `layout.json` over from where earlier builds kept it.
    static func ensureDirs() throws {
        for dir in [state, runtime] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let old = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Koi/layout.json")
        if override == nil, !FileManager.default.fileExists(atPath: layout.path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.moveItem(at: old, to: layout)
        }
    }
}
