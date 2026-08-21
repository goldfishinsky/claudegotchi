import XCTest
import AppKit
@testable import claudegotchi

@MainActor
final class SettingsStoreTests: XCTestCase {
    func testPetDisplayModeDefaultsToIslandAndPersistsFloatingChoice() {
        let suite = "SettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let initial = SettingsStore(defaults: defaults)
        XCTAssertEqual(initial.petDisplayMode, .island)

        initial.petDisplayMode = .floating
        let restored = SettingsStore(defaults: defaults)
        XCTAssertEqual(restored.petDisplayMode, .floating)
    }
}

final class IslandPetDragTests: XCTestCase {
    func testOnlyDownwardTravelCountsTowardDetachingPet() {
        let start = NSPoint(x: 500, y: 900)

        XCTAssertEqual(
            IslandPetDrag.downwardDistance(from: start, to: NSPoint(x: 620, y: 900)),
            0
        )
        XCTAssertEqual(
            IslandPetDrag.downwardDistance(from: start, to: NSPoint(x: 500, y: 930)),
            0
        )
        XCTAssertEqual(
            IslandPetDrag.downwardDistance(from: start, to: NSPoint(x: 530, y: 870)),
            30
        )
    }

    func testDetachThresholdNeedsAnIntentionalPull() {
        let start = NSPoint(x: 500, y: 900)
        let shortPull = IslandPetDrag.downwardDistance(
            from: start,
            to: NSPoint(x: 500, y: start.y - IslandPetDrag.activationDistance + 1)
        )
        let committedPull = IslandPetDrag.downwardDistance(
            from: start,
            to: NSPoint(x: 500, y: start.y - IslandPetDrag.activationDistance)
        )

        XCTAssertLessThan(shortPull, IslandPetDrag.activationDistance)
        XCTAssertGreaterThanOrEqual(committedPull, IslandPetDrag.activationDistance)
    }
}

final class DropdownPetDragTests: XCTestCase {
    func testTravelInAnyDirectionCanDetachPetFromDropdown() {
        let start = NSPoint(x: 500, y: 500)

        XCTAssertEqual(
            DropdownPetDrag.travelDistance(from: start, to: NSPoint(x: 528, y: 500)),
            28,
            accuracy: 0.001
        )
        XCTAssertEqual(
            DropdownPetDrag.travelDistance(from: start, to: NSPoint(x: 500, y: 472)),
            28,
            accuracy: 0.001
        )
    }

    func testShortMovementStaysARegularPetInteraction() {
        let start = NSPoint(x: 500, y: 500)
        let distance = DropdownPetDrag.travelDistance(
            from: start,
            to: NSPoint(x: 510, y: 510)
        )

        XCTAssertLessThan(distance, DropdownPetDrag.activationDistance)
    }
}
