import XCTest
@testable import PetCore

final class TitleMarkerTests: XCTestCase {
    func testTokenIsGlyphPlusFirstSixHex() {
        XCTAssertEqual(TitleMarker.token(forSessionId: "4163ffb0-4f9b-4cf9-a004"), "❖4163ff")
    }

    func testTokenStripsCodexNamespace() {
        XCTAssertEqual(TitleMarker.token(forSessionId: "codex-abcdef12-3456"), "❖abcdef")
    }

    func testTokenShorterThanSixReturnsWhatIsAvailable() {
        XCTAssertEqual(TitleMarker.token(forSessionId: "ab-c"), "❖abc")
    }

    func testEscapeSequenceWrapsTokenAndRepo() {
        let esc = TitleMarker.escapeSequence(token: "❖4163ff", repo: "claudegotchi")
        XCTAssertEqual(esc, "\u{1b}]0;❖4163ff claudegotchi\u{07}")
    }

    func testEscapeSequenceOmitsRepoWhenEmpty() {
        XCTAssertEqual(TitleMarker.escapeSequence(token: "❖abc", repo: ""), "\u{1b}]0;❖abc\u{07}")
    }

    func testRepoLabelIsBasename() {
        XCTAssertEqual(TitleMarker.repoLabel(cwd: "/Users/jalen/code/claudegotchi/"), "claudegotchi")
        XCTAssertEqual(TitleMarker.repoLabel(cwd: nil), "")
        XCTAssertEqual(TitleMarker.repoLabel(cwd: ""), "")
    }

    func testEnabledByDefaultAndToggleViaFlagFile() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tm-\(UUID().uuidString)")
        let flag = TitleMarker.disabledFlagURL(appSupport: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertTrue(TitleMarker.isEnabled(flagURL: flag), "fresh install: markers on")

        TitleMarker.setEnabled(false, flagURL: flag)
        XCTAssertFalse(TitleMarker.isEnabled(flagURL: flag))
        XCTAssertTrue(FileManager.default.fileExists(atPath: flag.path))

        TitleMarker.setEnabled(true, flagURL: flag)
        XCTAssertTrue(TitleMarker.isEnabled(flagURL: flag))
        XCTAssertFalse(FileManager.default.fileExists(atPath: flag.path))
    }
}
