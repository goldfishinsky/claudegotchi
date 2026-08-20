import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct DeviceCodeStart: Decodable, Equatable, Sendable {
    public let deviceCode: String
    public let userCode: String
    public let verificationUri: String
    public let expiresIn: Int
    public let interval: Int
}

public enum DevicePollResult: Equatable, Sendable {
    case pending
    case authorized(githubToken: String)
    case failed(String)
}

public struct WebAuthStart: Codable, Equatable, Sendable {
    public let authorizationUrl: String
    public init(authorizationUrl: String) { self.authorizationUrl = authorizationUrl }
}

public struct AuthUser: Decodable, Equatable, Sendable {
    public let id: Int64
    public let login: String
    public let avatarUrl: String?
}

public struct AuthResponse: Decodable, Equatable, Sendable {
    public let token: String
    public let user: AuthUser
}

public struct SyncPayload: Codable, Equatable, Sendable {
    public struct Totals: Codable, Equatable, Sendable {
        public let tokensIn: Int64
        public let tokensOut: Int64
        public let sessions: Int64
        public let toolsUsed: Int64
        public init(tokensIn: Int64, tokensOut: Int64, sessions: Int64, toolsUsed: Int64) {
            self.tokensIn = tokensIn; self.tokensOut = tokensOut
            self.sessions = sessions; self.toolsUsed = toolsUsed
        }
    }

    public struct PetSnapshot: Codable, Equatable, Sendable {
        public let uid: String
        public let species: String
        public let name: String?
        public let birthdayMs: Int64
        public let xp: Int64
        public init(uid: String, species: String, name: String?, birthdayMs: Int64, xp: Int64) {
            self.uid = uid; self.species = species; self.name = name
            self.birthdayMs = birthdayMs; self.xp = xp
        }
    }

    public struct Best: Codable, Equatable, Sendable {
        public let survivalMs: Int64
        public let species: String
        public let name: String?
        public init(survivalMs: Int64, species: String, name: String?) {
            self.survivalMs = survivalMs; self.species = species; self.name = name
        }
    }

    public struct ModelCounts: Codable, Equatable, Sendable {
        public let `in`: Int64
        public let out: Int64
        public let calls: Int64
        public init(in tokensIn: Int64, out: Int64, calls: Int64) {
            self.in = tokensIn; self.out = out; self.calls = calls
        }
    }

    public struct PlatformCounts: Codable, Equatable, Sendable {
        public let tokensIn: Int64
        public let tokensOut: Int64
        public let models: [String: ModelCounts]

        public init(tokensIn: Int64, tokensOut: Int64, models: [String: ModelCounts]) {
            self.tokensIn = tokensIn
            self.tokensOut = tokensOut
            self.models = models
        }
    }

    /// Legacy dominant-platform field, kept so older servers can still accept a sync.
    public let platform: String
    public let totals: Totals
    public let pet: PetSnapshot?
    public let best: Best?
    /// Legacy flat model map. New servers use `platforms` as the source of truth.
    public let models: [String: ModelCounts]
    public let platforms: [String: PlatformCounts]

    public init(
        platform: String, totals: Totals, pet: PetSnapshot?, best: Best?,
        models: [String: ModelCounts], platforms: [String: PlatformCounts] = [:]
    ) {
        self.platform = platform; self.totals = totals
        self.pet = pet; self.best = best; self.models = models; self.platforms = platforms
    }
}

public struct SyncResponse: Decodable, Equatable, Sendable {
    public let ok: Bool
    public let clamped: Bool
    public let nextSyncAfterMs: Int64
}

public struct LeaderboardRow: Decodable, Equatable, Sendable {
    public struct PetRef: Decodable, Equatable, Sendable {
        public let species: String
        public let name: String?
    }
    public let rank: Int
    public let login: String
    public let avatarUrl: String?
    public let pet: PetRef?
    public let value: Int64?
    public let valueMs: Int64?
}

public struct LeaderboardPage: Decodable, Equatable, Sendable {
    public let board: String
    public let platform: String
    public let page: Int
    public let rows: [LeaderboardRow]
}

