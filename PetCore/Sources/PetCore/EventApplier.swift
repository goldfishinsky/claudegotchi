import Foundation

public final class EventApplier {
    public struct PendingPreUse {
        public let eventId: String
        public let sessionId: String
        public let tool: String
        public let startedMs: Int64
    }

    private struct SessionStart {
        let startedMs: Int64
    }

    private let config: ConfigYAML
    private var pending: [String: PendingPreUse] = [:]
    private var sessionStarts: [String: SessionStart] = [:]

    public init(config: ConfigYAML) { self.config = config }

    public var pendingCount: Int { pending.count }

    public func apply(event: Event, to pet: Pet) -> Pet {
        var p = pet

        switch event.type {
        case .sessionStart:
            if let sid = event.sessionId {
                sessionStarts[sid] = SessionStart(startedMs: event.ts)
            }
            if p.hibernationSince != nil {
                p.hibernationSince = nil
                p.lastTickAt = event.ts
            }

        case .preToolUse:
            // Defensive: malformed pre_tool_use missing session_id or tool
            // silently dropped (no stamina charge, no pending entry). The
            // helper always populates both fields per spec §4.
            guard let sid = event.sessionId, let tool = event.tool else { return p }
            // Storm damping: only the first pre_tool_use per charge window drains
            // stamina; the marker persists on the pet so replay stays idempotent.
            let windowMs = Int64(config.eventCosts.resolvedStaminaChargeWindowSeconds) * 1000
            let charges = p.lastStaminaChargeAt.map { event.ts - $0 >= windowMs } ?? true
            if charges {
                let cost = isSustained(sessionId: sid, eventMs: event.ts)
                    ? config.eventCosts.preToolUseStaminaSustained
                    : config.eventCosts.preToolUseStamina
                p.stamina = clamp(p.stamina - cost)
                p.lastStaminaChargeAt = event.ts
            }
            pending[sid + "\u{1}" + tool] = PendingPreUse(
                eventId: event.eventId, sessionId: sid, tool: tool, startedMs: event.ts
            )

        case .postToolUse:
            if let sid = event.sessionId, let tool = event.tool {
                pending.removeValue(forKey: sid + "\u{1}" + tool)
            }
            feed(&p, tokensTotal: event.tokensTotal)

        case .stop:
            p.intimacy = clamp(p.intimacy + config.eventCosts.stopIntimacy)
            feed(&p, tokensTotal: event.tokensTotal)

        case .petClick, .petting:
            p.intimacy = clamp(p.intimacy + config.eventCosts.petClickIntimacy)

        case .userPromptSubmit:
            break

        case .notification:
            break

        case .hibernateStart:
            p.hibernationSince = event.ts

        case .hibernateEnd:
            p.hibernationSince = nil

        case .prApproved:
            p.intimacy = clamp(p.intimacy + config.work.prApprovedIntimacy)

        case .prMerged:
            p.xp += config.work.prMergedXp
        }
        return p
    }

    @discardableResult
    public func tickPendingTimeouts(nowMs: Int64) -> [PendingPreUse] {
        let timeoutMs = Int64(config.thresholds.preToolUseTimeoutSeconds * 1000)
        let cutoff = nowMs - timeoutMs
        let expired = pending.values.filter { $0.startedMs <= cutoff }
        for p in expired {
            pending.removeValue(forKey: p.sessionId + "\u{1}" + p.tool)
        }
        return Array(expired)
    }

    private func feed(_ p: inout Pet, tokensTotal: Int) {
        let total = Double(tokensTotal)
        let fullnessBump = min(total / 2000.0 * config.eventCosts.postToolUseFullnessPer2kTokens, 5.0)
        p.fullness = clamp(p.fullness + fullnessBump)
        p.xp += Int64((total / 200.0 * config.eventCosts.postToolUseXpPer200Tokens).rounded(.down))
    }

    private func isSustained(sessionId: String, eventMs: Int64) -> Bool {
        guard let start = sessionStarts[sessionId] else { return false }
        let elapsedMs = eventMs - start.startedMs
        return elapsedMs >= Int64(config.thresholds.sustainedSessionSeconds * 1000)
    }

    private func clamp(_ v: Double) -> Double { min(100, max(0, v)) }
}
