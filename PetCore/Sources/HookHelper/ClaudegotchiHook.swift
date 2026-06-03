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

    static func run(args: [String], stdin: String?, spoolURL: URL = ClaudegotchiHook.spoolURL()) -> Int32 {
        guard args.count >= 2 else { return 0 }
        let type = args[1]
        if rejectsRawType(type) { return 0 }

        var rawJSON = stdin
        if let i = args.firstIndex(of: "--json"), i + 1 < args.count {
            rawJSON = args[i + 1]
        }

        let extras = parsePayload(rawJSON)
        let event = Event(
            schemaVersion: 1,
            eventId: ULID.generate(),
            ts: Int64(Date().timeIntervalSince1970 * 1000),
            type: Event.EventType(rawValue: type) ?? .notification,
            sessionId: extras["session_id"] as? String,
            tool: extras["tool"] as? String,
            tokensIn: extras["tokens_in"] as? Int,
            tokensOut: extras["tokens_out"] as? Int,
            model: extras["model"] as? String,
            cwd: extras["cwd"] as? String
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
        if let v = obj["tool_name"] ?? obj["tool"] { out["tool"] = v }
        if let v = obj["model"] { out["model"] = v }
        if let v = obj["tokens_in"] { out["tokens_in"] = v }
        if let v = obj["tokens_out"] { out["tokens_out"] = v }
        return out
    }

    static func cwdFromPayload(_ raw: String?) -> String? {
        parsePayload(raw)["cwd"] as? String
    }

    static func rejectsRawType(_ type: String) -> Bool {
        type.hasPrefix("pr_") || type.hasPrefix("pet_")
    }

    static func spoolURL() -> URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("claudegotchi")
        return support.appendingPathComponent("spool.jsonl")
    }
}
