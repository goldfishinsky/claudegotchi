import Foundation
import PetCore

enum TokenFormat {
    static func compact(_ tokens: Int64) -> String {
        if tokens <= 0 { return "0" }
        if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        }
        let label = PRTabFormat.tokenLabel(Int(min(tokens, Int64(Int.max))))
        return label.isEmpty ? "0" : label.replacingOccurrences(of: " tok", with: "")
    }

    static func compactXP(_ xp: Int64) -> String {
        if xp >= 1_000_000 { return String(format: "%.1fM", Double(xp) / 1_000_000) }
        if xp >= 1_000 { return String(format: "%.1fk", Double(xp) / 1_000) }
        return "\(xp)"
    }
}
