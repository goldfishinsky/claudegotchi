import XCTest
@testable import PetCore

final class ClaudeUsageClientTests: XCTestCase {
    private func fixture() throws -> Data {
        let url = Bundle.module.url(forResource: "Fixtures/claude-usage", withExtension: "json")!
        return try Data(contentsOf: url)
    }

    func testParsesRealResponseShape() throws {
        let usage = ClaudeUsageClient.parse(try fixture())
        XCTAssertEqual(usage?.fiveHourPct, 42)
        XCTAssertEqual(usage?.weeklyPct, 63)
        XCTAssertNotNil(usage?.fiveHourResetsAt)
        XCTAssertNotNil(usage?.weeklyResetsAt)
    }

    func testFetchSendsAuthorizedRequestToAnthropicOnly() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueue(status: 200, body: try fixture())
        let client = ClaudeUsageClient(transport: transport, tokenReader: StaticClaudeTokenReader("tok-abc"))

        let usage = await client.fetch()
        XCTAssertEqual(usage?.fiveHourPct, 42)
        XCTAssertEqual(usage?.weeklyPct, 63)

        XCTAssertEqual(transport.calls.count, 1)
        let call = transport.calls[0]
        XCTAssertEqual(call.method, "GET")
        XCTAssertEqual(call.url?.host, "api.anthropic.com")
        XCTAssertEqual(call.url?.path, "/api/oauth/usage")
        XCTAssertEqual(call.headers["Authorization"], "Bearer tok-abc")
        XCTAssertEqual(call.headers["anthropic-beta"], "oauth-2025-04-20")
    }

    func testNilTokenSkipsNetworkAndReturnsNil() async {
        let transport = FakeHTTPTransport()
        let client = ClaudeUsageClient(transport: transport, tokenReader: StaticClaudeTokenReader(nil))
        let usage = await client.fetch()
        XCTAssertNil(usage)
        XCTAssertTrue(transport.calls.isEmpty, "no request may be sent without a token")
    }

    func testUnauthorizedReturnsNil() async {
        let transport = FakeHTTPTransport()
        transport.enqueue(status: 401, json: "{\"error\":\"unauthorized\"}")
        let client = ClaudeUsageClient(transport: transport, tokenReader: StaticClaudeTokenReader("tok"))
        let usage = await client.fetch()
        XCTAssertNil(usage)
    }

    func testMalformedBodyReturnsNil() async {
        let transport = FakeHTTPTransport()
        transport.enqueue(status: 200, json: "not json")
        let client = ClaudeUsageClient(transport: transport, tokenReader: StaticClaudeTokenReader("tok"))
        let usage = await client.fetch()
        XCTAssertNil(usage)
    }

    func testMissingBucketsReturnsNil() {
        let usage = ClaudeUsageClient.parse(Data("{\"five_hour\":{\"utilization\":10.0}}".utf8))
        XCTAssertNil(usage, "both buckets required")
    }

    func testTransportFailureReturnsNil() async {
        let transport = FakeHTTPTransport()
        transport.failNext(HTTPTransportError.nonHTTPResponse)
        let client = ClaudeUsageClient(transport: transport, tokenReader: StaticClaudeTokenReader("tok"))
        let usage = await client.fetch()
        XCTAssertNil(usage)
    }
}
