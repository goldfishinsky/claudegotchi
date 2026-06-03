import Foundation

/// JSON contract between `claudegotchi-hook` and the app.
/// Forward-compatible: unknown JSON keys are ignored by JSONDecoder, and
/// `ApplyTransaction` stores the raw line in `event.payload` so future
/// fields are not lost.
public struct Event: Codable, Equatable {
    public let schemaVersion: Int
    public let eventId: String
    public let ts: Int64
    public let type: EventType
    public let sessionId: String?
    public let tool: String?
    public let tokensIn: Int?
    public let tokensOut: Int?
    public let model: String?
    public let cwd: String?

    public init(
        schemaVersion: Int, eventId: String, ts: Int64, type: EventType,
        sessionId: String?, tool: String?,
        tokensIn: Int?, tokensOut: Int?, model: String?,
        cwd: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.eventId = eventId
        self.ts = ts
        self.type = type
        self.sessionId = sessionId
        self.tool = tool
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.model = model
        self.cwd = cwd
    }

    public var tokensTotal: Int { (tokensIn ?? 0) + (tokensOut ?? 0) }

    public enum EventType: String, Codable {
        case sessionStart = "session_start"
        case preToolUse = "pre_tool_use"
        case postToolUse = "post_tool_use"
        case stop
        case notification
        case hibernateStart = "hibernate_start"
        case hibernateEnd = "hibernate_end"
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case eventId = "event_id"
        case ts, type
        case sessionId = "session_id"
        case tool
        case tokensIn = "tokens_in"
        case tokensOut = "tokens_out"
        case model
        case cwd
    }

    public static func parse(_ json: String) throws -> Event {
        guard let data = json.data(using: .utf8) else {
            throw EventError.invalidUTF8
        }
        return try JSONDecoder().decode(Event.self, from: data)
    }

    public func encodeJSON() throws -> String {
        let data = try JSONEncoder().encode(self)
        return String(data: data, encoding: .utf8) ?? ""
    }
}

public enum EventError: Error, Equatable {
    case invalidUTF8
}
