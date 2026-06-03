import Foundation
import GRDB
import PetCore

@MainActor
final class FixCoordinator: ObservableObject {
    struct PendingJob {
        let jobId: Int64
        let prRowid: Int64
        let slug: String
        let number: Int
        let repoPath: URL
        let headBranch: String
    }

    @Published private(set) var progress: [Int64: ClaudeProgress] = [:]

    private let db: DatabaseQueue
    private let makeRunner: () -> FixRunner
    private let git: GitRunner
    private let config: ConfigYAML

    // All mutation of queue/lockedSlugs/cancelTokens/runningJobId happens on this serial queue.
    private let serial = DispatchQueue(label: "fix.coordinator")
    private let work = DispatchQueue(label: "fix.coordinator.work", attributes: .concurrent)

    private var queue: [PendingJob] = []
    private var lockedSlugs: Set<String> = []
    private var cancelTokens: [Int64: CancelToken] = [:]
    private var runningJobId: Int64?

    init(db: DatabaseQueue, makeRunner: @escaping () -> FixRunner,
         git: GitRunner, config: ConfigYAML) {
        self.db = db
        self.makeRunner = makeRunner
        self.git = git
        self.config = config
    }

    nonisolated func enqueue(prRowid: Int64, slug: String, number: Int,
                             repoPath: URL, headBranch: String) {
        let createdAt = Int64(Date().timeIntervalSince1970 * 1000)
        var job = FixJob(prRowid: prRowid, repoSlug: slug, prNumber: number,
                         state: .queued, createdAt: createdAt)
        guard let jobId = try? db.write({ conn -> Int64 in
            try job.insert(conn)
            return job.id!
        }) else { return }

        serial.async { [weak self] in
            guard let self else { return }
            self.queue.append(PendingJob(jobId: jobId, prRowid: prRowid, slug: slug,
                                         number: number, repoPath: repoPath,
                                         headBranch: headBranch))
            self.pump()
        }
    }

    nonisolated func cancel(jobId: Int64) {
        serial.async { [weak self] in
            self?.cancelTokens[jobId]?.cancel()
        }
    }

    /// Called from applicationWillTerminate — SIGTERMs every live fix process group.
    nonisolated func terminateAll() {
        serial.sync { [weak self] in
            self?.cancelTokens.values.forEach { $0.cancel() }
        }
    }

    /// Call once at launch, before the first pump.
    nonisolated func reconcileOnLaunch() {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let inFlight = (try? db.read { try FixJobStore.inFlightJobs(in: $0) }) ?? []
        for job in inFlight {
            if let wt = job.worktreePath,
               let repoPath = repoPath(forSlug: job.repoSlug) {
                try? git.removeWorktree(repoPath, dir: URL(fileURLWithPath: wt))
            }
            try? db.write { conn in
                try FixJobStore.finish(id: job.id!, state: .failed, exitCode: nil,
                                       commitSha: nil, logPath: job.logPath,
                                       error: "应用在修复中途重启", endedAt: now, in: conn)
            }
        }
        // queued rows remain queued; resume them via the queue + pump.
        let queued = (try? db.read { try FixJobStore.queuedJobs(in: $0) }) ?? []
        serial.async { [weak self] in
            guard let self else { return }
            for job in queued {
                guard let repoPath = self.repoPath(forSlug: job.repoSlug) else { continue }
                self.queue.append(PendingJob(jobId: job.id!, prRowid: job.prRowid,
                                             slug: job.repoSlug, number: job.prNumber,
                                             repoPath: repoPath, headBranch: ""))
            }
            self.pump()
        }
    }

    // MARK: - Pump (serial queue only)

    private func pump() {
        guard runningJobId == nil else { return }
        guard let idx = queue.firstIndex(where: { !lockedSlugs.contains($0.slug) }) else { return }
        let pending = queue.remove(at: idx)

        lockedSlugs.insert(pending.slug)
        runningJobId = pending.jobId
        let token = CancelToken()
        cancelTokens[pending.jobId] = token

        let runner = makeRunner()
        work.async { [weak self] in
            let onProgress: (ClaudeProgress) -> Void = { p in
                Task { @MainActor in self?.progress[pending.jobId] = p }
            }
            let headBranch = pending.headBranch.isEmpty
                ? (self?.resolveHeadBranch(pending.prRowid) ?? pending.headBranch)
                : pending.headBranch
            _ = runner.run(job: FixJob(id: pending.jobId, prRowid: pending.prRowid,
                                       repoSlug: pending.slug, prNumber: pending.number,
                                       state: .queued, createdAt: 0),
                           repoPath: pending.repoPath, headBranch: headBranch,
                           prNumber: pending.number, slug: pending.slug,
                           onProgress: onProgress, cancel: token)
            self?.serial.async {
                guard let self else { return }
                self.lockedSlugs.remove(pending.slug)
                self.cancelTokens[pending.jobId] = nil
                self.runningJobId = nil
                Task { @MainActor in self.progress[pending.jobId] = nil }
                self.pump()
            }
        }
    }

    private func resolveHeadBranch(_ prRowid: Int64) -> String? {
        try? db.read { conn in
            try String.fetchOne(conn, sql: "SELECT head_branch FROM pr WHERE id = ?",
                                arguments: [prRowid])
        }
    }

    private func repoPath(forSlug slug: String) -> URL? {
        let path = try? db.read { conn in
            try String.fetchOne(conn, sql: "SELECT local_path FROM watched_repo WHERE slug = ?",
                                arguments: [slug])
        }
        guard let path = path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
}
