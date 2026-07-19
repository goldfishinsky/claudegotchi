import XCTest
@testable import PetCore

final class QuietSceneTests: XCTestCase {
    func testDisplayCaptureActivatesRegardlessOfApp() {
        XCTAssertTrue(QuietScene.isActive(displayCaptured: true, frontmostBundleID: nil))
        XCTAssertTrue(QuietScene.isActive(displayCaptured: true, frontmostBundleID: "com.apple.Terminal"))
    }

    func testKnownCaptureAppFrontmostActivates() {
        XCTAssertTrue(QuietScene.isActive(displayCaptured: false, frontmostBundleID: "us.zoom.xos"))
        XCTAssertTrue(QuietScene.isActive(displayCaptured: false, frontmostBundleID: "com.obsproject.obs-studio"))
    }

    func testOrdinaryAppIsNotQuiet() {
        XCTAssertFalse(QuietScene.isActive(displayCaptured: false, frontmostBundleID: "com.apple.Terminal"))
        XCTAssertFalse(QuietScene.isActive(displayCaptured: false, frontmostBundleID: nil))
    }

    func testCustomCaptureListIsHonored() {
        XCTAssertFalse(QuietScene.isActive(
            displayCaptured: false, frontmostBundleID: "us.zoom.xos", captureAppBundleIDs: []))
        XCTAssertTrue(QuietScene.isActive(
            displayCaptured: false, frontmostBundleID: "com.example.recorder",
            captureAppBundleIDs: ["com.example.recorder"]))
    }
}
