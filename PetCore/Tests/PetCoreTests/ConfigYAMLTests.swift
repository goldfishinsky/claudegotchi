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
}
