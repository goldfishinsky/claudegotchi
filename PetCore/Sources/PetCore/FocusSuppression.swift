import Foundation

/// Pure decision for "the user is already looking at this session's terminal".
/// Suppresses auto-expansion (completion reveal, permission strip) when the
/// frontmost focused window title contains the session cwd's basename. Without
/// AX trust there is no title to inspect, so suppression never applies and this
/// path never prompts for accessibility.
public enum FocusSuppression {
    public static func suppresses(axTrusted: Bool, focusedWindowTitle: String?, cwd: String?) -> Bool {
        guard axTrusted, let title = focusedWindowTitle, let cwd else { return false }
        let base = basename(cwd)
        guard !base.isEmpty else { return false }
        return title.lowercased().contains(base.lowercased())
    }

    static func basename(_ cwd: String) -> String {
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        return trimmed.split(separator: "/").last.map(String.init) ?? ""
    }
}
