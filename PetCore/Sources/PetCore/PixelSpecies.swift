import Foundation

public typealias PixelFrame = [[UInt8]]

public struct PixelSpeciesDef: Equatable {
    public let id: String
    public let nameZh: String
    public let ink: InkIndices
    public let base4: SpeciesBase4
    public let stages: [(id: String, minXp: Int)]
    public let frames: [String: [PixelFrame]]
    public let iconGrids: [String: PixelFrame]

    public static func == (lhs: PixelSpeciesDef, rhs: PixelSpeciesDef) -> Bool {
        lhs.id == rhs.id && lhs.nameZh == rhs.nameZh
            && lhs.stages.map(\.id) == rhs.stages.map(\.id)
            && lhs.stages.map(\.minXp) == rhs.stages.map(\.minXp)
            && lhs.frames == rhs.frames
    }
}

public enum PixelSpeciesCatalog {
    // MARK: - fixed render slots

    // Every species' grids index these eight slots; per-pet colour comes from
    // overwriting them in the resolved palette. Values are the PaletteRamp
    // expansion order.
    public static let slotBody: UInt8 = 26
    public static let slotBodyDark: UInt8 = 27
    public static let slotBodyLight: UInt8 = 28
    public static let slotOutline: UInt8 = 29
    public static let slotLight: UInt8 = 30
    public static let slotSecondary: UInt8 = 31
    public static let slotSecondaryDark: UInt8 = 32
    public static let slotAccent: UInt8 = 33

    /// Shared low-index colours: transparent, structural ink, face/state tints,
    /// and the stage props/particles the App references by fixed index.
    static let commonBase: [UInt32] = [
        0x0000_0000, // 0 transparent
        0xFF3A_2E28, // 1 outline (warm dark brown)
        0xFFFF_FFFF, // 2 eye white
        0xFF4A_3A34, // 3 pupil
        0xFFFF_9DB4, // 4 blush
        0xFFC2_CCEE, // 5 sleep Z
        0xFFAF_C894, // 6 sick body tint
        0xFF8C_C4F2, // 7 sweat
        0xFF83_CE63, // 8 prop veggie / confetti green
        0xFF4E_9B3A, // 9 legacy
        0xFFE7_F3C0, // 10 legacy
        0xFFFF_93C0, // 11 legacy
        0xFFE1_62A0, // 12 legacy
        0xFFFF_D2E6, // 13 legacy
        0xFFFF_C178, // 14 legacy
        0xFFE8_925A, // 15 legacy
        0xFFFF_F1DC, // 16 legacy
        0xFFB4_9BF0, // 17 legacy
        0xFF84_68CE, // 18 legacy
        0xFFF6_E1A8, // 19 legacy
        0xFFB7_ADA0, // 20 prop: laptop shell (warm gray)
        0xFF9F_E0E8, // 21 prop: screen glow / spark (soft cyan)
        0xFFF0_6A82, // 22 prop: umeboshi / heart (warm red)
        0xFFE0_A96B, // 23 prop: bento box (tan)
        0xFFF2_946B, // 24 prop: salmon (food accent)
        0xFFFF_D36B, // 25 prop: confetti gold
    ]

    /// Prop-only colours, appended after the render slots so slot indices stay put.
    static let propExtras: [UInt32] = [
        0xFF2E_3540, // 34 prop: laptop ink (cool charcoal)
        0xFF5E_6878, // 35 prop: keycap slate
        0xFF23_8F55, // 36 prop: terminal green
        0xFF36_4A43, // 37 prop: nori
        0xFFE4_DAC4, // 38 prop: rice shade
    ]

    static let frogBase4 = SpeciesBase4(body: 0xFF83_CE63, dark: 0xFF4E_9B3A, light: 0xFFE7_F3C0, accent: 0xFF4E_9B3A)

    /// Common colours plus the eight render slots filled from a base-four set.
    /// `slotBody` is the first appended index (`commonBase.count == 26`).
    public static func resolvedPalette(base4: SpeciesBase4) -> [UInt32] {
        commonBase + PaletteRamp.expand(base4) + propExtras
    }

    /// The default palette (frog ramp): a self-contained fallback for an unknown
    /// species. Real pets always render through a `resolvedPalette`.
    public static let palette: [UInt32] = resolvedPalette(base4: frogBase4)

