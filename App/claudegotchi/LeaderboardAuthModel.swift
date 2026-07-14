import Foundation
import AppKit
import PetCore

@MainActor
final class LeaderboardAuthModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting
        case waiting(userCode: String, verificationUri: String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    private let service: LeaderboardService
    private let githubClientID: String
    private let onAuthorized: (LeaderboardAccount) -> Void
    private var pollTask: Task<Void, Never>?

    init(service: LeaderboardService, githubClientID: String, onAuthorized: @escaping (LeaderboardAccount) -> Void) {
        self.service = service
        self.githubClientID = githubClientID
        self.onAuthorized = onAuthorized
    }

    func begin() {
        guard !githubClientID.isEmpty else {
            phase = .failed("未配置 GitHub Client ID，请在 config.yaml 的 排行榜 github_client_id 填写")
            return
        }
        phase = .starting
        pollTask?.cancel()
        pollTask = Task { await run() }
    }

    func cancel() {
        pollTask?.cancel()
        pollTask = nil
        phase = .idle
    }

    func copyCode() {
        guard case let .waiting(userCode, _) = phase else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(userCode, forType: .string)
    }

    private func run() async {
        do {
            let start = try await service.startDeviceFlow()
            if Task.isCancelled { return }
            openURL(start.verificationUri)
            phase = .waiting(userCode: start.userCode, verificationUri: start.verificationUri)

            let deadline = Date().addingTimeInterval(600)
            let interval = UInt64(max(start.interval, 5))
            while Date() < deadline {
                try await Task.sleep(nanoseconds: interval * 1_000_000_000)
                switch try await service.pollDeviceFlow(deviceCode: start.deviceCode) {
                case .pending:
                    continue
                case .failed(let code):
                    phase = .failed(readableError(code))
                    return
                case .authorized(let githubToken):
                    let auth = try await service.authenticate(githubToken: githubToken)
                    onAuthorized(LeaderboardAccount(
                        token: auth.token,
                        githubLogin: auth.user.login,
                        avatarUrl: auth.user.avatarUrl
                    ))
                    phase = .idle
                    return
                }
            }
            phase = .failed("登录超时，请重试")
        } catch is CancellationError {
            return
        } catch {
            phase = .failed("登录失败，请重试")
        }
    }

    private func openURL(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }

    private func readableError(_ code: String) -> String {
        switch code {
        case "expired_token": return "验证码已过期，请重试"
        case "access_denied": return "已取消授权"
        default: return "登录失败：\(code)"
        }
    }
}
