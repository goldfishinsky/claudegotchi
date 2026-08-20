import Foundation

public enum HookInstallStatus: String, Equatable {
    case notInstalled, installed, partiallyInstalled
}

public enum HooksInstallerError: Error, Equatable {
    case corruptSettings
}

public enum HooksInstaller {
    private static let tagKey = "_claudegotchi"

    public enum Platform: Equatable {
        case claude, codex
    }

    private struct Entry {
        let event: String
        let arg: String
        let matcher: String?
        let timeout: Int?
    }

    private static func entries(for platform: Platform) -> [Entry] {
        switch platform {
        case .claude:
            return [
                Entry(event: "PreToolUse", arg: "pre_tool_use", matcher: "*", timeout: nil),
                Entry(event: "PostToolUse", arg: "post_tool_use", matcher: "*", timeout: nil),
                Entry(event: "SessionStart", arg: "session_start", matcher: nil, timeout: nil),
                Entry(event: "UserPromptSubmit", arg: "user_prompt_submit", matcher: nil, timeout: nil),
                Entry(event: "Stop", arg: "stop", matcher: nil, timeout: nil),
                Entry(event: "Notification", arg: "notification", matcher: nil, timeout: nil),
            ]
        case .codex:
            return [
                Entry(event: "SessionStart", arg: "codex_session_start", matcher: nil, timeout: 5),
                Entry(event: "UserPromptSubmit", arg: "codex_user_prompt_submit", matcher: nil, timeout: 5),
                Entry(event: "PreToolUse", arg: "codex_pre_tool_use", matcher: "", timeout: 5),
                Entry(event: "PostToolUse", arg: "codex_post_tool_use", matcher: "", timeout: 5),
                Entry(event: "Stop", arg: "codex_stop", matcher: nil, timeout: 5),
                Entry(event: "PermissionRequest", arg: "codex_permission_request", matcher: nil, timeout: 5),
            ]
        }
    }

    public static func install(settingsPath: URL, hookBinaryPath: String, nowISO: String) throws {
        try install(platform: .claude, settingsPath: settingsPath, hookBinaryPath: hookBinaryPath, nowISO: nowISO)
    }

    public static func install(platform: Platform, settingsPath: URL, hookBinaryPath: String, nowISO: String) throws {
        var root = try readRoot(settingsPath)
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        let command = shellQuoted(hookBinaryPath)

        for entry in entries(for: platform) {
            var groups = (hooks[entry.event] as? [[String: Any]]) ?? []
            let fullCommand = "\(command) \(entry.arg)"

            if let gi = indexOfTaggedGroup(in: groups) {
                var group = groups[gi]
                var leaves = (group["hooks"] as? [[String: Any]]) ?? []
                if let li = leaves.firstIndex(where: { $0[tagKey] as? Bool == true }) {
                    leaves[li]["command"] = fullCommand
                    if let timeout = entry.timeout { leaves[li]["timeout"] = timeout }
                } else {
                    leaves.append(taggedLeaf(fullCommand, timeout: entry.timeout))
                }
                group["hooks"] = leaves
                groups[gi] = group
            } else {
                var group: [String: Any] = ["hooks": [taggedLeaf(fullCommand, timeout: entry.timeout)]]
                if let matcher = entry.matcher { group["matcher"] = matcher }
                groups.append(group)
            }
            hooks[entry.event] = groups
        }
        root["hooks"] = hooks
        try writeAtomically(root, to: settingsPath, nowISO: nowISO)
    }

    public static func uninstall(settingsPath: URL) throws {
        try uninstall(platform: .claude, settingsPath: settingsPath)
    }

    public static func uninstall(platform: Platform, settingsPath: URL) throws {
        var root = try readRoot(settingsPath)
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        for event in entries(for: platform).map(\.event) {
            guard var groups = hooks[event] as? [[String: Any]] else { continue }
            for gi in groups.indices {
                var leaves = (groups[gi]["hooks"] as? [[String: Any]]) ?? []
                leaves.removeAll { $0[tagKey] as? Bool == true }
                groups[gi]["hooks"] = leaves
            }
            groups.removeAll { (($0["hooks"] as? [[String: Any]]) ?? []).isEmpty }
            if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        try writeAtomically(root, to: settingsPath, nowISO: ISO8601DateFormatter().string(from: Date()))
    }

    public static func status(settingsPath: URL) throws -> HookInstallStatus {
        try status(platform: .claude, settingsPath: settingsPath)
    }

    public static func status(platform: Platform, settingsPath: URL) throws -> HookInstallStatus {
        guard FileManager.default.fileExists(atPath: settingsPath.path) else { return .notInstalled }
        let root = try readRoot(settingsPath)
        let hooks = (root["hooks"] as? [String: Any]) ?? [:]
        let events = entries(for: platform)
        var found = 0
        for event in events.map(\.event) {
            for g in (hooks[event] as? [[String: Any]]) ?? [] {
                if ((g["hooks"] as? [[String: Any]]) ?? []).contains(where: { $0[tagKey] as? Bool == true }) {
                    found += 1
                }
            }
        }
        if found == 0 { return .notInstalled }
        if found == events.count { return .installed }
        return .partiallyInstalled
    }

    // MARK: - helpers

    private static func indexOfTaggedGroup(in groups: [[String: Any]]) -> Int? {
        groups.firstIndex { g in
            ((g["hooks"] as? [[String: Any]]) ?? []).contains { $0[tagKey] as? Bool == true }
        }
    }

    private static func taggedLeaf(_ command: String, timeout: Int? = nil) -> [String: Any] {
        var leaf: [String: Any] = ["type": "command", "command": command, tagKey: true]
        if let timeout { leaf["timeout"] = timeout }
        return leaf
    }

    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func readRoot(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            throw HooksInstallerError.corruptSettings
        }
        return dict
    }

    private static func writeAtomically(_ root: [String: Any], to url: URL, nowISO: String) throws {
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]
        )
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existed = fm.fileExists(atPath: url.path)
        if existed {
            let backup = url.appendingPathExtension("bak-\(nowISO)")
            try? fm.removeItem(at: backup)
            try? fm.copyItem(at: url, to: backup)
        }
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: tmp, options: .atomic)
        if existed {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
    }
}
