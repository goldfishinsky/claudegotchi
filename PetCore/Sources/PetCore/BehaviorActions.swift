import Foundation

public struct GridPoint: Equatable {
    public let row: Int
    public let col: Int
    public init(_ row: Int, _ col: Int) {
        self.row = row
        self.col = col
    }
}

/// Where a species' body parts sit, in the 16-space feature coordinates the
/// sprite grids are authored against; a 32×32 grid scales them by `side / 16`.
public struct SpriteAnchors: Equatable {
    public let mouth: GridPoint
    public let pawL: GridPoint
    public let pawR: GridPoint
    public let feetRow: Int
    public let cheekL: GridPoint
    public let cheekR: GridPoint

    public init(mouth: GridPoint, pawL: GridPoint, pawR: GridPoint,
                feetRow: Int, cheekL: GridPoint, cheekR: GridPoint) {
        self.mouth = mouth
        self.pawL = pawL
        self.pawR = pawR
        self.feetRow = feetRow
        self.cheekL = cheekL
        self.cheekR = cheekR
    }
}

/// Each action animates on its own clock inside the behaviour's phases; every
/// behaviour loop holds a whole number of its action's cycles.
public enum BehaviorRhythm {
    public struct Cadence: Equatable {
        public let key: String
        public let frameMs: Int64
        public let count: Int
        public var cycleMs: Int64 { frameMs * Int64(count) }

        public init(key: String, frameMs: Int64, count: Int) {
            self.key = key
            self.frameMs = frameMs
            self.count = count
        }
    }

    public static let chew = Cadence(key: "eat", frameMs: 180, count: 3)
    public static let typing = Cadence(key: "work", frameMs: 120, count: 4)
    public static let step = Cadence(key: "walk", frameMs: 140, count: 2)
    public static let breath = Cadence(key: "nap", frameMs: 450, count: 2)
    public static let cheer = Cadence(key: "cheer", frameMs: 160, count: 2)
    public static let wave = Cadence(key: "wave", frameMs: 150, count: 4)
    public static let nuzzle = Cadence(key: "petting", frameMs: 220, count: 2)

    public static let all: [Cadence] = [chew, typing, step, breath, cheer, wave, nuzzle]

    public static func cadence(_ key: String) -> Cadence? { all.first { $0.key == key } }

    public static func frame(_ c: Cadence, loopPos: Int64) -> Int {
        let i = (loopPos / c.frameMs) % Int64(c.count)
        return Int(i < 0 ? i + Int64(c.count) : i)
    }
}

/// Anchor-driven local patches — chewing mouth, typing paws, alternating feet,
/// raised arms — in palette slots only, clipped to the grid.
enum BehaviorActions {
    /// Paws are an outline ring around a pale core so they read against any body
    /// colour: flat for a hand laid on the keyboard, upright for a raised arm.
    static let pawFlat = [".DDD.", "D+++D", ".DDD."]
    static let pawUp = [".D.", "D+D", "D+D", "D+D", ".D."]

    static func unit(_ g: [String]) -> Int { max(1, g.count / 16) }

    private static func cells(_ g: [String]) -> [[Character]] { g.map(Array.init) }
    private static func joined(_ m: [[Character]]) -> [String] { m.map { String($0) } }

    static func paint(_ g: [String], rows rr: ClosedRange<Int>, cols cc: ClosedRange<Int>,
                      _ ch: Character, masked: Bool) -> [String] {
        var m = cells(g)
        for r in rr where r >= 0 && r < m.count {
            for c in cc where c >= 0 && c < m[r].count {
                if masked, m[r][c] == "." { continue }
                m[r][c] = ch
            }
        }
        return joined(m)
    }

    /// Moves every lit pixel of a box up by `dy`, clearing what it left behind:
    /// a foot or a paw leaving the ground.
    static func lift(_ g: [String], rows rr: ClosedRange<Int>, cols cc: ClosedRange<Int>,
                     dy: Int) -> [String] {
        var m = cells(g)
        var moved: [(Int, Int, Character)] = []
        for r in rr where r >= 0 && r < m.count {
            for c in cc where c >= 0 && c < m[r].count && m[r][c] != "." {
                moved.append((r - dy, c, m[r][c]))
                m[r][c] = "."
            }
        }
        for (r, c, ch) in moved where r >= 0 && r < m.count && c < m[r].count {
            m[r][c] = ch
        }
        return joined(m)
    }

    static func stampPaw(_ g: [String], _ art: [String], bottomRow: Int, centerCol: Int) -> [String] {
        var m = cells(g)
        let top = bottomRow - art.count + 1
        let left = centerCol - (art[0].count - 1) / 2
        for (i, row) in art.enumerated() {
            for (j, ch) in row.enumerated() where ch != "." {
                let r = top + i, c = left + j
                if r >= 0, r < m.count, c >= 0, c < m[r].count { m[r][c] = ch }
            }
        }
        return joined(m)
    }

