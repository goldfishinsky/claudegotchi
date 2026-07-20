import XCTest
@testable import PetCore

final class FakeTokenReader: ClaudeOAuthTokenReading, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [String?]
    private let fallback: String?
    private(set) var reads = 0

    init(constant: String?) { queue = []; fallback = constant }
    init(sequence: [String?]) { queue = sequence; fallback = nil }

    func accessToken() -> String? {
        lock.lock(); defer { lock.unlock() }
        reads += 1
        if !queue.isEmpty { return queue.removeFirst() }
        return fallback
    }
}

final class ClaudeTokenProviderTests: XCTestCase {
    func testServesCacheWithoutReadingUpstream() {
        let upstream = FakeTokenReader(constant: "up")
        let provider = CachedClaudeTokenProvider(upstream: upstream, cache: InMemoryClaudeTokenCache("cached"))
        XCTAssertEqual(provider.token(), "cached")
        XCTAssertEqual(upstream.reads, 0, "a warm cache must never touch the prompting item")
    }

    func testColdCacheReadsUpstreamOnceThenServesFromCache() {
        let upstream = FakeTokenReader(constant: "up")
        let cache = InMemoryClaudeTokenCache()
        let provider = CachedClaudeTokenProvider(upstream: upstream, cache: cache)

        XCTAssertEqual(provider.token(), "up")
        XCTAssertEqual(cache.read(), "up", "successful upstream read is copied into our own item")
        XCTAssertEqual(provider.token(), "up")
        XCTAssertEqual(upstream.reads, 1, "second read is served from the cache, no re-prompt")
    }

    func testNilUpstreamAndEmptyCacheYieldsNil() {
        let upstream = FakeTokenReader(constant: nil)
        let provider = CachedClaudeTokenProvider(upstream: upstream, cache: InMemoryClaudeTokenCache())
        XCTAssertNil(provider.token())
    }

    func testRefreshReReadsUpstreamAndUpdatesCache() {
        let upstream = FakeTokenReader(sequence: ["new"])
        let cache = InMemoryClaudeTokenCache("old")
        let provider = CachedClaudeTokenProvider(upstream: upstream, cache: cache)

        XCTAssertEqual(provider.token(), "old")
        XCTAssertEqual(upstream.reads, 0)
        XCTAssertEqual(provider.refreshedToken(), "new")
        XCTAssertEqual(upstream.reads, 1)
        XCTAssertEqual(cache.read(), "new")
    }

    func testInMemoryCacheRoundTrip() {
        let cache = InMemoryClaudeTokenCache()
        XCTAssertNil(cache.read())
        cache.write("tok")
        XCTAssertEqual(cache.read(), "tok")
    }
}
