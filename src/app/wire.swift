import Foundation

/// Koi's socket protocol between the app (or the CLI) and the server.
///
/// Every message is a frame: a one-byte kind, a little-endian UInt32 payload
/// length, then the payload.
///
/// The server holds a tree: a list of tabs and groups of tabs, each tab
/// holding panes, and each pane one shell on one PTY. A connection does one of two things:
///
/// - **Control.** `.watch` subscribes to the tree: the server sends `.state`
///   at once and again whenever anything in it changes. `.command` changes
///   the tree and is answered by `.result`.
/// - **A pane.** `.open` attaches to one pane: the server answers
///   `.attached`, then `.snapshot` (the pane's full state), then a stream of
///   `.output` (raw PTY bytes) and `.resized`, in the order the pane saw
///   them, so the client's terminal always matches the server's.
enum Wire {
    /// Bumped on any incompatible change; part of the socket's name.
    static let version = 6

    enum Kind: UInt8 {
        // Client to server.
        case open = 1      // JSON OpenRequest
        case input = 2     // bytes for the PTY
        case resize = 3    // GridSize
        case kill = 5      // empty; ends the attached pane
        case watch = 6     // empty; answered by .state, now and on changes
        case command = 7   // JSON Command; answered by .result
        case offer = 8     // empty, over the local socket; answered by .offered

        // Server to client.
        case attached = 64 // JSON PaneInfo
        case snapshot = 65 // libghostty-vt snapshot
        case output = 66   // PTY bytes
        case resized = 67  // GridSize, once the pane has resized
        case exited = 68   // Int32 exit status, little-endian; also for a pane that is gone
        case state = 69    // JSON State
        case result = 70   // JSON Result
        case offered = 71  // JSON Offer: a UDP port and secret for one client
    }

    struct OpenRequest: Codable {
        var pane: String
        var cols: UInt16
        var rows: UInt16
        var cellWidth: UInt32
        var cellHeight: UInt32
    }

    /// The whole tree, as every watcher sees it: tabs and groups, in order.
    struct State: Codable, Equatable {
        var items: [Item] = []

        /// Every tab, top to bottom, groups included.
        var tabs: [TabInfo] {
            items.flatMap { item -> [TabInfo] in
                switch item {
                case .tab(let t): [t]
                case .group(let g): g.tabs
                }
            }
        }
    }

    /// A top-level entry of the sidebar: a tab on its own, or a group of tabs
    /// the user made and named.
    enum Item: Codable, Equatable, Identifiable {
        case tab(TabInfo)
        case group(GroupInfo)

        var id: String {
            switch self {
            case .tab(let t): t.id
            case .group(let g): g.id
            }
        }
    }

    struct GroupInfo: Codable, Equatable, Identifiable {
        var id: String
        /// The name the user gave it; "" until they do.
        var name: String
        var tabs: [TabInfo]
    }

    struct TabInfo: Codable, Equatable, Identifiable {
        var id: String
        /// A name the user gave the tab; nil or empty shows its program.
        var name: String?
        var panes: [PaneInfo]
        var layout: LayoutNode

        func pane(_ id: String?) -> PaneInfo? { panes.first { $0.id == id } }
    }

    enum Direction: String, Codable {
        case right, down
    }

    /// How a tab's panes are arranged: one pane, or a split holding two or
    /// more children in a row or column. Encoded as `{"pane":"id"}` or
    /// `{"split":{"id":…,"direction":…,"children":[{"layout":…,"weight":…},…]}}`,
    /// as the core writes it.
    indirect enum LayoutNode: Codable, Equatable {
        case pane(String)
        case split(Split)

        struct Split: Codable, Equatable {
            var id: String
            var direction: Direction
            var children: [Child]
        }

        /// A child of a split and its share of the split's length, relative to
        /// its siblings.
        struct Child: Codable, Equatable {
            var layout: LayoutNode
            var weight: Double
        }

        private enum CodingKeys: String, CodingKey { case pane, split }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let id = try c.decodeIfPresent(String.self, forKey: .pane) {
                self = .pane(id)
            } else {
                self = .split(try c.decode(Split.self, forKey: .split))
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .pane(let id): try c.encode(id, forKey: .pane)
            case .split(let s): try c.encode(s, forKey: .split)
            }
        }