    /// Outermost body pixel of a row. Accent pixels are skipped so an aura — the
    /// goldfish bubble, a spike halo — never becomes the shoulder a paw hangs off.
    static func edgeCol(_ g: [String], row: Int, left: Bool) -> Int? {
        guard row >= 0, row < g.count else { return nil }
        let chars = Array(g[row])
        let lit = chars.indices.filter { chars[$0] != "." && chars[$0] != "^" }
        guard !lit.isEmpty else { return nil }
        return left ? lit.min() : lit.max()
    }

    // MARK: - actions

    /// Mouth openness 0/1/2: shut, ajar, wide with a tongue. Masked to the head so
    /// the opening can never float off the silhouette.
    static func mouth(_ g: [String], _ a: SpriteAnchors, open: Int) -> [String] {
        guard open > 0 else { return g }
        let u = unit(g)
        let r = a.mouth.row * u, c = a.mouth.col * u
        if open == 1 {
            return paint(g, rows: r...(r + u - 1), cols: (c - u / 2)...(c + u + u / 2 - 1),
                         "#", masked: true)
        }
        let top = r - u / 2, bottom = r + 3 * u / 2 - 1
        var out = paint(g, rows: top...bottom, cols: (c - u)...(c + 2 * u - 1), "#", masked: true)
        out = paint(out, rows: bottom...bottom, cols: (c - u / 2)...(c + u + u / 2 - 1),
                    "*", masked: true)
        return out
    }

    static func eat(_ base: [String], _ a: SpriteAnchors) -> [[String]] {
        [base, mouth(base, a, open: 1), mouth(base, a, open: 2)]
    }

    /// Sprite row the laptop's top edge cuts across: everything below it is behind
    /// the lid, so poses and screen light are measured against this line.
    static func deskRow(_ g: [String]) -> Int {
        Int((PetTheater.stageFloorY - PixelProps.size(.laptop).height) * Double(unit(g)))
    }

    /// Sprite columns the lid's top edge spans, mapped from the prop's own art so
    /// the taper stays in sync with it.
    static func lidSpan(_ g: [String]) -> ClosedRange<Int> {
        let m = PixelProps.matrix(.laptop)
        let top = m.first ?? []
        let drawn = top.indices.filter { top[$0] != 0 }
        let scale = Double(unit(g))
        let left = 8 - Double(top.count) * PixelProps.cellUnits / 2
        guard let a = drawn.min(), let b = drawn.max() else { return 0...(g.count - 1) }
        let c0 = Int(((left + PixelProps.cellUnits * Double(a)) * scale).rounded())
        let c1 = Int(((left + PixelProps.cellUnits * Double(b + 1)) * scale).rounded()) - 1
        return c0...max(c0, c1)
    }

    /// Screen spill: the lowest body pixels still clear of the lid catch the light
    /// coming over its top edge, following the silhouette column by column. A
    /// keystroke adds the hot core; between strikes only the falloff survives.
    static func screenRim(_ g: [String], bright: Bool) -> [String] {
        var m = cells(g)
        let t = max(1, unit(g) / 2), line = deskRow(g)
        let span = lidSpan(g)
        for c in span {
            let hot = bright && c >= span.lowerBound + t && c <= span.upperBound - t
            var r = min(line - 1, m.count - 1)
            while r >= 0, c >= m[r].count || m[r][c] == "." || m[r][c] == "^" { r -= 1 }
            guard r >= 0 else { continue }
            for k in max(0, r - t + 1)...r { m[k][c] = hot ? "G" : "g" }
            guard r - t >= 0 else { continue }
            for k in max(0, r - 2 * t + 1)...(r - t) where m[k][c] != "." && m[k][c] != "^" {
                m[k][c] = "g"
            }
        }
        return joined(m)
    }

    /// A screen-lit stare: the pupil drops inside the eye white where there is room,
    /// otherwise the whole eye slides down a pixel. Eyes that would leave the
    /// silhouette either way keep the plain gaze.
    static func eyesDown(_ g: [String]) -> [String] {
        pupilsDown(g) ?? eyeBlockDown(g) ?? g
    }

    private static func eyePixels(_ m: [[Character]]) -> [(Int, Int)] {
        var pts: [(Int, Int)] = []
        for r in m.indices {
            for c in m[r].indices where m[r][c] == "w" || m[r][c] == "x" { pts.append((r, c)) }
        }
        return pts
    }

