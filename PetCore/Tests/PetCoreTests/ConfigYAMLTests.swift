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

    private func loadYAML(_ yaml: String) throws -> ConfigYAML {
        let path = NSTemporaryDirectory() + "cfg-\(UUID()).yaml"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try yaml.write(toFile: path, atomically: true, encoding: .utf8)
        return try ConfigYAML.load(from: URL(fileURLWithPath: path))
    }

    private var minimalConfigBody: String {
        """
        decay:
          fullness_per_second: 0.0006
          intimacy_per_second: 0.0003
          stamina_regen_per_second: 0.0002
        event_costs:
          pre_tool_use_stamina: 0.5
          pre_tool_use_stamina_sustained: 1.0
          post_tool_use_fullness_per_2k_tokens: 1.0
          post_tool_use_xp_per_200_tokens: 1.0
          stop_intimacy: 0.5
          pet_click_intimacy: 2.0
        thresholds:
          death_stat_low: 20
          death_low_stats_required: 2
          death_consecutive_days: 5
          hibernation_after_seconds: 259200
          pet_click_cooldown_seconds: 60
          sustained_session_seconds: 1800
          pre_tool_use_timeout_seconds: 300
        spool:
          rotate_when_bytes_exceed: 10485760
          rotate_when_age_exceeds_seconds: 604800
        work:
          poll_interval_seconds: 90
          pressure_busy_threshold: 1
          pressure_stressed_threshold: 3
          pr_approved_intimacy: 2.0
          pr_merged_xp: 50
          fix_timeout_seconds: 900
          fix_permission_mode: acceptEdits
          fix_allowed_tools: "Edit,Read,Write,Grep,Glob"
          fix_disallowed_tools: "WebFetch,WebSearch"
          fix_commit: true
        """
    }

    func testExistingConfigWithoutLeaderboardStillDecodes() throws {
        let cfg = try loadYAML(minimalConfigBody)
        XCTAssertNil(cfg.leaderboard)
        let resolved = cfg.resolvedLeaderboard
        XCTAssertEqual(resolved.baseURL, ConfigYAML.placeholderLeaderboardBaseURL)
        XCTAssertEqual(resolved.syncIntervalSeconds, 1800)
        XCTAssertEqual(resolved.githubClientID, "")
    }

    func testLeaderboardSectionParsed() throws {
        let yaml = minimalConfigBody + """

        leaderboard:
          base_url: "https://cg.example.dev"
          sync_interval_seconds: 600
          github_client_id: "Iv1.abc123"
        """
        let cfg = try loadYAML(yaml)
        XCTAssertEqual(cfg.leaderboard?.baseURL, "https://cg.example.dev")
        let resolved = cfg.resolvedLeaderboard
        XCTAssertEqual(resolved.baseURL, "https://cg.example.dev")
        XCTAssertEqual(resolved.syncIntervalSeconds, 600)
        XCTAssertEqual(resolved.githubClientID, "Iv1.abc123")
    }

    func testLeaderboardPartialSectionUsesDefaults() throws {
        let yaml = minimalConfigBody + """

        leaderboard:
          github_client_id: "Iv1.only"
        """
        let cfg = try loadYAML(yaml)
        let resolved = cfg.resolvedLeaderboard
        XCTAssertEqual(resolved.baseURL, ConfigYAML.placeholderLeaderboardBaseURL)
        XCTAssertEqual(resolved.syncIntervalSeconds, 1800)
        XCTAssertEqual(resolved.githubClientID, "Iv1.only")
    }
}
