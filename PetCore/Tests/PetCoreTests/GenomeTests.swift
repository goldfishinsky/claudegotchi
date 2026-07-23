import XCTest
@testable import PetCore

final class GenomeTests: XCTestCase {
    private let fullCatalogIDs = [
        "dog", "cat", "goldfish", "bird", "rabbit", "hamster", "frog", "turtle", "hedgehog", "slime", "dragon",
    ]

    // MARK: - GenomeRNG

    func testGenomeRNGIsDeterministicForSameSeedAndStream() {
        var a = GenomeRNG(seed: 42, stream: "test.stream")
        var b = GenomeRNG(seed: 42, stream: "test.stream")
        let seqA = (0..<10).map { _ in a.next() }
        let seqB = (0..<10).map { _ in b.next() }
        XCTAssertEqual(seqA, seqB)
    }

    func testGenomeRNGDiffersAcrossStreams() {
        var a = GenomeRNG(seed: 42, stream: "stream.a")
        var b = GenomeRNG(seed: 42, stream: "stream.b")
        XCTAssertNotEqual(a.next(), b.next())
    }

    func testGenomeRNGDiffersAcrossSeeds() {
        var a = GenomeRNG(seed: 1, stream: "same")
        var b = GenomeRNG(seed: 2, stream: "same")
        XCTAssertNotEqual(a.next(), b.next())
    }

    // MARK: - whole-genome determinism & dimension isolation

    func testAllDimensionsAreIdenticalForSameSeed() {
        let seed: UInt64 = 0xDEAD_BEEF_1234_5678
        XCTAssertEqual(Genome.species(seed: seed, availableIDs: fullCatalogIDs), Genome.species(seed: seed, availableIDs: fullCatalogIDs))
        XCTAssertEqual(Genome.paletteTransform(seed: seed), Genome.paletteTransform(seed: seed))
        XCTAssertEqual(Genome.markings(seed: seed), Genome.markings(seed: seed))
        XCTAssertEqual(Genome.personality(seed: seed), Genome.personality(seed: seed))
    }

    func testAddingADimensionDoesNotDisturbAnotherDimension() {
        let seed: UInt64 = 99
        // Deriving species first (or not at all) must not change what
        // palette/markings/personality independently derive from the same seed.
        let personalityAlone = Genome.personality(seed: seed)
        _ = Genome.species(seed: seed, availableIDs: fullCatalogIDs)
        _ = Genome.paletteTransform(seed: seed)
        _ = Genome.markings(seed: seed)
        let personalityAfter = Genome.personality(seed: seed)
        XCTAssertEqual(personalityAlone, personalityAfter)
    }

    // MARK: - species weighting

    func testSpeciesDistributionMatchesWeightsWithinTwoPercent() throws {
        let expected: [String: Double] = [
            "dog": 15, "cat": 15, "goldfish": 12, "bird": 12, "rabbit": 10,
            "hamster": 10, "frog": 8, "turtle": 7, "hedgehog": 6, "slime": 3, "dragon": 2,
        ]
        var counts: [String: Int] = [:]
        let n = 10_000
        for i in 0..<n {
            let id = Genome.species(seed: UInt64(i), availableIDs: fullCatalogIDs)
            counts[id, default: 0] += 1
        }
        for (id, expectedWeight) in expected {
            let pct = Double(counts[id] ?? 0) / Double(n) * 100
            XCTAssertEqual(pct, expectedWeight, accuracy: 2.0, "\(id) distribution off target")
        }
        let dragonCount = counts["dragon"] ?? 0
        for (id, count) in counts where id != "dragon" {
            XCTAssertLessThan(dragonCount, count, "dragon must be the rarest species, but \(id) had fewer picks")
        }
    }

    func testSpeciesFiltersUnavailableIDsAndRenormalizes() {
        // With only two ids available, every pick must be one of the two.
        let ids = ["dog", "dragon"]
        for i in 0..<200 {
            let pick = Genome.species(seed: UInt64(i), availableIDs: ids)
            XCTAssertTrue(ids.contains(pick))
        }
    }

    func testSpeciesUnweightedIDGetsDefaultWeight() {
        // An id absent from the weight table must still be pickable (default weight 5).
        var sawCustom = false
        for i in 0..<2_000 {
            let pick = Genome.species(seed: UInt64(i), availableIDs: ["totally-custom-species", "dragon"])
            if pick == "totally-custom-species" { sawCustom = true; break }
        }
        XCTAssertTrue(sawCustom, "an id with no explicit weight should still be reachable via the default weight")
    }

    // MARK: - palette rarity

