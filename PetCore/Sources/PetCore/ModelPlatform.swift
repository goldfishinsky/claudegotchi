import Foundation

public enum ModelPlatform {
    public static let codex = "codex"
    public static let claudeCode = "claude-code"

    public static func infer(model: String) -> String {
        let m = model.lowercased()
        if m.hasPrefix("gpt-") || m.hasPrefix("codex-") { return codex }
        if m.hasPrefix("o"), let second = m.dropFirst().first, second.isNumber { return codex }
        return claudeCode
    }

    /// Dominant platform by lifetime tokens; retained for the legacy sync field.
    public static func dominant(models: [ModelUsage]) -> String {
        var codexTokens: Int64 = 0
        var claudeTokens: Int64 = 0
        for u in models {
            let total = u.tokensIn + u.tokensOut
            if u.platform == codex { codexTokens += total } else { claudeTokens += total }
        }
        return codexTokens > claudeTokens ? codex : claudeCode
    }
}
