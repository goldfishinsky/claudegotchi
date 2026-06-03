import Foundation

public typealias PixelFrame = [[UInt8]]

public struct PixelSpeciesDef: Equatable {
    public let id: String
    public let nameZh: String
    public let stages: [(id: String, minXp: Int)]
    public let frames: [String: [PixelFrame]]

    public static func == (lhs: PixelSpeciesDef, rhs: PixelSpeciesDef) -> Bool {
        lhs.id == rhs.id && lhs.nameZh == rhs.nameZh
            && lhs.stages.map(\.id) == rhs.stages.map(\.id)
            && lhs.stages.map(\.minXp) == rhs.stages.map(\.minXp)
            && lhs.frames == rhs.frames
    }
}

public enum PixelSpeciesCatalog {
    public static let palette: [UInt32] = [
        0x0000_0000, // 0 transparent
        0xFF1B_1B1B, // 1 outline
        0xFF4C_AF50, // 2 frog green
        0xFF2E_7D32, // 3 frog dark green
        0xFF9C_CC65, // 4 slime light
        0xFFFF_B74D, // 5 cat orange
        0xFFB0_71F0, // 6 dragon purple
        0xFFFF_FFFF, // 7 eye white
        0xFFE5_7373, // 8 sick flush / cheek
    ]

    public static let all: [PixelSpeciesDef] = [
        def(id: "frog",   nameZh: "小青蛙", body: 2, dark: 3),
        def(id: "slime",  nameZh: "史莱姆", body: 4, dark: 2),
        def(id: "cat",    nameZh: "小猫",   body: 5, dark: 1),
        def(id: "dragon", nameZh: "小龙",   body: 6, dark: 1),
    ]

    public static var ids: [String] { all.map(\.id) }

    public static func def(_ id: String) -> PixelSpeciesDef? {
        all.first { $0.id == id }
    }

    public static func stage(id: String, xp: Int64) -> String {
        guard let d = def(id) else { return "unknown" }
        var current = d.stages.first?.id ?? "unknown"
        for s in d.stages where Int64(s.minXp) <= xp { current = s.id }
        return current
    }

    // MARK: - construction

    private static func def(id: String, nameZh: String, body: UInt8, dark: UInt8) -> PixelSpeciesDef {
        let idle = blob(body: body, dark: dark, eye: 7)
        let happy = blob(body: body, dark: dark, eye: 7, cheek: 8)
        let sick = blob(body: 8, dark: dark, eye: 7)
        let sleeping = blobClosedEyes(body: body, dark: dark)
        return PixelSpeciesDef(
            id: id, nameZh: nameZh,
            stages: [("baby", 0), ("child", 100), ("adult", 400)],
            frames: [
                "idle": [idle, shift(idle)],
                "happy": [happy, shift(happy)],
                "sick": [sick],
                "sleeping": [sleeping],
            ]
        )
    }

    private static func blank() -> PixelFrame {
        Array(repeating: Array(repeating: UInt8(0), count: 16), count: 16)
    }

    private static func blob(body: UInt8, dark: UInt8, eye: UInt8, cheek: UInt8? = nil) -> PixelFrame {
        var g = blank()
        for r in 3...13 {
            for c in 3...12 {
                let edge = (r == 3 || r == 13 || c == 3 || c == 12)
                g[r][c] = edge ? 1 : body
            }
        }
        for c in 4...11 { g[12][c] = dark }
        g[6][5] = eye; g[6][6] = 1
        g[6][9] = eye; g[6][10] = 1
        if let cheek {
            g[8][4] = cheek; g[8][11] = cheek
        }
        return g
    }

    private static func blobClosedEyes(body: UInt8, dark: UInt8) -> PixelFrame {
        var g = blob(body: body, dark: dark, eye: 1)
        g[6][5] = 1; g[6][6] = 1; g[6][9] = 1; g[6][10] = 1
        return g
    }

    private static func shift(_ frame: PixelFrame) -> PixelFrame {
        var g = blank()
        for r in 1..<16 { g[r] = frame[r - 1] }
        return g
    }
}
