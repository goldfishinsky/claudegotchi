import Foundation
import GRDB
import PetCore

@MainActor
final class PRWatcher: ObservableObject {
    struct RepoStatus: Equatable {
        var lastSuccessAtMs: Int64?
        var lastError: String?
    }

    struct Snapshot: Equatable {
        var firstPollComplete: Bool = false
        var lastPollAtMs: Int64?
        var perRepoStatus: [String: RepoStatus] = [:]
        var ghUnavailable: Bool = false
    }

    @Published private(set) var snapshot = Snapshot()

    private nonisolated let db: DatabaseQueue
    private nonisolated let applier: EventApplier
    private nonisolated let github: GitHubClient
    private nonisolated let config: ConfigYAML
    private nonisolated let pausedProvider: () -> Bool

    private var timer: DispatchSourceTimer?
    private nonisolated let pollQueue = DispatchQueue(label: "claudegotchi.prwatcher")
    // Touched only on pollQueue (serial); the queue is the synchronization domain.
    private nonisolated(unsafe) var cachedSelfLogin: String?
    private nonisolated(unsafe) var isPolling = false
    private nonisolated(unsafe) var lastPerRepoStatus: [String: RepoStatus] = [:]

    init(db: DatabaseQueue, applier: EventApplier, github: GitHubClient, config: ConfigYAML,
         pausedProvider: @escaping () -> Bool = { false }) {
        self.db = db
        self.applier = applier
        self.github = github
        self.config = config
        self.pausedProvider = pausedProvider
    }

    func start() {
        stop()
        let t = DispatchSource.makeTimerSource(queue: pollQueue)
        let interval = max(1, config.work.pollIntervalSeconds)
        t.schedule(deadline: .now(), repeating: .seconds(interval))
        t.setEventHandler { [weak self] in
            self?.pollOnSerialQueue()
        }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    nonisolated func pollOnce() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pollQueue.async { [weak self] in
                self?.pollLocked()
                continuation.resume()
            }
        }
    }

    private nonisolated func pollOnSerialQueue() {
        pollQueue.async { [weak self] in self?.pollLocked() }
    }

    // Runs entirely on pollQueue: all gh/git/DB I/O happens here, never on the main actor.
    private nonisolated func pollLocked() {
        if isPolling { return }
        isPolling = true
        defer { isPolling = false }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        var perRepoStatus = lastPerRepoStatus
        var ghUnavailable = false

        let login = resolveSelfLogin()
        if login == nil {
            ghUnavailable = true
        }
        let selfLogin = login ?? ""

        let repos: [WatchedRepo]
        let cached: [PR]
        do {
            repos = try PRStore.watchedRepos(in: db).filter { $0.enabled }
            cached = try PRStore.allPRs(in: db)
        } catch {
            publish(nowMs: nowMs, perRepoStatus: perRepoStatus, ghUnavailable: ghUnavailable)
            return
        }

        for repo in repos {
            do {
                let authors = try PRStore.authors(repoId: repo.id!, in: db)
                let logins = authors.isEmpty ? [selfLogin].filter { !$0.isEmpty } : authors.map(\.login)

                var listed: [Int: GHPullRequest] = [:]
                for author in logins {
                    for pr in try github.listOpenPRs(slug: repo.slug, author: author) {
                        listed[pr.number] = pr
                    }
                }

                let cachedForRepo = cached.filter { $0.repoSlug == repo.slug }
                var fresh: [ClassifiedPR] = []
                for (number, listPR) in listed {
                    let prior = cachedForRepo.first { $0.number == number }
                    let changed = prior == nil || prior!.updatedAt != listPR.updatedAtMs
                    if changed {
                        let detail = try github.prDetail(slug: repo.slug, number: number)
                        fresh.append(ClassifiedPR(slug: repo.slug, list: listPR, detail: detail))
                    } else if let prior {
                        fresh.append(ClassifiedPR(slug: repo.slug, list: listPR, detail: detailFrom(prior)))
                    }
                }

                var disappeared: [(slug: String, number: Int, outcome: PRDisappearance)] = []
                for row in cachedForRepo where row.state == "OPEN" && listed[row.number] == nil {
                    let outcome = try github.classifyDisappeared(slug: repo.slug, number: row.number)
                    disappeared.append((slug: repo.slug, number: row.number, outcome: outcome))
                }

                let result = PRSync.diff(
                    old: cachedForRepo, fresh: fresh, disappeared: disappeared,
                    selfLogin: selfLogin, config: config, nowMs: nowMs
                )
                try PRStore.upsertPRs(result.upserts, in: db)

                // §3: reuse the shared EventApplier/DatabaseQueue (never fresh); the pause
                // gate lives inside process(event:) so polling/upserts stay live while paused.
                if !result.events.isEmpty {
                    let atx = ApplyTransaction(db: db, applier: applier, paused: pausedProvider())
                    for event in result.events {
                        try atx.process(event: event)
                    }
                }

                perRepoStatus[repo.slug] = RepoStatus(lastSuccessAtMs: nowMs, lastError: nil)
            } catch {
                var status = perRepoStatus[repo.slug] ?? RepoStatus()
                status.lastError = describe(error)
                perRepoStatus[repo.slug] = status
            }
        }

        publish(nowMs: nowMs, perRepoStatus: perRepoStatus, ghUnavailable: ghUnavailable)
    }

    private nonisolated func resolveSelfLogin() -> String? {
        if let cachedSelfLogin { return cachedSelfLogin }
        do {
            let login = try github.selfLogin()
            cachedSelfLogin = login.isEmpty ? nil : login
            return cachedSelfLogin
        } catch {
            return nil
        }
    }

    nonisolated func refreshSelfLogin() {
        pollQueue.async { [weak self] in
            self?.cachedSelfLogin = nil
            _ = self?.resolveSelfLogin()
        }
    }

    private nonisolated func detailFrom(_ pr: PR) -> PRDetail {
        PRDetail(
            number: pr.number, reviewDecision: pr.reviewDecision,
            unresolvedCount: pr.unresolvedCount, lastApprovedReviewAtMs: pr.lastApprovedReviewAt,
            state: pr.state, mergedAtMs: nil, threads: []
        )
    }

    private nonisolated func describe(_ error: Error) -> String {
        if let e = error as? GitHubClientError {
            switch e {
            case .commandFailed(_, let stderr): return LogRedactor.redact(stderr)
            case .decodeFailed: return "解析失败"
            }
        }
        return LogRedactor.redact("\(error)")
    }

    private nonisolated func publish(nowMs: Int64, perRepoStatus: [String: RepoStatus], ghUnavailable: Bool) {
        lastPerRepoStatus = perRepoStatus
        Task { @MainActor in
            var s = self.snapshot
            s.lastPollAtMs = nowMs
            s.perRepoStatus = perRepoStatus
            s.ghUnavailable = ghUnavailable
            s.firstPollComplete = true
            self.snapshot = s
        }
    }
}
