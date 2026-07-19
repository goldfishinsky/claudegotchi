import Foundation

/// Codex rollout files precompute a per-turn token delta in each
/// `token_count` line's `last_token_usage`, so the Stop hook reads the newest
/// such line directly — no cursor bookkeeping like Claude's `TranscriptTokens`.
/// The `token_count` object is either bare (`{"type":"token_count","info":…}`)
/// or wrapped in an `event_msg` payload (`{"type":"event_msg","payload":{"type":"token_count","info":…}}`).
enum CodexTokens {
    struct Delta: Equatable {
        let tokensIn: Int
        let tokensOut: Int
    }

    static func delta(rolloutPath: String) -> Delta? {
        guard let text = try? String(contentsOfFile: rolloutPath, encoding: .utf8) else { return nil }
        return delta(fromRollout: text)
    }

    static func delta(fromRollout text: String) -> Delta? {
        var latest: Delta?
        text.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let last = lastTokenUsage(in: obj)
            else { return }
            latest = Delta(
                tokensIn: intValue(last["input_tokens"]),
                tokensOut: intValue(last["output_tokens"])
            )
        }
        return latest
    }

    private static func lastTokenUsage(in obj: [String: Any]) -> [String: Any]? {
        let info: [String: Any]?
        if (obj["type"] as? String) == "token_count" {
            info = obj["info"] as? [String: Any]
        } else if let payload = obj["payload"] as? [String: Any],
                  (payload["type"] as? String) == "token_count" {
            info = payload["info"] as? [String: Any]
        } else {
            info = nil
        }
        return info?["last_token_usage"] as? [String: Any]
    }

    private static func intValue(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        return 0
    }
}
