import Foundation

public protocol GitRunner {
    func isRepo(_ path: URL) -> Bool
    func remoteSlug(_ path: URL) throws -> String?
    func fetch(_ path: URL, branch: String) throws
    func worktreeList(_ path: URL) throws -> [String]
    func addWorktree(_ path: URL, branch fixBranch: String, dir: URL, startPoint: String) throws
    func removeWorktree(_ path: URL, dir: URL) throws
    func isClean(_ dir: URL) throws -> Bool
    func commitAll(_ dir: URL, message: String) throws -> String
}

public enum GitRunnerError: Error, Equatable {
    case commandFailed(status: Int32, stderr: String)
}

public final class CLIGitRunner: GitRunner {
    private static let hardening = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"]
    private let runner: ProcessRunner
    public init(runner: ProcessRunner) { self.runner = runner }

    public func isRepo(_ path: URL) -> Bool {
        let r = try? git(in: path, ["rev-parse", "--is-inside-work-tree"])
        return (r?.status ?? 1) == 0
    }

    public func remoteSlug(_ path: URL) throws -> String? {
        let r = try git(in: path, ["remote", "get-url", "origin"])
        guard r.status == 0 else { return nil }
        let url = (String(data: r.stdout, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.slug(fromRemote: url)
    }

    public func fetch(_ path: URL, branch: String) throws {
        try ok(git(in: path, ["fetch", "origin", "--", branch]))
    }

    public func worktreeList(_ path: URL) throws -> [String] {
        let r = try git(in: path, ["worktree", "list", "--porcelain"])
        try ok(r)
        let text = String(data: r.stdout, encoding: .utf8) ?? ""
        return text.split(separator: "\n").compactMap { line in
            line.hasPrefix("worktree ") ? String(line.dropFirst("worktree ".count)) : nil
        }
    }

    public func addWorktree(_ path: URL, branch fixBranch: String, dir: URL, startPoint: String) throws {
        try ok(git(in: path, ["worktree", "add", "-B", fixBranch, dir.path, "--", startPoint]))
    }

    public func removeWorktree(_ path: URL, dir: URL) throws {
        try ok(git(in: path, ["worktree", "remove", "--force", dir.path]))
        try ok(git(in: path, ["worktree", "prune"]))
    }

    public func isClean(_ dir: URL) throws -> Bool {
        let r = try git(in: dir, ["status", "--porcelain"])
        try ok(r)
        return (String(data: r.stdout, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func commitAll(_ dir: URL, message: String) throws -> String {
        try ok(git(in: dir, ["add", "-A"]))
        try ok(git(in: dir, ["commit", "-m", message]))
        let r = try git(in: dir, ["rev-parse", "HEAD"])
        try ok(r)
        return (String(data: r.stdout, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func git(in path: URL, _ args: [String]) throws -> ProcessResult {
        try runner.run("git", Self.hardening + ["-C", path.path] + args, cwd: nil, timeout: 120)
    }

    @discardableResult
    private func ok(_ r: ProcessResult) throws -> ProcessResult {
        guard r.status == 0 else {
            throw GitRunnerError.commandFailed(status: r.status, stderr: r.stderr)
        }
        return r
    }

    static func slug(fromRemote url: String) -> String? {
        var s = url
        if let r = s.range(of: "github.com") {
            s = String(s[r.upperBound...])
        } else {
            return nil
        }
        if s.hasPrefix(":") || s.hasPrefix("/") { s.removeFirst() }
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        let parts = s.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return "\(parts[parts.count - 2])/\(parts[parts.count - 1])"
    }
}
