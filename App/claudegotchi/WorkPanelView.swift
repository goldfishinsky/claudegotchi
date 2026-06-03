import SwiftUI
import GRDB
import PetCore

enum WorkPanelFormat {
    static let rowCap = 3
    static let countCap = 99

    static func cappedCount(_ n: Int) -> String {
        n > countCap ? "\(countCap)+" : "\(n)"
    }

    static func attentionRank(_ pr: PR) -> Int {
        if pr.reviewDecision == "CHANGES_REQUESTED" { return 0 }
        if pr.unresolvedCount > 0 { return 1 }
        return 2
    }

    static func ordered(_ prs: [PR]) -> [PR] {
        prs.sorted {
            let ra = attentionRank($0), rb = attentionRank($1)
            if ra != rb { return ra < rb }
            return $0.updatedAt > $1.updatedAt
        }
    }

    static func chip(for pr: PR) -> String {
        if pr.isDraft { return "📝 草稿" }
        switch pr.reviewDecision {
        case "CHANGES_REQUESTED": return "⚠ CR"
        case "APPROVED": return "✅ 已批准"
        default: return pr.unresolvedCount > 0 ? "💬 \(cappedCount(pr.unresolvedCount))" : "👁 待审"
        }
    }
}

@MainActor
final class WorkPanelModel: ObservableObject {
    @Published private(set) var prs: [PR] = []
    @Published private(set) var runningRepoCount: Int = 0
    @Published private(set) var firstPollComplete: Bool = false

    let config: ConfigYAML
    private let db: DatabaseQueue
    private let sessionWindowMs: Int64

    init(db: DatabaseQueue, config: ConfigYAML, sessionWindowMs: Int64 = 15 * 60 * 1000) {
        self.db = db
        self.config = config
        self.sessionWindowMs = sessionWindowMs
    }

    var pendingCount: Int { WorkPressure.pendingCount(prs) }
    var tier: PressureTier { WorkPressure.tier(prs, config: config) }

    func refresh(firstPollComplete: Bool) {
        self.firstPollComplete = firstPollComplete
        prs = (try? PRStore.allPRs(in: db)) ?? []

        let repoPaths = (try? PRStore.watchedRepos(in: db))?
            .compactMap { repo -> (slug: String, path: String)? in
                guard let path = repo.localPath, !path.isEmpty else { return nil }
                return (slug: repo.slug, path: path)
            } ?? []
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let sessions = (try? SessionTracker.activeSessions(
            db: db, nowMs: nowMs, windowMs: sessionWindowMs, repoPaths: repoPaths
        )) ?? []
        runningRepoCount = Set(sessions.map { $0.repo }).count
    }
}

struct WorkPanelView: View {
    @ObservedObject var model: WorkPanelModel
    var onOpenWorktable: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                moodSprite
                Text("工作").font(.subheadline.bold())
                Spacer()
            }

            content
                .frame(maxHeight: 120)

            runningLine

            Button(action: onOpenWorktable) {
                Text("打开工作台").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(width: 260, alignment: .leading)
        .padding(8)
    }

    @ViewBuilder
    private var content: some View {
        if !model.firstPollComplete {
            Text("正在加载…").font(.caption).foregroundColor(.secondary)
        } else if model.pendingCount == 0 {
            Text("✅ 全部清空").font(.caption).foregroundColor(.secondary)
        } else {
            attentionHeader
            prList
        }
    }

    private var attentionHeader: some View {
        HStack {
            Text("🔔 \(model.pendingCount) 个 PR 待处理").font(.caption)
            Spacer()
            Text(WorkPanelFormat.cappedCount(model.pendingCount))
                .font(.caption.bold()).foregroundColor(.orange)
        }
    }

    private var prList: some View {
        let ordered = WorkPanelFormat.ordered(model.prs)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 3) {
                ForEach(Array(ordered.prefix(WorkPanelFormat.rowCap)), id: \.id) { pr in
                    HStack(spacing: 4) {
                        Text("•").font(.caption)
                        Text(pr.title).font(.caption)
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        Text(WorkPanelFormat.chip(for: pr))
                            .font(.caption).foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                if ordered.count > WorkPanelFormat.rowCap {
                    Text("… 还有 \(WorkPanelFormat.cappedCount(ordered.count - WorkPanelFormat.rowCap)) 个")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
        }
        .frame(maxHeight: 96)
    }

    @ViewBuilder
    private var runningLine: some View {
        if model.runningRepoCount > 0 {
            Text("🟢 Claude 在 \(WorkPanelFormat.cappedCount(model.runningRepoCount)) 个仓库运行")
                .font(.caption).foregroundColor(.green)
                .lineLimit(1)
        }
    }

    private var moodSprite: some View {
        Text(moodEmoji).font(.body)
    }

    private var moodEmoji: String {
        switch model.tier {
        case .calm: return "🙂"
        case .busy: return "😐"
        case .stressed: return "😰"
        }
    }
}
