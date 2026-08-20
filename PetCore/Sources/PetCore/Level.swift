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

/// Long-horizon milestones are deliberately separate from the three sprite
/// shapes (baby / child / adult). The pet can keep earning visible progression
/// for years without requiring every milestone to replace its artwork.
public enum GrowthJourney {
    public struct Milestone: Equatable, Sendable {
        public let id: String
        public let nameZh: String
        public let minXp: Int64

        public init(id: String, nameZh: String, minXp: Int64) {
            self.id = id
            self.nameZh = nameZh
            self.minXp = minXp
        }
    }

    public static let milestones: [Milestone] = [
        .init(id: "newborn", nameZh: "初生", minXp: 0),
        .init(id: "young", nameZh: "幼年", minXp: 100),
        .init(id: "adult", nameZh: "成年", minXp: 400),
        .init(id: "thriving", nameZh: "茁壮", minXp: 2_500),
        .init(id: "companion", nameZh: "伙伴", minXp: 10_000),
        .init(id: "bonded", nameZh: "默契", minXp: 50_000),
        .init(id: "awakened", nameZh: "觉醒", minXp: 250_000),
        .init(id: "starlit", nameZh: "星辉", minXp: 1_000_000),
        .init(id: "legendary", nameZh: "传说", minXp: 5_000_000),
        .init(id: "mythic", nameZh: "神话", minXp: 25_000_000),
        .init(id: "eternal", nameZh: "永恒羁绊", minXp: 100_000_000),
    ]

    public static func current(xp: Int64) -> Milestone {
        milestones.last(where: { $0.minXp <= xp }) ?? milestones[0]
    }

    public static func next(xp: Int64) -> Milestone? {
        milestones.first(where: { $0.minXp > xp })
    }

    public static func progress(xp: Int64) -> Double {
        let current = current(xp: xp)
        guard let next = next(xp: xp) else { return 1 }
        let span = max(1, next.minXp - current.minXp)
        return min(1, max(0, Double(xp - current.minXp) / Double(span)))
    }
}
