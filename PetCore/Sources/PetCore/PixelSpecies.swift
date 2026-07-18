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
        0xFF3A_2E28, // 1 outline (warm dark brown)
        0xFFFF_FFFF, // 2 eye white
        0xFF4A_3A34, // 3 pupil
        0xFFFF_9DB4, // 4 blush
        0xFFC2_CCEE, // 5 sleep Z
        0xFFAF_C894, // 6 sick body tint
        0xFF8C_C4F2, // 7 sweat
        0xFF83_CE63, // 8 frog body
        0xFF4E_9B3A, // 9 frog dark
        0xFFE7_F3C0, // 10 frog belly
        0xFFFF_93C0, // 11 slime body
        0xFFE1_62A0, // 12 slime dark
        0xFFFF_D2E6, // 13 slime gloss
        0xFFFF_C178, // 14 cat body
        0xFFE8_925A, // 15 cat dark
        0xFFFF_F1DC, // 16 cat light
        0xFFB4_9BF0, // 17 dragon body
        0xFF84_68CE, // 18 dragon dark
        0xFFF6_E1A8, // 19 dragon gold
        0xFFB7_ADA0, // 20 prop: laptop shell (warm gray)
        0xFF9F_E0E8, // 21 prop: screen glow / spark (soft cyan)
        0xFFF0_6A82, // 22 prop: umeboshi / heart (warm red)
        0xFFE0_A96B, // 23 prop: bento box (tan)
        0xFFF2_946B, // 24 prop: salmon (food accent)
        0xFFFF_D36B, // 25 prop: confetti gold
    ]

    public static let all: [PixelSpeciesDef] = [frog(), slime(), cat(), dragon()]

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

    // MARK: - palette bindings

    private struct Ink { let body, dark, light, accent: UInt8 }

    private static func px(_ ch: Character, _ ink: Ink) -> UInt8 {
        switch ch {
        case "#": return 1
        case "w": return 2
        case "x": return 3
        case "*": return 4
        case "z": return 5
        case "s": return 6
        case ",": return 7
        case "O": return ink.body
        case "o": return ink.dark
        case "+": return ink.light
        case "^": return ink.accent
        default: return 0
        }
    }

    private static func f(_ rows: [String], _ ink: Ink) -> PixelFrame {
        rows.map { $0.map { px($0, ink) } }
    }

    // MARK: - grid transforms (operate on 16×16 char rows)

    private static func stamp(_ g: [String], _ pts: [(Int, Int, Character)]) -> [String] {
        var m = g.map(Array.init)
        for (r, c, ch) in pts where r >= 0 && r < 16 && c >= 0 && c < 16 { m[r][c] = ch }
        return m.map { String($0) }
    }

    private static func squash(_ g: [String]) -> [String] {
        var m = g.map(Array.init)
        let split = 9
        for r in stride(from: split, through: 1, by: -1) { m[r] = m[r - 1] }
        m[0] = Array(repeating: ".", count: 16)
        return m.map { String($0) }
    }

    private static func bounce(_ g: [String], up n: Int) -> [String] {
        let src = g.map(Array.init)
        var out = Array(repeating: Array(repeating: Character("."), count: 16), count: 16)
        for r in 0..<16 where r + n < 16 { out[r] = src[r + n] }
        return out.map { String($0) }
    }

    private static func sickly(_ g: [String]) -> [String] {
        g.map { row in String(row.map { "O+^".contains($0) ? Character("s") : $0 }) }
    }

    private static func closeEyes(_ g: [String]) -> [String] {
        var m = g.map(Array.init)
        var pts: [(Int, Int)] = []
        for r in 0..<16 { for c in 0..<16 where m[r][c] == "w" || m[r][c] == "x" { pts.append((r, c)) } }
        for side in [pts.filter { $0.1 < 8 }, pts.filter { $0.1 >= 8 }] where !side.isEmpty {
            let maxR = side.map(\.0).max()!
            let minC = side.map(\.1).min()!, maxC = side.map(\.1).max()!
            for (r, c) in side { m[r][c] = "O" }
            for c in minC...maxC { m[maxR][c] = "#" }
        }
        return m.map { String($0) }
    }

    // MARK: - animation assembly

    private struct Feat {
        let mouthRow: Int
        let mouthCols: [Int]
        let cheek: [(Int, Int)]
        let z: [(Int, Int)]
        let sweat: (Int, Int)
    }

    private static func anims(_ base: [String], _ ink: Ink, _ ft: Feat, sleep: [String]? = nil) -> [String: [PixelFrame]] {
        let smile = ft.mouthCols.map { (ft.mouthRow, $0, Character("#")) }
            + [(ft.mouthRow - 1, ft.mouthCols.first!, Character("#")),
               (ft.mouthRow - 1, ft.mouthCols.last!, Character("#"))]
        let blush = ft.cheek.map { ($0.0, $0.1, Character("*")) }
        let happy = stamp(base, smile + blush)

        let sickBase = sickly(closeEyes(base))
        let frown = ft.mouthCols.map { (ft.mouthRow, $0, Character("o")) }
        let sick0 = stamp(sickBase, frown + [(ft.sweat.0, ft.sweat.1, Character(","))])
        let sick1 = stamp(squash(sickBase), [(ft.sweat.0 + 1, ft.sweat.1, Character(","))])

        let slp = sleep ?? closeEyes(base)
        let z0 = stamp(slp, [(ft.z[0].0, ft.z[0].1, Character("z"))])
        let z1 = stamp(slp, [(ft.z[0].0, ft.z[0].1, Character("z")), (ft.z[1].0, ft.z[1].1, Character("z"))])

        return [
            "idle": [f(base, ink), f(squash(base), ink)],
            "happy": [f(bounce(happy, up: 1), ink), f(happy, ink)],
            "sick": [f(sick0, ink), f(sick1, ink)],
            "sleeping": [f(z0, ink), f(z1, ink)],
        ]
    }

    private static func assemble(
        id: String, nameZh: String, ink: Ink,
        stages: [(stage: String, base: [String], feat: Feat, sleep: [String]?)]
    ) -> PixelSpeciesDef {
        var frames: [String: [PixelFrame]] = [:]
        for s in stages {
            for (k, v) in anims(s.base, ink, s.feat, sleep: s.sleep) { frames["\(s.stage)/\(k)"] = v }
        }
        let adult = stages.first { $0.stage == "adult" }!
        for (k, v) in anims(adult.base, ink, adult.feat, sleep: adult.sleep) { frames[k] = v }
        return PixelSpeciesDef(
            id: id, nameZh: nameZh,
            stages: [("baby", 0), ("child", 100), ("adult", 400)],
            frames: frames
        )
    }

    // MARK: - frog 小青蛙

    private static func frog() -> PixelSpeciesDef {
        let ink = Ink(body: 8, dark: 9, light: 10, accent: 9)
        let baby = [
            "................",
            "....######......",
            "...#OOOOOOOO#...",
            "..#OOOOOOOOOO#..",
            ".#OO#ww##ww#OO#.",
            ".#OO#wx##xw#OO#.",
            ".#OOOOOOOOOOOO#.",
            ".#OOOOOOOOOOOO#.",
            ".#OOO++++++OOO#.",
            ".#OOO+oooo+OOO#.",
            ".#OOO++++++OOO#.",
            "..#OOOOOOOOOO#..",
            "..#OOOOOOOOOO#..",
            "...oo#..#oo.....",
            "................",
            "................",
        ]
        let child = [
            "................",
            "...##....##.....",
            "..#ww#..#ww#....",
            "..#wx#..#xw#....",
            "..#OOOOOOOOOO#..",
            ".#OOOOOOOOOOOO#.",
            ".#OOOOOOOOOOOO#.",
            ".#OO++++++++OO#.",
            ".#O++oooooo++O#.",
            ".#O++++++++++O#.",
            ".#OO++++++++OO#.",
            "..#OOOOOOOOOO#..",
            "..#OOOOOOOOOO#..",
            "...oo#..#oo.....",
            "................",
            "................",
        ]
        let adult = [
            "................",
            "...##......##...",
            "..#ww#....#ww#..",
            "..#wx#....#xw#..",
            ".#OOOOOOOOOOOO#.",
            "#OOOOOOOOOOOOOO#",
            "#OOOOOOOOOOOOOO#",
            "#OO++++++++++OO#",
            "#O+++oooooo+++O#",
            "#O++++++++++++O#",
            "#OO++++++++++OO#",
            ".#OO++++++++OO#.",
            "..#OOOOOOOOOO#..",
            "..#OOOOOOOOOO#..",
            ".oo#o....o#oo...",
            "................",
        ]
        return assemble(id: "frog", nameZh: "小青蛙", ink: ink, stages: [
            ("baby", baby, Feat(mouthRow: 9, mouthCols: [6, 7, 8, 9], cheek: [(7, 3), (7, 4), (7, 11), (7, 12)], z: [(2, 13), (0, 13)], sweat: (4, 12)), nil),
            ("child", child, Feat(mouthRow: 8, mouthCols: [5, 6, 7, 8, 9, 10], cheek: [(6, 3), (6, 4), (6, 10), (6, 11)], z: [(2, 13), (0, 13)], sweat: (3, 12)), nil),
            ("adult", adult, Feat(mouthRow: 8, mouthCols: [5, 6, 7, 8, 9, 10], cheek: [(6, 3), (6, 4), (6, 11), (6, 12)], z: [(3, 14), (1, 14)], sweat: (3, 13)), nil),
        ])
    }

    // MARK: - slime 史莱姆

    private static func slime() -> PixelSpeciesDef {
        let ink = Ink(body: 11, dark: 12, light: 13, accent: 13)
        let baby = [
            "................",
            "................",
            ".......#........",
            "......#+#.......",
            ".....#O+O#......",
            "....#OOOOO#.....",
            "...#OOOOOOO#....",
            "..#OO#ww#ww#O#..",
            "..#OO#wx#xw#O#..",
            "..#OOOOOOOOOO#..",
            "..#OOO+oo+OOO#..",
            ".#OOOOOOOOOOOO#.",
            ".#OOOOOOOOOOOO#.",
            "..############..",
            "................",
            "................",
        ]
        let child = [
            "................",
            "................",
            ".......##.......",
            "......#++#......",
            ".....#O++O#.....",
            ".....#OO+O#.....",
            "....#OOOOOO#....",
            "...#OOOOOOOO#...",
            "..#OO#ww#ww#O#..",
            "..#OO#wx#xw#O#..",
            "..#OOOOOOOOOO#..",
            "..#OOO+oo+OOO#..",
            ".#OOOOOOOOOOOO#.",
            ".#OOOOOOOOOOOO#.",
            "..############..",
            "................",
        ]
        let adult = [
            "................",
            ".......##.......",
            "......#++#......",
            "......#++#......",
            ".....#O++O#.....",
            ".....#OO+O#.....",
            "....#OOOOOO#....",
            "...#OOOOOOOO#...",
            "..#OOOOOOOOOO#..",
            ".#OO#ww##ww#OO#.",
            ".#OO#wx##xw#OO#.",
            ".#OOOOOOOOOOOO#.",
            ".#OOO+oooo+OOO#.",
            "#OOOOOOOOOOOOOO#",
            "#OOOOOOOOOOOOOO#",
            ".#OOOOOOOOOOOO#.",
        ]
        return assemble(id: "slime", nameZh: "史莱姆", ink: ink, stages: [
            ("baby", baby, Feat(mouthRow: 10, mouthCols: [6, 7, 8, 9], cheek: [(9, 3), (9, 4), (9, 11), (9, 12)], z: [(3, 12), (1, 12)], sweat: (8, 13)), nil),
            ("child", child, Feat(mouthRow: 11, mouthCols: [6, 7, 8, 9], cheek: [(10, 3), (10, 4), (10, 11), (10, 12)], z: [(3, 12), (1, 12)], sweat: (8, 13)), nil),
            ("adult", adult, Feat(mouthRow: 12, mouthCols: [6, 7, 8, 9], cheek: [(11, 3), (11, 4), (11, 11), (11, 12)], z: [(2, 12), (0, 12)], sweat: (9, 13)), nil),
        ])
    }

    // MARK: - cat 小猫

    private static func cat() -> PixelSpeciesDef {
        let ink = Ink(body: 14, dark: 15, light: 16, accent: 15)
        let sleepPose = [
            "................",
            "................",
            "....######......",
            "..##OOOOOOOO##..",
            ".#ooOOOOOOOOoo#.",
            "#OOOOOOOOOOOOOO#",
            "#OOOOOOOOOOOOOO#",
            "#OOO##OOOO##OOO#",
            "#OOOOO+oo+OOOOO#",
            "#OOoOOOOOOOOoOO#",
            "#OOooooooooooOO#",
            ".#OOOOOOOOOOOO#.",
            "..############..",
            "................",
            "................",
            "................",
        ]
        let baby = [
            "................",
            "...#......#.....",
            "..##......##....",
            ".#OOOOOOOOOOOO#.",
            ".#O#ww#OO#ww#O#.",
            ".#O#wx#OO#xw#O#.",
            ".#OOOO+oo+OOOO#.",
            ".#OOOOOOOOOOOO#.",
            "..#OOOOOOOOOO#..",
            "..#OO#..#OO#....",
            "................",
            "................",
            "................",
            "................",
            "................",
            "................",
        ]
        let child = [
            "................",
            "................",
            "..##......##....",
            ".#oo#....#oo#...",
            ".#OOOOOOOOOOOO#.",
            ".#oOOOOOOOOOOo#.",
            ".#O#ww#OO#ww#O#.",
            ".#O#wx#OO#xw#O#.",
            "o#OOO+oo+OOOO#o.",
            ".#OOOOOOOOOOOO#.",
            ".#OO++++++OO#o..",
            ".#OOO++++OOO#o..",
            "..#OO#..#OO#.o..",
            "................",
            "................",
            "................",
        ]
        let adult = [
            "................",
            "..##......##....",
            ".#oo#....#oo#...",
            ".#OOo#..#oOO#...",
            ".#OOOOOOOOOOOO#.",
            ".#oOOOOOOOOOOo#.",
            ".#O#ww#OO#ww#O#.",
            ".#O#wx#OO#xw#O#.",
            "o#OOO+oo+OOOO#o.",
            ".#OOOOOOOOOOOO#.",
            ".#OOOOOOOOOO#...",
            ".#OO++++++OO#o..",
            ".#OO++++++OO#oo.",
            ".#OOO++++OOO#oo.",
            "..#OO#..#OO#.o#.",
            "................",
        ]
        return assemble(id: "cat", nameZh: "小猫", ink: ink, stages: [
            ("baby", baby, Feat(mouthRow: 7, mouthCols: [6, 7], cheek: [(6, 3), (6, 4), (6, 11), (6, 12)], z: [(2, 13), (0, 13)], sweat: (4, 12)), sleepPose),
            ("child", child, Feat(mouthRow: 8, mouthCols: [6, 7], cheek: [(8, 3), (8, 4), (8, 11), (8, 12)], z: [(2, 14), (0, 14)], sweat: (4, 12)), sleepPose),
            ("adult", adult, Feat(mouthRow: 8, mouthCols: [6, 7], cheek: [(8, 3), (8, 4), (8, 11), (8, 12)], z: [(1, 14), (-1, 14)], sweat: (4, 12)), sleepPose),
        ])
    }

    // MARK: - dragon 小龙

    private static func dragon() -> PixelSpeciesDef {
        let ink = Ink(body: 17, dark: 18, light: 19, accent: 19)
        let baby = [
            "................",
            "................",
            ".....#..#.......",
            "....##..##......",
            "..#OOOOOOOOOO#..",
            ".#OOOOOOOOOOOO#.",
            ".#OO#ww##ww#O#..",
            ".#OO#wx##xw#O#..",
            ".#OOOO+oo+OOOO#.",
            ".#OOO++++++OOO#.",
            ".#OOOOOOOOOOOO#.",
            "..#OOOOOOOO#o...",
            "..#OOOOOOOO#o...",
            "...########.....",
            "................",
            "................",
        ]
        let child = [
            "................",
            "................",
            "....#....#......",
            "...#^#..#^#.....",
            "..#OOOOOOOOOO#..",
            ".oO#ww#OO#ww#Oo.",
            ".#O#wx#OO#xw#O#.",
            ".#OOOO+oo+OOOO#.",
            ".#OO++++++++OO#.",
            ".#OO++++++++OO#.",
            "..#OO++++OO#o...",
            "..#OOOOOOOO#oo..",
            "...########.oo..",
            "................",
            "................",
            "................",
        ]
        let adult = [
            "................",
            "....#....#......",
            "...#^#..#^#.....",
            "..#OOOOOOOOOO#..",
            ".o#OOOOOOOOOO#o.",
            "oo#OwwOOOOwwO#oo",
            "oo#OwxOOOOxwO#oo",
            ".o#OOO+oo+OOO#o.",
            ".#OO++++++++OO#.",
            ".#OO++++++++OO#.",
            ".#OO++++++++OO#.",
            "..#OO++++OO#o...",
            "..#OOOOOOOO#oo..",
            "...#OOOOOO#Ooo..",
            "....######..oo..",
            "................",
        ]
        return assemble(id: "dragon", nameZh: "小龙", ink: ink, stages: [
            ("baby", baby, Feat(mouthRow: 8, mouthCols: [6, 7, 8, 9], cheek: [(8, 4), (8, 5), (8, 10), (8, 11)], z: [(3, 13), (1, 13)], sweat: (4, 12)), nil),
            ("child", child, Feat(mouthRow: 7, mouthCols: [6, 7, 8, 9], cheek: [(6, 2), (6, 13)], z: [(3, 13), (1, 13)], sweat: (4, 12)), nil),
            ("adult", adult, Feat(mouthRow: 7, mouthCols: [6, 7, 8, 9], cheek: [(7, 3), (7, 4), (7, 11), (7, 12)], z: [(2, 13), (0, 13)], sweat: (4, 12)), nil),
        ])
    }
}