    private static func pupilsDown(_ g: [String]) -> [String]? {
        var m = cells(g)
        let pupils = eyePixels(m).filter { m[$0.0][$0.1] == "x" }
        guard !pupils.isEmpty else { return nil }
        var moved = m.map { Array(repeating: false, count: $0.count) }
        for (r, c) in pupils {
            let t = r + 1
            guard t < m.count, c < m[t].count, m[t][c] == "x" || m[t][c] == "w" else { return nil }
            moved[t][c] = true
        }
        for (r, c) in pupils where !moved[r][c] { m[r][c] = "w" }
        for r in m.indices { for c in m[r].indices where moved[r][c] { m[r][c] = "x" } }
        return joined(m)
    }

    private static func eyeBlockDown(_ g: [String]) -> [String]? {
        var m = cells(g)
        let n = m.count
        let pts = eyePixels(m)
        guard !pts.isEmpty else { return nil }
        for side in [pts.filter { $0.1 < n / 2 }, pts.filter { $0.1 >= n / 2 }] where !side.isEmpty {
            let r0 = side.map(\.0).min()!, r1 = side.map(\.0).max()!
            let c0 = side.map(\.1).min()!, c1 = side.map(\.1).max()!
            guard r0 > 0, r1 + 1 < n else { return nil }
            for c in c0...c1 where m[r0 - 1][c] == "." || m[r1 + 1][c] == "." { return nil }
            for r in stride(from: r1 + 1, through: r0, by: -1) {
                for c in c0...c1 { m[r][c] = m[r - 1][c] }
            }
        }
        return joined(m)
    }

    static func work(_ base: [String], _ a: SpriteAnchors) -> [[String]] {
        let focused = eyesDown(base)
        let line = deskRow(focused), span = lidSpan(focused)
        let down = line + 1, up = line - 1
        let lx = max(span.lowerBound - 1, edgeCol(focused, row: up, left: true) ?? a.pawL.col)
        let rx = min(span.upperBound + 1, edgeCol(focused, row: up, left: false) ?? a.pawR.col)
        func pose(_ l: Int, _ r: Int, _ bright: Bool) -> [String] {
            stampPaw(stampPaw(screenRim(focused, bright: bright), pawFlat, bottomRow: l, centerCol: lx),
                     pawFlat, bottomRow: r, centerCol: rx)
        }
        return [pose(down, up, true), pose(up, up, false), pose(up, down, true), pose(up, up, false)]
    }

    static func walk(_ base: [String], _ a: SpriteAnchors) -> [[String]] {
        let u = unit(base), n = base.count
        let bottom = a.feetRow * u + u - 1
        let band = (bottom - u)...bottom
        return [
            lift(base, rows: band, cols: 0...(n / 2 - 1), dy: u),
            lift(base, rows: band, cols: (n / 2)...(n - 1), dy: u),
        ]
    }

    static func raisedPaws(_ g: [String], _ a: SpriteAnchors, dy: Int = 0, dx: Int = 0,
                           rightOnly: Bool = false) -> [String] {
        let u = unit(g)
        let lr = (a.pawL.row - 4) * u + u - 1 + dy
        let rr = (a.pawR.row - 4) * u + u - 1 + dy
        var out = g
        if !rightOnly {
            let lc = edgeCol(g, row: max(0, lr), left: true) ?? (a.pawL.col * u)
            out = stampPaw(out, pawUp, bottomRow: lr, centerCol: lc - dx)
        }
        let rc = edgeCol(g, row: max(0, rr), left: false) ?? (a.pawR.col * u)
        return stampPaw(out, pawUp, bottomRow: rr, centerCol: rc + dx)
    }

    static func cheer(_ happy: [String], _ a: SpriteAnchors) -> [[String]] {
        let pose = raisedPaws(happy, a)
        return [pose, PixelSpeciesCatalog.bounce(pose, up: 1)]
    }

    static func wave(_ happy: [String], _ a: SpriteAnchors) -> [[String]] {
        let u = unit(happy)
        func pose(_ dy: Int, _ dx: Int) -> [String] {
            raisedPaws(happy, a, dy: dy, dx: dx, rightOnly: true)
        }
        return [pose(0, 0), pose(-u / 2, u / 2), pose(-u, u), pose(-u / 2, u / 2)]
    }

    static func petting(_ happy: [String], _ a: SpriteAnchors) -> [[String]] {
        let lidded = PixelSpeciesCatalog.closeEyes(happy, fraction: 0.5)
        return [lidded, PixelSpeciesCatalog.squash(lidded)]
    }

    static func nap(_ sleeping: [String]) -> [[String]] {
        [sleeping, PixelSpeciesCatalog.squash(sleeping)]
    }

    /// Head bob that peaks as the jaw shuts, so every bite lands with weight.
    /// Zero at mid-chew, which keeps the loop seam continuous.
    static func chewDip(loopPos: Int64) -> Double {
        let cycle = BehaviorRhythm.chew.cycleMs
        let u = Double(((loopPos % cycle) + cycle) % cycle) / Double(cycle)
        let shape = (cos(2 * .pi * u) + 1) / 2
        return 0.5 * shape * shape
    }
}
