import Foundation

/// The genome-derived look of a pet, resolved once per genome and reused across
/// every render surface: a per-pet palette (the species' four ink slots recoloured
/// by the palette gene) plus the marking gene applied to each frame. A NULL genome
/// falls back to `.base` — the shared catalogue palette with no markings.
public struct PetAppearance: Equatable {
    public let palette: [UInt32]
    public let marking: MarkingGene
    public let bodyIndex: UInt8
    public let darkIndex: UInt8

    public init(palette: [UInt32], marking: MarkingGene, bodyIndex: UInt8, darkIndex: UInt8) {
        self.palette = palette
        self.marking = marking
        self.bodyIndex = bodyIndex
        self.darkIndex = darkIndex
    }

    public static let base = PetAppearance(
        palette: PixelSpeciesCatalog.palette,
        marking: MarkingGene(kind: .none, patternSeed: 0),
        bodyIndex: 0, darkIndex: 0
    )

    /// The NULL-genome look for a known species: its authored base-four expanded
    /// into the render slots, no markings. Reproduces the pre-genome palette.
    public static func resolvedBase(species: String) -> PetAppearance {
        guard let def = PixelSpeciesCatalog.def(species) else { return .base }
        return PetAppearance(
            palette: PixelSpeciesCatalog.resolvedPalette(base4: def.base4),
            marking: MarkingGene(kind: .none, patternSeed: 0),
            bodyIndex: def.ink.body, darkIndex: def.ink.dark
        )
    }

    public static func make(seed: UInt64, species: String) -> PetAppearance {
        guard let def = PixelSpeciesCatalog.def(species) else { return .base }
        let gene = Genome.paletteTransform(seed: seed)
        let base4 = SpeciesBase4(body: gene.body, dark: gene.dark, light: gene.light, accent: gene.accent)
        return PetAppearance(
            palette: PixelSpeciesCatalog.resolvedPalette(base4: base4),
            marking: Genome.markings(seed: seed),
            bodyIndex: def.ink.body, darkIndex: def.ink.dark
        )
    }

    public func transformedFrame(_ raw: PixelFrame) -> PixelFrame {
        marking.apply(to: raw, bodyIndex: bodyIndex, darkIndex: darkIndex)
    }

    public func argb(_ index: UInt8) -> UInt32? {
        guard index != 0, Int(index) < palette.count else { return nil }
        return palette[Int(index)]
    }
}

/// Personality multipliers fed into the theater. Every field defaults to the
/// identity value, so `.neutral` reproduces the pre-genome behaviour exactly and
/// a genome pet nudges motion/chatter/fidget bias without preempting any behaviour.
public struct TheaterPersonality: Equatable {
    public var bounceAmplitude: Double
    public var motionSpeed: Double
    public var blinkRate: Double
    public var chattiness: Double
    public var particleHueShift: Double
    public var fidgetWeights: [Double]
    public var curiosity: Double
    public var playfulness: Double
    public var sociability: Double
    public var patience: Double
    public var energy: Double

    public init(
        bounceAmplitude: Double = 1, motionSpeed: Double = 1, blinkRate: Double = 1,
        chattiness: Double = 1, particleHueShift: Double = 0, fidgetWeights: [Double] = [],
        curiosity: Double = 1, playfulness: Double = 1, sociability: Double = 1,
        patience: Double = 1, energy: Double = 1
    ) {
        self.bounceAmplitude = bounceAmplitude
        self.motionSpeed = motionSpeed
        self.blinkRate = blinkRate
        self.chattiness = chattiness
        self.particleHueShift = particleHueShift
        self.fidgetWeights = fidgetWeights
        self.curiosity = curiosity
        self.playfulness = playfulness
        self.sociability = sociability
        self.patience = patience
        self.energy = energy
    }

    public static let neutral = TheaterPersonality()

    public init(from gene: PersonalityGene) {
        self.init(
            bounceAmplitude: gene.bounceAmplitude,
            motionSpeed: gene.motionSpeed,
            blinkRate: gene.blinkRate,
            chattiness: gene.chattiness,
            particleHueShift: gene.particleHueShift,
            fidgetWeights: gene.fidgetWeights,
            curiosity: gene.curiosity,
            playfulness: gene.playfulness,
            sociability: gene.sociability,
            patience: gene.patience,
            energy: gene.energy
        )
    }
}

/// A pet's full genome-derived render bundle, cached by genome at the call site.
public struct PetLook: Equatable {
    public let appearance: PetAppearance
    public let personality: TheaterPersonality
    public let genome: Int64?

    public init(appearance: PetAppearance, personality: TheaterPersonality, genome: Int64?) {
        self.appearance = appearance
        self.personality = personality
        self.genome = genome
    }

    public static let base = PetLook(appearance: .base, personality: .neutral, genome: nil)

    public static func make(genome: Int64?, species: String) -> PetLook {
        guard let genome else {
            return PetLook(appearance: PetAppearance.resolvedBase(species: species), personality: .neutral, genome: nil)
        }
        let seed = Genome.unpack(genome)
        return PetLook(
            appearance: PetAppearance.make(seed: seed, species: species),
            personality: TheaterPersonality(from: Genome.personality(seed: seed)),
            genome: genome
        )
    }
}
