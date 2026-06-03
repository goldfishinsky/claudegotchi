import XCTest
@testable import PetCore

final class PixelSpriteTests: XCTestCase {
    let anims = ["idle", "happy", "sick", "sleeping"]

    func testCatalogHasFourKnownIds() {
        XCTAssertEqual(Set(PixelSpeciesCatalog.ids), ["frog", "slime", "cat", "dragon"])
    }

    func testEveryDefHasAllAnimationsWithFrames() {
        for def in PixelSpeciesCatalog.all {
            for anim in anims {
                let frames = def.frames[anim]
                XCTAssertNotNil(frames, "\(def.id) missing \(anim)")
                XCTAssertGreaterThanOrEqual(frames?.count ?? 0, 1)
            }
        }
    }

    func testEveryFrameIs16x16WithInRangeIndices() {
        let count = UInt8(PixelSpeciesCatalog.palette.count)
        for def in PixelSpeciesCatalog.all {
            for (_, frames) in def.frames {
                for frame in frames {
                    XCTAssertEqual(frame.count, 16)
                    for row in frame {
                        XCTAssertEqual(row.count, 16)
                        for px in row { XCTAssertLessThan(px, count) }
                    }
                }
            }
        }
    }

    func testPaletteIndexZeroIsTransparent() {
        XCTAssertEqual(PixelSpeciesCatalog.palette[0] & 0xFF00_0000, 0, "index 0 alpha = 0")
    }

    func testDefLookupAndUnknownNil() {
        XCTAssertEqual(PixelSpeciesCatalog.def("frog")?.id, "frog")
        XCTAssertNil(PixelSpeciesCatalog.def("unicorn"))
    }

    func testStageThresholds() {
        let firstStage = PixelSpeciesCatalog.def("frog")!.stages.first!.id
        XCTAssertEqual(PixelSpeciesCatalog.stage(id: "frog", xp: 0), firstStage)
        XCTAssertEqual(PixelSpeciesCatalog.stage(id: "unicorn", xp: 0), "unknown", "fallback stage for unknown id")
    }

    func testStageAdvancesWithXp() {
        let def = PixelSpeciesCatalog.def("frog")!
        guard def.stages.count >= 2 else { return }
        let secondMin = def.stages[1].minXp
        XCTAssertEqual(PixelSpeciesCatalog.stage(id: "frog", xp: Int64(secondMin)), def.stages[1].id)
    }
}
