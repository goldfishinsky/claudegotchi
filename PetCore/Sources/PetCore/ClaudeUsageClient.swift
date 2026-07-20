import Foundation
import Security
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ClaudeUsage: Equatable, Sendable {
    public let fiveHourPct: Double
    public let weeklyPct: Double
    public let fiveHourResetsAt: Date?
    public let weeklyResetsAt: Date?

    public init(fiveHourPct: Double, weeklyPct: Double,
                fiveHourResetsAt: Date? = nil, weeklyResetsAt: Date? = nil) {
        self.fiveHourPct = fiveHourPct
        self.weeklyPct = weeklyPct
        self.fiveHourResetsAt = fiveHourResetsAt
        self.weeklyResetsAt = weeklyResetsAt
    }
}

public protocol ClaudeOAuthTokenReading: Sendable {
    func accessToken() -> String?
}

/// Read-only reader for Claude Code's OAuth access token. Never writes or
/// deletes the item. A cross-app read triggers the standard one-time macOS
/// keychain consent; "Always Allow" makes it silent thereafter, and any other
/// outcome yields nil so the caller simply hides the usage UI.
public final class KeychainClaudeTokenReader: ClaudeOAuthTokenReading {
    private let service = "Claude Code-credentials"

    public init() {}

    public func accessToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty
        else { return nil }
        return token
    }
}

public struct StaticClaudeTokenReader: ClaudeOAuthTokenReading {
    private let token: String?
    public init(_ token: String?) { self.token = token }
    public func accessToken() -> String? { token }
}

/// Fetches the signed-in user's subscription usage from Anthropic's OAuth usage
/// endpoint. Every path degrades to nil (missing token, non-2xx, bad shape) so
/// the caller can simply hide the UI when usage is unavailable.
public final class ClaudeUsageClient: @unchecked Sendable {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let beta = "oauth-2025-04-20"
    private static let timeout: TimeInterval = 12

    private let transport: HTTPTransport
    private let provider: ClaudeTokenProviding

    public init(transport: HTTPTransport = URLSessionTransport(),
                provider: ClaudeTokenProviding = CachedClaudeTokenProvider()) {
        self.transport = transport
        self.provider = provider
    }

    public convenience init(transport: HTTPTransport, tokenReader: ClaudeOAuthTokenReading) {
        self.init(transport: transport,
                  provider: CachedClaudeTokenProvider(upstream: tokenReader, cache: InMemoryClaudeTokenCache()))
    }

    private enum Attempt {
        case success(ClaudeUsage)
        case unauthorized
        case failed
    }

    public func fetch() async -> ClaudeUsage? {
        guard let token = provider.token() else { return nil }
        switch await attempt(token) {
        case .success(let usage): return usage
        case .failed: return nil
        case .unauthorized:
            guard let fresh = provider.refreshedToken(), fresh != token else { return nil }
            if case .success(let usage) = await attempt(fresh) { return usage }
            return nil
        }
    }

    private func attempt(_ token: String) async -> Attempt {
        var req = URLRequest(url: Self.usageURL)
        req.httpMethod = "GET"
        req.timeoutInterval = Self.timeout
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(Self.beta, forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await transport.send(req) else { return .failed }
        if response.statusCode == 401 || response.statusCode == 403 { return .unauthorized }
        guard (200..<300).contains(response.statusCode) else { return .failed }
        if let usage = Self.parse(data) { return .success(usage) }
        return .failed
    }

    static func parse(_ data: Data) -> ClaudeUsage? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let five = utilization(obj["five_hour"]),
              let week = utilization(obj["seven_day"])
        else { return nil }
        return ClaudeUsage(
            fiveHourPct: five, weeklyPct: week,
            fiveHourResetsAt: resetsAt(obj["five_hour"]),
            weeklyResetsAt: resetsAt(obj["seven_day"])
        )
    }

    private static func utilization(_ bucket: Any?) -> Double? {
        guard let dict = bucket as? [String: Any] else { return nil }
        if let n = dict["utilization"] as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func resetsAt(_ bucket: Any?) -> Date? {
        guard let dict = bucket as? [String: Any], let s = dict["resets_at"] as? String else { return nil }
        if let d = isoFractional.date(from: s) { return d }
        return isoPlain.date(from: s)
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
