import Foundation
import Observation
import Darwin

/// Caches reported device families independently of connection and session startup.
@MainActor @Observable final class DeviceIcons {
    static let shared = DeviceIcons()
    private var symbols: [String: String]
    @ObservationIgnored private var tasks: [Endpoint: Task<Void, Never>] = [:]
    @ObservationIgnored private var generations: [Endpoint: UUID] = [:]
    @ObservationIgnored private var completed: Set<Endpoint> = []
    @ObservationIgnored private let lookup: @Sendable (Endpoint) async -> String?
    @ObservationIgnored private let persist: @MainActor (String, String?) -> Void
    @ObservationIgnored private let scope: @MainActor () -> URL
    @ObservationIgnored private let load: @MainActor () -> [String: String]
    @ObservationIgnored private var currentScope: URL
    private static let allowedSymbols: Set<String> = ["macmini", "macstudio", "macbook.gen2", "macpro.gen3", "desktopcomputer", "server.rack"]

    init(symbols: [String: String]? = nil,
         lookup: @escaping @Sendable (Endpoint) async -> String? = DeviceProbe.defaultLookup,
         scope: @escaping @MainActor () -> URL = { Paths.layout },
         load: @escaping @MainActor () -> [String: String] = { Layout.load().deviceSymbols },
         persist: @escaping @MainActor (String, String?) -> Void = { key, symbol in
             var layout = Layout.load()
             layout.deviceSymbols[key] = symbol
             layout.save()
         }) {
        self.symbols = (symbols ?? load()).filter { Self.allowedSymbols.contains($0.value) }
        self.lookup = lookup
        self.persist = persist
        self.scope = scope
        self.load = load
        self.currentScope = scope()
    }

    isolated deinit { tasks.values.forEach { $0.cancel() } }

    /// Retire old lookups before reading or writing a different layout directory.
    private func syncScope() {
        let next = scope()
        guard currentScope != next else { return }
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        generations.removeAll()
        completed.removeAll()
        currentScope = next
        symbols = load().filter { Self.allowedSymbols.contains($0.value) }
    }

    /// Returns a cached symbol immediately; it never starts a process.
    func symbol(for endpoint: Endpoint) -> String {
        syncScope()
        return symbols[Self.key(endpoint)] ?? (endpoint == .local ? "laptopcomputer" : "desktopcomputer")
    }

    private static func key(_ endpoint: Endpoint) -> String {
        switch endpoint { case .local: "local"; case .ssh(let host): "ssh:" + host }
    }

    /// Starts at most one lookup per endpoint; failures may retry on reconnect.
    func probe(_ endpoint: Endpoint) {
        syncScope()
        guard tasks[endpoint] == nil, !completed.contains(endpoint) else { return }
        let generation = UUID(), lookup = lookup
        generations[endpoint] = generation
        tasks[endpoint] = Task { [weak self] in
            let result = await lookup(endpoint)
            guard let self else { return }
            self.syncScope()
            guard !Task.isCancelled, self.generations[endpoint] == generation else { return }
            self.tasks[endpoint] = nil
            self.generations[endpoint] = nil
            guard let result, Self.allowedSymbols.contains(result) else { return }
            self.completed.insert(endpoint)
            self.symbols[Self.key(endpoint)] = result
            self.persist(Self.key(endpoint), result)
        }
    }

    /// Discards a removed profile and prevents its old lookup from publishing.
    func remove(_ endpoint: Endpoint) {
        syncScope()
        tasks.removeValue(forKey: endpoint)?.cancel()
        generations[endpoint] = nil
        completed.remove(endpoint)
        symbols[Self.key(endpoint)] = nil
        persist(Self.key(endpoint), nil)
    }
}

/// Runs a bounded, noninteractive client-side hardware lookup, without server changes.
enum DeviceProbe {
    /// Map only the reported model family, never an SSH alias or hostname.
    static func symbol(model: String) -> String? {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let family = name.components(separatedBy: " (").first ?? name
        switch family {
        case "mac mini": return "macmini"
        case "mac studio": return "macstudio"
        case "macbook", "macbook air", "macbook pro": return "macbook.gen2"
        case "mac pro": return "macpro.gen3"
        case "imac", "imac pro": return "desktopcomputer"
        default: return nil
        }
    }

    /// Interpret the filtered command output; an empty response is a failed probe.
    static func symbol(output: String) -> String? {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return value == "Linux" ? "server.rack" : symbol(model: value)
    }

    /// XCTest fixtures never run the real hardware or SSH command.
    static func defaultLookup(_ endpoint: Endpoint) async -> String? {
        guard Bundle.main.bundleURL.pathExtension != "xctest" else { return nil }
        return await lookup(endpoint)
    }

    /// Read only the model name from profiler JSON; never retain other fields.
    static func symbol(profilerJSON: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: profilerJSON)) as? [String: Any],
              let hardware = root["SPHardwareDataType"] as? [[String: Any]],
              let model = hardware.first?["machine_name"] as? String else { return nil }
        return symbol(model: model)
    }

    static func lookup(_ endpoint: Endpoint) async -> String? {
        let command = "case $(uname -s) in Darwin) /usr/sbin/system_profiler -detailLevel mini SPHardwareDataType -json | /usr/bin/plutil -extract SPHardwareDataType.0.machine_name raw -o - - ;; Linux) printf 'Linux' ;; *) exit 1 ;; esac"
        let process = ProbeProcess()
        let task = Task.detached(priority: .utility) { () -> String? in
            let arguments: [String]
            let executable: String
            switch endpoint {
            case .local:
                executable = "/usr/sbin/system_profiler"; arguments = ["-detailLevel", "mini", "SPHardwareDataType", "-json"]
            case .ssh(let host):
                executable = "/usr/bin/ssh"; arguments = Remote.sshOptions + ["-T", host, command]
            }
            guard let data = process.run(executable, arguments) else { return nil }
            if endpoint == .local { return symbol(profilerJSON: data) }
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            return symbol(output: output)
        }
        return await withTaskCancellationHandler { await task.value } onCancel: {
            process.cancel()
            task.cancel()
        }
    }
}

/// Owns one subprocess and terminates it on cancellation or timeout.
private final class ProbeProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.withLock {
            cancelled = true
            if let process, process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        }
    }

    func run(_ executable: String, _ arguments: [String]) -> Data? {
        let p = Process()
        let output = Pipe()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        let started = lock.withLock { () -> Bool in
            guard !cancelled else { return false }
            do { try p.run(); process = p; return true } catch { return false }
        }
        guard started else { return nil }
        let timeout = DispatchWorkItem { [self] in cancel() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15, execute: timeout)
        var data = Data()
        while let chunk = try? output.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
            data.append(chunk)
            if data.count > 1_048_576 { cancel(); break }
        }
        try? output.fileHandleForReading.close()
        p.waitUntilExit()
        timeout.cancel()
        let valid = lock.withLock { () -> Bool in
            process = nil
            return !cancelled && p.terminationStatus == 0
        }
        return valid ? data : nil
    }
}
