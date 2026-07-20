import Foundation

/// Merge-safe manager for the one `env` entry that stops Claude Code overwriting
/// our jump markers on single-title emulators (Warp, Ghostty).
public enum NativeTitleSetting {
    public static let envKey = "CLAUDE_CODE_DISABLE_TERMINAL_TITLE"
    public static let disabledValue = "1"

    public enum SettingError: Error, Equatable { case corruptSettings }

    public static func isDisabled(settingsPath: URL) throws -> Bool {
        let root = try readRoot(settingsPath)
        let env = (root["env"] as? [String: Any]) ?? [:]
        return (env[envKey] as? String) == disabledValue
    }

    public static func setDisabled(_ disabled: Bool, settingsPath: URL, nowISO: String) throws {
        var root = try readRoot(settingsPath)
        var env = (root["env"] as? [String: Any]) ?? [:]
        if disabled {
            env[envKey] = disabledValue
        } else {
            // only reclaim the exact value we wrote; a user-authored value stays.
            if (env[envKey] as? String) == disabledValue { env.removeValue(forKey: envKey) }
        }
        if env.isEmpty { root.removeValue(forKey: "env") } else { root["env"] = env }
        try writeAtomically(root, to: settingsPath, nowISO: nowISO)
    }

    private static func readRoot(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            throw SettingError.corruptSettings
        }
        return dict
    }

    private static func writeAtomically(_ root: [String: Any], to url: URL, nowISO: String) throws {
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
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
