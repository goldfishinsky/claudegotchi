import Foundation
import PetCore

@main
struct ClaudegotchiHook {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            FileHandle.standardError.write(Data("usage: claudegotchi-hook <type> [--json '<json>']\n".utf8))
            exit(2)
        }
        let type = args[1]
        if rejectsRawType(type) {
            FileHandle.standardError.write(Data("claudegotchi-hook: type '\(type)' is app-internal\n".utf8))
            exit(2)
        }
        var rawJSON: String? = nil
        if let i = args.firstIndex(of: "--json"), i + 1 < args.count {
            rawJSON = args[i + 1]
        }

        let extras = parseExtras(rawJSON)
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

        do {
            let line = try event.encodeJSON()
            try HookSpool.append(line, to: spoolURL())
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("claudegotchi-hook: \(error)\n".utf8))
            exit(1)
        }
    }

    static func parseExtras(_ raw: String?) -> [String: Any] {
        guard let raw, let data = raw.data(using: .utf8) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    static func cwdFromPayload(_ raw: String?) -> String? {
        parseExtras(raw)["cwd"] as? String
    }

    static func rejectsRawType(_ type: String) -> Bool {
        type.hasPrefix("pr_")
    }

    private static func spoolURL() -> URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("claudegotchi")
        return support.appendingPathComponent("spool.jsonl")
    }
}
