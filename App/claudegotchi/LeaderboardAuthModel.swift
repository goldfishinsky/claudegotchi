import Foundation
import AppKit
import AuthenticationServices
import CryptoKit
import PetCore

@MainActor
final class LeaderboardAuthModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting
        case authorizing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    private let service: LeaderboardService
    private let onAuthorized: (LeaderboardAccount) -> Void
    private var pollTask: Task<Void, Never>?
    private var webSession: ASWebAuthenticationSession?
    private let presentationContext = OAuthPresentationContext()

    init(service: LeaderboardService, onAuthorized: @escaping (LeaderboardAccount) -> Void) {
        self.service = service
        self.onAuthorized = onAuthorized
    }

    func begin() {
        phase = .starting
        pollTask?.cancel()
        pollTask = Task { await run() }
    }

    func cancel() {
        pollTask?.cancel()
        pollTask = nil
        webSession?.cancel()
        webSession = nil
        phase = .idle
    }

    private func run() async {
        do {
            let verifier = Self.randomVerifier()
            let challenge = Self.challenge(for: verifier)
            let start = try await service.startWebAuth(codeChallenge: challenge)
            if Task.isCancelled { return }
            guard let authorizationURL = URL(string: start.authorizationUrl) else {
                throw LeaderboardError.decode
            }
            phase = .authorizing
            let callbackURL = try await authenticate(at: authorizationURL)
            if Task.isCancelled { return }
            let parts = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
            if let error = parts?.queryItems?.first(where: { $0.name == "error" })?.value {
                phase = .failed(readableError(error))
                return
            }
            guard let grant = parts?.queryItems?.first(where: { $0.name == "grant" })?.value,
                  !grant.isEmpty else { throw LeaderboardError.decode }
            let auth = try await service.exchangeWebAuth(grant: grant, codeVerifier: verifier)
            onAuthorized(LeaderboardAccount(
                token: auth.token,
                githubLogin: auth.user.login,
                avatarUrl: auth.user.avatarUrl
            ))
            phase = .idle
        } catch is CancellationError {
            return
        } catch let error as ASWebAuthenticationSessionError
            where error.code == .canceledLogin {
            phase = .idle
        } catch let error as LeaderboardError {
            phase = .failed(readableError(error))
        } catch {
            phase = .failed("登录失败，请重试")
        }
        webSession = nil
    }

    private func authenticate(at url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url, callbackURLScheme: "claudegotchi"
            ) { callbackURL, error in
                if let error { continuation.resume(throwing: error) }
                else if let callbackURL { continuation.resume(returning: callbackURL) }
                else { continuation.resume(throwing: LeaderboardError.decode) }
            }
            session.presentationContextProvider = presentationContext
            session.prefersEphemeralWebBrowserSession = false
            webSession = session
            if !session.start() {
                continuation.resume(throwing: LeaderboardError.transport)
            }
        }
    }

    private func readableError(_ code: String) -> String {
        switch code {
        case "expired_token": return "验证码已过期，请重试"
        case "access_denied": return "已取消授权"
        case "oauth_denied": return "已取消授权"
        default: return "登录失败：\(code)"
        }
    }

    private func readableError(_ error: LeaderboardError) -> String {
        switch error {
        case .transport:
            return "排行榜服务暂不可用"
        case .http(status: 503):
            return "排行榜服务尚未开放"
        case .http:
            return "排行榜服务响应异常，请稍后重试"
        case .unauthorized:
            return "GitHub 授权已失效，请重试"
        case .rateLimited:
            return "请求过于频繁，请稍后重试"
        case .decode:
            return "排行榜服务返回了无法识别的数据"
        }
    }

    private static func randomVerifier() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return base64URL(Data(bytes))
    }

    private static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private final class OAuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let fallbackWindow = NSWindow()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) ?? fallbackWindow
    }
}