public struct GlobalModelStat: Decodable, Equatable, Sendable {
    public let platform: String?
    public let model: String
    public let tokensIn: Int64
    public let tokensOut: Int64
    public let calls: Int64
    public let users: Int?
}

public struct GlobalModelStats: Decodable, Equatable, Sendable {
    public let platform: String?
    public let models: [GlobalModelStat]
}

public struct RankEntry: Decodable, Equatable, Sendable {
    public let rank: Int
    public let total: Int
}

public struct MyRanks: Decodable, Equatable, Sendable {
    public let tokens: RankEntry?
    public let survivalCurrent: RankEntry?
    public let survivalBest: RankEntry?
}

public struct MeResponse: Decodable, Equatable, Sendable {
    public let login: String?
    public let avatarUrl: String?
    public let ranks: MyRanks
}

public enum LeaderboardError: Error, Equatable {
    case transport
    case http(status: Int)
    case unauthorized
    case rateLimited(retryAfterMs: Int64?)
    case decode
}

public protocol LeaderboardService: Sendable {
    func startWebAuth(codeChallenge: String) async throws -> WebAuthStart
    func exchangeWebAuth(grant: String, codeVerifier: String) async throws -> AuthResponse
    func startDeviceFlow() async throws -> DeviceCodeStart
    func pollDeviceFlow(deviceCode: String) async throws -> DevicePollResult
    func authenticate(githubToken: String) async throws -> AuthResponse
    func sync(_ payload: SyncPayload, token: String) async throws -> SyncResponse
    func leaderboard(board: String, platform: String?, page: Int) async throws -> LeaderboardPage
    func modelStats(platform: String?) async throws -> GlobalModelStats
    func me(token: String) async throws -> MeResponse
    func deleteAccount(token: String) async throws
}

public final class HTTPLeaderboardClient: LeaderboardService, @unchecked Sendable {
    private static let deviceCodeURL = URL(string: "https://github.com/login/device/code")!
    private static let accessTokenURL = URL(string: "https://github.com/login/oauth/access_token")!
    private static let deviceGrantType = "urn:ietf:params:oauth:grant-type:device_code"
    private static let timeout: TimeInterval = 15

    private let transport: HTTPTransport
    private let baseURL: URL
    private let githubClientID: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(transport: HTTPTransport, baseURL: URL, githubClientID: String) {
        self.transport = transport
        self.baseURL = baseURL
        self.githubClientID = githubClientID
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        encoder = enc
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        decoder = dec
    }

    public func startWebAuth(codeChallenge: String) async throws -> WebAuthStart {
        let body = try encoder.encode(["code_challenge": codeChallenge])
        let req = request(path: "/v1/auth/github/web/start", method: "POST", token: nil, jsonBody: body)
        let (data, response) = try await perform(req)
        return try decodeResponse(WebAuthStart.self, from: data, response: response)
    }

    public func exchangeWebAuth(grant: String, codeVerifier: String) async throws -> AuthResponse {
        let body = try encoder.encode(["grant": grant, "code_verifier": codeVerifier])
        let req = request(path: "/v1/auth/github/web/exchange", method: "POST", token: nil, jsonBody: body)
        let (data, response) = try await perform(req)
        return try decodeResponse(AuthResponse.self, from: data, response: response)
    }

    public func startDeviceFlow() async throws -> DeviceCodeStart {
        var req = URLRequest(url: Self.deviceCodeURL)
        req.httpMethod = "POST"
        req.timeoutInterval = Self.timeout
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formEncode(["client_id": githubClientID, "scope": ""])
        let (data, response) = try await perform(req)
        return try decodeResponse(DeviceCodeStart.self, from: data, response: response)
    }

