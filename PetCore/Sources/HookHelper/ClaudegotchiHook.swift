import Foundation
import PetCore

@main
struct ClaudegotchiHook {
    static func main() {
        var stdin: String? = nil
        let raw = FileHandle.standardInput.readDataToEndOfFile()
        if !raw.isEmpty { stdin = String(data: raw, encoding: .utf8) }
        exit(run(args: CommandLine.arguments, stdin: stdin))
    }

    static func run(args: [String], stdin: String?, spoolURL: URL = ClaudegotchiHook.spoolURL(),
                    cursorDir: URL = TranscriptTokens.defaultCursorDir()) -> Int32 {
        guard args.count >= 2 else { return 0 }
        let type = args[1]
        if rejectsRawType(type) { return 0 }

        var rawJSON = stdin
        if let i = args.firstIndex(of: "--json"), i + 1 < args.count {
            rawJSON = args[i + 1]
        }

        let extras = parsePayload(rawJSON)
        var tokensIn = extras["tokens_in"] as? Int
        var tokensOut = extras["tokens_out"] as? Int
        var model = extras["model"] as? String
        let prompt = type == "user_prompt_submit" ? promptTitle(from: extras["prompt"] as? String) : nil

        if tokensIn == nil, tokensOut == nil, type == "stop",
           let transcript = extras["transcript_path"] as? String,
           let sid = extras["session_id"] as? String,
           let delta = TranscriptTokens.delta(transcriptPath: transcript, sessionId: sid, cursorDir: cursorDir) {
            tokensIn = delta.tokensIn
            tokensOut = delta.tokensOut
            if model == nil { model = delta.model }
        }

        let event = Event(
            schemaVersion: 1,
            eventId: ULID.generate(),
            ts: Int64(Date().timeIntervalSince1970 * 1000),
            type: Event.EventType(rawValue: type) ?? .notification,
            sessionId: extras["session_id"] as? String,
            tool: extras["tool"] as? String,
            tokensIn: tokensIn,
            tokensOut: tokensOut,
            model: model,
            cwd: extras["cwd"] as? String,
            prompt: prompt
        )

        if let line = try? event.encodeJSON() {
            try? HookSpool.append(line, to: spoolURL)
        }
        return 0
    }

    static func parsePayload(_ raw: String?) -> [String: Any] {
        guard let raw, let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var out: [String: Any] = [:]
        if let v = obj["session_id"] { out["session_id"] = v }
        if let v = obj["cwd"] { out["cwd"] = v }
        if let v = obj["prompt"] { out["prompt"] = v }
        if let v = obj["transcript_path"] { out["transcript_path"] = v }
        if let v = obj["tool_name"] ?? obj["tool"] { out["tool"] = v }
        if let v = obj["model"] { out["model"] = v }
        if let tokens = obj["tokens"] as? [String: Any] {
            if let v = tokens["input"] { out["tokens_in"] = v }
            if let v = tokens["output"] { out["tokens_out"] = v }
        }
        if out["tokens_in"] == nil, let v = obj["tokens_in"] { out["tokens_in"] = v }
        if out["tokens_out"] == nil, let v = obj["tokens_out"] { out["tokens_out"] = v }
        return out
    }

    static func cwdFromPayload(_ raw: String?) -> String? {
        parsePayload(raw)["cwd"] as? String
    }

    static func rejectsRawType(_ type: String) -> Bool {
        type.hasPrefix("pr_") || type.hasPrefix("pet_")
    }

    static let promptTitleMaxChars = 120

    static func promptTitle(from raw: String?) -> String? {
        guard let raw else { return nil }
        let flattened = raw
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if flattened.isEmpty { return nil }
        return flattened.count <= promptTitleMaxChars
            ? flattened
            : String(flattened.prefix(promptTitleMaxChars))
    }

    static func spoolURL() -> URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("claudegotchi")
        return support.appendingPathComponent("spool.jsonl")
    }
}
