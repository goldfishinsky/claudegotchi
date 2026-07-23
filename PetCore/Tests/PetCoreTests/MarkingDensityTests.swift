import XCTest
@testable import PetCore

/// Markings scale their feature size with grid density so a 32×32 pet reads the
/// same as it did at 16×16: spots become 2×2 clusters, stripe bands double.
final class MarkingDensityTests: XCTestCase {
    private let body: UInt8 = 1
    private let dark: UInt8 = 2

    private func solid(_ side: Int) -> [[UInt8]] {
        Array(repeating: Array(repeating: body, count: side), count: side)
    }

    private func coverage(_ g: [[UInt8]]) -> Double {
        let total = g.reduce(0) { $0 + $1.count }
        let hit = g.reduce(0) { $0 + $1.filter { $0 == dark }.count }
        return Double(hit) / Double(total)
    }

    func testSpotsFormAlignedTwoByTwoClustersOn32Grid() {
        let gene = MarkingGene(kind: .spots, patternSeed: 0xABCD_1234)
        let out = gene.apply(to: solid(32), bodyIndex: body, darkIndex: dark)
        for r in stride(from: 0, to: 32, by: 2) {
            for c in stride(from: 0, to: 32, by: 2) {
                let block = [out[r][c], out[r][c + 1], out[r + 1][c], out[r + 1][c + 1]]
                XCTAssertEqual(Set(block).count, 1, "2×2 spot block at (\(r),\(c)) is not uniform")
            }
        }
    }

    func testSpotsCoverageIsSimilarAcrossGridSizes() {
        for seed: UInt64 in [1, 7, 42, 9999] {
            let gene = MarkingGene(kind: .spots, patternSeed: seed)
            let c16 = coverage(gene.apply(to: solid(16), bodyIndex: body, darkIndex: dark))
            let c32 = coverage(gene.apply(to: solid(32), bodyIndex: body, darkIndex: dark))
            XCTAssertEqual(c16, 0.22, accuracy: 0.12, "16 spot coverage off (seed \(seed))")
            XCTAssertEqual(c32, 0.22, accuracy: 0.12, "32 spot coverage off (seed \(seed))")
        }
    }

    func testStripeBandsDoubleOn32Grid() {
        // Band width for a given seed must be exactly twice the 16-grid width.
        for seed: UInt64 in [0, 1, 2, 3, 4, 5] {
            let gene = MarkingGene(kind: .stripes, patternSeed: seed)
            let b16 = maxRun(gene.apply(to: solid(16), bodyIndex: body, darkIndex: dark))
            let b32 = maxRun(gene.apply(to: solid(32), bodyIndex: body, darkIndex: dark))
            XCTAssertEqual(b32, b16 * 2, "stripe band did not double (seed \(seed): 16=\(b16) 32=\(b32))")
        }
    }

    /// Longest vertical run of dark in column 0 — the band thickness.
    private func maxRun(_ g: [[UInt8]]) -> Int {
        var best = 0, cur = 0
        for row in g {
            if row.first == dark { cur += 1; best = max(best, cur) } else { cur = 0 }
        }
        return best
    }

    func testDeterministicOnBothGridSizes() {
        for kind in MarkingKind.allCases where kind != .none {
            let gene = MarkingGene(kind: kind, patternSeed: 555)
            for side in [16, 32] {
                let a = gene.apply(to: solid(side), bodyIndex: body, darkIndex: dark)
                let b = gene.apply(to: solid(side), bodyIndex: body, darkIndex: dark)
                XCTAssertEqual(a, b, "\(kind) not deterministic at \(side)")
            }
        }
    }

    func testSafeOnRaggedAndEmptyAt32Scale() {
        let ragged: [[UInt8]] = [Array(repeating: body, count: 30), [body], []]
        for kind in MarkingKind.allCases where kind != .none {
            let gene = MarkingGene(kind: kind, patternSeed: 77)
            let out = gene.apply(to: ragged, bodyIndex: body, darkIndex: dark)
            XCTAssertEqual(out.count, 3)
            XCTAssertEqual(out[0].count, 30)
            XCTAssertEqual(out[1].count, 1)
            XCTAssertEqual(out[2].count, 0)
        }
    }

    func testStarAndBellyStayWithinBodyOn32Grid() {
        for kind in [MarkingKind.starPatch, .bellyPatch] {
            let gene = MarkingGene(kind: kind, patternSeed: 314)
            let out = gene.apply(to: solid(32), bodyIndex: body, darkIndex: dark)
            for row in out { for px in row { XCTAssertTrue(px == body || px == dark) } }
            XCTAssertGreaterThan(coverage(out), 0, "\(kind) marked nothing")
        }
    }
}
