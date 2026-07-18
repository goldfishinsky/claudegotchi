import XCTest
@testable import PetCore

final class PixelPropsTests: XCTestCase {
    func testAllPropsAreWithinTwelveByTwelve() {
        for p in PropSprite.allCases {
            let m = PixelProps.matrix(p)
            XCTAssertGreaterThan(m.count, 0, "\(p) not empty")
            XCTAssertLessThanOrEqual(m.count, 12, "\(p) height ≤ 12")
            let width = m.first?.count ?? 0
            XCTAssertLessThanOrEqual(width, 12, "\(p) width ≤ 12")
            for row in m { XCTAssertEqual(row.count, width, "\(p) rows are rectangular") }
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
        XCTAssertLessThanOrEqual(PixelSpeciesCatalog.palette.count, 32)
    }

    func testPropsHaveVisiblePixels() {
        for p in PropSprite.allCases {
            let lit = PixelProps.matrix(p).flatMap { $0 }.contains { $0 != 0 }
            XCTAssertTrue(lit, "\(p) has drawn pixels")
        }
    }
}
