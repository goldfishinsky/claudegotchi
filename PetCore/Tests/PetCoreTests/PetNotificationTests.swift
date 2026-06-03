import XCTest
@testable import PetCore

final class PetNotificationTests: XCTestCase {
    func testNameIsStable() {
        XCTAssertEqual(Notification.Name.claudegotchiPetDidChange.rawValue, "claudegotchi.petDidChange")
    }

    func testPostPetDidChangeDeliversToObserver() {
        let exp = expectation(forNotification: .claudegotchiPetDidChange, object: nil, handler: nil)
        postPetDidChange()
        wait(for: [exp], timeout: 1.0)
    }
}
