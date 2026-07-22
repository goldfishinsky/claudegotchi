import XCTest
@testable import PetCore

final class EventApplierTests: XCTestCase {
    var applier: EventApplier!
    let cfg = ConfigYAML.defaults

    override func setUp() {
        applier = EventApplier(config: cfg)
    }

    private func evt(_ type: Event.EventType, sessionId: String? = nil, tool: String? = nil,
                     tokensIn: Int? = nil, tokensOut: Int? = nil, ts: Int64 = 0) -> Event {
        Event(
            schemaVersion: 1, eventId: UUID().uuidString, ts: ts, type: type,
            sessionId: sessionId, tool: tool, tokensIn: tokensIn, tokensOut: tokensOut, model: nil
        )
    }

    private func config(window seconds: Int?) -> ConfigYAML {
        let d = ConfigYAML.defaults
        let ec = ConfigYAML.EventCosts(
            preToolUseStamina: d.eventCosts.preToolUseStamina,
            preToolUseStaminaSustained: d.eventCosts.preToolUseStaminaSustained,
            postToolUseFullnessPer2kTokens: d.eventCosts.postToolUseFullnessPer2kTokens,
            postToolUseXpPer200Tokens: d.eventCosts.postToolUseXpPer200Tokens,
            stopIntimacy: d.eventCosts.stopIntimacy,
            petClickIntimacy: d.eventCosts.petClickIntimacy,
            staminaChargeWindowSeconds: seconds
        )
        return ConfigYAML(
            decay: d.decay, eventCosts: ec, thresholds: d.thresholds,
            spool: d.spool, work: d.work, leaderboard: d.leaderboard
        )
    }

