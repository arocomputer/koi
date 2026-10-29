import Foundation
import GhosttyVt
import Testing
@testable import Koi

@Suite struct WireTests {
    /// Frames arrive split and merged across reads however the socket
    /// delivers them; the reader must yield exactly the frames sent.
    @Test func readerReassemblesFramesAcrossArbitraryReads() throws {
        let frames: [(Wire.Kind, [UInt8])] = [
            (.output, Array("hello".utf8)),
            (.resized, Wire.encode(GridSize(cols: 80, rows: 24, cellWidth: 9, cellHeight: 18))),
            (.output, []),
            (.output, [UInt8](repeating: 7, count: 70_000)),
        ]
        let stream = frames.flatMap { Wire.frame($0.0, $0.1) }
        for chunk in [1, 3, 4096, stream.count] {
            var reader = FrameReader()
            var got: [(Wire.Kind, [UInt8])] = []
            var i = 0
            while i < stream.count {
                let end = min(i + chunk, stream.count)
                stream[i..<end].withUnsafeBytes { reader.append($0) }
                while let (k, p) = try reader.next() { got.append((k, Array(p))) }
                i = end
            }
            #expect(got.map(\.0) == frames.map(\.0), "chunk \(chunk)")
            #expect(got.map(\.1) == frames.map(\.1), "chunk \(chunk)")
        }
    }

    @Test func sizeRejectsTooManyCellsAndBadDimensions() {
        func size(_ c: UInt16, _ r: UInt16) -> GridSize? {
            Wire.decodeSize(Wire.encode(GridSize(cols: c, rows: r, cellWidth: 1, cellHeight: 1))[...])
        }
        #expect(size(1024, 1024) != nil)
        #expect(size(1025, 1024) == nil)
        #expect(size(65535, 1) != nil)
        #expect(size(65535, 65535) == nil)
        #expect(Wire.decodeSize([UInt8](repeating: 0, count: 15)[...]) == nil)
        #expect(Wire.decodeSize([UInt8](repeating: 0, count: 16)[...]) == nil)
    }

    @Test func secretBytesAcceptsOnlyExactHex() {
        let hex = String(repeating: "0aF9", count: 16)
        #expect(Wire.secretBytes(hex) == Array(repeating: [0x0a, 0xf9], count: 16).flatMap { $0 })
        #expect(Wire.secretBytes(String(hex.dropLast())) == [])
        #expect(Wire.secretBytes(hex + "00") == [])
        #expect(Wire.secretBytes("") == [])
        #expect(Wire.secretBytes(String(hex.dropLast()) + "g") == [])
        #expect(Wire.secretBytes(String(hex.dropLast()) + "é") == [])
        #expect(Wire.secretBytes("+1" + hex.dropFirst(2)) == [])
    }

    @Test func readerRejectsOversizedLengthAndUnknownKind() throws {
        func feed(_ header: [UInt8]) throws -> Bool {
            var reader = FrameReader()
            header.withUnsafeBytes { reader.append($0) }
            return try reader.next() != nil
        }
        func header(kind: UInt8, len: Int) -> [UInt8] {
            [kind] + withUnsafeBytes(of: UInt32(len).littleEndian) { Array($0) }
        }
        #expect(try feed(Array(header(kind: 66, len: 0).prefix(4))) == false)
        #expect(try feed(header(kind: 66, len: FrameReader.maxPayload)) == false)
        #expect(throws: POSIXError.self) { try feed(header(kind: 66, len: FrameReader.maxPayload + 1)) }
        #expect(throws: POSIXError.self) { try feed(header(kind: 99, len: 0)) }
    }

    @Test func readerStaysValidAfterReleasingLargeStorage() throws {
        var reader = FrameReader()
        let big = [UInt8](repeating: 9, count: 4 * 1024 * 1024)
        Wire.frame(.output, big).withUnsafeBytes { reader.append($0) }
        let (_, payload) = try #require(try reader.next())
        Wire.frame(.output, [1, 2]).withUnsafeBytes { reader.append($0) }
        let (_, small) = try #require(try reader.next())
        #expect(Array(small) == [1, 2])
        #expect(payload.count == big.count && payload.allSatisfy { $0 == 9 })
    }

