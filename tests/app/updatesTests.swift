import Foundation
import Testing
@testable import Koi

/// Feed fixtures use injected callbacks or URLProtocol; no external requests are made.
@Suite @MainActor struct UpdatesTests {
    @Test func versionComparisonUsesNumericAndPrereleasePrecedence() throws {
        let ordered = ["1.0.0-alpha", "1.0.0-alpha.2", "1.0.0-alpha.10", "1.0.0-beta", "1.0.0", "1.9", "v1.10.0", "2"]
        let versions = try ordered.map { try #require(ReleaseVersion($0)) }
        for (left, right) in zip(versions, versions.dropFirst()) { #expect(left < right) }
        #expect(ReleaseVersion("v1.2+build.1") == ReleaseVersion("1.2.0+other"))
        for invalid in ["", "latest", "1..2", "1.0-", "1.0-01", "1.0+", "1.2.3.4", "01.2"] {
            #expect(ReleaseVersion(invalid) == nil)
        }
    }

    @Test func githubFeedSelectsHighestPublishedStableVersion() throws {
        let data = Data("""
        [
          {"tag_name":"v1.9.0","html_url":"https://example.test/releases/1.9"},
          {"tag_name":"v1.10.0","html_url":"https://example.test/releases/1.10"},
          {"tag_name":"v8.0.0","html_url":"https://example.test/draft","draft":true},
          {"tag_name":"v9.0.0-beta","html_url":"https://example.test/beta"},
          {"tag_name":"v7.0.0","html_url":"file:///tmp/unsafe"}
        ]
        """.utf8)
        #expect(try UpdateChecker.latestRelease(in: data).version == "v1.10.0")
    }

    @Test func githubAtomFeedUsesTagLinksAndNumericVersions() throws {
        let data = Data("""
        <?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom">
          <entry><title>Do not parse release titles</title><link rel="alternate" href="https://github.com/fixture/app/releases/tag/v1.10.0"/></entry>
          <entry><link href="https://github.com/fixture/app/releases/tag/v2.0.0-beta"/></entry>
        </feed>
        """.utf8)
        #expect(try UpdateChecker.latestRelease(in: data).version == "v1.10.0")
    }

    @Test func manualCheckAndOpenUseOnlyInjectedCallbacks() async throws {
        var requests: [URLRequest] = []
        var opened: URL?
        let source = try #require(URL(string: "https://github.com/fixture/app/releases"))
        let checker = UpdateChecker(currentVersion: "1.9", sourceURL: source, fetch: { request in
            requests.append(request)
            let response = try #require(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(#"{"version":"1.10","url":"https://example.test/release"}"#.utf8), response)
        })
        #expect(requests.isEmpty)
        await checker.checkFromUserAction()
        #expect(requests.count == 1)
        #expect(requests.first?.url?.host == "api.github.com")
        #expect(requests.first?.url?.path == "/repos/fixture/app/releases")
        guard case .available(let release) = checker.state else { Issue.record("Expected available update"); return }
        #expect(release.version == "1.10")
        checker.openReleaseFromUserAction { opened = $0 }
        #expect(opened == release.pageURL)
        checker.sourceURL = nil
        #expect(checker.state == .notConfigured)
        checker.openReleaseFromUserAction { _ in Issue.record("No release should open after source removal") }
        await checker.checkFromUserAction()
        #expect(requests.count == 1)
    }

    @Test func failureAndOlderVersionsDoNotOfferAnUpdate() async throws {
        let source = try #require(URL(string: "https://example.test/feed"))
        let failure = UpdateChecker(currentVersion: "1", sourceURL: source, fetch: { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        })
        await failure.checkFromUserAction()
        guard case .failed(let message) = failure.state else { Issue.record("Expected HTTP failure"); return }
        #expect(message.contains("503"))
        let older = UpdateChecker(currentVersion: "2", sourceURL: source, fetch: { request in
            (Data(#"{"version":"1.9","url":"https://example.test/release"}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        await older.checkFromUserAction()
        #expect(older.state == .upToDate)
    }

    @Test func credentialsAndNonHTTPSURLsAreRejectedBeforeFetching() throws {
        for value in ["http://example.test/feed", "https://user:password@example.test/feed", "file:///tmp/feed"] {
            let url = try #require(URL(string: value))
            #expect(throws: (any Error).self) { try UpdateChecker.requestURL(for: url) }
        }
        #expect(throws: (any Error).self) { try UpdateChecker.latestRelease(in: Data("not a feed".utf8)) }
    }

    @Test func changingTheSourceDiscardsAnInFlightResponse() async throws {
        var checker: UpdateChecker?
        let source = try #require(URL(string: "https://example.test/old-feed"))
        let replacement = try #require(URL(string: "https://example.test/new-feed"))
        let updates = UpdateChecker(currentVersion: "1", sourceURL: source, fetch: { request in
            checker?.sourceURL = replacement
            return (Data(#"{"version":"2","url":"https://example.test/release"}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        checker = updates
        await updates.checkFromUserAction()
        #expect(updates.sourceURL == replacement)
        #expect(updates.state == .idle)
        #expect(updates.lastChecked == nil)
    }
}

/// A paced, unknown-length response fixture. Overflow leaves the response open so
/// stopLoading proves the downloader cancelled rather than waiting for completion.
private final class ReleaseFeedProtocol: URLProtocol, @unchecked Sendable {
    private let queue = DispatchQueue(label: "koi.tests.release-feed")
    private let stopLock = NSLock()
    private var stopped = false
    private var delivered = 0

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "feed.fixture.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        queue.async { [self] in
            let declared = request.url?.path == "/declared"
            let headers = declared ? ["Content-Length": String(ReleaseFeedDownload.limit + 1),
                                      "Content-Type": "application/json"] : ["Content-Type": "application/json"]
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if declared {
                // Supply an initial chunk so URLSession finishes response sniffing;
                // leave the oversized body unfinished to require cancellation.
                client?.urlProtocol(self, didLoad: Data(repeating: 32, count: 1024))
                return
            }
            if request.url?.path == "/hang" { return }
            if request.url?.path == "/valid" {
                client?.urlProtocol(self, didLoad: Data(#"{"version":"2","url":"https://example.test/release"}"#.utf8))
                client?.urlProtocolDidFinishLoading(self)
            } else { sendChunk() }
        }
    }

    /// Stop scheduled delivery without synchronously reentering the callback queue.
    override func stopLoading() {
        stopLock.withLock { stopped = true }
    }

    /// Deliver exactly the cap, then one excess byte, without finishing overflow feeds.
    private func sendChunk() {
        guard !stopLock.withLock({ stopped }) else { return }
        let exact = request.url?.path == "/exact"
        if delivered < ReleaseFeedDownload.limit {
            let count = min(64 * 1024, ReleaseFeedDownload.limit - delivered)
            client?.urlProtocol(self, didLoad: Data(repeating: 32, count: count))
            delivered += count
        } else if exact {
            client?.urlProtocolDidFinishLoading(self)
            return
        } else {
            client?.urlProtocol(self, didLoad: Data([32]))
            return
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(1)) { [self] in sendChunk() }
    }
}

/// Real URLSession delivery is intercepted entirely by the fixture protocol.
extension UpdatesTests {
    private func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReleaseFeedProtocol.self]
        return configuration
    }

    @Test func streamedFeedReachesUpdateChecker() async {
        let configuration = configuration()
        let checker = UpdateChecker(currentVersion: "1", sourceURL: URL(string: "https://feed.fixture.test/valid"), fetch: {
            try await ReleaseFeedDownload.fetch($0, configuration: configuration)
        })
        await checker.checkFromUserAction()
        guard case .available(let release) = checker.state else {
            Issue.record("Expected streamed release")
            return
        }
        #expect(release.version == "2")
    }

    @Test func acceptsExactlyTwoMiB() async throws {
        let request = URLRequest(url: URL(string: "https://feed.fixture.test/exact")!)
        let (data, _) = try await ReleaseFeedDownload.fetch(request, configuration: configuration())
        #expect(data.count == ReleaseFeedDownload.limit)
    }

    @Test(arguments: ["overflow", "declared"])
    func cancelsOversizedResponseWithoutWaitingForEOF(_ path: String) async {
        let request = URLRequest(url: URL(string: "https://feed.fixture.test/" + path)!)
        let start = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await ReleaseFeedDownload.fetch(request, configuration: configuration())
            Issue.record("Expected feed limit failure")
        } catch {
            if case UpdateChecker.Failure.invalidFeed = error { } else { Issue.record("Expected feed limit failure") }
        }
        #expect(ProcessInfo.processInfo.systemUptime - start < 3)
    }

    @Test func taskCancellationStopsAnUnfinishedResponse() async throws {
        let configuration = configuration()
        let task = Task {
            try await ReleaseFeedDownload.fetch(URLRequest(url: URL(string: "https://feed.fixture.test/hang")!),
                                                configuration: configuration)
        }
        try await Task.sleep(for: .milliseconds(50))
        let start = ProcessInfo.processInfo.systemUptime
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch {
            #expect((error as? URLError)?.code == .cancelled)
        }
        #expect(ProcessInfo.processInfo.systemUptime - start < 3)
    }

}
