import SwiftUI
import GRDB
import PetCore

enum PRScope: String, CaseIterable {
    case mine = "我的"
    case all = "全部"
    case others = "其他人"
}

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

    static let historyInlineCap = 20

    static func timeLabel(_ ms: Int64?) -> String {
        guard let ms else { return "排队中" }
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }

    static func tokenLabel(_ tokens: Int?) -> String {
        guard let tokens, tokens > 0 else { return "" }
        if tokens >= 1000 {
            return String(format: "%.1fk tok", Double(tokens) / 1000)
        }
        return "\(tokens) tok"
    }

    static func jobStateChip(_ state: FixJobState) -> String {
        switch state {
        case .queued: return "🕒 排队"
        case .checkout: return "📦 检出"
        case .running: return "▶️ 运行中"
        case .succeeded: return "✅ 成功"
        case .failed: return "❌ 失败"
        case .canceled: return "🚫 已取消"
        }
    }
}

struct PRWorktableTab: View {
    @ObservedObject var watcher: PRWatcher
    @ObservedObject var coordinator: FixCoordinator
    let db: DatabaseQueue
    let config: ConfigYAML
    let github: GitHubClient
    let git: GitRunner

    @State private var prs: [PR] = []
    @State private var repos: [WatchedRepo] = []
    @State private var activeSlugs: Set<String> = []
    @State private var history: [FixJob] = []
    @State private var logViewerJob: FixJob?
    @State private var scope: PRScope = .mine
    @State private var showWatchSettings = false
    @Environment(\.colorScheme) private var scheme

    private var scoped: [PR] {
        switch scope {
        case .mine:   return prs.filter { $0.isMine }
        case .all:    return prs
        case .others: return prs.filter { !$0.isMine }
        }
    }

    private var grouped: [(slug: String, rows: [PR])] {
        let bySlug = Dictionary(grouping: scoped, by: \.repoSlug)
        return bySlug.keys.sorted().map { slug in
            (slug: slug, rows: PRTabFormat.attentionSorted(bySlug[slug] ?? []))
        }
    }

    private var pendingCount: Int { PRTabFormat.pendingCount(scoped) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
            fixHistorySection
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .onReceive(watcher.$snapshot) { _ in reload() }
        .onReceive(coordinator.$progress) { _ in reloadHistory() }
        .onAppear { reload() }
        .sheet(item: $logViewerJob) { job in LogViewer(job: job) }
        .sheet(isPresented: $showWatchSettings, onDismiss: onWatchSettingsDismiss) {
            WatchSettingsView(db: db, github: github, git: git, config: config)
        }
    }

