import XCTest
@testable import PetCore

final class DeathIsolationTests: XCTestCase {
    let cfg = ConfigYAML.defaults

    private func evt(_ type: Event.EventType) -> Event {
        Event(schemaVersion: 1, eventId: UUID().uuidString, ts: 0, type: type,
              sessionId: nil, tool: nil, tokensIn: nil, tokensOut: nil, model: nil, cwd: nil)
    }

    func testWorkStormNeverPushesPetTowardDeath() {
        let applier = EventApplier(config: cfg)
        let clock = FixedClock(start: 0)

        var pet = Pet.fresh(species: "frog", at: 0)
        pet.fullness = 100; pet.stamina = 100; pet.intimacy = 100
        let intimacyBefore = pet.intimacy

        for i in 0..<500 {
            pet = applier.apply(event: evt(i.isMultiple(of: 2) ? .prApproved : .prMerged), to: pet)
            XCTAssertGreaterThanOrEqual(pet.intimacy, intimacyBefore,
                                        "No work event ever decreases intimacy")
        }

        let days = cfg.thresholds.deathConsecutiveDays + 2
        for _ in 0..<days {
            let low = DeathWindow.isLowDay(pet: pet, threshold: cfg.thresholds.deathStatLow,
                                           requiredCount: cfg.thresholds.deathLowStatsRequired)
            pet = DeathWindow.appendDay(pet: pet, lowToday: low)
            clock.advance(seconds: 86_400)
            XCTAssertFalse(DeathWindow.shouldDie(pet: pet),
                           "A work storm on a healthy pet can never make shouldDie true")
        }

        XCTAssertGreaterThanOrEqual(pet.intimacy, intimacyBefore)
        XCTAssertFalse(DeathWindow.shouldDie(pet: pet))
    }

    func testWorkStormOnAlreadyLowPetDoesNotWorsenDeathWindow() {
        // Work can't touch fullness/stamina; pr_approved only RAISES intimacy,
        // so isLowDay can only improve or hold — never add a low stat.
        let applier = EventApplier(config: cfg)
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.fullness = 5; pet.stamina = 5; pet.intimacy = 5

        let lowBefore = DeathWindow.isLowDay(pet: pet, threshold: cfg.thresholds.deathStatLow,
                                             requiredCount: cfg.thresholds.deathLowStatsRequired)
        for _ in 0..<500 { pet = applier.apply(event: evt(.prApproved), to: pet) }
        let lowAfter = DeathWindow.isLowDay(pet: pet, threshold: cfg.thresholds.deathStatLow,
                                            requiredCount: cfg.thresholds.deathLowStatsRequired)
        XCTAssertFalse(lowAfter && !lowBefore, "Work approvals never add a low-stat")
        XCTAssertGreaterThan(pet.intimacy, 5)
    }
}
