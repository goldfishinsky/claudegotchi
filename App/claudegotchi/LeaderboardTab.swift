import SwiftUI
import PetCore

struct LeaderboardTab: View {
    @ObservedObject var driver: LeaderboardSyncDriver
    let service: LeaderboardService
    var openSettings: () -> Void

    enum Board: Hashable { case survival, tokens, models }
    enum SurvivalMode: Hashable { case current, best }
    enum PlatformFilter: Hashable { case all, claudeCode, codex }
    private enum LoadState { case loading, loaded, failed }

    @State private var board: Board = .survival
    @State private var survivalMode: SurvivalMode = .current
    @State private var platform: PlatformFilter = .all
    @State private var rows: [LeaderboardRow] = []
    @State private var modelRows: [GlobalModelStat] = []
    @State private var state: LoadState = .loading
    @State private var reloadToken = 0
    @Environment(\.colorScheme) private var scheme

    private var boardString: String {
        switch board {
        case .tokens: return "tokens"
        case .survival: return survivalMode == .current ? "survival_current" : "survival_best"
        case .models: return "models"
        }
    }

    private var platformParam: String? {
        switch platform {
        case .all: return nil
        case .claudeCode: return ModelPlatform.claudeCode
        case .codex: return ModelPlatform.codex
        }
    }

    private var platformLabel: String {
        switch platform {
        case .all: return "全部平台"
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    private var fetchKey: String { "\(boardString)|\(platformParam ?? "-")|\(reloadToken)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WarmSegmented(selection: $board, items: [
                (.survival, "生存天数"),
                (.tokens, "Token 消耗"),
                (.models, "全球模型"),
            ])

            controls

            if driver.snapshot.account == nil { loggedOutBanner }

            content

            Spacer(minLength: 0)

            if board != .models, driver.snapshot.account != nil { myRankCard }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .task(id: fetchKey) { await load() }
    }

