import SwiftUI
import PetCore

struct LeaderboardSettingsView: View {
    @ObservedObject var driver: LeaderboardSyncDriver
    @StateObject private var auth: LeaderboardAuthModel
    @Environment(\.dismiss) private var dismiss

    init(driver: LeaderboardSyncDriver, service: LeaderboardService, githubClientID: String) {
        self.driver = driver
        _auth = StateObject(wrappedValue: LeaderboardAuthModel(
            service: service,
            githubClientID: githubClientID,
            onAuthorized: { account in driver.didLogin(account) }
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("全球排行榜").font(.headline)
                Spacer()
                Text(driver.snapshot.account == nil ? "未登录" : "已登录")
                    .font(.caption)
                    .foregroundStyle(driver.snapshot.account == nil ? Color.secondary : Color.green)
            }

            if let account = driver.snapshot.account {
                loggedIn(account)
            } else if case let .waiting(userCode, _) = auth.phase {
                waiting(userCode: userCode)
            } else {
                loggedOut
            }

            Text("上传聚合统计与宠物信息，不含代码与会话内容。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    @ViewBuilder
    private var loggedOut: some View {
        Text("使用 GitHub 登录后即可上榜并查看自己的排名。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 8) {
            Button("使用 GitHub 登录") { auth.begin() }
                .disabled(auth.phase == .starting)
            if auth.phase == .starting {
                ProgressView().controlSize(.small)
            }
        }

        if case let .failed(message) = auth.phase {
            Text(message)
                .font(.caption2)
                .foregroundStyle(.red)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func waiting(userCode: String) -> some View {
        Text("在浏览器中输入以下验证码：")
            .font(.caption)
            .foregroundStyle(.secondary)
        HStack(spacing: 8) {
            Text(userCode)
                .font(.title3.monospaced())
                .textSelection(.enabled)
            Button("复制") { auth.copyCode() }
                .controlSize(.small)
        }
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("已打开浏览器，请完成授权…")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("取消") { auth.cancel() }
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private func loggedIn(_ account: LeaderboardAccount) -> some View {
        HStack(spacing: 8) {
            LeaderboardAvatar(url: account.avatarUrl, size: 24)
            Text("@\(account.githubLogin)")
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.tail)
        }

        VStack(alignment: .leading, spacing: 3) {
            Text("我的排名").font(.caption.bold()).foregroundStyle(.secondary)
            rankLine("Token 消耗", driver.snapshot.me?.ranks.tokens)
            rankLine("现役生存", driver.snapshot.me?.ranks.survivalCurrent)
            rankLine("历史最佳", driver.snapshot.me?.ranks.survivalBest)
        }

        Text("上次同步：\(LeaderboardFormat.time(driver.snapshot.lastSyncAtMs))")
            .font(.caption)
            .foregroundStyle(.secondary)

        if let err = driver.snapshot.lastError {
            Text(err)
                .font(.caption2)
                .foregroundStyle(.red)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack(spacing: 8) {
            Button("立即同步") { driver.syncNow() }
                .disabled(driver.snapshot.syncing)
            Button("退出登录") { driver.logout() }
        }
    }

    @ViewBuilder
    private func rankLine(_ title: String, _ entry: RankEntry?) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(LeaderboardFormat.rank(entry))
                .font(.caption.monospacedDigit())
        }
    }
}