    public static let all: [PixelSpeciesDef] = [
        frog(), slime(), cat(), dragon(),
        dog(), goldfish(), bird(), rabbit(), hamster(), turtle(), hedgehog(),
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

    // MARK: - symbol → slot mapping

    private static func px(_ ch: Character) -> UInt8 {
        switch ch {
        case "#": return 1
        case "w": return 2
        case "x": return 3
        case "*": return 4
        case "z": return 5
        case "s": return 6
        case ",": return 7
        case "O": return slotBody
        case "o": return slotBodyDark
        case "L": return slotBodyLight
        case "D": return slotOutline
        case "+": return slotLight
        case "S": return slotSecondary
        case "d": return slotSecondaryDark
        case "^": return slotAccent
        default: return 0
        }
    }

    private static func f(_ rows: [String]) -> PixelFrame {
        rows.map { $0.map(px) }
    }

    // MARK: - grid transforms (scale-aware: a 32×32 grid animates as an exact 2x
    // of the same 16×16 art, so the mechanical upscale is visually lossless).
    // Feature coordinates are authored in 16-space; `unit = side / 16`.

    private static func unit(_ g: [String]) -> Int { max(1, g.count / 16) }

    private static func stamp(_ g: [String], _ pts: [(Int, Int, Character)]) -> [String] {
        let n = g.count, u = unit(g)
        var m = g.map(Array.init)
        for (r, c, ch) in pts {
            for dr in 0..<u { for dc in 0..<u {
                let rr = r * u + dr, cc = c * u + dc
                if rr >= 0, rr < n, cc >= 0, cc < n { m[rr][cc] = ch }
            } }
        }
        return m.map { String($0) }
    }

    private static func squash(_ g: [String]) -> [String] {
        let n = g.count, u = unit(g)
        var m = g.map(Array.init)
        let split = 9 * u
        for r in stride(from: split, through: u, by: -1) { m[r] = m[r - u] }
        for r in 0..<u { m[r] = Array(repeating: ".", count: n) }
        return m.map { String($0) }
    }

    private static func bounce(_ g: [String], up n: Int) -> [String] {
        let side = g.count, shift = n * unit(g)
        let src = g.map(Array.init)
        var out = Array(repeating: Array(repeating: Character("."), count: side), count: side)
        for r in 0..<side where r + shift < side { out[r] = src[r + shift] }
        return out.map { String($0) }
    }

    private static func sickly(_ g: [String]) -> [String] {
        g.map { row in String(row.map { "OLSd+^".contains($0) ? Character("s") : $0 }) }
    }

    private static func closeEyes(_ g: [String]) -> [String] {
        let n = g.count
        var m = g.map(Array.init)
        var pts: [(Int, Int)] = []
        for r in 0..<n { for c in 0..<n where m[r][c] == "w" || m[r][c] == "x" { pts.append((r, c)) } }
        for side in [pts.filter { $0.1 < n / 2 }, pts.filter { $0.1 >= n / 2 }] where !side.isEmpty {
            let maxR = side.map(\.0).max()!
            let minC = side.map(\.1).min()!, maxC = side.map(\.1).max()!
            for (r, c) in side { m[r][c] = "O" }
            for c in minC...maxC { m[maxR][c] = "#" }
        }
        return m.map { String($0) }
    }

    // MARK: - animation assembly

    struct Feat {
        let mouthRow: Int
        let mouthCols: [Int]
        let cheek: [(Int, Int)]
        let z: [(Int, Int)]
        let sweat: (Int, Int)
    }

    private static func anims(_ base: [String], _ ft: Feat, sleep: [String]? = nil) -> [String: [PixelFrame]] {
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
            "idle": [f(base), f(squash(base))],
            "happy": [f(bounce(happy, up: 1)), f(happy)],
            "sick": [f(sick0), f(sick1)],
            "sleeping": [f(z0), f(z1)],
        ]
    }

    /// Nearest-neighbour halving of a clean 2x grid; used to keep a 16×16 icon
    /// beside a 32×32 stage sprite. A grid already ≤16 rows is returned as-is.
    static func iconDownsample(_ frame: PixelFrame) -> PixelFrame {
        guard frame.count > 16 else { return frame }
        var out: PixelFrame = []
        for r in stride(from: 0, to: frame.count, by: 2) {
            let row = frame[r]
            out.append(stride(from: 0, to: row.count, by: 2).map { row[$0] })
        }
        return out
    }

    static func assemble(
        id: String, nameZh: String, base4: SpeciesBase4,
        stages: [(stage: String, base: [String], feat: Feat, sleep: [String]?)]
    ) -> PixelSpeciesDef {
        var frames: [String: [PixelFrame]] = [:]
        var iconGrids: [String: PixelFrame] = [:]
        for s in stages {
            let stageAnims = anims(s.base, s.feat, sleep: s.sleep)
            for (k, v) in stageAnims { frames["\(s.stage)/\(k)"] = v }
            if let idle = stageAnims["idle"]?.first { iconGrids[s.stage] = iconDownsample(idle) }
        }
        let adult = stages.first { $0.stage == "adult" }!
        for (k, v) in anims(adult.base, adult.feat, sleep: adult.sleep) { frames[k] = v }
        return PixelSpeciesDef(
            id: id, nameZh: nameZh,
            ink: InkIndices(body: slotBody, dark: slotBodyDark, light: slotLight, accent: slotAccent),
            base4: base4,
            stages: [("baby", 0), ("child", 100), ("adult", 400)],
            frames: frames,
            iconGrids: iconGrids
        )
    }
}
