import Foundation

/// Pure derivation of a session's display repo label from its cwd: worktree-aware
/// and collision-disambiguated across a batch of sessions. Kept separate from the
/// single-cwd `repoName` (still used by island strips) so cross-session context is
/// only paid for where the full list is known.
public enum SessionRepo {
    static let worktreeMarker = "/.claude/worktrees/"

    struct Parsed: Equatable {
        let repo: String
        let worktree: String?
        let identity: String
        let parent: String?
    }

    static func parse(cwd: String?) -> Parsed {
        guard let raw = cwd, !raw.isEmpty else {
            return Parsed(repo: "未知目录", worktree: nil, identity: "", parent: nil)
        }
        let trimmed = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        if let marker = trimmed.range(of: worktreeMarker) {
            let repoPath = String(trimmed[..<marker.lowerBound])
            let after = trimmed[marker.upperBound...]
            let worktree = after.split(separator: "/").first.map(String.init)
            return Parsed(repo: basename(repoPath), worktree: worktree,
                          identity: repoPath, parent: parentName(repoPath))
        }
        return Parsed(repo: basename(trimmed), worktree: nil,
                      identity: trimmed, parent: parentName(trimmed))
    }

    /// Display labels index-aligned to `cwds`. Two sessions whose repo names collide
    /// but resolve to different repo paths are prefixed with their parent directory
    /// ("daoai/phoenix" vs "code/phoenix"); worktrees of one repo share the name and
    /// are told apart by the "⌥ <worktree>" suffix instead.
    public static func labels(cwds: [String?]) -> [String] {
        let parsed = cwds.map(parse)
        var identitiesByRepo: [String: Set<String>] = [:]
        for p in parsed { identitiesByRepo[p.repo, default: []].insert(p.identity) }
        return parsed.map { p in
            let collides = (identitiesByRepo[p.repo]?.count ?? 0) > 1
            var base = p.repo
            if collides, let parent = p.parent, !parent.isEmpty {
                base = "\(parent)/\(p.repo)"
            }
            if let worktree = p.worktree, !worktree.isEmpty {
                return "\(base) ⌥ \(worktree)"
            }
            return base
        }
    }

    static func basename(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    static func parentName(_ path: String) -> String? {
        let comps = path.split(separator: "/")
        guard comps.count >= 2 else { return nil }
        return String(comps[comps.count - 2])
    }
}
