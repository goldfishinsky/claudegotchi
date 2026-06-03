import XCTest
@testable import PetCore

final class SpeciesRouletteTests: XCTestCase {
    func testPicksFromRegistry() throws {
        let url = Bundle.module.url(forResource: "Fixtures/species", withExtension: nil)!
        let registry = try SpeciesRegistry.load(directory: url)
        var rng = SeededRNG(seed: 1)
        let pick = SpeciesRoulette.pick(from: registry, using: &rng)
        XCTAssertEqual(pick.id, "frog")
        XCTAssertFalse(pick.usedFallback)
    }

    func testFallbackOnEmptyRegistry() {
        var rng = SeededRNG(seed: 1)
        let pick = SpeciesRoulette.pick(
            from: SpeciesRegistry(all: []),
            using: &rng
        )
        XCTAssertEqual(pick.id, "frog")
        XCTAssertTrue(pick.usedFallback)
    }

    func testUniformOver4Species() throws {
        let url = Bundle.module.url(forResource: "Fixtures/species", withExtension: nil)!
        let frog = try SpeciesRegistry.load(directory: url).all.first!
        let species = (0..<4).map { i in
            Species(
                id: "s\(i)", nameZh: "x", nameEn: "y",
                stages: frog.stages, animations: frog.animations,
                spriteGrid: frog.spriteGrid, bundleURL: frog.bundleURL
            )
        }
        let registry = SpeciesRegistry(all: species)
        var counts = [String: Int]()
        for seed in (0..<200).map(UInt64.init) {
            var rng = SeededRNG(seed: seed)
            let pick = SpeciesRoulette.pick(from: registry, using: &rng)
            counts[pick.id, default: 0] += 1
        }
        XCTAssertEqual(counts.count, 4, "Across 200 seeds, all 4 species should be reachable")
    }

    func testPickFromIdsDeterministicWithSeed() {
        let ids = ["frog", "slime", "cat", "dragon"]
        var a = SeededRNG(seed: 7)
        var b = SeededRNG(seed: 7)
        let pa = SpeciesRoulette.pick(fromIds: ids, using: &a)
        let pb = SpeciesRoulette.pick(fromIds: ids, using: &b)
        XCTAssertEqual(pa, pb, "same seed → same id")
        XCTAssertTrue(ids.contains(pa))
    }

    func testPickFromIdsSingleton() {
        var rng = SeededRNG(seed: 1)
        XCTAssertEqual(SpeciesRoulette.pick(fromIds: ["only"], using: &rng), "only")
    }
}

struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed | 1 }
    mutating func next() -> UInt64 {
        state &*= 6364136223846793005
        state &+= 1442695040888963407
        return state
    }
}
