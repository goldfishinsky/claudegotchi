import Foundation

/// Shared marker contract: the hook writes it to the tty, the app scans for it —
/// both derive the same token from a session id so the window matches.
public enum TitleMarker {
    public static let glyph = "❖"
    public static let tokenHexCount = 6
    static let codexPrefix = "codex-"

    /// `❖ab12cd` — the glyph plus the first six characters of the raw session
    /// uuid (Codex ids are stored `codex-<uuid>`; the prefix is stripped first).
    public static func token(forSessionId sessionId: String) -> String {
        var id = sessionId
        if id.hasPrefix(codexPrefix) { id.removeFirst(codexPrefix.count) }
        let head = id.filter { $0 != "-" }.prefix(tokenHexCount)
        return glyph + head
    }

    /// OSC-0 title escape: `ESC ] 0 ; <token> <repo> BEL`.
    public static func escapeSequence(token: String, repo: String) -> String {
        let label = repo.isEmpty ? token : "\(token) \(repo)"
        return "\u{1b}]0;\(label)\u{07}"
    }

    public static func repoLabel(cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "" }
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        return trimmed.split(separator: "/").last.map(String.init) ?? ""
    }

    // MARK: - enable flag (default ON)

    /// Presence of this file disables injection; its absence (fresh install) leaves
    /// markers on. A single `stat` keeps the per-event check cheap for the helper.
    public static func disabledFlagURL(appSupport: URL) -> URL {
        appSupport
            .appendingPathComponent("claudegotchi")
            .appendingPathComponent("title-markers.disabled")
    }

    public static func defaultDisabledFlagURL() -> URL {
        disabledFlagURL(appSupport: FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
    }

    public static func isEnabled(flagURL: URL = TitleMarker.defaultDisabledFlagURL(),
                                 fileManager: FileManager = .default) -> Bool {
        !fileManager.fileExists(atPath: flagURL.path)
    }

    @discardableResult
    public static func setEnabled(_ enabled: Bool,
                                  flagURL: URL = TitleMarker.defaultDisabledFlagURL(),
                                  fileManager: FileManager = .default) -> Bool {
        if enabled {
            try? fileManager.removeItem(at: flagURL)
        } else {
            try? fileManager.createDirectory(at: flagURL.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
            fileManager.createFile(atPath: flagURL.path, contents: Data())
        }
        return isEnabled(flagURL: flagURL, fileManager: fileManager)
    }
}
