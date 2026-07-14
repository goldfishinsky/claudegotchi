import SwiftUI
import PetCore

struct LeaderboardTab: View {
    @ObservedObject var driver: LeaderboardSyncDriver
    let service: LeaderboardService
    var openSettings: () -> Void

    enum Board: Hashable { case survival, tokens, models }
    enum SurvivalMode: Hashable { case current, best }
    enum PlatformFilter: Hashable { case all, claudeCode }
    private enum LoadState { case loading, loaded, failed }

    @State private var board: Board = .survival
    @State private var survivalMode: SurvivalMode = .current
    @State private var platform: PlatformFilter = .all
    @State private var rows: [LeaderboardRow] = []
    @State private var modelRows: [GlobalModelStat] = []
    @State private var state: LoadState = .loading
    @State private var reloadToken = 0

    private var boardString: String {
        switch board {
        case .tokens: return "tokens"
        case .survival: return survivalMode == .current ? "survival_current" : "survival_best"
        case .models: return "models"
        }
    }

    private var platformParam: String? { platform == .all ? nil : "claude-code" }

    private var fetchKey: String { "\(boardString)|\(platformParam ?? "-")|\(reloadToken)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $board) {
                Text("生存天数").tag(Board.survival)
                Text("Token 消耗").tag(Board.tokens)
                Text("全球模型").tag(Board.models)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if board != .models { controls }

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
        HStack {
            if board == .survival {
                Picker("", selection: $survivalMode) {
                    Text("现役").tag(SurvivalMode.current)
                    Text("历史最佳").tag(SurvivalMode.best)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Spacer()
            Menu {
                Button("全部平台") { platform = .all }
                Button("Claude Code") { platform = .claudeCode }
            } label: {
                Label(platform == .all ? "全部平台" : "Claude Code",
                      systemImage: "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var loggedOutBanner: some View {
        HStack(spacing: 8) {
            Text("登录后可上榜并查看自己的排名")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
            Spacer()
            Button("登录") { openSettings() }.controlSize(.small)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.groupFill))
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            stateMessage {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在加载…").foregroundStyle(.secondary)
                }
            }
        case .failed:
            stateMessage {
                VStack(spacing: 8) {
                    Text("加载失败").foregroundStyle(.secondary)
                    Button("重试") { reloadToken += 1 }.controlSize(.small)
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
        let own = isOwnRow(row)
        HStack(spacing: 10) {
            Text("\(row.rank)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 34, alignment: .trailing)
            LeaderboardAvatar(url: row.avatarUrl, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text("@\(row.login)")
                    .font(.callout)
                    .lineLimit(1).truncationMode(.tail)
                if let label = petLabel(row.pet) {
                    Text(label)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer()
            Text(valueText(row))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(own ? Color.accentColor.opacity(0.15) : Color.clear)
        )
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
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(model.model).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(TokenFormat.compact(model.tokensIn + model.tokensOut) + " tok")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text("\(TokenFormat.compact(model.calls)) 次调用")
                    .font(.caption2).foregroundStyle(.secondary)
                if let users = model.users {
                    Text("\(TokenFormat.compact(Int64(users))) 人使用")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 8)
    }

    private var myRankCard: some View {
        let entry: RankEntry?
        switch board {
        case .tokens: entry = driver.snapshot.me?.ranks.tokens
        case .survival: entry = survivalMode == .current
            ? driver.snapshot.me?.ranks.survivalCurrent
            : driver.snapshot.me?.ranks.survivalBest
        case .models: entry = nil
        }
        return HStack(spacing: 8) {
            Text("我的排名").font(.caption.bold()).foregroundStyle(.secondary)
            Spacer()
            Text(LeaderboardFormat.rank(entry)).font(.callout.monospacedDigit())
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.groupFill))
    }

    private var emptyState: some View {
        Text("暂无数据").font(.callout).foregroundStyle(.secondary)
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
