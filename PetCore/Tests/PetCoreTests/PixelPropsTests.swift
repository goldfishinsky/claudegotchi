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

    func testPropsHaveVisiblePixels() {
        for p in PropSprite.allCases {
            let lit = PixelProps.matrix(p).flatMap { $0 }.contains { $0 != 0 }
            XCTAssertTrue(lit, "\(p) has drawn pixels")
        }
    }
}
