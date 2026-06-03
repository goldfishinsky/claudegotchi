import Foundation
import Yams

public struct ConfigYAML: Codable, Equatable {
    public let decay: Decay
    public let eventCosts: EventCosts
    public let thresholds: Thresholds
    public let spool: Spool
    public let work: Work

    enum CodingKeys: String, CodingKey {
        case decay
        case eventCosts = "event_costs"
        case thresholds
        case spool
        case work
    }

    public struct Decay: Codable, Equatable {
        public let fullnessPerSecond: Double
        public let intimacyPerSecond: Double
        public let staminaRegenPerSecond: Double
        enum CodingKeys: String, CodingKey {
            case fullnessPerSecond = "fullness_per_second"
            case intimacyPerSecond = "intimacy_per_second"
            case staminaRegenPerSecond = "stamina_regen_per_second"
        }
    }

    public struct EventCosts: Codable, Equatable {
        public let preToolUseStamina: Double
        public let preToolUseStaminaSustained: Double
        public let postToolUseFullnessPer2kTokens: Double
        public let postToolUseXpPer200Tokens: Double
        public let stopIntimacy: Double
        public let petClickIntimacy: Double
        enum CodingKeys: String, CodingKey {
            case preToolUseStamina = "pre_tool_use_stamina"
            case preToolUseStaminaSustained = "pre_tool_use_stamina_sustained"
            case postToolUseFullnessPer2kTokens = "post_tool_use_fullness_per_2k_tokens"
            case postToolUseXpPer200Tokens = "post_tool_use_xp_per_200_tokens"
            case stopIntimacy = "stop_intimacy"
            case petClickIntimacy = "pet_click_intimacy"
        }
    }

    public struct Thresholds: Codable, Equatable {
        public let deathStatLow: Double
        public let deathLowStatsRequired: Int
        public let deathConsecutiveDays: Int
        public let hibernationAfterSeconds: Int
        public let petClickCooldownSeconds: Int
        public let sustainedSessionSeconds: Int
        public let preToolUseTimeoutSeconds: Int
        enum CodingKeys: String, CodingKey {
            case deathStatLow = "death_stat_low"
            case deathLowStatsRequired = "death_low_stats_required"
            case deathConsecutiveDays = "death_consecutive_days"
            case hibernationAfterSeconds = "hibernation_after_seconds"
            case petClickCooldownSeconds = "pet_click_cooldown_seconds"
            case sustainedSessionSeconds = "sustained_session_seconds"
            case preToolUseTimeoutSeconds = "pre_tool_use_timeout_seconds"
        }
    }

    public struct Spool: Codable, Equatable {
        public let rotateWhenBytesExceed: Int
        public let rotateWhenAgeExceedsSeconds: Int
        enum CodingKeys: String, CodingKey {
            case rotateWhenBytesExceed = "rotate_when_bytes_exceed"
            case rotateWhenAgeExceedsSeconds = "rotate_when_age_exceeds_seconds"
        }
    }

    public struct Work: Codable, Equatable {
        public let pollIntervalSeconds: Int
        public let pressureBusyThreshold: Int
        public let pressureStressedThreshold: Int
        public let prApprovedIntimacy: Double
        public let prMergedXp: Int64
        public let fixTimeoutSeconds: Int
        public let fixPermissionMode: String
        public let fixAllowedTools: String
        public let fixDisallowedTools: String
        public let fixCommit: Bool
        enum CodingKeys: String, CodingKey {
            case pollIntervalSeconds = "poll_interval_seconds"
            case pressureBusyThreshold = "pressure_busy_threshold"
            case pressureStressedThreshold = "pressure_stressed_threshold"
            case prApprovedIntimacy = "pr_approved_intimacy"
            case prMergedXp = "pr_merged_xp"
            case fixTimeoutSeconds = "fix_timeout_seconds"
            case fixPermissionMode = "fix_permission_mode"
            case fixAllowedTools = "fix_allowed_tools"
            case fixDisallowedTools = "fix_disallowed_tools"
            case fixCommit = "fix_commit"
        }
    }

    public static func load(from url: URL) throws -> ConfigYAML {
        let raw = try String(contentsOf: url)
        return try YAMLDecoder().decode(ConfigYAML.self, from: raw)
    }

    public static let defaults: ConfigYAML = ConfigYAML(
        decay: .init(fullnessPerSecond: 0.0006, intimacyPerSecond: 0.0003, staminaRegenPerSecond: 0.0002),
        eventCosts: .init(
            preToolUseStamina: 0.5, preToolUseStaminaSustained: 1.0,
            postToolUseFullnessPer2kTokens: 1.0, postToolUseXpPer200Tokens: 1.0,
            stopIntimacy: 0.5, petClickIntimacy: 2.0
        ),
        thresholds: .init(
            deathStatLow: 20, deathLowStatsRequired: 2, deathConsecutiveDays: 5,
            hibernationAfterSeconds: 259200, petClickCooldownSeconds: 60,
            sustainedSessionSeconds: 1800, preToolUseTimeoutSeconds: 300
        ),
        spool: .init(rotateWhenBytesExceed: 10_485_760, rotateWhenAgeExceedsSeconds: 604_800),
        work: .init(
            pollIntervalSeconds: 90,
            pressureBusyThreshold: 1, pressureStressedThreshold: 3,
            prApprovedIntimacy: 2.0, prMergedXp: 50,
            fixTimeoutSeconds: 900, fixPermissionMode: "acceptEdits",
            fixAllowedTools: "Edit,Read,Write,Grep,Glob",
            fixDisallowedTools: "WebFetch,WebSearch", fixCommit: true
        )
    )
}