    /// Ownership negotiation leaves old open requests unchanged on the wire.
    @Test func paneOwnershipFieldsAreAdditive() throws {
        let legacy = Wire.OpenRequest(pane: "p", cols: 80, rows: 24, cellWidth: 8, cellHeight: 16)
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        #expect(object["paneControl"] == nil && object["observer"] == nil)
        let modern = Wire.OpenRequest(pane: "p", cols: 80, rows: 24, cellWidth: 8, cellHeight: 16,
                                      paneControl: true, observer: false)
        let decoded = try JSONDecoder().decode(Wire.OpenRequest.self, from: JSONEncoder().encode(modern))
        #expect(decoded.paneControl == true && decoded.observer == false)
        let info = try JSONDecoder().decode(Wire.Result.self, from: Data(#"{"layoutFormat":"binary-v1","snapshotFormat":"ghostty-vt-v1"}"#.utf8))
        #expect(info.layoutFormat == "binary-v1" && info.snapshotFormat == "ghostty-vt-v1")
        #expect(Wire.Kind.paneControl.rawValue == 9 && Wire.Kind.ownership.rawValue == 72 && Wire.Kind.failure.rawValue == 73)
    }

    /// Old commands and results omit workflow capabilities and server identity.
    @Test func optionalWorkflowFieldsKeepV6JSONCompatible() throws {
        let old = try JSONDecoder().decode(Wire.Command.self, from: Data(#"{"op":"newTab"}"#.utf8))
        #expect(old.startup == nil && old.appearance == nil)
        let oldJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any]
        #expect(oldJSON?["startup"] == nil && oldJSON?["appearance"] == nil)
        let result = try JSONDecoder().decode(Wire.Result.self, from: Data(#"{"pane":"existing"}"#.utf8))
        #expect(result.serverPID == nil && result.serverVersion == nil)
        #expect(!result.supports("resetPane"))
        let rejected = Wire.Result(error: "malformed command", capabilities: ["resetPane"])
        #expect(!rejected.supports("resetPane"))
        let supported = Wire.Result(serverVersion: "0.1.0", serverPID: 42, protocolVersion: 6,
                                    uptimeSeconds: 5, transports: ["unix"], capabilities: ["resetPane"])
        #expect(supported.supports("resetPane") && !supported.supports("unknown"))
    }

    @Test func appearanceDefaultsAndStartupSourceRoundTrip() throws {
        let appearance = try JSONDecoder().decode(Wire.Appearance.self, from: Data(
            #"{"foreground":"aA11ff","background":"000000","cursor":"ffffff"}"#.utf8))
        #expect(appearance.scrollbackMB == 32)
        let source = "printf '%s' 'two words' | cat"
        let command = Wire.Command(op: .splitPane, pane: "original", cwd: "/", startup: source, appearance: appearance)
        let back = try JSONDecoder().decode(Wire.Command.self, from: JSONEncoder().encode(command))
        #expect(back.startup == source && back.appearance == appearance && back.cwd == "/")
        for op in [Wire.Command.Op.clearPane, .resetPane, .configurePane, .serverInfo] {
            let encoded = try JSONEncoder().encode(Wire.Command(op: op, pane: "original"))
            #expect(try JSONDecoder().decode(Wire.Command.self, from: encoded).op == op)
        }
    }

    /// A live pre-weighted v6 server must stay readable after its first split,
    /// including unequal nested dividers whose IDs are used for resizing.
    @Test func legacySplitsPreserveTheirTreeAndDividerWeights() throws {
        let json = #"{"split":{"id":"outer","direction":"right","ratio":0.25,"first":{"pane":"a"},"second":{"split":{"id":"inner","direction":"down","ratio":0.75,"first":{"pane":"b"},"second":{"pane":"c"}}}}}"#
        let layout = try JSONDecoder().decode(Wire.LayoutNode.self, from: Data(json.utf8))
        guard case .split(let outer) = layout, case .split(let inner) = outer.children[1].layout else {
            Issue.record("The server's nested splits were lost")
            return
        }
        #expect(layout.panes == ["a", "b", "c"])
        #expect(outer.id == "outer" && outer.direction == .right)
        #expect(outer.children.map(\.weight) == [0.25, 0.75])
        #expect(inner.id == "inner" && inner.direction == .down)
        #expect(inner.children.map(\.weight) == [0.75, 0.25])
        let encoded = try JSONEncoder().encode(layout)
        #expect(try JSONDecoder().decode(Wire.LayoutNode.self, from: encoded) == layout)
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let split = try #require(object["split"] as? [String: Any])
        #expect(split["children"] != nil && split["ratio"] == nil && split["first"] == nil)
    }

    /// A malformed weighted split must not fall back to the legacy fields.
    @Test func malformedSplitFormatsAreRejected() {
        for split in [
            #""ratio":0,"first":{"pane":"a"},"second":{"pane":"b"}"#,
            #""ratio":0.5,"first":{"pane":"a"}"#,
            #""children":null,"ratio":0.5,"first":{"pane":"a"},"second":{"pane":"b"}"#,
        ] {
            let json = "{\"split\":{\"id\":\"s\",\"direction\":\"right\",\(split)}}"
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(Wire.LayoutNode.self, from: Data(json.utf8))
            }
        }
    }

    /// Projects assign weights after construction; old ratio-only commands
    /// keep omitting weights and status from their v6 JSON.
    @Test func splitWeightsAndTypedStatusRoundTripAdditively() throws {
        var weighted = Wire.Command(op: .resizeSplit, split: "split123")
        weighted.weights = [1, 2, 3]
        let decoded = try JSONDecoder().decode(Wire.Command.self, from: JSONEncoder().encode(weighted))
        #expect(decoded.weights == [1, 2, 3] && decoded.ratio == nil && decoded.index == nil)
        let divider = Wire.Command(op: .resizeSplit, split: "split123", ratio: 0.25, index: 1)
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(divider)) as? [String: Any])
        #expect(object["weights"] == nil && object["status"] == nil)
        for status in [Wire.Status.working, .blocked, .done, .error, .idle] {
            let command = Wire.Command(op: .reportStatus, pane: "status01", status: status)
            let json = try JSONEncoder().encode(command)
            let back = try JSONDecoder().decode(Wire.Command.self, from: json)
            #expect(back.op == .reportStatus && back.status == status)
            let payload = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
            #expect(payload["status"] as? String == status.rawValue)
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Wire.Command.self, from: Data(#"{"op":"reportStatus","status":"unknown"}"#.utf8))
        }
    }

    /// Snapshots preserve server defaults and parser continuation through
    /// repeated decode/encode cycles, rather than applying the local theme.
    @Test func restoredAppearanceAndParserRemainAuthoritative() throws {
        let source = VTTerminal(cols: 20, rows: 4)
        var foreground = GhosttyColorRgb(r: 0x12, g: 0x34, b: 0x56)
        var background = GhosttyColorRgb(r: 0x78, g: 0x9a, b: 0xbc)
        var cursor = GhosttyColorRgb(r: 0xab, g: 0xcd, b: 0xef)
        var limit = 1 * 1024 * 1024
        ghostty_terminal_set(source.raw, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foreground)
        ghostty_terminal_set(source.raw, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &background)
        ghostty_terminal_set(source.raw, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cursor)
        ghostty_terminal_set(source.raw, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &limit)
        source.write(Array("visible\u{1b}]2;unfinished".utf8))
        let mirror = try #require(VTTerminal(snapshot: source.snapshot()))
        let replay = try #require(VTTerminal(snapshot: mirror.snapshot()))
        for (key, expected) in [(GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND, foreground),
                                (GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND, background),
                                (GHOSTTY_TERMINAL_DATA_COLOR_CURSOR, cursor)] {
            var actual = GhosttyColorRgb()
            #expect(ghostty_terminal_get(replay.raw, key, &actual) == GHOSTTY_SUCCESS)
            #expect(actual.r == expected.r && actual.g == expected.g && actual.b == expected.b)
        }
        var restoredLimit = 0
        #expect(ghostty_terminal_get(replay.raw, GHOSTTY_TERMINAL_DATA_SCROLLBACK_MAX_BYTES, &restoredLimit) == GHOSTTY_SUCCESS)
        #expect(restoredLimit == limit)
        replay.write(Array(" title\u{7}after".utf8))
        #expect(replay.title == "unfinished title")
        #expect(replay.text() == "visibleafter")
    }

    /// A restored mirror keeps the grapheme-clustering mode its program left,
    /// but a full reset returns it to the same default as the server's terminal.
    @Test func restoredTerminalsReturnToGraphemeClusteringOnReset() throws {
        let source = VTTerminal(cols: 20, rows: 4)
        source.write(Array("\u{1b}[?2027l".utf8))
        let mirror = try #require(VTTerminal(snapshot: source.snapshot()))
        #expect(!mirror.mode(2027))
        mirror.write(Array("\u{1b}c".utf8))
        #expect(mirror.mode(2027))
    }

    @Test func promptScrollingUsesEngineMarkersAndReportsNoMovement() {
        let terminal = VTTerminal(cols: 80, rows: 2)
        for n in 1...3 {
            terminal.write(Array("\u{1b}]133;P;k=i\u{7}p\(n)\r\n\u{1b}]133;B\u{7}cmd\(n)\r\n\u{1b}]133;C\u{7}out\(n)\r\n".utf8))
        }
        terminal.write(Array("\u{1b}]133;P;k=i\u{7}p4".utf8))
        #expect(terminal.scrollPrompt(previous: true))
        var bar = GhosttyTerminalScrollbar()
        ghostty_terminal_get(terminal.raw, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &bar)
        #expect(bar.offset == 6)
        #expect(terminal.scrollPrompt(previous: true))
        ghostty_terminal_get(terminal.raw, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &bar)
        #expect(bar.offset == 3)
        #expect(terminal.scrollPrompt(previous: false))
        ghostty_terminal_get(terminal.raw, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &bar)
        #expect(bar.offset == 6)
        terminal.write(Array("\u{1b}[?1049h".utf8))
        #expect(!terminal.scrollPrompt(previous: true))
        let unmarked = VTTerminal(cols: 20, rows: 2)
        unmarked.write(Array(String(repeating: "output\r\n", count: 10).utf8))
        #expect(!unmarked.scrollPrompt(previous: true))
    }
}

/// Private-server checks join the suite that serializes process-wide KOI_DIR.
extension SessionTests {
    @Test func serverInfoAndStartupCommandsUseTheRunningServer() throws {
        let server = try TestServer()
        defer { server.stop() }
        let control = try #require(TestControl())
        let info = control.run(.init(op: .serverInfo))
        #expect(info.error == nil && info.serverPID == server.process.processIdentifier)
        #expect(info.protocolVersion == 6 && info.uptimeSeconds != nil)
        #expect(info.supports("startup") && info.supports("configurePane") && info.supports("resetPane"))
        #expect(info.transports?.contains("encryptedUDP") == true)
        let created = control.run(.init(op: .newTab, cwd: "/",
            startup: "printf '<%s>\\n' 'two words'; pwd -P; exec /bin/cat",
            appearance: .init(foreground: "123456", background: "789abc", cursor: "abcdef", scrollbackMB: 1)))
        #expect(created.error == nil)
        let id = try #require(created.pane)
        let original = try #require(TestPane(id))
        defer { original.close() }
        #expect(original.waitForText("<two words>\n/"))
        let split = control.run(.init(op: .splitPane, pane: id, direction: .down,
            startup: "printf '%s' 'a b' | tr ' ' '_'; printf '\\n'; pwd -P; exec /bin/cat"))
        #expect(split.error == nil)
        let secondID = try #require(split.pane)
        let second = try #require(TestPane(secondID))
        defer { second.close() }
        #expect(second.waitForText("a_b\n/"))
        #expect(control.run(.init(op: .closeTab, tab: created.tab)).error == nil)
    }
}

/// Exposes engine state under the reader lock, so snapshot replacement and
/// subsequent output can be asserted without racing the private server.
private final class WorkflowMirror: @unchecked Sendable {
    private let socket: Socket
    private let lock = NSLock()
    private var terminal: VTTerminal?
    private var snapshots = 0

    init?(_ pane: String) {
        guard let socket = Socket.connect(path: Paths.socket) else { return nil }
        self.socket = socket
        socket.send(Wire.frame(.open, json: Wire.OpenRequest(pane: pane, cols: 0, rows: 0, cellWidth: 0, cellHeight: 0)))
        Thread.detachNewThread { [self] in
            socket.readFrames { kind, payload in
                lock.withLock {
                    switch kind {
                    case .snapshot:
                        terminal = VTTerminal(snapshot: Array(payload))
                        snapshots += 1
                    case .output: payload.withUnsafeBytes { terminal?.write($0) }
                    case .resized: if let size = Wire.decodeSize(payload) { terminal?.resize(size) }
                    default: break
                    }
                }
            }
        }
    }

    func type(_ text: String) { socket.send(.input, Array(text.utf8)) }
    func close() { socket.close() }

    /// Waits for engine state on this stream, including a specific replacement
    /// snapshot count, rather than relying on the control reply's timing.
    func waitFor(_ predicate: (VTTerminal, Int) -> Bool) -> Bool {
        for _ in 0..<1000 {
            if lock.withLock({ terminal.map { predicate($0, snapshots) } == true }) { return true }
            usleep(10_000)
        }
        return false
    }
}

extension SessionTests {
    @Test func paneEditsReplaceAttachedMirrorsAndReplayPostResetOutput() throws {
        let server = try TestServer()
        defer { server.stop() }
        let control = try #require(TestControl())
        let made = control.run(.init(op: .newTab,
            startup: "printf 'before-reset\\n'; printf '\\033[?2004h\\033]2;unfinished'; exec /bin/cat"))
        let id = try #require(made.pane)
        let first = try #require(WorkflowMirror(id))
        defer { first.close() }
        let second = try #require(WorkflowMirror(id))
        defer { second.close() }
        #expect(first.waitFor { terminal, count in count == 1 && terminal.text().contains("before-reset") })
        #expect(second.waitFor { terminal, count in count == 1 && terminal.mode(2004) })
        #expect(control.waitFor { $0.tabs.first?.panes.first?.id == id })
        let pid = control.state.tabs.first?.panes.first?.pid
        #expect(control.run(.init(op: .configurePane, pane: id,
            appearance: .init(foreground: "123456", background: "789abc", cursor: "abcdef", scrollbackMB: 1))).error == nil)
        for mirror in [first, second] {
            #expect(mirror.waitFor { terminal, count in
                var foreground = GhosttyColorRgb()
                var limit = 0
                ghostty_terminal_get(terminal.raw, GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND, &foreground)
                ghostty_terminal_get(terminal.raw, GHOSTTY_TERMINAL_DATA_SCROLLBACK_MAX_BYTES, &limit)
                return count == 2 && foreground.r == 0x12 && foreground.g == 0x34 && foreground.b == 0x56
                    && limit == 1024 * 1024 && terminal.mode(2004)
            })
        }
        #expect(control.run(.init(op: .clearPane, pane: id)).error == nil)
        for mirror in [first, second] {
            #expect(mirror.waitFor { terminal, count in count == 3 && terminal.text().contains("before-reset") && terminal.mode(2004) })
        }
        #expect(control.run(.init(op: .resetPane, pane: id)).error == nil)
        for mirror in [first, second] {
            #expect(mirror.waitFor { terminal, count in
                count == 4 && terminal.text().isEmpty && !terminal.mode(2004) && terminal.title.isEmpty
            })
        }
        first.type("after-reset\r")
        for mirror in [first, second] {
            #expect(mirror.waitFor { terminal, _ in terminal.text().contains("after-reset") && !terminal.text().contains("before-reset") })
        }
        let reattached = try #require(WorkflowMirror(id))
        defer { reattached.close() }
        #expect(reattached.waitFor { terminal, count in count == 1 && terminal.text().contains("after-reset") })
        #expect(control.state.tabs.first?.panes.first?.pid == pid)
        #expect(control.run(.init(op: .closeTab, tab: made.tab)).error == nil)
    }
}

