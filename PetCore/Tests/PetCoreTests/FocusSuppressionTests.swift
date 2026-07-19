import XCTest
@testable import PetCore

final class FocusSuppressionTests: XCTestCase {
    func testSuppressesWhenTitleContainsBasename() {
        XCTAssertTrue(FocusSuppression.suppresses(
            axTrusted: true, focusedWindowTitle: "jalen — claudegotchi — zsh",
            cwd: "/Users/jalen/code/claudegotchi"))
    }

    func testCaseInsensitive() {
        XCTAssertTrue(FocusSuppression.suppresses(
            axTrusted: true, focusedWindowTitle: "CLAUDEGOTCHI", cwd: "/x/claudegotchi"))
    }

    func testNoSuppressionWithoutAX() {
        XCTAssertFalse(FocusSuppression.suppresses(
            axTrusted: false, focusedWindowTitle: "claudegotchi — zsh", cwd: "/x/claudegotchi"),
            "without AX trust there is no title to inspect")
    }

    func testNoSuppressionWhenTitleMissing() {
        XCTAssertFalse(FocusSuppression.suppresses(
            axTrusted: true, focusedWindowTitle: nil, cwd: "/x/claudegotchi"))
    }

    func testNoSuppressionWhenCwdMissingOrEmpty() {
        XCTAssertFalse(FocusSuppression.suppresses(
            axTrusted: true, focusedWindowTitle: "anything", cwd: nil))
        XCTAssertFalse(FocusSuppression.suppresses(
            axTrusted: true, focusedWindowTitle: "anything", cwd: "/"))
    }

    func testDifferentRepoNotSuppressed() {
        XCTAssertFalse(FocusSuppression.suppresses(
            axTrusted: true, focusedWindowTitle: "some-other-repo — zsh",
            cwd: "/x/claudegotchi"))
    }

    func testTrailingSlashBasename() {
        XCTAssertEqual(FocusSuppression.basename("/Users/jalen/code/app/"), "app")
        XCTAssertEqual(FocusSuppression.basename("/"), "")
    }
}
