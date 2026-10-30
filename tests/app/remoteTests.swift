import CryptoKit
import Darwin
import Foundation
import Synchronization
import Testing
@testable import Koi

/// Disposable local shell fixtures exercise process I/O without contacting SSH hosts.
@Suite struct RemoteTests {
    /// Shell builtins keep timeout/cancellation fixtures confined to one child process.
    private func command(_ script: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        return process
    }

    @Test func drainsStderrWhileStdoutRemainsOpen() throws {
        let process = command("i=0; while [ $i -lt 8000 ]; do printf 'stderr line filling the pipe\\n' >&2; i=$((i+1)); done; printf done")
        let result = try Remote.runProcess(process, timeout: 5)
        #expect(String(decoding: result.output, as: UTF8.self) == "done")
        #expect(result.errors.count == 8000 * 29)
        #expect(process.terminationStatus == 0)
    }

    @Test func permitsExactLimitAndRejectsOverflowOnEitherStream() throws {
        let result = try Remote.runProcess(command("printf 12345678; printf abcdefgh >&2"), outputLimit: 8)
        #expect(result.output == Data("12345678".utf8))
        #expect(result.errors == Data("abcdefgh".utf8))
        for redirect in ["", " >&2"] {
            let process = command("printf 123456789" + redirect + "; while :; do :; done")
            #expect(throws: Remote.Failure.self) {
                try Remote.runProcess(process, outputLimit: 8, timeout: 2)
            }
            #expect(!process.isRunning)
            #expect(kill(process.processIdentifier, 0) == -1 && errno == ESRCH)
        }
    }

    @Test func timeoutReapsChildThatIgnoresTerminationAndNeverReadsInput() {
        let process = command("trap '' TERM; while :; do :; done")
        let start = ProcessInfo.processInfo.systemUptime
        #expect(throws: Remote.Failure.self) {
            try Remote.runProcess(process, input: Data(repeating: 65, count: 4 * 1024 * 1024), timeout: 0.1)
        }
        #expect(ProcessInfo.processInfo.systemUptime - start < 3)
        #expect(!process.isRunning)
        #expect(kill(process.processIdentifier, 0) == -1 && errno == ESRCH)
    }

    @Test func cancellationReapsChildWithBlockedInput() async throws {
        let process = command("while :; do :; done")
        let task = Task.detached {
            try Remote.runProcess(process, input: Data(repeating: 65, count: 4 * 1024 * 1024), timeout: 5)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let started = process.isRunning
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError { } catch { Issue.record("Unexpected error type") }
        #expect(started)
        #expect(!process.isRunning)
        if started { #expect(kill(process.processIdentifier, 0) == -1 && errno == ESRCH) }
    }

    @Test func sendsInputAndClosesItAtEOF() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        let input = Data(repeating: 65, count: 256 * 1024)
        let result = try Remote.runProcess(process, input: input, timeout: 5)
        #expect(result.output == input)
        #expect(result.errors.isEmpty)
    }

    /// Both output pipes fill before the child consumes a larger input stream.
    /// A command that reads its input to the end must see the end every time, even
    /// when many run at once. Shutting down our write side alone left one in about
    /// five hundred blocked in `cat` until the deadline, so this runs a few hundred.
    /// The workers are dispatch threads: they block, and blocking tasks would take
    /// every thread the other tests need to resume.
    @Test func concurrentCommandsAlwaysSeeTheEndOfTheirInput() {
        let input = Data(repeating: 107, count: 128 * 1024)
        let stalled = Mutex(0)
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            for _ in 0..<30 {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", "cat > /dev/null"]
                do { _ = try Remote.runProcess(process, input: input, timeout: 4) }
                catch { stalled.withLock { $0 += 1 } }
            }
        }
        #expect(stalled.withLock { $0 } == 0)
    }

    @Test func drainsBothOutputsWhileFeedingInput() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", """
            print STDERR "e" x (256 * 1024);
            print STDOUT "o" x (256 * 1024);
            while (read(STDIN, $buf, 65536)) { print STDOUT $buf; }
            """]
        let input = Data(repeating: 105, count: 512 * 1024)
        let result = try Remote.runProcess(process, input: input, timeout: 5)
        #expect(result.output == Data(repeating: 111, count: 256 * 1024) + input)
        #expect(result.errors == Data(repeating: 101, count: 256 * 1024))
        #expect(process.terminationStatus == 0)
    }

    /// Early stdin closure rejects an incomplete upload without masking a failed child's stderr.
    @Test(arguments: [0, 23]) func reportsEarlyInputClosure(status: Int) throws {
        let process = command("exec 0<&-; printf rejected >&2; exit \(status)")
        let input = Data(repeating: 1, count: 4 * 1024 * 1024)
        if status == 0 {
            #expect(throws: Remote.Failure.self) {
                try Remote.runProcess(process, input: input, timeout: 3)
            }
        } else {
            let result = try Remote.runProcess(process, input: input, timeout: 3)
            #expect(result.errors == Data("rejected".utf8))
        }
        #expect(process.terminationStatus == Int32(status))
        #expect(!process.isRunning)
    }

    /// A child exiting cannot bypass the deadline through pipes inherited by its descendant.
    @Test func boundsLifetimeOfInheritedOutputPipes() throws {
        let fixture = try RemoteFixture()
        defer { fixture.remove() }
        let pidFile = fixture.root.appendingPathComponent("child-pid")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", """
            $pid = fork(); die $! unless defined $pid; exit 0 if $pid;
            open(my $file, '>', $ARGV[0]) or die $!; print $file $$; close $file;
            sleep 60;
            """, pidFile.path]
        defer {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(text) {
                kill(pid, SIGKILL)
            }
        }
        let start = ContinuousClock.now
        #expect(throws: Remote.Failure.self) {
            try Remote.runProcess(process, timeout: 0.5)
        }
        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(!process.isRunning)
    }
}

/// Preparation scripts run locally in private homes, including paths containing spaces.
extension RemoteTests {
    /// A queued caller re-probes the finished install; a different host never waits for it.
    @Test func remotePreparationSerializesOneHostWhileOtherHostsProceed() throws {
        let fixture = try RemoteFixture()
        let other = try RemoteFixture()
        defer { fixture.remove(); other.remove() }
        let host = UUID().uuidString
        let uploading = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let secondStarted = DispatchSemaphore(value: 0)
        let secondProbe = DispatchSemaphore(value: 0)
        let done = DispatchGroup()
        let failures = Mutex<[String]>([])
        defer { release.signal(); _ = done.wait(timeout: .now() + RemoteFixture.hangLimit) }
        done.enter()
        DispatchQueue.global().async {
            defer { done.leave() }
            do {
                try fixture.prepare(host) { input in
                    if input != nil {
                        uploading.signal()
                        #expect(release.wait(timeout: .now() + RemoteFixture.hangLimit) == .success)
                    }
                }
            } catch { failures.withLock { $0.append(String(describing: error)) } }
        }
        try #require(uploading.wait(timeout: .now() + RemoteFixture.hangLimit) == .success)
        done.enter()
        DispatchQueue.global().async {
            defer { done.leave() }
            secondStarted.signal()
            do {
                try fixture.prepare(host) { input in
                    if input == nil { secondProbe.signal() }
                }
            } catch { failures.withLock { $0.append(String(describing: error)) } }
        }
        try #require(secondStarted.wait(timeout: .now() + RemoteFixture.hangLimit) == .success)
        try other.prepare(UUID().uuidString)
        #expect(secondProbe.wait(timeout: .now() + 0.1) == .timedOut)
        release.signal()
        try #require(done.wait(timeout: .now() + RemoteFixture.hangLimit) == .success)
        #expect(failures.withLock { $0.isEmpty })
        #expect(fixture.counts.withLock { $0.probes } == 2)
        #expect(fixture.counts.withLock { $0.uploads } == 1)
        #expect(fixture.counts.withLock { $0.links } == 2)
        #expect(try Data(contentsOf: fixture.installed) == Data(contentsOf: fixture.binary))
        #expect(!FileManager.default.fileExists(atPath: fixture.hashFile.path))
    }

    /// Failed staging leaves the previous files intact, cleans up, and releases the host gate.
    @Test func remotePreparationPreservesInstallationOnFailureAndCanRetry() throws {
        let fixture = try RemoteFixture()
        defer { fixture.remove() }
        let host = UUID().uuidString
        try Data("previous binary".utf8).write(to: fixture.installed)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.installed.path)
        try Data("previous hash\n".utf8).write(to: fixture.hashFile)
        #expect(throws: Remote.Failure.self) { try fixture.prepare(host, failUpload: true) }
        #expect(fixture.counts.withLock { $0.links } == 0)
        #expect(try String(contentsOf: fixture.installed, encoding: .utf8) == "previous binary")
        #expect(try String(contentsOf: fixture.hashFile, encoding: .utf8) == "previous hash\n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.installed.deletingLastPathComponent().path).sorted()
            == ["koi", "koi.sha256"])
        try fixture.prepare(host)
        #expect(fixture.counts.withLock { $0.links } == 1)
        #expect(try Data(contentsOf: fixture.installed) == Data(contentsOf: fixture.binary))
        #expect(try String(contentsOf: fixture.hashFile, encoding: .utf8) == "previous hash\n")
    }

    /// Pause version A after its rename, publish B, then finish A. A later probe
    /// must detect B's real bytes even if an old client left A's hash sidecar.
    @Test func remotePreparationDetectsInterleavedVersionsAcrossProcesses() throws {
        let fixture = try RemoteFixture()
        defer { fixture.remove() }
        let versionB = fixture.root.appendingPathComponent("version-b")
        let bytesB = Data(repeating: 98, count: 128 * 1024)
        try bytesB.write(to: versionB)
        let done = DispatchGroup()
        let failures = Mutex<[String]>([])
        defer {
            try? Data().write(to: fixture.root.appendingPathComponent("release"))
            _ = done.wait(timeout: .now() + RemoteFixture.hangLimit)
        }
        done.enter()
        DispatchQueue.global().async {
            defer { done.leave() }
            do { try fixture.prepare(UUID().uuidString, environment: ["PAUSE_PUBLICATION": "after"]) }
            catch { failures.withLock { $0.append(String(describing: error)) } }
        }
        try #require(fixture.waitForPublication())
        try fixture.prepare(UUID().uuidString, source: versionB)
        #expect(try Data(contentsOf: fixture.installed) == bytesB)
        try Data().write(to: fixture.root.appendingPathComponent("release"))
        try #require(done.wait(timeout: .now() + RemoteFixture.hangLimit) == .success)
        #expect(failures.withLock { $0.isEmpty })
        try Data((fixture.hash + "\n").utf8).write(to: fixture.hashFile)
        try fixture.prepare(UUID().uuidString)
        #expect(try Data(contentsOf: fixture.installed) == Data(contentsOf: fixture.binary))
        #expect(fixture.counts.withLock { $0.uploads } == 3)
    }

    /// SIGKILL on either side of the commit leaves no lock to recover. The next
    /// probe ignores abandoned stages and recognizes a completed binary rename.
    @Test(arguments: ["before", "after"]) func remotePreparationRecoversFromPublisherCrash(phase: String) throws {
        let fixture = try RemoteFixture()
        defer { fixture.remove() }
        try Data("previous binary".utf8).write(to: fixture.installed)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.installed.path)
        try Data("stale sidecar\n".utf8).write(to: fixture.hashFile)
        do {
            try fixture.prepare(UUID().uuidString, environment: ["CRASH_PUBLICATION": phase])
            Issue.record("Expected the publisher to be killed")
        } catch let failure as Remote.Failure {
            #expect(failure.description.isEmpty, "Expected a killed publisher, received: \(failure)")
        }
        if phase == "before" {
            #expect(try String(contentsOf: fixture.installed, encoding: .utf8) == "previous binary")
        } else {
            #expect(try Data(contentsOf: fixture.installed) == Data(contentsOf: fixture.binary))
        }
        try fixture.prepare(UUID().uuidString)
        #expect(try Data(contentsOf: fixture.installed) == Data(contentsOf: fixture.binary))
        #expect(fixture.counts.withLock { $0.uploads } == (phase == "before" ? 2 : 1))
    }

    /// A truncated upload must never replace the current executable, even when
    /// SSH and the byte-copying command themselves exit successfully.
    @Test func remotePreparationRejectsCorruptedStagedBytes() throws {
        let fixture = try RemoteFixture()
        defer { fixture.remove() }
        try Data("previous binary".utf8).write(to: fixture.installed)
        #expect(throws: Remote.Failure.self) {
            try fixture.prepare(UUID().uuidString, inputOverride: Data("truncated".utf8))
        }
        #expect(try String(contentsOf: fixture.installed, encoding: .utf8) == "previous binary")
        #expect(fixture.counts.withLock { $0.links } == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.installed.deletingLastPathComponent().path) == ["koi"])
    }
}

/// Runs the actual probe/install scripts in a private HOME with a fake binary.
/// Fake tools can fail staging or pause/crash a publisher around the binary rename.
private final class RemoteFixture: Sendable {
    let root: URL
    let binary: URL
    let installed: URL
    let hashFile: URL
    let hash: String
    let counts = Mutex((probes: 0, uploads: 0, links: 0))
    /// How long a fixture command or a wait on another thread may take before the
    /// test calls it hung. A paused publisher legitimately lives as long as the
    /// rest of its test, and a loaded CI Mac can take seconds to run the others,
    /// so this only has to catch something that never returns.
    static let hangLimit: TimeInterval = 30

    init() throws {
        let temporaryRoot = ProcessInfo.processInfo.environment["KOI_TEST_ROOT"] ?? NSTemporaryDirectory()
        root = URL(fileURLWithPath: temporaryRoot).appendingPathComponent("koi remote-\(UUID().uuidString)")
        binary = root.appendingPathComponent("server")
        installed = root.appendingPathComponent(".local/share/koi/koi")
        hashFile = root.appendingPathComponent(".local/share/koi/koi.sha256")
        let data = Data(repeating: 107, count: 128 * 1024)
        hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: binary)
        let tools = root.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: tools.appendingPathComponent("failing"), withIntermediateDirectories: true)
        let chmod = tools.appendingPathComponent("failing/chmod")
        try Data("#!/bin/sh\necho fixture-chmod-failed >&2\nexit 1\n".utf8).write(to: chmod)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: chmod.path)
        let mv = tools.appendingPathComponent("mv")
        try Data("""
            #!/bin/sh
            publication() {
                if [ "${CRASH_PUBLICATION-}" = "$1" ]; then kill -KILL "$PPID"; exit 1; fi
                if [ "${PAUSE_PUBLICATION-}" = "$1" ]; then
                    : > "$HOME/publishing"
                    while [ ! -f "$HOME/release" ]; do /bin/sleep 0.01; done
                fi
            }
            if [ "$3" = "$HOME/.local/share/koi/koi" ]; then
                publication before
                /bin/mv "$@" || exit 1
                publication after
            else
                /bin/mv "$@"
            fi
            """.utf8).write(to: mv)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mv.path)
    }

    /// Remove only this fixture's private files after all its commands finish.
    func remove() { try? FileManager.default.removeItem(at: root) }

    /// Waits for the remote shell's publication barrier, up to the hang limit.
    func waitForPublication() -> Bool {
        for _ in 0..<Int(Self.hangLimit * 100) {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("publishing").path) { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    /// Gates commands for concurrency checks; only the upload gets failing tools.
    func prepare(_ host: String, failUpload: Bool = false, source: URL? = nil, inputOverride: Data? = nil,
                 environment: [String: String] = [:], beforeCommand: (Data?) -> Void = { _ in }) throws {
        try Remote.prepare(host, serverBinary: { _ in source ?? self.binary }, run: { _, command, input in
            self.counts.withLock {
                if input == nil { $0.probes += 1 } else { $0.uploads += 1 }
            }
            beforeCommand(input)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.environment = ["HOME": self.root.path,
                "PATH": (failUpload && input != nil ? self.root.appendingPathComponent("tools/failing").path + ":" : "")
                    + self.root.appendingPathComponent("tools").path + ":/usr/bin:/bin"]
                .merging(environment) { _, value in value }
            let result = try Remote.runProcess(process, input: input == nil ? nil : inputOverride ?? input, timeout: Self.hangLimit)
            guard process.terminationStatus == 0 else {
                throw Remote.Failure(description: String(decoding: result.errors, as: UTF8.self))
            }
            return String(decoding: result.output, as: UTF8.self)
        }, openLink: { _ in self.counts.withLock { $0.links += 1 } })
    }
}
