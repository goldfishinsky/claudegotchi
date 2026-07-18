import Foundation

/// Current Claude Code exposes neither token counts nor the model on hook
/// stdin — they live in the session transcript, split across lines that share
/// one `message.id`. This derives the per-Stop token delta from that transcript.
enum TranscriptTokens {
    struct Delta: Equatable {
        let tokensIn: Int
        let tokensOut: Int
        let model: String?
    }

    struct AssistantMessage: Equatable {
        let id: String
        let model: String?
        let tokensIn: Int
        let tokensOut: Int
    }

    static func assistantMessages(fromTranscript text: String) -> [AssistantMessage] {
        var seen = Set<String>()
        var out: [AssistantMessage] = []
        text.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["type"] as? String) == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let id = msg["id"] as? String,
                  seen.insert(id).inserted
            else { return }
            let usage = msg["usage"] as? [String: Any]
            let input = (usage?["input_tokens"] as? Int ?? 0)
                + (usage?["cache_creation_input_tokens"] as? Int ?? 0)
            let output = usage?["output_tokens"] as? Int ?? 0
            out.append(AssistantMessage(id: id, model: msg["model"] as? String,
                                        tokensIn: input, tokensOut: output))
        }
        return out
    }

    /// A nil or unknown `lastId` (first sight of a session, or a compacted
    /// transcript) resyncs the cursor to the newest message and emits nothing,
    /// so pre-deploy backlog never lands in one turn.
    static func newDelta(messages: [AssistantMessage], afterLastId lastId: String?)
        -> (delta: Delta, newLastId: String?) {
        guard let newestId = messages.last?.id else {
            return (Delta(tokensIn: 0, tokensOut: 0, model: nil), lastId)
        }
        let fresh: ArraySlice<AssistantMessage>
        if let lastId, let idx = messages.firstIndex(where: { $0.id == lastId }) {
            fresh = messages[(idx + 1)...]
        } else {
            fresh = messages[messages.endIndex...]
        }
        let tin = fresh.reduce(0) { $0 + $1.tokensIn }
        let tout = fresh.reduce(0) { $0 + $1.tokensOut }
        return (Delta(tokensIn: tin, tokensOut: tout, model: fresh.last?.model), newestId)
    }

    static func delta(transcriptPath: String, sessionId: String,
                      cursorDir: URL = defaultCursorDir()) -> Delta? {
        guard let text = try? String(contentsOfFile: transcriptPath, encoding: .utf8) else { return nil }
        let messages = assistantMessages(fromTranscript: text)
        let cursorURL = cursorDir.appendingPathComponent(cursorName(for: sessionId))
        let stored = (try? String(contentsOf: cursorURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = (stored?.isEmpty == false) ? stored : nil
        let (delta, newLastId) = newDelta(messages: messages, afterLastId: previous)
        if let newLastId {
            try? FileManager.default.createDirectory(at: cursorDir, withIntermediateDirectories: true)
            try? newLastId.write(to: cursorURL, atomically: true, encoding: .utf8)
        }
        return delta
    }

    static func defaultCursorDir() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("claudegotchi/token-cursor")
    }

    private static func cursorName(for sessionId: String) -> String {
        String(sessionId.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? Character($0) : "_"
        })
    }
}
