import Foundation
import Testing
@testable import Koi

/// Feed and transport fixtures are local; these tests never call URLSession.
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
