import XCTest
@testable import PetCore

final class ChiptuneTests: XCTestCase {
    func testEveryEventHasANonEmptyMotif() {
        for event in ChiptuneEvent.allCases {
            let motif = ChiptuneLibrary.motif(for: event)
            XCTAssertFalse(motif.notes.isEmpty, "\(event) must have notes")
        }
    }

    func testAllDurationsPositiveAndFrequenciesNonNegative() {
        for event in ChiptuneEvent.allCases {
            for note in ChiptuneLibrary.motif(for: event).notes {
                XCTAssertGreaterThan(note.durationMs, 0)
                XCTAssertGreaterThanOrEqual(note.frequency, 0)
            }
        }
    }

    func testTotalDurationSums() {
        let motif = ChiptuneMotif([
            ChiptuneNote(frequency: 440, durationMs: 100, waveform: .square),
            ChiptuneNote(frequency: 0, durationMs: 50, waveform: .square),
        ])
        XCTAssertEqual(motif.totalDurationMs, 150)
    }

    func testShortMotifsWithinBudget() {
        for event: ChiptuneEvent in [.sessionStart, .taskComplete, .permission] {
            let total = ChiptuneLibrary.motif(for: event).totalDurationMs
            XCTAssertLessThanOrEqual(total, 300, "\(event) should stay a short motif")
            XCTAssertGreaterThanOrEqual(total, 100)
        }
    }

    func testSessionStartRises() {
        let notes = ChiptuneLibrary.motif(for: .sessionStart).notes
        XCTAssertEqual(notes.count, 2)
        XCTAssertLessThan(notes[0].frequency, notes[1].frequency)
    }

    func testTaskCompleteIsAscendingArpeggio() {
        let pitched = ChiptuneLibrary.motif(for: .taskComplete).notes.filter { !$0.isRest }
        XCTAssertEqual(pitched.count, 3)
        XCTAssertLessThan(pitched[0].frequency, pitched[1].frequency)
        XCTAssertLessThan(pitched[1].frequency, pitched[2].frequency)
    }

    func testPermissionIsTwoTone() {
        let pitched = ChiptuneLibrary.motif(for: .permission).notes.filter { !$0.isRest }
        XCTAssertEqual(pitched.count, 2)
        XCTAssertNotEqual(pitched[0].frequency, pitched[1].frequency)
    }

    func testLevelUpIsLongerFanfare() {
        let levelUp = ChiptuneLibrary.motif(for: .levelUp).totalDurationMs
        for event: ChiptuneEvent in [.sessionStart, .taskComplete, .permission] {
            XCTAssertGreaterThan(levelUp, ChiptuneLibrary.motif(for: event).totalDurationMs)
        }
        XCTAssertGreaterThan(ChiptuneLibrary.motif(for: .levelUp).notes.count, 3)
    }
}
