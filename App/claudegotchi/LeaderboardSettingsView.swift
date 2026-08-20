import SwiftUI
import PetCore

struct LeaderboardSettingsView: View {
    @ObservedObject var driver: LeaderboardSyncDriver
    @StateObject private var auth: LeaderboardAuthModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    init(driver: LeaderboardSyncDriver, service: LeaderboardService) {
        self.driver = driver
        _auth = StateObject(wrappedValue: LeaderboardAuthModel(
            service: service,
            onAuthorized: { account in driver.didLogin(account) }
        ))
    }

    var body: some View {
        let t = WarmTheme(scheme: scheme)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("全球排行榜").font(WFont.title).foregroundStyle(t.inkStrong)
                Spacer()
                Text(driver.snapshot.account == nil ? "未登录" : "已登录")
                    .font(WFont.caption)
                    .foregroundStyle(driver.snapshot.account == nil ? t.inkFaint : t.good)
            }

            if let account = driver.snapshot.account {
                loggedIn(account, t)
            } else {
                loggedOut(t)
            }

            Text("上传聚合统计与宠物信息，不含代码与会话内容。")
                .font(WFont.caption)
                .foregroundStyle(t.inkFaint)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(WarmButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(t.windowFill.ignoresSafeArea())
    }

    @ViewBuilder
    private func loggedOut(_ t: WarmTheme) -> some View {
        Text("使用 GitHub 登录后即可上榜并查看自己的排名。")
            .font(WFont.body)
            .foregroundStyle(t.ink)
            .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 8) {
            Button("继续使用 GitHub") { auth.begin() }
                .buttonStyle(WarmButtonStyle(prominent: true))
                .disabled(auth.phase == .starting || auth.phase == .authorizing)
            if auth.phase == .starting || auth.phase == .authorizing {
                ProgressView().controlSize(.small)
            }
        }

        if case let .failed(message) = auth.phase {
            Text(message)
                .font(WFont.caption)
                .foregroundStyle(t.danger)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func loggedIn(_ account: LeaderboardAccount, _ t: WarmTheme) -> some View {
        HStack(spacing: 8) {
            LeaderboardAvatar(url: account.avatarUrl, size: 24)
            Text("@\(account.githubLogin)")
                .font(WFont.label).foregroundStyle(t.inkStrong)
                .lineLimit(1)
                .truncationMode(.tail)
        }

        SoftCard(fill: t.cardFill, cornerRadius: 12, padding: 10, shadow: t.cardShadow) {
            VStack(alignment: .leading, spacing: 4) {
                Text("我的排名").font(WFont.section).foregroundStyle(t.ink)
                rankLine("Token 消耗", driver.snapshot.me?.ranks.tokens, t)
                rankLine("现役生存", driver.snapshot.me?.ranks.survivalCurrent, t)
                rankLine("历史最佳", driver.snapshot.me?.ranks.survivalBest, t)
            }
        }

        Text("上次同步：\(LeaderboardFormat.time(driver.snapshot.lastSyncAtMs))")
            .font(WFont.caption)
            .foregroundStyle(t.inkFaint)

        if let err = driver.snapshot.lastError {
            Text(err)
                .font(WFont.caption)
                .foregroundStyle(t.danger)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack(spacing: 8) {
            Button("立即同步") { driver.syncNow() }
                .buttonStyle(WarmButtonStyle(prominent: true))
                .disabled(driver.snapshot.syncing)
            Button("退出登录") { driver.logout() }
                .buttonStyle(WarmButtonStyle())
        }
    }

    @ViewBuilder
    private func rankLine(_ title: String, _ entry: RankEntry?, _ t: WarmTheme) -> some View {
        HStack(spacing: 8) {
            Text(title).font(WFont.caption).foregroundStyle(t.inkFaint)
            Spacer()
            Text(LeaderboardFormat.rank(entry))
                .font(WFont.caption).monospacedDigit().foregroundStyle(t.ink)
        }
    }
}