    @ViewBuilder
    private var controls: some View {
        let t = WarmTheme(scheme: scheme)
        HStack {
            if board == .survival {
                WarmSegmented(selection: $survivalMode, items: [
                    (.current, "现役"),
                    (.best, "历史最佳"),
                ])
                .fixedSize()
            }
            Spacer()
            Menu {
                Button("全部平台") { platform = .all }
                Button("Claude Code") { platform = .claudeCode }
                Button("Codex") { platform = .codex }
            } label: {
                Label(platformLabel,
                      systemImage: "line.3.horizontal.decrease.circle")
                    .font(WFont.section).foregroundStyle(t.ink)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var loggedOutBanner: some View {
        let t = WarmTheme(scheme: scheme)
        return SoftCard(fill: t.cardFill, cornerRadius: 12, padding: 10, shadow: t.cardShadow) {
            HStack(spacing: 8) {
                Text("登录后可上榜并查看自己的排名")
                    .font(WFont.caption).foregroundStyle(t.ink)
                    .lineLimit(1).truncationMode(.tail)
                Spacer()
                Button("登录") { openSettings() }.buttonStyle(WarmButtonStyle(prominent: true))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let t = WarmTheme(scheme: scheme)
        switch state {
        case .loading:
            stateMessage {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在加载…").font(WFont.body).foregroundStyle(t.inkFaint)
                }
            }
        case .failed:
            stateMessage {
                VStack(spacing: 10) {
                    Text("加载失败").font(WFont.body).foregroundStyle(t.inkFaint)
                    Button("重试") { reloadToken += 1 }.buttonStyle(WarmButtonStyle())
                }
            }
        case .loaded:
            if board == .models {
                if modelRows.isEmpty { emptyState } else { modelList }
            } else {
                if rows.isEmpty { emptyState } else { leaderList }
            }
        }
    }

    private var leaderList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    leaderRow(row)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 380)
    }

    @ViewBuilder
    private func leaderRow(_ row: LeaderboardRow) -> some View {
        let t = WarmTheme(scheme: scheme)
        let own = isOwnRow(row)
        SoftCard(fill: own ? t.highlight : t.cardFill, cornerRadius: 12, padding: 9, shadow: t.cardShadow) {
            HStack(spacing: 10) {
                Text("\(row.rank)")
                    .font(WFont.value).monospacedDigit()
                    .foregroundStyle(own ? t.accent : t.inkFaint)
                    .frame(minWidth: 30, alignment: .trailing)
                LeaderboardAvatar(url: row.avatarUrl, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("@\(row.login)")
                        .font(WFont.label).foregroundStyle(t.inkStrong)
                        .lineLimit(1).truncationMode(.tail)
                    if let label = petLabel(row.pet) {
                        Text(label)
                            .font(WFont.caption).foregroundStyle(t.inkFaint)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer()
                Text(valueText(row))
                    .font(WFont.value).monospacedDigit()
                    .foregroundStyle(own ? t.accent : t.ink)
            }
        }
    }

    private var modelList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(modelRows.enumerated()), id: \.offset) { _, model in
                    modelStatRow(model)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 380)
    }

    @ViewBuilder
    private func modelStatRow(_ model: GlobalModelStat) -> some View {
        let t = WarmTheme(scheme: scheme)
        SoftCard(fill: t.cardFill, cornerRadius: 12, padding: 10, shadow: t.cardShadow) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(model.model).font(WFont.label).foregroundStyle(t.inkStrong)
                        .lineLimit(1).truncationMode(.middle)
                    if platform == .all, let source = model.platform {
                        Text(source == ModelPlatform.codex ? "Codex" : "Claude")
                            .font(WFont.caption).foregroundStyle(t.inkFaint)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(t.panelFill))
                    }
                    Spacer()
                    Text(TokenFormat.compact(model.tokensIn + model.tokensOut) + " tok")
                        .font(WFont.value).monospacedDigit().foregroundStyle(t.ink)
                }
                HStack(spacing: 8) {
                    Text("\(TokenFormat.compact(model.calls)) 次调用")
                        .font(WFont.caption).foregroundStyle(t.inkFaint)
                    if let users = model.users {
                        Text("\(TokenFormat.compact(Int64(users))) 人使用")
                            .font(WFont.caption).foregroundStyle(t.inkFaint)
                    }
                    Spacer()
                }
            }
        }
    }

    private var myRankCard: some View {
        let t = WarmTheme(scheme: scheme)
        let entry: RankEntry?
        switch board {
        case .tokens: entry = driver.snapshot.me?.ranks.tokens
        case .survival: entry = survivalMode == .current
            ? driver.snapshot.me?.ranks.survivalCurrent
            : driver.snapshot.me?.ranks.survivalBest
        case .models: entry = nil
        }
        return SoftCard(fill: t.cardFill, cornerRadius: 12, padding: 10, shadow: t.cardShadow) {
            HStack(spacing: 8) {
                Text("我的排名").font(WFont.section).foregroundStyle(t.ink)
                Spacer()
                Text(LeaderboardFormat.rank(entry)).font(WFont.value).monospacedDigit().foregroundStyle(t.inkStrong)
            }
        }
    }

    private var emptyState: some View {
        let t = WarmTheme(scheme: scheme)
        return Text("暂无数据").font(WFont.body).foregroundStyle(t.inkFaint)
            .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 24)
    }

    @ViewBuilder
    private func stateMessage<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
    }

    private func petLabel(_ pet: LeaderboardRow.PetRef?) -> String? {
        guard let pet else { return nil }
        let species = PixelSpeciesCatalog.def(pet.species)?.nameZh ?? pet.species
        if let name = pet.name, !name.isEmpty { return "\(species)「\(name)」" }
        return species
    }

    private func valueText(_ row: LeaderboardRow) -> String {
        switch board {
        case .survival: return LeaderboardFormat.days(row.valueMs)
        case .tokens: return TokenFormat.compact(row.value ?? 0)
        case .models: return ""
        }
    }

    private func isOwnRow(_ row: LeaderboardRow) -> Bool {
        guard let login = driver.snapshot.account?.githubLogin else { return false }
        return login.caseInsensitiveCompare(row.login) == .orderedSame
    }

    private func load() async {
        state = .loading
        do {
            if board == .models {
                let stats = try await service.modelStats(platform: platformParam)
                if Task.isCancelled { return }
                modelRows = stats.models
            } else {
                let page = try await service.leaderboard(board: boardString, platform: platformParam, page: 1)
                if Task.isCancelled { return }
                rows = page.rows
            }
            state = .loaded
        } catch {
            if Task.isCancelled { return }
            state = .failed
        }
    }
}

enum LeaderboardFormat {
    static func rank(_ entry: RankEntry?) -> String {
        guard let entry else { return "—" }
        return "第 \(entry.rank) 名 / 共 \(entry.total) 人"
    }

    static func time(_ ms: Int64?) -> String {
        guard let ms else { return "—" }
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    static func days(_ ms: Int64?) -> String {
        guard let ms, ms > 0 else { return "0 天" }
        let days = Double(ms) / 86_400_000
        if days >= 10 { return "\(Int(days.rounded())) 天" }
        return String(format: "%.1f 天", days)
    }
}

struct LeaderboardAvatar: View {
    let url: String?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url.flatMap { URL(string: $0) }) { phase in
            if case let .success(image) = phase {
                image.resizable().scaledToFill()
            } else {
                Color.primary.opacity(0.1)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
