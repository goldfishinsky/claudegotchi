import XCTest
@testable import PetCore

final class ConfigYAMLTests: XCTestCase {
    func testLoadsAllConstants() throws {
        let url = Bundle.module.url(forResource: "Fixtures/config-default", withExtension: "yaml")!
        let cfg = try ConfigYAML.load(from: url)
        XCTAssertEqual(cfg.decay.fullnessPerSecond, 0.0006, accuracy: 1e-9)
        XCTAssertEqual(cfg.eventCosts.preToolUseStamina, 0.5)
        XCTAssertEqual(cfg.thresholds.deathConsecutiveDays, 5)
        XCTAssertEqual(cfg.spool.rotateWhenBytesExceed, 10_485_760)
    }

    func testMissingFileFallsBackToDefaults() {
        let cfg = ConfigYAML.defaults
        XCTAssertEqual(cfg.thresholds.deathConsecutiveDays, 5)
    }

    /// Drift guard: the in-Swift `ConfigYAML.defaults` literal must stay in
    /// sync with `Fixtures/config-default.yaml`. If someone tunes one but
    /// not the other, this test fails.
    func testDefaultsMatchBundledYAML() throws {
        let url = Bundle.module.url(forResource: "Fixtures/config-default", withExtension: "yaml")!
        let fromYAML = try ConfigYAML.load(from: url)
        XCTAssertEqual(fromYAML, ConfigYAML.defaults)
    }

    func testWorkDefaults() {
        let w = ConfigYAML.defaults.work
        XCTAssertEqual(w.pollIntervalSeconds, 90)
        XCTAssertEqual(w.pressureBusyThreshold, 1)
        XCTAssertEqual(w.pressureStressedThreshold, 3)
        XCTAssertEqual(w.prApprovedIntimacy, 2.0, accuracy: 1e-9)
        XCTAssertEqual(w.prMergedXp, 50)
        XCTAssertEqual(w.fixTimeoutSeconds, 900)
        XCTAssertEqual(w.fixPermissionMode, "acceptEdits")
        XCTAssertEqual(w.fixAllowedTools, "Edit,Read,Write,Grep,Glob")
        XCTAssertEqual(w.fixDisallowedTools, "WebFetch,WebSearch")
        XCTAssertTrue(w.fixCommit)
    }

    func testWorkDecodesFromYAML() throws {
        let url = Bundle.module.url(forResource: "Fixtures/config-default", withExtension: "yaml")!
        let cfg = try ConfigYAML.load(from: url)
        XCTAssertEqual(cfg.work.pollIntervalSeconds, 90)
        XCTAssertEqual(cfg.work.fixPermissionMode, "acceptEdits")
    }
}