extension SessionTests {
    /// Restores a three-child project layout and updates program metadata
    /// over the control stream while attached terminal contents stay intact.
    @Test func fullSplitWeightsAndStatusReportsReachWatchers() throws {
        let server = try TestServer()
        defer { server.stop() }
        let control = try #require(TestControl())
        let made = control.run(.init(op: .newTab, startup: "printf 'status-ready\\n'; exec /bin/cat"))
        let pane = try #require(made.pane)
        let mirror = try #require(WorkflowMirror(pane))
        defer { mirror.close() }
        #expect(mirror.waitFor { terminal, _ in terminal.text().contains("status-ready") })
        for _ in 0..<2 {
            #expect(control.run(.init(op: .splitPane, pane: pane, direction: .right, startup: "exec /bin/cat")).error == nil)
        }
        #expect(control.waitFor { $0.tabs.first?.panes.count == 3 })
        let layout = try #require(control.state.tabs.first?.layout)
        guard case .split(let split) = layout else { Issue.record("expected a split"); return }
        #expect(control.run(.init(op: .resizeSplit, split: split.id, weights: [1, 2, 3])).error == nil)
        #expect(control.waitFor { state in
            guard case .split(let current) = state.tabs.first?.layout else { return false }
            let actual = current.children.map(\.weight)
            return actual.count == 3 && abs(actual[0] - 1.0 / 6) < 1e-12
                && abs(actual[1] - 1.0 / 3) < 1e-12 && abs(actual[2] - 0.5) < 1e-12
        })
        let info = control.run(.init(op: .serverInfo))
        #expect(info.supports("resizeSplitWeights") && info.supports("reportStatus"))
        #expect(info.serverVersion?.hasPrefix("0.1.0+") == true)
        // Wait for foreground discovery before binding an explicit report to
        // cat, matching the report's lifetime when the program changes.
        #expect(control.waitFor { $0.tabs.first?.pane(pane)?.program == "cat" })
        for status in [Wire.Status.blocked, .done, .error, .working, .idle] {
            #expect(control.run(.init(op: .reportStatus, pane: pane, status: status)).error == nil)
            #expect(control.waitFor { $0.tabs.first?.pane(pane)?.status == status })
        }
        for (arguments, status) in [(["status", pane, "blocked"], Wire.Status.blocked), (["status", "done"], .done)] {
            let cli = Process()
            cli.executableURL = server.process.executableURL
            cli.arguments = arguments
            cli.environment = (server.process.environment ?? [:]).merging([
                "KOI_DIR": server.dir.path, "KOI_PANE": pane
            ]) { _, value in value }
            try cli.run()
            cli.waitUntilExit()
            #expect(cli.terminationStatus == 0)
            #expect(control.waitFor { $0.tabs.first?.pane(pane)?.status == status })
        }
        #expect(mirror.waitFor { terminal, count in count == 1 && terminal.text().contains("status-ready") })
        #expect(control.run(.init(op: .closeTab, tab: made.tab)).error == nil)
    }
}
