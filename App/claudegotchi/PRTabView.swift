import SwiftUI
import GRDB
import PetCore

struct PRStatusChip: Equatable {
    let label: String
    let symbol: String

    static func from(isDraft: Bool, reviewDecision: String?, state: String) -> PRStatusChip {
        if state == "MERGED" { return PRStatusChip(label: "已合并", symbol: "🔀") }
        if isDraft { return PRStatusChip(label: "草稿", symbol: "📝") }
        switch reviewDecision {
        case "CHANGES_REQUESTED": return PRStatusChip(label: "CR", symbol: "⚠️")
        case "APPROVED": return PRStatusChip(label: "已批准", symbol: "✅")
        default: return PRStatusChip(label: "待审", symbol: "👁")
        }
    }
}

enum PRTabFormat {
    static let rowWindowCap = 100
    static let countCap = 99

    static func cappedCount(_ n: Int) -> String {
        n > countCap ? "\(countCap)+" : "\(n)"
    }

    static func isAttention(_ pr: PR) -> Bool {
        pr.isMine && pr.state == "OPEN" && !pr.isDraft
            && (pr.reviewDecision == "CHANGES_REQUESTED" || pr.unresolvedCount > 0)
    }

    static func pendingCount(_ prs: [PR]) -> Int {
        prs.filter(isAttention).count
    }

    static func attentionSorted(_ prs: [PR]) -> [PR] {
        prs.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            return a.updatedAt > b.updatedAt
        }
    }

    private static func rank(_ pr: PR) -> Int {
        if pr.reviewDecision == "CHANGES_REQUESTED" { return 0 }
        if pr.unresolvedCount > 0 { return 1 }
        return 2
    }

    static func lastUpdatedLabel(_ ms: Int64?) -> String {
        guard let ms else { return "" }
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return "上次更新于 \(f.string(from: date))"
    }
}

struct PRTabView: View {
    @ObservedObject var watcher: PRWatcher
    let db: DatabaseQueue
    let config: ConfigYAML

    @State private var prs: [PR] = []

    private var grouped: [(slug: String, rows: [PR])] {
        let bySlug = Dictionary(grouping: prs, by: \.repoSlug)
        return bySlug.keys.sorted().map { slug in
            (slug: slug, rows: PRTabFormat.attentionSorted(bySlug[slug] ?? []))
        }
    }

    private var pendingCount: Int { PRTabFormat.pendingCount(prs) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onReceive(watcher.$snapshot) { _ in reload() }
        .onAppear { reload() }
    }

    @ViewBuilder
    private var header: some View {
        HStack {
            Text("工作台").font(.headline)
            Spacer()
            if pendingCount > 0 {
                Text("\(PRTabFormat.cappedCount(pendingCount)) 个待处理")
                    .font(.caption).foregroundColor(.orange)
            }
        }
        ForEach(erroredRepos, id: \.self) { slug in
            errorBanner(slug: slug)
        }
    }

    private var erroredRepos: [String] {
        watcher.snapshot.perRepoStatus
            .filter { $0.value.lastError != nil }
            .keys.sorted()
    }

    @ViewBuilder
    private func errorBanner(slug: String) -> some View {
        let status = watcher.snapshot.perRepoStatus[slug]
        HStack(spacing: 6) {
            Text("⚠️").font(.caption)
            if watcher.snapshot.ghUnavailable {
                Text("gh 未安装或未登录").font(.caption)
            } else {
                Text("\(slug)：\(PRTabFormat.lastUpdatedLabel(status?.lastSuccessAtMs))")
                    .font(.caption).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var content: some View {
        if !watcher.snapshot.firstPollComplete && prs.isEmpty {
            loadingState
        } else if prs.isEmpty {
            emptyState
        } else if pendingCount == 0 {
            // All-clear: no attention PRs, but non-mine status rows may exist.
            VStack(alignment: .leading, spacing: 6) {
                Text("✅ 全部清空").font(.subheadline).foregroundColor(.green)
                prList
            }
        } else {
            prList
        }
    }

    private var loadingState: some View {
        HStack { ProgressView().controlSize(.small); Text("正在加载…").foregroundColor(.secondary) }
            .frame(maxWidth: .infinity, alignment: .center).padding()
    }

    private var emptyState: some View {
        Text("✅ 全部清空").font(.title3).foregroundColor(.green)
            .frame(maxWidth: .infinity, alignment: .center).padding()
    }

    private var prList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(grouped, id: \.slug) { group in
                    Text(group.slug).font(.caption.bold()).foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    ForEach(Array(group.rows.prefix(PRTabFormat.rowWindowCap)), id: \.id) { pr in
                        prRow(pr)
                    }
                    if group.rows.count > PRTabFormat.rowWindowCap {
                        Text("… 还有 \(group.rows.count - PRTabFormat.rowWindowCap) 个")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 360)
    }

    @ViewBuilder
    private func prRow(_ pr: PR) -> some View {
        let chip = PRStatusChip.from(isDraft: pr.isDraft, reviewDecision: pr.reviewDecision, state: pr.state)
        HStack(spacing: 8) {
            Text("#\(pr.number)").font(.caption.monospaced()).foregroundColor(.secondary)
            Text(pr.title).lineLimit(1).truncationMode(.tail)
            Spacer()
            Text("\(chip.symbol) \(chip.label)").font(.caption)
            if pr.unresolvedCount > 0 {
                Text("💬\(PRTabFormat.cappedCount(pr.unresolvedCount))").font(.caption)
            }
        }
    }

    private func reload() {
        prs = (try? PRStore.allPRs(in: db)) ?? []
    }
}
