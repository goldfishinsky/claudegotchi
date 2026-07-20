import Foundation
import Security

public protocol ClaudeTokenCaching: Sendable {
    func read() -> String?
    func write(_ token: String)
}

/// claudegotchi's own generic-password item; an app reads back items it created
/// without the cross-app consent prompt the Claude Code item would raise.
public final class KeychainClaudeTokenCache: ClaudeTokenCaching {
    private let service = "claudegotchi.claude-oauth"
    private let account = "default"

    public init() {}

    public func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty
        else { return nil }
        return token
    }

    public func write(_ token: String) {
        let data = Data(token.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateStatus = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

public final class InMemoryClaudeTokenCache: ClaudeTokenCaching, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    public init(_ initial: String? = nil) { token = initial }

    public func read() -> String? {
        lock.lock(); defer { lock.unlock() }
        return token
    }

    public func write(_ token: String) {
        lock.lock(); defer { lock.unlock() }
        self.token = token
    }
}

public protocol ClaudeTokenProviding: Sendable {
    func token() -> String?
    func refreshedToken() -> String?
}

/// Serves claudegotchi's cached copy first (silent) and only re-reads Claude
/// Code's item (may prompt) when the cache is empty or the cached token failed.
public final class CachedClaudeTokenProvider: ClaudeTokenProviding, @unchecked Sendable {
    private let upstream: ClaudeOAuthTokenReading
    private let cache: ClaudeTokenCaching
    private let lock = NSLock()

    public init(upstream: ClaudeOAuthTokenReading = KeychainClaudeTokenReader(),
                cache: ClaudeTokenCaching = KeychainClaudeTokenCache()) {
        self.upstream = upstream
        self.cache = cache
    }

    public func token() -> String? {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache.read() { return cached }
        return refillLocked()
    }

    public func refreshedToken() -> String? {
        lock.lock(); defer { lock.unlock() }
        return refillLocked()
    }

    private func refillLocked() -> String? {
        guard let fresh = upstream.accessToken() else { return nil }
        cache.write(fresh)
        return fresh
    }
}
