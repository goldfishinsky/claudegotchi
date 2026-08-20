import XCTest
@testable import PetCore

final class SpeciesCatalogTests: XCTestCase {
    private var frog: PixelSpeciesDef { PixelSpeciesCatalog.def("frog")! }

    func testRosterHasElevenDistinctSpecies() {
        let ids = PixelSpeciesCatalog.ids
        XCTAssertEqual(ids.count, 11)
        XCTAssertEqual(Set(ids).count, ids.count, "ids are unique")
        XCTAssertEqual(
            Set(ids),
            ["frog", "slime", "cat", "dragon",
             "dog", "goldfish", "bird", "rabbit", "hamster", "turtle", "hedgehog"]
        )
    }

    func testEverySpeciesHasNonEmptyChineseName() {
        for def in PixelSpeciesCatalog.all {
            XCTAssertFalse(def.nameZh.isEmpty, "\(def.id) missing nameZh")
        }
    }

    /// Parity guard: every species must expose the exact same frame-key set as
    /// the frog reference, so the theater's stage/anim lookups resolve uniformly.
    func testEverySpeciesFrameKeySetEqualsFrog() {
        let expected = Set(frog.frames.keys)
        XCTAssertFalse(expected.isEmpty)
        for def in PixelSpeciesCatalog.all {
            XCTAssertEqual(
                Set(def.frames.keys), expected,
                "\(def.id) frame-key set differs from frog"
            )
        }
    }

    func testEverySpeciesStagesMatchFrog() {
        for def in PixelSpeciesCatalog.all {
            XCTAssertEqual(def.stages.map(\.id), frog.stages.map(\.id), "\(def.id) stage ids")
            XCTAssertEqual(def.stages.map(\.minXp), frog.stages.map(\.minXp), "\(def.id) stage thresholds")
        }
    }

    func testEveryFrameIsLegal32x32WithinPalette() {
        let cap = UInt8(PixelSpeciesCatalog.palette.count)
        for def in PixelSpeciesCatalog.all {
            for (key, frames) in def.frames {
                XCTAssertGreaterThanOrEqual(frames.count, 1, "\(def.id)/\(key) empty")
                for frame in frames {
                    XCTAssertEqual(frame.count, 32, "\(def.id)/\(key) row count")
                    for row in frame {
                        XCTAssertEqual(row.count, 32, "\(def.id)/\(key) col count")
                        for px in row { XCTAssertLessThan(px, cap, "\(def.id)/\(key) index in palette") }
                    }
                }
            }
        }
    }

    func testEveryIconGridIs16x16() {
        let cap = UInt8(PixelSpeciesCatalog.palette.count)
        for def in PixelSpeciesCatalog.all {
            XCTAssertEqual(Set(def.iconGrids.keys), ["baby", "child", "adult"], "\(def.id) icon stages")
            for (stage, grid) in def.iconGrids {
                XCTAssertEqual(grid.count, 16, "\(def.id)/\(stage) icon row count")
                for row in grid {
                    XCTAssertEqual(row.count, 16, "\(def.id)/\(stage) icon col count")
                    for px in row { XCTAssertLessThan(px, cap, "\(def.id)/\(stage) icon index in palette") }
                }
            }
        }
    }

    func testEveryFrameHasVisiblePixels() {
        for def in PixelSpeciesCatalog.all {
            for (key, frames) in def.frames {
                for (i, frame) in frames.enumerated() {
                    let lit = frame.flatMap { $0 }.contains { $0 != 0 }
                    XCTAssertTrue(lit, "\(def.id)/\(key) frame \(i) is fully transparent")
                }
            }
        }
    }

    func testIdleAndTheaterAnimsAreMultiFrame() {
        for def in PixelSpeciesCatalog.all {
            for stage in ["baby", "child", "adult"] {
                for anim in ["idle", "happy", "sick", "sleeping"] {
                    let frames = def.frames["\(stage)/\(anim)"]
                    XCTAssertNotNil(frames, "\(def.id) missing \(stage)/\(anim)")
                    XCTAssertGreaterThanOrEqual(frames?.count ?? 0, 2, "\(def.id) \(stage)/\(anim) needs >= 2 frames")
                }
            }
        }
    }

    func testSickFramesKeepIdentityColorInsteadOfLegacyGrayGreenWash() {
        for def in PixelSpeciesCatalog.all {
            for stage in ["baby", "child", "adult"] {
                for frame in def.frames["\(stage)/sick"] ?? [] {
                    XCTAssertFalse(
                        frame.flatMap { $0 }.contains(6),
                        "\(def.id)/\(stage) sick frame must not replace the body with the legacy sick tint"
                    )
                }
            }
        }
    }
}