    func testPaletteTierDistributionMatchesDesignWithinTwoPercent() {
        var tierCounts: [RarityTier: Int] = [.common: 0, .uncommon: 0, .shiny: 0]
        let n = 10_000
        for i in 0..<n {
            let gene = Genome.paletteTransform(seed: UInt64(i))
            tierCounts[gene.rarityTier, default: 0] += 1
        }
        XCTAssertEqual(Double(tierCounts[.common] ?? 0) / Double(n) * 100, 70, accuracy: 2.0)
        XCTAssertEqual(Double(tierCounts[.uncommon] ?? 0) / Double(n) * 100, 25, accuracy: 2.0)
        XCTAssertEqual(Double(tierCounts[.shiny] ?? 0) / Double(n) * 100, 5, accuracy: 2.0)
    }

    func testPaletteApplyReplacesOnlyMappedSlots() {
        let gene = Genome.paletteTransform(seed: 7)
        let base: [UInt32] = [0, 1, 2, 3, 4, 5]
        let ink = InkIndices(body: 2, dark: 3, light: 4, accent: 5)
        let out = gene.apply(to: base, ink: ink)
        XCTAssertEqual(out[0], base[0])
        XCTAssertEqual(out[1], base[1])
        XCTAssertEqual(out[2], gene.body)
        XCTAssertEqual(out[3], gene.dark)
        XCTAssertEqual(out[4], gene.light)
        XCTAssertEqual(out[5], gene.accent)
    }

    func testPaletteApplyIsSafeWithOutOfRangeIndicesAndEmptyPalette() {
        let gene = Genome.paletteTransform(seed: 3)
        let ink = InkIndices(body: 10, dark: 11, light: 12, accent: 13)
        let base: [UInt32] = [1, 2, 3]
        let out = gene.apply(to: base, ink: ink)
        XCTAssertEqual(out, base, "out-of-range ink indices must leave the palette untouched")
        XCTAssertEqual(gene.apply(to: [], ink: ink), [], "empty palette must return as-is")
    }

    // MARK: - markings

    func testMarkingsApplyIsSafeOnEmptyGrid() {
        let gene = Genome.markings(seed: 1)
        XCTAssertEqual(gene.apply(to: [], bodyIndex: 1, darkIndex: 2), [])
    }

    func testMarkingsApplyIsSafeOn1x1Grid() {
        for seed: UInt64 in 0..<200 {
            let gene = Genome.markings(seed: seed)
            let out = gene.apply(to: [[1]], bodyIndex: 1, darkIndex: 2)
            XCTAssertEqual(out.count, 1)
            XCTAssertEqual(out[0].count, 1)
            XCTAssertTrue(out[0][0] == 1 || out[0][0] == 2)
        }
    }

    func testMarkingsApplyIsSafeOnRaggedGrid() {
        let gene = MarkingGene(kind: .spots, patternSeed: 123)
        let ragged: [[UInt8]] = [[1, 1, 1], [1], []]
        let out = gene.apply(to: ragged, bodyIndex: 1, darkIndex: 2)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[1].count, 1)
        XCTAssertEqual(out[2].count, 0)
    }

    func testMarkingsNoneLeavesGridUnchanged() {
        let gene = MarkingGene(kind: .none, patternSeed: 999)
        let grid: [[UInt8]] = [[1, 1], [1, 1]]
        XCTAssertEqual(gene.apply(to: grid, bodyIndex: 1, darkIndex: 2), grid)
    }

    func testMarkingsDistributionMatchesWeightsWithinTwoPercent() {
        let expected: [MarkingKind: Double] = [
            .none: 40, .spots: 22, .stripes: 20, .bellyPatch: 12, .starPatch: 6,
        ]
        var counts: [MarkingKind: Int] = [:]
        let n = 10_000
        for i in 0..<n {
            counts[Genome.markings(seed: UInt64(i)).kind, default: 0] += 1
        }
        for (kind, expectedWeight) in expected {
            let pct = Double(counts[kind] ?? 0) / Double(n) * 100
            XCTAssertEqual(pct, expectedWeight, accuracy: 2.0, "\(kind) distribution off target")
        }
    }

    // MARK: - personality

    func testPersonalityRangesAreRespected() {
        for i: UInt64 in 0..<500 {
            let gene = Genome.personality(seed: i)
            XCTAssertTrue((0.7...1.3).contains(gene.bounceAmplitude))
            XCTAssertTrue((0.85...1.2).contains(gene.motionSpeed))
            XCTAssertTrue((0.6...1.6).contains(gene.blinkRate))
            XCTAssertTrue((0.5...1.5).contains(gene.chattiness))
            XCTAssertTrue((0..<360).contains(gene.particleHueShift))
            XCTAssertEqual(gene.fidgetWeights.count, 8)
            XCTAssertEqual(gene.fidgetWeights.reduce(0, +), 1.0, accuracy: 1e-9)
        }
    }

    // MARK: - pack/unpack round trip

    func testPackUnpackRoundTrips() {
        for seed: UInt64 in [0, 1, .max, .max / 2, 0x8000_0000_0000_0000] {
            XCTAssertEqual(Genome.unpack(Genome.pack(seed)), seed)
        }
    }
}
