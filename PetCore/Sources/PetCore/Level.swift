import Foundation

public enum Level {
    public static func compute(xp: Int64) -> Int {
        guard xp > 0 else { return 0 }
        return Int(Double(xp / 100).squareRoot().rounded(.down))
    }

    public static func xpForLevel(_ lv: Int) -> Int64 {
        Int64(lv * lv) * 100
    }
}
