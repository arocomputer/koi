import Darwin
import Foundation
import Testing
@testable import Koi

/// Opt-in measurement against scripts/benchmark-remote.py's disposable Linux
/// process. No SSH, server creation, local KOI_DIR or display work happens here.
extension SessionTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KOI_REMOTE_BENCHMARK"] == "1"))
    func actualRemoteProcessEchoRoundTrip() throws {
        let fixture = try RemoteBenchmarkOffer.load()
        // Keep credentials out of Testing macro diagnostics, including failures.
        let connection = LinkClient(host: fixture.host, port: fixture.port,
                                    secret: Wire.secretBytes(fixture.secret))
        let link = try #require(connection, "remote encrypted UDP connection failed")
        let opened = link.open()
        let stream = try #require(opened, "remote stream could not open")
        defer { stream.close() }
        let attached = TestPane(fixture.pane, cols: 100, rows: 24, transport: stream)
        let pane = try #require(attached, "remote pane could not attach")
        defer { pane.close() }
        try #require(pane.waitForText("benchmark-ready"), "remote process did not become ready")

        // Unique response tags prevent prior samples or kernel input echo from
        // satisfying a later sample. Each reply comes from the child shell.
        var samples: [Double] = []
        let deadline = DispatchTime.now().uptimeNanoseconds + 90_000_000_000
        for index in 0..<43 {
            let request = String(format: "%03d", index)
            let response = "echo:\(request):done"
            let start = DispatchTime.now().uptimeNanoseconds
            try #require(start < deadline, "remote benchmark exceeded its 90-second budget")
            pane.type(request + "\n")
            while !pane.visibleText().contains(response),
                  DispatchTime.now().uptimeNanoseconds < min(deadline, start + 5_000_000_000) {
                usleep(500)
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            try #require(pane.visibleText().contains(response), "remote process echo exceeded five seconds")
            if index >= 3 { samples.append(Double(elapsed) / 1_000_000) }
        }
        samples.sort()
        print(String(format: "REMOTE_ECHO_COMPLETE encrypted UDP Mac-to-server process echo: median %.2f ms, p90 %.2f ms (n=%d; 3 warmups; display excluded)",
                     samples[samples.count / 2], samples[Int(ceil(Double(samples.count) * 0.9)) - 1], samples.count))
    }
}

/// Credentials are accepted only through an owned regular 0600 file; decoding
/// failures deliberately discard the underlying diagnostic and its input.
private struct RemoteBenchmarkOffer: Decodable {
    let host: String
    let port: UInt16
    let secret: String
    let pane: String

    private enum Failure: Error { case invalidPrivateOffer }

    /// Decode only an owned private offer file, with no credential-bearing errors.
    static func load() throws -> Self {
        guard let path = ProcessInfo.processInfo.environment["KOI_REMOTE_BENCHMARK_FILE"] else {
            throw Failure.invalidPrivateOffer
        }
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.invalidPrivateOffer }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o777 == 0o600,
              info.st_size > 0, info.st_size <= 4096 else { throw Failure.invalidPrivateOffer }
        do {
            let offer = try JSONDecoder().decode(Self.self, from: handle.readToEnd() ?? Data())
            guard !offer.host.isEmpty, offer.port > 0, !offer.pane.isEmpty,
                  offer.secret.utf8.count == 64,
                  offer.secret.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw Failure.invalidPrivateOffer
            }
            return offer
        } catch { throw Failure.invalidPrivateOffer }
    }
}
