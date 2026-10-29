import Darwin
import Foundation
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
}
