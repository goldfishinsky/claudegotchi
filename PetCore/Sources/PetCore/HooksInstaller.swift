import Foundation

public enum HookInstallStatus: String, Equatable {
    case notInstalled, installed, partiallyInstalled
}

public enum HooksInstallerError: Error, Equatable {
    case corruptSettings
}

public enum HooksInstaller {
    private static let tagKey = "_claudegotchi"
    private static let matcherEvents = ["PreToolUse", "PostToolUse"]
    private static let eventArg: [(event: String, arg: String)] = [
        ("PreToolUse", "pre_tool_use"),
        ("PostToolUse", "post_tool_use"),
        ("SessionStart", "session_start"),
        ("UserPromptSubmit", "user_prompt_submit"),
        ("Stop", "stop"),
        ("Notification", "notification"),
    ]

    public static func install(settingsPath: URL, hookBinaryPath: String, nowISO: String) throws {
        var root = try readRoot(settingsPath)
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        let command = shellQuoted(hookBinaryPath)

        for (event, arg) in eventArg {
            var groups = (hooks[event] as? [[String: Any]]) ?? []
            let fullCommand = "\(command) \(arg)"
            let wantsMatcher = matcherEvents.contains(event)

            if let gi = indexOfTaggedGroup(in: groups) {
                var group = groups[gi]
                var leaves = (group["hooks"] as? [[String: Any]]) ?? []
                if let li = leaves.firstIndex(where: { $0[tagKey] as? Bool == true }) {
                    leaves[li]["command"] = fullCommand
                } else {
                    leaves.append(taggedLeaf(fullCommand))
                }
                group["hooks"] = leaves
                groups[gi] = group
            } else {
                var group: [String: Any] = ["hooks": [taggedLeaf(fullCommand)]]
                if wantsMatcher { group["matcher"] = "*" }
                groups.append(group)
            }
            hooks[event] = groups
        }
        root["hooks"] = hooks
        try writeAtomically(root, to: settingsPath, nowISO: nowISO)
    }

    public static func uninstall(settingsPath: URL) throws {
        var root = try readRoot(settingsPath)
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        for event in eventArg.map(\.event) {
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
        guard FileManager.default.fileExists(atPath: settingsPath.path) else { return .notInstalled }
        let root = try readRoot(settingsPath)
        let hooks = (root["hooks"] as? [String: Any]) ?? [:]
        var found = 0
        for event in eventArg.map(\.event) {
            for g in (hooks[event] as? [[String: Any]]) ?? [] {
                if ((g["hooks"] as? [[String: Any]]) ?? []).contains(where: { $0[tagKey] as? Bool == true }) {
                    found += 1
                }
            }
        }
        if found == 0 { return .notInstalled }
        if found == eventArg.count { return .installed }
        return .partiallyInstalled
    }

    // MARK: - helpers

    private static func indexOfTaggedGroup(in groups: [[String: Any]]) -> Int? {
        groups.firstIndex { g in
            ((g["hooks"] as? [[String: Any]]) ?? []).contains { $0[tagKey] as? Bool == true }
        }
    }

    private static func taggedLeaf(_ command: String) -> [String: Any] {
        ["type": "command", "command": command, tagKey: true]
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
        if FileManager.default.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("bak-\(nowISO)")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
        }
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}
