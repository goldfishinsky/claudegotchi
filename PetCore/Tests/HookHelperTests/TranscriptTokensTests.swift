import XCTest
@testable import HookHelper

final class TranscriptTokensTests: XCTestCase {
    // Real Claude Code 2.1.211 transcript shape: one API response is split into
    // several lines sharing a single message.id (thinking / tool_use / text);
    // usage is repeated on each. tokens_in = input + cache_creation.
    private let transcript = """
    {"type":"queue-operation"}
    {"type":"user","message":{"role":"user","content":"hi"}}
    {"type":"attachment"}
    {"type":"assistant","uuid":"u1","message":{"id":"msg_A","model":"claude-haiku-4-5-20251001","content":[{"type":"thinking"}],"usage":{"input_tokens":10,"cache_creation_input_tokens":9667,"cache_read_input_tokens":17370,"output_tokens":116}}}
    {"type":"assistant","uuid":"u2","message":{"id":"msg_A","model":"claude-haiku-4-5-20251001","content":[{"type":"tool_use"}],"usage":{"input_tokens":10,"cache_creation_input_tokens":9667,"cache_read_input_tokens":17370,"output_tokens":116}}}
    {"type":"user","message":{"role":"user","content":[{"type":"tool_result"}]}}
    {"type":"assistant","uuid":"u3","message":{"id":"msg_B","model":"claude-haiku-4-5-20251001","content":[{"type":"thinking"}],"usage":{"input_tokens":8,"cache_creation_input_tokens":191,"cache_read_input_tokens":27037,"output_tokens":38}}}
    {"type":"assistant","uuid":"u4","message":{"id":"msg_B","model":"claude-haiku-4-5-20251001","content":[{"type":"text"}],"usage":{"input_tokens":8,"cache_creation_input_tokens":191,"cache_read_input_tokens":27037,"output_tokens":38}}}
    """

    func testAssistantMessagesDedupedByMessageId() {
        let msgs = TranscriptTokens.assistantMessages(fromTranscript: transcript)
        XCTAssertEqual(msgs.map(\.id), ["msg_A", "msg_B"])
        XCTAssertEqual(msgs[0].tokensIn, 10 + 9667)
        XCTAssertEqual(msgs[0].tokensOut, 116)
        XCTAssertEqual(msgs[1].tokensIn, 8 + 191)
        XCTAssertEqual(msgs[1].tokensOut, 38)
        XCTAssertEqual(msgs[1].model, "claude-haiku-4-5-20251001")
    }

    func testFirstSightEmitsNothingAndResyncs() {
        let msgs = TranscriptTokens.assistantMessages(fromTranscript: transcript)
        let (delta, newId) = TranscriptTokens.newDelta(messages: msgs, afterLastId: nil)
        XCTAssertEqual(delta, TranscriptTokens.Delta(tokensIn: 0, tokensOut: 0, model: nil))
        XCTAssertEqual(newId, "msg_B", "cursor jumps to newest so pre-deploy backlog is skipped")
    }

    func testDeltaAfterCursorCountsOnlyNewMessages() {
        let msgs = TranscriptTokens.assistantMessages(fromTranscript: transcript)
        let (delta, newId) = TranscriptTokens.newDelta(messages: msgs, afterLastId: "msg_A")
        XCTAssertEqual(delta, TranscriptTokens.Delta(tokensIn: 199, tokensOut: 38, model: "claude-haiku-4-5-20251001"))
        XCTAssertEqual(newId, "msg_B")
    }

    func testUnknownCursorResyncsWithoutDoubleCount() {
        let msgs = TranscriptTokens.assistantMessages(fromTranscript: transcript)
        let (delta, newId) = TranscriptTokens.newDelta(messages: msgs, afterLastId: "msg_GONE")
        XCTAssertEqual(delta.tokensIn, 0, "a compacted/unknown cursor emits nothing")
        XCTAssertEqual(newId, "msg_B")
    }

    func testDeltaIOPersistsAndAdvancesCursor() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cursor-\(UUID())")
        let tp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("t-\(UUID()).jsonl")
        try transcript.write(to: tp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tp); try? FileManager.default.removeItem(at: dir) }

        let first = TranscriptTokens.delta(transcriptPath: tp.path, sessionId: "sess-1", cursorDir: dir)
        XCTAssertEqual(first, TranscriptTokens.Delta(tokensIn: 0, tokensOut: 0, model: nil))

        // Append a new turn; the second read must count only the new message.
        let appended = transcript + "\n" +
            #"{"type":"assistant","uuid":"u5","message":{"id":"msg_C","model":"claude-haiku-4-5-20251001","content":[{"type":"text"}],"usage":{"input_tokens":5,"cache_creation_input_tokens":45,"output_tokens":70}}}"#
        try appended.write(to: tp, atomically: true, encoding: .utf8)

        let second = TranscriptTokens.delta(transcriptPath: tp.path, sessionId: "sess-1", cursorDir: dir)
        XCTAssertEqual(second, TranscriptTokens.Delta(tokensIn: 50, tokensOut: 70, model: "claude-haiku-4-5-20251001"))
    }

    func testMissingTranscriptReturnsNil() {
        XCTAssertNil(TranscriptTokens.delta(transcriptPath: "/no/such/file.jsonl", sessionId: "x",
                                            cursorDir: URL(fileURLWithPath: NSTemporaryDirectory())))
    }
}
