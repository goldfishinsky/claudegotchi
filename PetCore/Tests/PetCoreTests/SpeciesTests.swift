import XCTest
@testable import PetCore

final class SpeciesTests: XCTestCase {
    var fixturesURL: URL {
        Bundle.module.url(forResource: "Fixtures/species", withExtension: nil)!
    }

    func testLoadValidSpecies() throws {
        let registry = try SpeciesRegistry.load(directory: fixturesURL)
        XCTAssertEqual(registry.all.count, 1)
        XCTAssertEqual(registry.all.first?.id, "frog")
        XCTAssertEqual(registry.all.first?.stages.count, 4)
    }

    func testFrameIndicesWithinBounds() throws {
        let registry = try SpeciesRegistry.load(directory: fixturesURL)
        let frog = registry.all.first!
        XCTAssertEqual(frog.maxFrameIndex, 8)
        for indices in frog.animations.values {
            for i in indices {
                XCTAssertLessThanOrEqual(i, frog.maxFrameIndex)
            }
        }
    }

    /// Regression guard: catches anyone breaking the `min_xp` ↔ `minXp`
    /// CodingKeys mapping on Species.Stage.
    func testStageMinXpDecodes() throws {
        let registry = try SpeciesRegistry.load(directory: fixturesURL)
        let frog = registry.all.first!
        XCTAssertEqual(frog.stages.map(\.minXp), [0, 50, 200, 800])
    }

    func testLoadEmptyDirectoryReturnsEmptyRegistry() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("empty-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let registry = try SpeciesRegistry.load(directory: tmp)
        XCTAssertTrue(registry.all.isEmpty)
    }
}