    func testPostToolUseIncreasesFullnessAndXP() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.fullness = 50
        let before = pet.fullness
        let next = applier.apply(event: evt(.postToolUse, tokensIn: 1000, tokensOut: 1000), to: pet)
        XCTAssertEqual(next.fullness, before + 1, accuracy: 1e-9)
        XCTAssertEqual(next.xp, 10)
    }

    func testPostToolUseFullnessCappedAt5() {
        let pet = Pet.fresh(species: "frog", at: 0)
        let next = applier.apply(event: evt(.postToolUse, tokensIn: 100_000, tokensOut: 100_000), to: pet)
        XCTAssertEqual(next.fullness, min(100, pet.fullness + 5), accuracy: 1e-9)
    }

    func testPostToolUseFullnessClampsTo100() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.fullness = 99
        let next = applier.apply(event: evt(.postToolUse, tokensIn: 5000, tokensOut: 5000), to: pet)
        XCTAssertEqual(next.fullness, 100)
    }

    func testUserPromptSubmitLeavesPetUntouched() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.fullness = 40; pet.stamina = 60; pet.intimacy = 70; pet.xp = 12
        let next = applier.apply(event: evt(.userPromptSubmit, sessionId: "s1", ts: 5), to: pet)
        XCTAssertEqual(next.fullness, 40, accuracy: 1e-9)
        XCTAssertEqual(next.stamina, 60, accuracy: 1e-9)
        XCTAssertEqual(next.intimacy, 70, accuracy: 1e-9)
        XCTAssertEqual(next.xp, 12)
    }

    func testPreToolUseDrainsStamina() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.stamina = 50
        let next = applier.apply(event: evt(.preToolUse, sessionId: "s1", tool: "Bash", ts: 0), to: pet)
        XCTAssertEqual(next.stamina, 49.5, accuracy: 1e-9)
    }

    func testStopAddsIntimacy() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.intimacy = 10
        let next = applier.apply(event: evt(.stop), to: pet)
        XCTAssertEqual(next.intimacy, 10.5, accuracy: 1e-9)
    }

    func testStopWithTokensFeedsFullnessAndXP() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.fullness = 50; pet.intimacy = 10
        let next = applier.apply(event: evt(.stop, tokensIn: 1000, tokensOut: 1000), to: pet)
        XCTAssertEqual(next.fullness, 51, accuracy: 1e-9, "turn tokens now feed fullness on stop")
        XCTAssertEqual(next.xp, 10)
        XCTAssertEqual(next.intimacy, 10.5, accuracy: 1e-9, "intimacy bump preserved")
    }

    func testStopWithoutTokensLeavesFullnessAndXP() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.fullness = 50
        let next = applier.apply(event: evt(.stop), to: pet)
        XCTAssertEqual(next.fullness, 50, accuracy: 1e-9)
        XCTAssertEqual(next.xp, 0)
    }

    func testSessionStartClearsHibernation() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.hibernationSince = 100
        let next = applier.apply(event: evt(.sessionStart, ts: 1_000_000), to: pet)
        XCTAssertNil(next.hibernationSince)
    }

    func testPreToolUsePendingResolvedByPostToolUse() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet = applier.apply(event: evt(.preToolUse, sessionId: "s1", tool: "Bash", ts: 0), to: pet)
        XCTAssertEqual(applier.pendingCount, 1)
        pet = applier.apply(event: evt(.postToolUse, sessionId: "s1", tool: "Bash", tokensIn: 1000, tokensOut: 0, ts: 1000), to: pet)
        XCTAssertEqual(applier.pendingCount, 0)
    }

    func testPendingTimeoutDropsAfter5Min() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet = applier.apply(event: evt(.preToolUse, sessionId: "s1", tool: "Bash", ts: 0), to: pet)
        XCTAssertEqual(applier.pendingCount, 1)
        applier.tickPendingTimeouts(nowMs: 5 * 60 * 1000 + 1)
        XCTAssertEqual(applier.pendingCount, 0)
    }

    func testSustainedSessionDoublesPreToolCost() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.stamina = 50
        pet = applier.apply(event: evt(.sessionStart, sessionId: "s1", ts: 0), to: pet)
        pet = applier.apply(event: evt(.preToolUse, sessionId: "s1", tool: "Bash", ts: 1_860_000), to: pet)
        XCTAssertEqual(pet.stamina, 49, accuracy: 1e-9)
    }

    func testHibernateStartSetsField() {
        let pet = Pet.fresh(species: "frog", at: 0)
        let next = applier.apply(event: evt(.hibernateStart, ts: 5000), to: pet)
        XCTAssertEqual(next.hibernationSince, 5000)
    }

    func testPrApprovedRaisesIntimacy() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.intimacy = 40
        let next = applier.apply(event: evt(.prApproved), to: pet)
        XCTAssertEqual(next.intimacy, 40 + cfg.work.prApprovedIntimacy, accuracy: 1e-9)
    }

    func testPrApprovedIntimacyClampsTo100() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.intimacy = 99.5
        let next = applier.apply(event: evt(.prApproved), to: pet)
        XCTAssertEqual(next.intimacy, 100)
    }

    func testPrApprovedRepeatedApplyStaysClamped() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.intimacy = 100
        let a = applier.apply(event: evt(.prApproved), to: pet)
        let b = applier.apply(event: evt(.prApproved), to: a)
        XCTAssertEqual(a.intimacy, 100)
        XCTAssertEqual(b.intimacy, 100)
    }

    func testPrMergedAddsXpAndLeavesStatsUntouched() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.fullness = 30; pet.stamina = 30; pet.intimacy = 30
        let next = applier.apply(event: evt(.prMerged), to: pet)
        XCTAssertEqual(next.xp, cfg.work.prMergedXp)
        XCTAssertEqual(next.fullness, 30, accuracy: 1e-9)
        XCTAssertEqual(next.stamina, 30, accuracy: 1e-9)
        XCTAssertEqual(next.intimacy, 30, accuracy: 1e-9)
    }

    func testPetClickAddsIntimacyClamped() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.intimacy = 10
        let next = applier.apply(event: evt(.petClick), to: pet)
        XCTAssertEqual(next.intimacy, 10 + cfg.eventCosts.petClickIntimacy, accuracy: 1e-9)
    }

    func testPetClickClampsAt100() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.intimacy = 99.5
        let next = applier.apply(event: evt(.petClick), to: pet)
        XCTAssertEqual(next.intimacy, 100)
    }

    func testSessionStartWakeReanchorsLastTickAt() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.hibernationSince = 100
        pet.lastTickAt = 100
        let next = applier.apply(event: evt(.sessionStart, ts: 5_000_000), to: pet)
        XCTAssertNil(next.hibernationSince)
        XCTAssertEqual(next.lastTickAt, 5_000_000, "wake re-anchors lastTickAt to event.ts")
    }

    func testSessionStartWhenAwakeDoesNotReanchor() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.hibernationSince = nil
        pet.lastTickAt = 100
        let next = applier.apply(event: evt(.sessionStart, ts: 5_000_000), to: pet)
        XCTAssertEqual(next.lastTickAt, 100, "no wake → lastTickAt untouched")
    }

    func testStormDampingChargesOncePerWindow() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.stamina = 100
        for i in 0..<5 {
            pet = applier.apply(event: evt(.preToolUse, sessionId: "s1", tool: "Bash", ts: Int64(i) * 5_000), to: pet)
        }
        XCTAssertEqual(pet.stamina, 99.5, accuracy: 1e-9, "only the first call in the 30s window charges")
        XCTAssertEqual(pet.lastStaminaChargeAt, 0)
        pet = applier.apply(event: evt(.preToolUse, sessionId: "s1", tool: "Bash", ts: 30_000), to: pet)
        XCTAssertEqual(pet.stamina, 99.0, accuracy: 1e-9, "a call at the window boundary charges again")
        XCTAssertEqual(pet.lastStaminaChargeAt, 30_000)
    }

    func testStormDampingIsReplayIdempotent() {
        let seed = Pet.fresh(species: "frog", at: 0)
        let events = (0..<8).map { evt(.preToolUse, sessionId: "s1", tool: "Bash", ts: Int64($0) * 12_000) }
        func run() -> Double {
            let a = EventApplier(config: cfg)
            var p = seed
            for e in events { p = a.apply(event: e, to: p) }
            return p.stamina
        }
        XCTAssertEqual(run(), run(), accuracy: 1e-12, "replaying the same stream is deterministic")
    }

    func testStormDampingWindowZeroChargesEveryCall() {
        let a = EventApplier(config: config(window: 0))
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.stamina = 100
        for i in 0..<10 {
            pet = a.apply(event: evt(.preToolUse, sessionId: "s1", tool: "Bash", ts: Int64(i)), to: pet)
        }
        XCTAssertEqual(pet.stamina, 95.0, accuracy: 1e-9, "window 0 disables damping: every call charges")
    }

    private struct HeavyDay { let dayEnd: Double; let nightEnd: Double; let charges: Int }

    private func runHeavyDay(applier a: EventApplier, regenConfig: ConfigYAML) -> HeavyDay {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.stamina = 100
        let dayMs: Int64 = 10 * 3600 * 1000
        let totalCalls = 2500
        let burstCount = 400
        let burstSpacing = dayMs / Int64(burstCount)
        let intraMs: Int64 = 3_000
        var lastTs: Int64 = 0
        var charges = 0
        func regen(to ts: Int64) {
            pet = Decay.apply(pet: pet, elapsedSeconds: Double(ts - lastTs) / 1000.0, config: regenConfig)
            lastTs = ts
        }
        for b in 0..<burstCount {
            let calls = totalCalls / burstCount + (b < totalCalls % burstCount ? 1 : 0)
            let burstStart = Int64(b) * burstSpacing
            for c in 0..<calls {
                let ts = burstStart + Int64(c) * intraMs
                regen(to: ts)
                let before = pet.stamina
                pet = a.apply(event: evt(.preToolUse, sessionId: "s", tool: "Bash", ts: ts), to: pet)
                if pet.stamina < before - 1e-9 { charges += 1 }
            }
        }
        let dayEnd = pet.stamina
        regen(to: lastTs + 8 * 3600 * 1000)
        return HeavyDay(dayEnd: dayEnd, nightEnd: pet.stamina, charges: charges)
    }

    func testHeavyDayDrainsSaneThenIdleNightRecovers() {
        let damped = runHeavyDay(applier: EventApplier(config: cfg), regenConfig: cfg)
        XCTAssertEqual(damped.charges, 400, "storm damping collapses 2500 calls to one charge per burst")
        XCTAssertGreaterThan(damped.dayEnd, 0, "damped day never floors the pet at 0")
        XCTAssertTrue(damped.dayEnd > 10 && damped.dayEnd < 50, "busy day lands in a sane band, got \(damped.dayEnd)")
        XCTAssertEqual(damped.nightEnd, 100, accuracy: 1e-6, "8h idle night fully recovers")

        let undamped = runHeavyDay(applier: EventApplier(config: config(window: 0)), regenConfig: cfg)
        XCTAssertEqual(undamped.charges, 2500, "without damping every call charges")
        XCTAssertEqual(undamped.dayEnd, 0, accuracy: 1e-9, "without damping the same day zeroes stamina")
    }
}