        /// The panes, left to right and top to bottom.
        var panes: [String] {
            switch self {
            case .pane(let id): [id]
            case .split(let s): s.children.flatMap { $0.layout.panes }
            }
        }
    }

    struct PaneInfo: Codable, Equatable, Identifiable {
        var id: String
        var pid: Int32
        /// The title the program set (OSC 0/2), or "".
        var title: String
        /// The foreground program's working directory, or the shell's.
        var cwd: String
        /// The home directory on the pane's machine, for showing `cwd` as
        /// `~/…`; absent from servers that predate it.
        var home: String?
        /// The foreground program, or "" when the shell is at its prompt.
        var program: String
        /// The shell's name, such as "zsh".
        var shell: String
        /// Whether a full-screen program (vim, btop) has the alternate screen.
        var fullscreen: Bool
        var status: Status
    }

    /// What a pane's program is doing: as it reports it (OSC 7501), or as
    /// the server infers it from output.
    enum Status: String, Codable {
        case idle, working, blocked, done, error
    }

    /// Per-pane engine defaults. Colors are six hex digits without '#'.
    /// JSON accepts a page-granularity MiB estimate in 0...1024; the config
    /// file and Settings use 1...32 (`Config.scrollbackMBRange`). Zero
    /// disables server/cooperating-mirror history. Old v6 apps
    /// restore their own 32 MiB default; this is not a privacy or hard cap.
    struct Appearance: Codable, Equatable {
        var foreground: String = "e6e6ea"
        var background: String = "17171b"
        var cursor: String = "e6e6ea"
        var scrollbackMB: Int = 32

        init(foreground: String = "e6e6ea", background: String = "17171b",
             cursor: String = "e6e6ea", scrollbackMB: Int = 32) {
            self.foreground = foreground
            self.background = background
            self.cursor = cursor
            self.scrollbackMB = scrollbackMB
        }

        private enum CodingKeys: String, CodingKey { case foreground, background, cursor, scrollbackMB }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            foreground = try c.decodeIfPresent(String.self, forKey: .foreground) ?? "e6e6ea"
            background = try c.decodeIfPresent(String.self, forKey: .background) ?? "17171b"
            cursor = try c.decodeIfPresent(String.self, forKey: .cursor) ?? "e6e6ea"
            scrollbackMB = try c.decodeIfPresent(Int.self, forKey: .scrollbackMB) ?? 32
        }
    }

    struct Command: Codable {
        enum Op: String, Codable {
            /// A tab after `tab` (in its group, if it has one), or at the end.
            case newTab
            case closeTab
            /// A new shell beside `pane`, in `direction`; the pane keeps the
            /// first half.
            case splitPane
            case closePane
            /// Swaps `pane` and `target`'s positions within their tab.
            case swapPanes
            /// Sets a divider ratio/index or replaces all child weights.
            case resizeSplit
            /// Puts `tab` with `target`: into `target`'s group, or into a new
            /// group of the two where `target` was.
            case group
            /// Moves `tab` into `group` (or out to the top level when nil) at
            /// `index`, or at the end.
            case move
            case renameGroup
            case renameTab
            /// Replaces `group` with its tabs.
            case ungroup
            /// Closes every tab in `group`.
            case closeGroup
            /// Clears retained history, preserving the visible screen, modes and parser.
            case clearPane
            /// Resets screen, modes, history and parser; keeps PTY, size and appearance.
            case resetPane
            /// Applies appearance defaults and history limit to an existing pane.
            case configurePane
            /// Feature probe; old v6 servers return a command error without changes.
            case serverInfo
            /// Reports the current pane program's status without OSC output.
            case reportStatus
        }
        var op: Op
        var tab: String?
        var pane: String?
        var direction: Direction?
        var split: String?
        var ratio: Double?
        /// Full split weights, one finite positive value per child. Requires
        /// resizeSplitWeights; mutually exclusive with ratio and index.
        var weights: [Double]?
        var target: String?
        var group: String?
        var index: Int?
        var name: String?
        /// New tab cwd (home if nil); split cwd (source pane's cwd if nil).
        /// Explicit split cwd requires splitCwd: old v6 silently ignores it.
        var cwd: String?
        /// Shell source passed intact to the user's login shell with -c.
        /// Nil preserves interactive login-shell startup. Requires capability startup.
        var startup: String?
        /// Creation/configuration defaults. Requires capability configurePane.
        var appearance: Appearance?
        /// Explicit foreground-program status for reportStatus; pane required.
        var status: Status?
        var cols: UInt16?
        var rows: UInt16?
        var cellWidth: UInt32?
        var cellHeight: UInt32?
    }

    /// A UDP port and secret for one client, from `koi --offer`.
    struct Offer: Codable {
        var port: UInt16
        /// 32 random bytes, hex.
        var secret: String
    }

    /// What a command made or failed to do.
    struct Result: Codable {
        var tab: String?
        var pane: String?
        var group: String?
        var error: String?
        /// Identity and capabilities of the answering process; absent on old v6 servers.
        var serverVersion: String?
        var serverPID: Int32?
        var protocolVersion: UInt32?
        var uptimeSeconds: UInt64?
        var transports: [String]?
        var capabilities: [String]?

        /// A successful serverInfo response must explicitly advertise a feature.
        func supports(_ capability: String) -> Bool {
            error == nil && capabilities?.contains(capability) == true
        }
    }

    /// The 32 bytes of an offer's secret, written as 64 ASCII hex digits;
    /// empty for anything else (wrong length, a non-hex character).
    static func secretBytes(_ hex: String) -> [UInt8] {
        func digit(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: c - 0x30
            case 0x41...0x46: c - 0x41 + 10
            case 0x61...0x66: c - 0x61 + 10
            default: nil
            }
        }
        let chars = Array(hex.utf8)
        guard chars.count == 64 else { return [] }
        var out = [UInt8]()
        out.reserveCapacity(32)
        for i in stride(from: 0, to: 64, by: 2) {
            guard let hi = digit(chars[i]), let lo = digit(chars[i + 1]) else { return [] }
            out.append(hi << 4 | lo)
        }
        return out
    }

    static let headerSize = 5

    static func frame(_ kind: Kind, _ payload: some Collection<UInt8>) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(headerSize + payload.count)
        out.append(kind.rawValue)
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { out.append(contentsOf: $0) }
        out.append(contentsOf: payload)
        return out
    }

    static func frame(_ kind: Kind, json value: some Encodable) -> [UInt8] {
        frame(kind, [UInt8](try! JSONEncoder().encode(value)))
    }

    static func exitPayload(_ code: Int32) -> [UInt8] {
        withUnsafeBytes(of: code.littleEndian) { Array($0) }
    }

    static func encode(_ size: GridSize) -> [UInt8] {
        var out = [UInt8]()
        for v in [UInt32(size.cols), UInt32(size.rows), size.cellWidth, size.cellHeight] {
            withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) }
        }
        return out
    }

    /// The most cells (columns times rows) a grid may have.
    static let maxCells: UInt32 = 1_048_576

    /// A size from its 16 bytes; nil if the length is wrong, a dimension is
    /// zero or over 65535, or the grid has more than `maxCells` cells.
    static func decodeSize(_ p: ArraySlice<UInt8>) -> GridSize? {
        guard p.count == 16 else { return nil }
        let v = (0..<4).map { i in
            p.dropFirst(i * 4).prefix(4).reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        }
        guard v[0] > 0, v[1] > 0, v[0] <= UInt16.max, v[1] <= UInt16.max,
              v[0] * v[1] <= maxCells else { return nil }
        return GridSize(cols: UInt16(v[0]), rows: UInt16(v[1]), cellWidth: v[2], cellHeight: v[3])
    }
}

