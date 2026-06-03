import Foundation
import GRDB
import PetCore

final class FixRunner {
    private let git: GitRunner
    private let claude: ClaudeRunner
    private let gh: GitHubClient
    private let db: DatabaseQueue
    private let config: ConfigYAML
    private let worktreesRoot: URL

    init(git: GitRunner, claude: ClaudeRunner, gh: GitHubClient,
         db: DatabaseQueue, config: ConfigYAML, worktreesRoot: URL) {
        self.git = git
        self.claude = claude
        self.gh = gh
        self.db = db
        self.config = config
        self.worktreesRoot = worktreesRoot
    }

    /// The exact string surfaced to the UI (never executed by the app).
    static func integrationCommand(number: Int, headBranch: String) -> String {
        "git push origin claudegotchi/fix/\(number):\(headBranch)"
    }

    func run(job: FixJob, repoPath: URL, headBranch: String, prNumber: Int, slug: String,
             onProgress: @escaping (ClaudeProgress) -> Void, cancel: CancelToken) -> FixJob {
        let jobId = job.id!
        let jobDir = worktreesRoot
            .appendingPathComponent(slug, isDirectory: true)
            .appendingPathComponent(String(prNumber), isDirectory: true)

        // --- Guards (state checkout) ---
        if cancel.isCancelled { return cancelOut(jobId: jobId, jobDir: jobDir, repoPath: repoPath) }

        guard git.isRepo(repoPath) else {
            return fail(jobId: jobId, reason: "本地路径不是 git 仓库")
        }
        guard RefValidator.isValidBranch(headBranch), RefValidator.isValidSlug(slug) else {
            return fail(jobId: jobId, reason: "分支或仓库名非法，已拒绝执行")
        }
        do {
            let remote = try git.remoteSlug(repoPath)
            guard remote == slug else {
                return fail(jobId: jobId, reason: "本地仓库 origin 与 owner/name 不匹配")
            }
        } catch {
            return fail(jobId: jobId, reason: LogRedactor.redact("\(error)"))
        }

        // --- Reconcile-before-add: clear any registered worktree at job_dir ---
        do {
            let registered = try git.worktreeList(repoPath)
            if registered.contains(jobDir.path) {
                try git.removeWorktree(repoPath, dir: jobDir)
            }
        } catch {
            return fail(jobId: jobId, reason: "工作目录被占用")
        }

        if cancel.isCancelled { return cancelOut(jobId: jobId, jobDir: jobDir, repoPath: repoPath) }

        // --- checkout transition: fetch + worktree add -B ---
        do {
            try git.fetch(repoPath, branch: headBranch)
            try git.addWorktree(repoPath, branch: "claudegotchi/fix/\(prNumber)",
                                dir: jobDir, startPoint: "origin/\(headBranch)")
        } catch {
            return fail(jobId: jobId, reason: LogRedactor.redact("\(error)"))
        }
        do {
            try db.write { conn in
                try FixJobStore.markCheckout(id: jobId, worktreePath: jobDir.path,
                                             startedAt: nowMs(), in: conn)
            }
        } catch {
            return fail(jobId: jobId, reason: LogRedactor.redact("\(error)"))
        }

        if cancel.isCancelled { return cancelOut(jobId: jobId, jobDir: jobDir, repoPath: repoPath) }

        // --- prompt (still checkout) ---
        let prompt: String
        do {
            let detail = try gh.prDetail(slug: slug, number: prNumber)
            prompt = FixPromptBuilder.build(threads: detail.threads, branch: headBranch)
            try db.write { conn in try FixJobStore.setPrompt(id: jobId, prompt: prompt, in: conn) }
        } catch {
            return fail(jobId: jobId, reason: LogRedactor.redact("\(error)"))
        }

        if cancel.isCancelled { return cancelOut(jobId: jobId, jobDir: jobDir, repoPath: repoPath) }

        // --- run transition (checkout → running) ---
        let logURL = jobDir.appendingPathComponent("fix.log")
        FileManager.default.createFile(atPath: logURL.path, contents: Data(),
                                       attributes: [.posixPermissions: 0o600])
        do {
            try db.write { conn in try FixJobStore.markRunning(id: jobId, logPath: logURL.path, in: conn) }
        } catch {
            return fail(jobId: jobId, reason: LogRedactor.redact("\(error)"))
        }

        let exitCode: Int32
        do {
            exitCode = try claude.runFix(
                prompt: prompt, cwd: jobDir,
                allowedTools: config.work.fixAllowedTools,
                disallowedTools: config.work.fixDisallowedTools,
                permissionMode: config.work.fixPermissionMode,
                timeout: TimeInterval(config.work.fixTimeoutSeconds),
                logURL: logURL, onProgress: onProgress, cancel: cancel
            )
        } catch {
            return fail(jobId: jobId, reason: LogRedactor.redact("修复超时或执行失败：\(error)"),
                        logPath: logURL.path)
        }

        // --- finish ---
        let state = FixJobMachine.next(.running, exit: exitCode, canceled: cancel.isCancelled)
        if state == .canceled {
            try? git.removeWorktree(repoPath, dir: jobDir)
            return finish(jobId: jobId, state: .canceled, exitCode: exitCode,
                          commitSha: nil, logPath: logURL.path, error: "已取消")
        }

        var commitSha: String?
        if state == .succeeded && config.work.fixCommit {
            commitSha = try? git.commitAll(
                jobDir,
                message: "claudegotchi: address review feedback on \(headBranch)"
            )
        }
        let error = state == .failed ? "修复失败，详见日志" : nil
        return finish(jobId: jobId, state: state, exitCode: exitCode,
                      commitSha: commitSha, logPath: logURL.path, error: error)
    }

    // MARK: - Terminal helpers

    private func fail(jobId: Int64, reason: String, logPath: String? = nil) -> FixJob {
        finish(jobId: jobId, state: .failed, exitCode: nil,
               commitSha: nil, logPath: logPath, error: LogRedactor.redact(reason))
    }

    private func cancelOut(jobId: Int64, jobDir: URL, repoPath: URL) -> FixJob {
        try? git.removeWorktree(repoPath, dir: jobDir)
        return finish(jobId: jobId, state: .canceled, exitCode: nil,
                      commitSha: nil, logPath: nil, error: "已取消")
    }

    private func finish(jobId: Int64, state: FixJobState, exitCode: Int32?,
                        commitSha: String?, logPath: String?, error: String?) -> FixJob {
        let ended = nowMs()
        try? db.write { conn in
            try FixJobStore.finish(id: jobId, state: state, exitCode: exitCode,
                                   commitSha: commitSha, logPath: logPath,
                                   error: error, endedAt: ended, in: conn)
        }
        let refetched = try? db.read { try FixJobStore.job(id: jobId, in: $0) }
        return refetched ?? FixJob(id: jobId, prRowid: 0, repoSlug: "", prNumber: 0,
                                   state: state, createdAt: ended)
    }

    private func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}
