import XCTest
@testable import PetCore

final class PixelPropsTests: XCTestCase {
    func testAllPropsStayUnderStageBudget() {
        for p in PropSprite.allCases {
            let m = PixelProps.matrix(p)
            XCTAssertGreaterThan(m.count, 0, "\(p) not empty")
            let width = m.first?.count ?? 0
            for row in m { XCTAssertEqual(row.count, width, "\(p) rows are rectangular") }
            let size = PixelProps.size(p)
            XCTAssertLessThanOrEqual(size.height, 6.5, "\(p) height ≤ 6.5 stage units")
            XCTAssertLessThanOrEqual(size.width, 10, "\(p) width ≤ 10 stage units")
        }
    }

    func testAllPropIndicesAreInPalette() {
        let cap = UInt8(PixelSpeciesCatalog.palette.count)
        for p in PropSprite.allCases {
            for row in PixelProps.matrix(p) {
                for px in row { XCTAssertLessThan(px, cap, "\(p) index in palette") }
            }
        }
    }

    func testPaletteStillWithinCap() {
        XCTAssertLessThanOrEqual(PixelSpeciesCatalog.palette.count, 64)
    }

    func testLaptopIsSeenFromBehind() {
        let m = PixelProps.matrix(.laptop)
        func width(_ r: Int) -> Int { m[r].filter { $0 != 0 }.count }
        XCTAssertLessThan(width(0), width(m.count / 2), "the lid tapers away from the viewer")
        XCTAssertFalse(m.contains { $0.contains(36) }, "the screen faces the pet, not the audience")
        XCTAssertTrue(m.contains { $0.contains(2) }, "the shell carries a badge")
        XCTAssertGreaterThan(width(m.count - 2), width(m.count - 3),
                             "the deck's side edges clear the lid")
    }

    func testPropsHaveVisiblePixels() {
        for p in PropSprite.allCases {
            let lit = PixelProps.matrix(p).flatMap { $0 }.contains { $0 != 0 }
            XCTAssertTrue(lit, "\(p) has drawn pixels")
        }
    }
}
