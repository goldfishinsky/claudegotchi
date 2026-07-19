import Foundation

/// Pure, testable rule for hiding noise sessions everywhere they surface (agent
/// list, island badge, permission alerts, completion reveals). The App owns
/// persistence and passes plain pattern arrays; this type stays value-only.
public struct SessionFilter: Equatable {
    public let directoryPatterns: [String]
    public let promptPrefixPatterns: [String]

    public init(directoryPatterns: [String] = [], promptPrefixPatterns: [String] = []) {
        self.directoryPatterns = directoryPatterns.filter { !$0.isEmpty }
        self.promptPrefixPatterns = promptPrefixPatterns.filter { !$0.isEmpty }
    }

    public static let empty = SessionFilter()

    public var isEmpty: Bool { directoryPatterns.isEmpty && promptPrefixPatterns.isEmpty }

    /// Hides a session whose cwd CONTAINS any directory pattern, or whose
    /// title/first prompt (trimmed) STARTS WITH any prompt-prefix pattern.
    public func hides(cwd: String?, title: String?) -> Bool {
        if let cwd, directoryPatterns.contains(where: { cwd.contains($0) }) { return true }
        if let title {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if promptPrefixPatterns.contains(where: { trimmed.hasPrefix($0) }) { return true }
        }
        return false
    }
}

/// A built-in filter rule the user sees and can toggle. Presets ship enabled and
/// carry the harness noise prefixes that were previously hard-coded, so they are
/// now visible and controllable rather than baked in.
public struct SessionFilterPreset: Equatable, Identifiable {
    public enum Kind: String, Equatable { case directory, promptPrefix }
    public let id: String
    public let kind: Kind
    public let pattern: String
    public let label: String

    public init(id: String, kind: Kind, pattern: String, label: String) {
        self.id = id
        self.kind = kind
        self.pattern = pattern
        self.label = label
    }
}

public enum SessionFilterPresets {
    public static let all: [SessionFilterPreset] = [
        SessionFilterPreset(id: "preset.dir.hookprobe", kind: .directory,
                            pattern: "/hookprobe", label: "探针会话"),
        SessionFilterPreset(id: "preset.dir.claudemem", kind: .directory,
                            pattern: "/.claude-mem", label: "Claude-Mem 后台会话"),
        SessionFilterPreset(id: "preset.prompt.tasknotification", kind: .promptPrefix,
                            pattern: "<task-notification>", label: "任务通知"),
        SessionFilterPreset(id: "preset.prompt.localcommandcaveat", kind: .promptPrefix,
                            pattern: "<local-command-caveat>", label: "本地命令说明"),
        SessionFilterPreset(id: "preset.prompt.commandname", kind: .promptPrefix,
                            pattern: "<command-name>", label: "斜杠命令"),
        SessionFilterPreset(id: "preset.prompt.system", kind: .promptPrefix,
                            pattern: "<system", label: "系统消息"),
    ]

    /// The prompt-prefix presets, used unconditionally to de-noise titles so
    /// title selection stays identical regardless of which presets are toggled.
    public static let promptPrefixPatterns: [String] =
        all.filter { $0.kind == .promptPrefix }.map(\.pattern)
}
