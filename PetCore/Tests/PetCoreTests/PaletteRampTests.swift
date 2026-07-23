import XCTest
@testable import PetCore

final class PaletteRampTests: XCTestCase {
    private let body: UInt32 = 0xFF83_CE63
    private let dark: UInt32 = 0xFF4E_9B3A
    private let light: UInt32 = 0xFFE7_F3C0
    private let accent: UInt32 = 0xFF2E_6B1E

    private func bright(_ argb: UInt32) -> Int {
        let r = Int((argb >> 16) & 0xFF), g = Int((argb >> 8) & 0xFF), b = Int(argb & 0xFF)
        return max(r, g, b)
    }

    func testExpandReturnsEightSlots() {
        XCTAssertEqual(PaletteRamp.expand(body: body, dark: dark, light: light, accent: accent).count, 8)
    }

    func testExpandIsDeterministic() {
        let a = PaletteRamp.expand(body: body, dark: dark, light: light, accent: accent)
        let b = PaletteRamp.expand(body: body, dark: dark, light: light, accent: accent)
        XCTAssertEqual(a, b)
    }

    /// The four carried-over slots must be bit-identical to their inputs — this
    /// is what keeps a legacy-symbol grid rendering pixel-for-pixel unchanged.
    func testCarriedSlotsAreBitIdentical() {
        let s = PaletteRamp.expand(body: body, dark: dark, light: light, accent: accent)
        XCTAssertEqual(s[0], body, "slot body")
        XCTAssertEqual(s[1], dark, "slot bodyDark")
        XCTAssertEqual(s[4], light, "slot light")
        XCTAssertEqual(s[7], accent, "slot accent")
    }

    func testSecondaryDefaultsToLight() {
        let s = PaletteRamp.expand(body: body, dark: dark, light: light, accent: accent)
        XCTAssertEqual(s[5], light, "slot secondary defaults to the light region base")
    }

    func testOutlineIsStrictlyDarkerThanBodyDark() {
        let s = PaletteRamp.expand(body: body, dark: dark, light: light, accent: accent)
        XCTAssertLessThan(bright(s[3]), bright(s[1]), "outline must be darker than bodyDark")
    }

    func testBodyLightIsBrighterThanBody() {
        let s = PaletteRamp.expand(body: body, dark: dark, light: light, accent: accent)
        XCTAssertGreaterThan(bright(s[2]), bright(s[0]), "bodyLight must be brighter than body")
    }

    func testSecondaryDarkSitsBetweenLightAndDark() {
        let s = PaletteRamp.expand(body: body, dark: dark, light: light, accent: accent)
        let mid = bright(s[6])
        XCTAssertLessThanOrEqual(mid, bright(light))
        XCTAssertGreaterThanOrEqual(mid, bright(dark))
    }

    func testPreservesFullyOpaqueAlpha() {
        for slot in PaletteRamp.expand(body: body, dark: dark, light: light, accent: accent) {
            XCTAssertEqual((slot >> 24) & 0xFF, 0xFF, "alpha preserved")
        }
    }

    func testResolvedPaletteHasThirtyFourEntriesWithSlotsAtTop() {
        let pal = PixelSpeciesCatalog.resolvedPalette(base4: SpeciesBase4(body: body, dark: dark, light: light, accent: accent))
        XCTAssertEqual(pal.count, 34)
        XCTAssertEqual(pal[Int(PixelSpeciesCatalog.slotBody)], body)
        XCTAssertEqual(pal[Int(PixelSpeciesCatalog.slotAccent)], accent)
    }
}
