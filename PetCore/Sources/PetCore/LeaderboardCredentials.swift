import Foundation
import Security

public struct LeaderboardAccount: Codable, Equatable, Sendable {
    public let token: String
    public let githubLogin: String
    public let avatarUrl: String?
    public init(token: String, githubLogin: String, avatarUrl: String?) {
        self.token = token
        self.githubLogin = githubLogin
        self.avatarUrl = avatarUrl
    }
}

public protocol LeaderboardCredentialsStore: Sendable {
    func load() throws -> LeaderboardAccount?
    func save(_ account: LeaderboardAccount) throws
    func clear() throws
}

public enum KeychainError: Error, Equatable {
    case status(OSStatus)
}

public final class KeychainCredentialsStore: LeaderboardCredentialsStore {
    private let service = "claudegotchi.leaderboard"
    private let account = "default"

    public init() {}

    public func load() throws -> LeaderboardAccount? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError.status(status)
        }
        return try JSONDecoder().decode(LeaderboardAccount.self, from: data)
    }

    public func save(_ account: LeaderboardAccount) throws {
        let data = try JSONEncoder().encode(account)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: self.account,
        ]
        let updateStatus = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
            return
        }
        throw KeychainError.status(updateStatus)
    }

    public func clear() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }
}

public final class InMemoryCredentialsStore: LeaderboardCredentialsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var account: LeaderboardAccount?

    public init(_ initial: LeaderboardAccount? = nil) {
        account = initial
    }

    public func load() throws -> LeaderboardAccount? {
        lock.lock(); defer { lock.unlock() }
        return account
    }

    public func save(_ account: LeaderboardAccount) throws {
        lock.lock(); defer { lock.unlock() }
        self.account = account
    }

    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        account = nil
    }
}
