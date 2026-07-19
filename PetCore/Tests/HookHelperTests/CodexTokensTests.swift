import XCTest
@testable import HookHelper

final class CodexTokensTests: XCTestCase {
    // Real Codex rollout shape: token_count is wrapped in an event_msg payload;
    // last_token_usage is the precomputed per-turn delta.
    func testReadsLastTokenUsageFromEventMsgWrappedLine() {
        let rollout = [
            #"{"timestamp":"t","type":"session_meta","payload":{"id":"x"}}"#,
            #"{"timestamp":"t","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":50,"total_tokens":150},"last_token_usage":{"input_tokens":40,"cached_input_tokens":10,"output_tokens":9,"total_tokens":49}}}}"#,
        ].joined(separator: "\n")
        XCTAssertEqual(CodexTokens.delta(fromRollout: rollout), CodexTokens.Delta(tokensIn: 40, tokensOut: 9))
    }

    func testUsesLastTokenCountLineWhenMultiple() {
        let rollout = [
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"output_tokens":5}}}}"#,
            #"{"type":"response_item","payload":{}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":77,"output_tokens":33}}}}"#,
        ].joined(separator: "\n")
        XCTAssertEqual(CodexTokens.delta(fromRollout: rollout), CodexTokens.Delta(tokensIn: 77, tokensOut: 33))
    }

    func testBareTokenCountShapeSupported() {
        let rollout = #"{"type":"token_count","info":{"last_token_usage":{"input_tokens":8,"output_tokens":3}}}"#
        XCTAssertEqual(CodexTokens.delta(fromRollout: rollout), CodexTokens.Delta(tokensIn: 8, tokensOut: 3))
    }

    func testNoTokenCountLineReturnsNil() {
        XCTAssertNil(CodexTokens.delta(fromRollout: #"{"type":"response_item","payload":{"foo":1}}"#))
    }

    func testMissingFileReturnsNil() {
        XCTAssertNil(CodexTokens.delta(rolloutPath: "/no/such/rollout.jsonl"))
    }
}