    public func pollDeviceFlow(deviceCode: String) async throws -> DevicePollResult {
        var req = URLRequest(url: Self.accessTokenURL)
        req.httpMethod = "POST"
        req.timeoutInterval = Self.timeout
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formEncode([
            "client_id": githubClientID,
            "device_code": deviceCode,
            "grant_type": Self.deviceGrantType,
        ])
        let (data, _) = try await perform(req)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LeaderboardError.decode
        }
        if let token = obj["access_token"] as? String, !token.isEmpty {
            return .authorized(githubToken: token)
        }
        if let error = obj["error"] as? String {
            switch error {
            case "authorization_pending", "slow_down": return .pending
            default: return .failed(error)
            }
        }
        throw LeaderboardError.decode
    }

    public func authenticate(githubToken: String) async throws -> AuthResponse {
        let body = try encoder.encode(AuthRequest(githubToken: githubToken))
        let req = request(path: "/v1/auth/github", method: "POST", token: nil, jsonBody: body)
        let (data, response) = try await perform(req)
        return try decodeResponse(AuthResponse.self, from: data, response: response)
    }

    public func sync(_ payload: SyncPayload, token: String) async throws -> SyncResponse {
        let body = try encoder.encode(payload)
        let req = request(path: "/v1/sync", method: "POST", token: token, jsonBody: body)
        let (data, response) = try await perform(req)
        return try decodeResponse(SyncResponse.self, from: data, response: response)
    }

    public func leaderboard(board: String, platform: String?, page: Int) async throws -> LeaderboardPage {
        var query = [URLQueryItem(name: "board", value: board), URLQueryItem(name: "page", value: String(page))]
        if let platform { query.append(URLQueryItem(name: "platform", value: platform)) }
        let req = request(path: "/v1/leaderboard", method: "GET", query: query, token: nil)
        let (data, response) = try await perform(req)
        return try decodeResponse(LeaderboardPage.self, from: data, response: response)
    }

    public func modelStats(platform: String?) async throws -> GlobalModelStats {
        var query: [URLQueryItem] = []
        if let platform { query.append(URLQueryItem(name: "platform", value: platform)) }
        let req = request(path: "/v1/stats/models", method: "GET", query: query, token: nil)
        let (data, response) = try await perform(req)
        return try decodeResponse(GlobalModelStats.self, from: data, response: response)
    }

    public func me(token: String) async throws -> MeResponse {
        let req = request(path: "/v1/me", method: "GET", token: token)
        let (data, response) = try await perform(req)
        return try decodeResponse(MeResponse.self, from: data, response: response)
    }

    public func deleteAccount(token: String) async throws {
        let req = request(path: "/v1/me", method: "DELETE", token: token)
        let (data, response) = try await perform(req)
        try checkStatus(data: data, response: response)
    }

    private struct AuthRequest: Encodable {
        let githubToken: String
    }

    private func request(path: String, method: String, query: [URLQueryItem] = [],
                         token: String?, jsonBody: Data? = nil) -> URLRequest {
        var req = URLRequest(url: url(path: path, query: query))
        req.httpMethod = method
        req.timeoutInterval = Self.timeout
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = jsonBody
        }
        if let token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private func url(path: String, query: [URLQueryItem]) -> URL {
        var base = baseURL.absoluteString
        if base.hasSuffix("/") { base.removeLast() }
        var comps = URLComponents(string: base + path)!
        if !query.isEmpty { comps.queryItems = query }
        return comps.url!
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch {
            throw LeaderboardError.transport
        }
    }

    private func decodeResponse<T: Decodable>(_ type: T.Type, from data: Data, response: HTTPURLResponse) throws -> T {
        try checkStatus(data: data, response: response)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw LeaderboardError.decode
        }
    }

    private func checkStatus(data: Data, response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200..<300: return
        case 401: throw LeaderboardError.unauthorized
        case 429: throw LeaderboardError.rateLimited(retryAfterMs: Self.retryAfterMs(from: data))
        default: throw LeaderboardError.http(status: response.statusCode)
        }
    }

    private static func retryAfterMs(from data: Data) -> Int64? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let ms = obj["retry_after_ms"] as? Int64 { return ms }
        if let ms = obj["retry_after_ms"] as? Int { return Int64(ms) }
        if let ms = obj["retry_after_ms"] as? NSNumber { return ms.int64Value }
        return nil
    }

    private static func formEncode(_ params: [String: String]) -> Data {
        var comps = URLComponents()
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((comps.percentEncodedQuery ?? "").utf8)
    }
}
