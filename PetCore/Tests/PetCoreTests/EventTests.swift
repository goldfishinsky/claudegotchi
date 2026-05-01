import XCTest
@testable import PetCore

final class EventTests: XCTestCase {
    func testRoundTrip() throws {
        let json = #"""
        {"schema_version":1,"event_id":"01HK6Y0000000000000000000A","ts":1714500000123,"type":"post_tool_use","session_id":"abc","tool":"Bash","tokens_in":100,"tokens_out":200,"model":"claude-opus-4-7"}
        """#
        let e = try Event.parse(json)
        XCTAssertEqual(e.schemaVersion, 1)
        XCTAssertEqual(e.eventId, "01HK6Y0000000000000000000A")
        XCTAssertEqual(e.ts, 1_714_500_000_123)
        XCTAssertEqual(e.type, .postToolUse)
        XCTAssertEqual(e.sessionId, "abc")
        XCTAssertEqual(e.tool, "Bash")
        XCTAssertEqual(e.tokensIn, 100)
        XCTAssertEqual(e.tokensOut, 200)
        XCTAssertEqual(e.model, "claude-opus-4-7")
    }

    func testTokensTotalSumsBothFields() throws {
        let json = #"""
        {"schema_version":1,"event_id":"a","ts":0,"type":"post_tool_use","tokens_in":300,"tokens_out":700}
        """#
        let e = try Event.parse(json)
        XCTAssertEqual(e.tokensTotal, 1000)
    }

    func testTokensTotalDefaultsToZero() throws {
        let json = #"""
        {"schema_version":1,"event_id":"a","ts":0,"type":"session_start"}
        """#
        let e = try Event.parse(json)
        XCTAssertEqual(e.tokensTotal, 0)
    }

    func testRejectsUnknownType() {
        let json = #"""
        {"schema_version":1,"event_id":"a","ts":0,"type":"who_knows"}
        """#
        XCTAssertThrowsError(try Event.parse(json))
    }

    func testRejectsMissingRequiredField() {
        let json = #"""
        {"schema_version":1,"event_id":"a","type":"session_start"}
        """#
        XCTAssertThrowsError(try Event.parse(json))
    }

    func testForwardCompatibleExtraFields() throws {
        let json = #"""
        {"schema_version":1,"event_id":"a","ts":0,"type":"session_start","future_field":42}
        """#
        let e = try Event.parse(json)
        XCTAssertEqual(e.eventId, "a")
    }
}