/// Splits a byte stream into frames, however the bytes arrive.
struct FrameReader {
    private var buffer = [UInt8]()
    private var start = 0

    /// The largest payload accepted; a bigger one means a broken peer.
    static let maxPayload = 64 * 1024 * 1024

    /// Drained backing storage larger than this is freed, not kept for reuse.
    private static let keptCapacity = 1024 * 1024

    private mutating func releaseIfDrained() {
        guard start == buffer.count else { return }
        // Payload slices still share the old storage; dropping our reference
        // leaves them valid.
        if buffer.capacity > Self.keptCapacity { buffer = [] } else { buffer.removeAll(keepingCapacity: true) }
        start = 0
    }

    mutating func append(_ bytes: UnsafeRawBufferPointer) {
        releaseIfDrained()
        if start > 64 * 1024 {
            buffer.removeSubrange(0..<start)
            start = 0
        }
        buffer.append(contentsOf: bytes)
    }

    /// The next whole frame, nil if more bytes are needed. Throws on a frame
    /// that cannot be valid.
    mutating func next() throws -> (Wire.Kind, ArraySlice<UInt8>)? {
        guard buffer.count - start >= Wire.headerSize else { return nil }
        let len = (1...4).reversed().reduce(0) { $0 << 8 | Int(buffer[start + $1]) }
        guard len <= Self.maxPayload, let kind = Wire.Kind(rawValue: buffer[start]) else {
            throw POSIXError(.EPROTO)
        }
        let end = start + Wire.headerSize + len
        guard buffer.count >= end else { return nil }
        let payload = buffer[(start + Wire.headerSize)..<end]
        start = end
        releaseIfDrained()
        return (kind, payload)
    }
}
