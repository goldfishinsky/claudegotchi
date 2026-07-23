import Foundation
import GRDB

/// splitmix64 (Vigna): a fixed golden-ratio increment plus a 3-round mix, the
/// canonical generator for deriving many independent sub-streams from one seed.
public struct GenomeRNG: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64, stream: String) {
        state = GenomeRNG.mix(seed ^ GenomeRNG.fnv1a64(stream))
    }

    public mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        return GenomeRNG.mix(state)
    }

    private static func mix(_ z0: UInt64) -> UInt64 {
        var z = z0
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Deterministic across process launches, unlike Swift's randomized String.hashValue.
    public static func fnv1a64(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}

public enum RarityTier: String, Equatable, Codable {
    case common, uncommon, shiny
}

public struct InkIndices: Equatable {
    public let body, dark, light, accent: UInt8
    public init(body: UInt8, dark: UInt8, light: UInt8, accent: UInt8) {
        self.body = body
        self.dark = dark
        self.light = light
        self.accent = accent
    }
}

public struct PaletteGene: Equatable {
    public let familyID: String
    public let rarityTier: RarityTier
    public let body, dark, light, accent: UInt32

    public func apply(to basePalette: [UInt32], ink: InkIndices) -> [UInt32] {
        guard !basePalette.isEmpty else { return basePalette }
        var out = basePalette
        for (idx, value) in [(ink.body, body), (ink.dark, dark), (ink.light, light), (ink.accent, accent)] {
            let i = Int(idx)
            if i < out.count { out[i] = value }
        }
        return out
    }
}

public enum MarkingKind: String, Equatable, CaseIterable, Codable {
    case none, spots, stripes, starPatch, bellyPatch
}

public struct MarkingGene: Equatable {
    public let kind: MarkingKind
    public let patternSeed: UInt64

    public func apply(to grid: [[UInt8]], bodyIndex: UInt8, darkIndex: UInt8) -> [[UInt8]] {
        guard !grid.isEmpty, kind != .none else { return grid }
        let rows = grid.count
        var out = grid
        switch kind {
        case .none:
            break
        case .spots:
            for r in 0..<rows {
                for c in 0..<grid[r].count where grid[r][c] == bodyIndex {
                    if Self.pixelHash(patternSeed, r, c) % 100 < 22 { out[r][c] = darkIndex }
                }
            }
        case .stripes:
            let period = 3 + Int(patternSeed % 3)
            let bandWidth = max(1, period / 2)
            let offset = Int((patternSeed >> 8) % UInt64(period))
            for r in 0..<rows where (r + offset) % period < bandWidth {
                for c in 0..<grid[r].count where grid[r][c] == bodyIndex { out[r][c] = darkIndex }
            }
        case .starPatch:
            let widestCols = grid.map(\.count).max() ?? 0
            guard widestCols > 0 else { return grid }
            let centerR = Int(patternSeed % UInt64(rows))
            let centerC = Int((patternSeed >> 16) % UInt64(widestCols))
            let radius = max(1, min(rows, widestCols) / 5)
            for r in 0..<rows {
                for c in 0..<grid[r].count where grid[r][c] == bodyIndex {
                    let dist = abs(r - centerR) + abs(c - centerC)
                    if dist <= radius && Self.pixelHash(patternSeed, r, c) % 100 < 70 { out[r][c] = darkIndex }
                }
            }
        case .bellyPatch:
            let rowStart = Int(Double(rows) * 0.5)
            for r in rowStart..<rows {
                let cols = grid[r].count
                let colStart = Int(Double(cols) * 0.2)
                let colEnd = Int(Double(cols) * 0.8)
                for c in colStart..<colEnd where grid[r][c] == bodyIndex { out[r][c] = darkIndex }
            }
        }
        return out
    }

    private static func pixelHash(_ seed: UInt64, _ r: Int, _ c: Int) -> UInt64 {
        var z = seed
        z ^= UInt64(r) &* 0x9E37_79B9_7F4A_7C15
        z ^= UInt64(c) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

public struct PersonalityGene: Equatable {
    public let bounceAmplitude: Double
    public let motionSpeed: Double
    public let blinkRate: Double
    public let chattiness: Double
    public let particleHueShift: Double
    public let fidgetWeights: [Double]
}

public enum Genome {
    private static let speciesWeights: [String: Double] = [
        "dog": 15, "cat": 15, "goldfish": 12, "bird": 12, "rabbit": 10,
        "hamster": 10, "frog": 8, "turtle": 7, "hedgehog": 6, "slime": 3, "dragon": 2,
    ]
    private static let defaultSpeciesWeight: Double = 5

    public static func species(seed: UInt64, availableIDs: [String]) -> String {
        precondition(!availableIDs.isEmpty, "species(seed:availableIDs:) requires a non-empty id list")
        let weighted = availableIDs.sorted().map { ($0, speciesWeights[$0] ?? defaultSpeciesWeight) }
        var rng = GenomeRNG(seed: seed, stream: "species")
        return weightedPick(weighted, using: &rng)
    }

    private static let colorFamilies: [ColorFamily] = [
        ColorFamily(id: "meadow-green", tier: .common, weight: 70.0 / 12, body: 0xFF6F_CB4C, dark: 0xFF3E_8A2A, light: 0xFFC9_F0AA, accent: 0xFF2E_6B1E),
        ColorFamily(id: "sky-blue", tier: .common, weight: 70.0 / 12, body: 0xFF5A_A9E6, dark: 0xFF2E_6FA8, light: 0xFFC7_E6FB, accent: 0xFF1F_4E7A),
        ColorFamily(id: "sunset-orange", tier: .common, weight: 70.0 / 12, body: 0xFFF2_924B, dark: 0xFFC9_662A, light: 0xFFFB_D8AE, accent: 0xFFA8_501C),
        ColorFamily(id: "blossom-pink", tier: .common, weight: 70.0 / 12, body: 0xFFF2_7FA0, dark: 0xFFC9_4E77, light: 0xFFFB_D3E1, accent: 0xFFA8_3A5C),
        ColorFamily(id: "grape-purple", tier: .common, weight: 70.0 / 12, body: 0xFFA9_7FE0, dark: 0xFF7A_4EB8, light: 0xFFE3_D3F7, accent: 0xFF5C_3A96),
        ColorFamily(id: "cocoa-brown", tier: .common, weight: 70.0 / 12, body: 0xFFB9_8259, dark: 0xFF7C_5334, light: 0xFFE8_CBA8, accent: 0xFF5E_3D22),
        ColorFamily(id: "cherry-red", tier: .common, weight: 70.0 / 12, body: 0xFFE0_564F, dark: 0xFFA9_3B34, light: 0xFFF7_C4C0, accent: 0xFF8A_2924),
        ColorFamily(id: "lemon-yellow", tier: .common, weight: 70.0 / 12, body: 0xFFF0_D24B, dark: 0xFFC9_A62A, light: 0xFFFB_EFAE, accent: 0xFFA8_841C),
        ColorFamily(id: "lagoon-teal", tier: .common, weight: 70.0 / 12, body: 0xFF4B_C9B0, dark: 0xFF2A_8A76, light: 0xFFAE_EEE0, accent: 0xFF1C_6B58),
        ColorFamily(id: "storm-gray", tier: .common, weight: 70.0 / 12, body: 0xFF9A_A0A8, dark: 0xFF65_6B72, light: 0xFFDC_E0E4, accent: 0xFF49_4E54),
        ColorFamily(id: "mint-fresh", tier: .common, weight: 70.0 / 12, body: 0xFF6F_E0A0, dark: 0xFF3E_A86E, light: 0xFFC9_F7DD, accent: 0xFF2E_7A50),
        ColorFamily(id: "lavender-mist", tier: .common, weight: 70.0 / 12, body: 0xFFB0_A0E0, dark: 0xFF7A_6BB8, light: 0xFFE6_DFF7, accent: 0xFF5C_4E96),
        ColorFamily(id: "indigo-deep", tier: .uncommon, weight: 25.0 / 8, body: 0xFF4B_4BC9, dark: 0xFF2E_2E8A, light: 0xFFAE_AEEE, accent: 0xFF1C_1C6B),
        ColorFamily(id: "coral-reef", tier: .uncommon, weight: 25.0 / 8, body: 0xFFF0_765C, dark: 0xFFC9_4E34, light: 0xFFFB_CEC0, accent: 0xFFA8_3A22),
        ColorFamily(id: "olive-drab", tier: .uncommon, weight: 25.0 / 8, body: 0xFF8A_9A4B, dark: 0xFF5C_6B2A, light: 0xFFD3_DDAE, accent: 0xFF45_4E1C),
        ColorFamily(id: "slate-blue", tier: .uncommon, weight: 25.0 / 8, body: 0xFF6B_7FA0, dark: 0xFF45_4E72, light: 0xFFC7_D0E4, accent: 0xFF33_3A54),
        ColorFamily(id: "plum-wine", tier: .uncommon, weight: 25.0 / 8, body: 0xFF8A_4B6B, dark: 0xFF5C_2E45, light: 0xFFDD_AEC7, accent: 0xFF3A_1C2C),
        ColorFamily(id: "rust-copper", tier: .uncommon, weight: 25.0 / 8, body: 0xFFC9_7A3E, dark: 0xFF96_5B2A, light: 0xFFEF_C9A0, accent: 0xFF6B_3E1C),
        ColorFamily(id: "glacier-ice", tier: .uncommon, weight: 25.0 / 8, body: 0xFFA0_DCE8, dark: 0xFF6B_AAB8, light: 0xFFE0_F7FB, accent: 0xFF4B_8A96),
        ColorFamily(id: "sunflower-gold", tier: .uncommon, weight: 25.0 / 8, body: 0xFFE8_C24B, dark: 0xFFB8_952A, light: 0xFFF7_E6AE, accent: 0xFF8A_6B1C),
        ColorFamily(id: "shiny-gold", tier: .shiny, weight: 5.0 / 4, body: 0xFFFF_D75E, dark: 0xFFC9_962A, light: 0xFFFF_F3C4, accent: 0xFF8A_5C10),
        ColorFamily(id: "shiny-silver", tier: .shiny, weight: 5.0 / 4, body: 0xFFE4_E8EC, dark: 0xFFA8_B0B8, light: 0xFFFF_FFFF, accent: 0xFF76_7E86),
        ColorFamily(id: "shiny-neon-cyan", tier: .shiny, weight: 5.0 / 4, body: 0xFF4B_FCE8, dark: 0xFF1C_B8A0, light: 0xFFC4_FFF7, accent: 0xFF0E_8A78),
        ColorFamily(id: "shiny-iridescent", tier: .shiny, weight: 5.0 / 4, body: 0xFFD6_6BE0, dark: 0xFF8A_2EA8, light: 0xFFF7_C4FB, accent: 0xFF4B_E0D6),
    ]

    public static func paletteTransform(seed: UInt64) -> PaletteGene {
        var rng = GenomeRNG(seed: seed, stream: "palette.family")
        let family = weightedPick(colorFamilies.map { ($0, $0.weight) }, using: &rng)
        return PaletteGene(familyID: family.id, rarityTier: family.tier, body: family.body, dark: family.dark, light: family.light, accent: family.accent)
    }

    private static let markingWeights: [(MarkingKind, Double)] = [
        (.none, 40), (.spots, 22), (.stripes, 20), (.bellyPatch, 12), (.starPatch, 6),
    ]

    public static func markings(seed: UInt64) -> MarkingGene {
        var kindRNG = GenomeRNG(seed: seed, stream: "markings.kind")
        let kind = weightedPick(markingWeights, using: &kindRNG)
        var patternRNG = GenomeRNG(seed: seed, stream: "markings.pattern")
        return MarkingGene(kind: kind, patternSeed: patternRNG.next())
    }

    public static func personality(seed: UInt64) -> PersonalityGene {
        var bounceRNG = GenomeRNG(seed: seed, stream: "personality.bounceAmplitude")
        var speedRNG = GenomeRNG(seed: seed, stream: "personality.motionSpeed")
        var blinkRNG = GenomeRNG(seed: seed, stream: "personality.blinkRate")
        var chatRNG = GenomeRNG(seed: seed, stream: "personality.chattiness")
        var hueRNG = GenomeRNG(seed: seed, stream: "personality.particleHueShift")
        var fidgetRNG = GenomeRNG(seed: seed, stream: "personality.fidgetWeights")

        let raw = (0..<8).map { _ in Double.random(in: 0.05...1.0, using: &fidgetRNG) }
        let sum = raw.reduce(0, +)

        return PersonalityGene(
            bounceAmplitude: Double.random(in: 0.7...1.3, using: &bounceRNG),
            motionSpeed: Double.random(in: 0.85...1.2, using: &speedRNG),
            blinkRate: Double.random(in: 0.6...1.6, using: &blinkRNG),
            chattiness: Double.random(in: 0.5...1.5, using: &chatRNG),
            particleHueShift: Double.random(in: 0..<360, using: &hueRNG),
            fidgetWeights: raw.map { $0 / sum }
        )
    }

    public static func pack(_ seed: UInt64) -> Int64 { Int64(bitPattern: seed) }
    public static func unpack(_ stored: Int64) -> UInt64 { UInt64(bitPattern: stored) }

    private static func weightedPick<T>(_ weighted: [(T, Double)], using rng: inout GenomeRNG) -> T {
        let total = weighted.reduce(0) { $0 + $1.1 }
        let roll = Double.random(in: 0..<total, using: &rng)
        var acc = 0.0
        for (value, weight) in weighted {
            acc += weight
            if roll < acc { return value }
        }
        return weighted.last!.0
    }
}

private struct ColorFamily {
    let id: String
    let tier: RarityTier
    let weight: Double
    let body, dark, light, accent: UInt32
}

/// Repeatedly perturbs a seed until it reproduces a pet's pre-existing species,
/// so upgrading to the genome column never changes an established pet's look.
public enum PetGenomeBackfill {
    public static func startingSeed(uid: String?, fallback: Int64) -> UInt64 {
        if let uid, !uid.isEmpty { return GenomeRNG.fnv1a64(uid) }
        return UInt64(bitPattern: fallback)
    }

    public static func findSeed(
        startingFrom start: UInt64,
        targetSpecies: String,
        availableIDs: [String],
        maxAttempts: Int = 100_000
    ) -> UInt64? {
        guard !availableIDs.isEmpty else { return nil }
        var seed = start
        for _ in 0..<maxAttempts {
            if Genome.species(seed: seed, availableIDs: availableIDs) == targetSpecies { return seed }
            seed = seed &+ 1
        }
        return nil
    }
}

public enum PetGenomeRerollError: Error, Equatable {
    case noAlivePet
}

public enum PetGenomeReroll {
    @discardableResult
    public static func reroll(db: DatabaseQueue, seed: UInt64) throws -> UInt64 {
        guard var pet = try Pet.fetchAlive(from: db) else { throw PetGenomeRerollError.noAlivePet }
        pet.genome = Genome.pack(seed)
        pet.species = Genome.species(seed: seed, availableIDs: PixelSpeciesCatalog.ids)
        try Pet.update(pet, in: db)
        return seed
    }
}