    @ViewBuilder
    private var header: some View {
        let t = WarmTheme(scheme: scheme)
        HStack {
            Text("工作台").font(WFont.title).foregroundStyle(t.inkStrong)
            Spacer()
            if pendingCount > 0 {
                Text("\(PRTabFormat.cappedCount(pendingCount)) 待处理")
                    .font(WFont.section).foregroundStyle(t.accent)
            }
            Button { showWatchSettings = true } label: {
                Image(systemName: "gearshape").font(.system(size: 13, weight: .semibold)).foregroundStyle(t.ink)
            }
            .buttonStyle(.plain)
            .help("配置监控仓库")
        }
        WarmSegmented(selection: $scope, items: PRScope.allCases.map { ($0, $0.rawValue) })
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
        let t = WarmTheme(scheme: scheme)
        let status = watcher.snapshot.perRepoStatus[slug]
        SoftCard(fill: t.highlight, cornerRadius: 10, padding: 8, shadow: .clear) {
            HStack(spacing: 6) {
                Text("⚠️").font(WFont.caption)
                if watcher.snapshot.ghUnavailable {
                    Text("gh 未安装或未登录").font(WFont.caption).foregroundStyle(t.inkStrong)
                } else {
                    Text("\(slug)：\(PRTabFormat.lastUpdatedLabel(status?.lastSuccessAtMs))")
                        .font(WFont.caption).foregroundStyle(t.inkStrong)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let t = WarmTheme(scheme: scheme)
        if !watcher.snapshot.firstPollComplete && prs.isEmpty {
            loadingState
        } else if scoped.isEmpty {
            emptyState
        } else if pendingCount == 0 {
            // All-clear: no attention PRs, but non-attention status rows may exist.
            VStack(alignment: .leading, spacing: 8) {
                Text("✅ 全部清空").font(WFont.title).foregroundStyle(t.good)
                prList
            }
        } else {
            prList
        }
    }

    private var emptyMessage: String {
        switch scope {
        case .mine:   return "你当前没有 open 的 PR"
        case .others: return "没有其他人的 PR"
        case .all:    return "✅ 全部清空"
        }
    }

    private var loadingState: some View {
        let t = WarmTheme(scheme: scheme)
        return HStack { ProgressView().controlSize(.small); Text("正在加载…").font(WFont.body).foregroundStyle(t.inkFaint) }
            .frame(maxWidth: .infinity, alignment: .center).padding()
    }

    private var emptyState: some View {
        let t = WarmTheme(scheme: scheme)
        return Text(emptyMessage).font(WFont.body).foregroundStyle(t.inkFaint)
            .frame(maxWidth: .infinity, alignment: .center).padding()
    }

    private var prList: some View {
        let t = WarmTheme(scheme: scheme)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(grouped, id: \.slug) { group in
                    Text(group.slug).font(WFont.section).foregroundStyle(t.ink)
                        .lineLimit(1).truncationMode(.middle).padding(.top, 2)
                    ForEach(Array(group.rows.prefix(PRTabFormat.rowWindowCap)), id: \.id) { pr in
                        prRow(pr, t)
                    }
                    if group.rows.count > PRTabFormat.rowWindowCap {
                        Text("… 还有 \(group.rows.count - PRTabFormat.rowWindowCap) 个")
                            .font(WFont.caption).foregroundStyle(t.inkFaint)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 360)
    }

    @ViewBuilder
    private func prRow(_ pr: PR, _ t: WarmTheme) -> some View {
        let chip = PRStatusChip.from(isDraft: pr.isDraft, reviewDecision: pr.reviewDecision, state: pr.state)
        SoftCard(fill: t.cardFill, cornerRadius: 12, padding: 10, shadow: t.cardShadow) {
            HStack(spacing: 8) {
                Text("#\(pr.number)").font(WFont.caption).monospacedDigit().foregroundStyle(t.inkFaint)
                Text(pr.title).font(WFont.label).foregroundStyle(t.inkStrong)
                    .lineLimit(1).truncationMode(.tail)
                Spacer()
                Text("\(chip.symbol) \(chip.label)").font(WFont.caption).foregroundStyle(t.ink)
                if pr.unresolvedCount > 0 {
                    Text("💬\(PRTabFormat.cappedCount(pr.unresolvedCount))").font(WFont.caption).foregroundStyle(t.accent)
                }
                fixButton(pr)
            }
        }
    }

    @ViewBuilder
    private func fixButton(_ pr: PR) -> some View {
        let disabledReason = fixDisabledReason(pr)
        Button("修复") { startFix(pr) }
            .buttonStyle(WarmButtonStyle())
            .disabled(disabledReason != nil)
            .help(disabledReason ?? "运行 Claude 修复评审反馈")
    }

    private func repo(forSlug slug: String) -> WatchedRepo? {
        repos.first { $0.slug == slug }
    }

    private func fixDisabledReason(_ pr: PR) -> String? {
        if !pr.isMine { return "仅能修复本人的 PR" }
        guard let repo = repo(forSlug: pr.repoSlug),
              let path = repo.localPath, !path.isEmpty else {
            return "无本地路径或 origin 不匹配"
        }
        if activeSlugs.contains(pr.repoSlug) { return "已有任务运行中" }
        return nil
    }

    private func startFix(_ pr: PR) {
        guard let repo = repo(forSlug: pr.repoSlug),
              let path = repo.localPath, !path.isEmpty,
              let prRowid = pr.id else { return }
        coordinator.enqueue(
            prRowid: prRowid, slug: pr.repoSlug, number: pr.number,
            repoPath: URL(fileURLWithPath: path), headBranch: pr.headBranch
        )
        reloadHistory()
    }

    // MARK: - 修复任务 (fix-job history)

    @ViewBuilder
    private var fixHistorySection: some View {
        let t = WarmTheme(scheme: scheme)
        VStack(alignment: .leading, spacing: 6) {
            Text("修复任务").font(WFont.section).foregroundStyle(t.ink)
            if history.isEmpty {
                Text("暂无修复任务").font(WFont.body).foregroundStyle(t.inkFaint)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(history, id: \.id) { job in fixJobRow(job, t) }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 160)
            }
        }
    }

    @ViewBuilder
    private func fixJobRow(_ job: FixJob, _ t: WarmTheme) -> some View {
        SoftCard(fill: t.cardFill, cornerRadius: 12, padding: 10, shadow: t.cardShadow) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(PRTabFormat.jobStateChip(job.state)).font(WFont.caption).foregroundStyle(t.ink)
                    Text("#\(job.prNumber)").font(WFont.caption).monospacedDigit().foregroundStyle(t.inkFaint)
                    Text(job.repoSlug).font(WFont.caption).foregroundStyle(t.inkFaint)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if job.state == .running, let id = job.id, let p = coordinator.progress[id] {
                        if let tool = p.tool {
                            Text(tool).font(WFont.caption).foregroundStyle(t.ink).lineLimit(1).truncationMode(.tail)
                        }
                        let tok = PRTabFormat.tokenLabel(p.tokens)
                        if !tok.isEmpty { Text(tok).font(WFont.caption).monospacedDigit().foregroundStyle(t.inkFaint) }
                        Button("取消") { coordinator.cancel(jobId: id) }.controlSize(.mini)
                    }
                    if job.logPath != nil {
                        Button("log") { logViewerJob = job }.controlSize(.mini)
                    }
                }
                HStack(spacing: 8) {
                    Text("开始：\(PRTabFormat.timeLabel(job.startedAt))")
                        .font(WFont.caption).monospacedDigit().foregroundStyle(t.inkFaint)
                    if let ended = job.endedAt {
                        Text("结束：\(PRTabFormat.timeLabel(ended))")
                            .font(WFont.caption).monospacedDigit().foregroundStyle(t.inkFaint)
                    }
                }
                if job.state == .succeeded {
                    if let sha = job.commitSha {
                        Text("提交 \(sha.prefix(8))").font(WFont.caption).monospacedDigit().foregroundStyle(t.inkFaint)
                    }
                    Text(FixRunner.integrationCommand(number: job.prNumber, headBranch: branch(for: job)))
                        .font(.system(size: 9.5, design: .monospaced)).foregroundStyle(t.inkFaint)
                        .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    if let wt = job.worktreePath {
                        Text(wt).font(WFont.caption).foregroundStyle(t.inkFaint)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                if let err = job.error {
                    Text(LogRedactor.redact(err)).font(WFont.caption).foregroundStyle(t.danger)
                        .lineLimit(2).truncationMode(.tail)
                }
            }
        }
    }

    private func branch(for job: FixJob) -> String {
        prs.first { $0.repoSlug == job.repoSlug && $0.number == job.prNumber }?.headBranch ?? ""
    }

    private func onWatchSettingsDismiss() {
        reload()
        Task { await watcher.pollOnce() }
    }

    private func reload() {
        prs = (try? PRStore.allPRs(in: db)) ?? []
        repos = (try? PRStore.watchedRepos(in: db)) ?? []
        reloadHistory()
    }

    private func reloadHistory() {
        history = (try? db.read { try FixJobStore.history(limit: PRTabFormat.historyInlineCap, in: $0) }) ?? []
        var slugs: Set<String> = []
        for repo in repos {
            if let active = try? db.read({ try FixJobStore.activeJob(repoSlug: repo.slug, in: $0) }),
               active != nil {
                slugs.insert(repo.slug)
            }
        }
        activeSlugs = slugs
    }
}

private struct LogViewer: View {
    let job: FixJob
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var contents: String = ""

    var body: some View {
        let t = WarmTheme(scheme: scheme)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("修复日志 #\(job.prNumber)").font(WFont.title).foregroundStyle(t.inkStrong)
                Spacer()
                Button("关闭") { dismiss() }.buttonStyle(WarmButtonStyle())
            }
            ScrollView {
                Text(contents.isEmpty ? "（无日志内容）" : contents)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(t.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minWidth: 480, maxHeight: 360)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(t.cardFill))
        }
        .padding(16)
        .background(t.windowFill.ignoresSafeArea())
        .onAppear { load() }
    }

    private func load() {
        guard let path = job.logPath,
              let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            contents = ""
            return
        }
        contents = LogRedactor.redact(raw)
    }
}

extension FixJob: Identifiable {}
