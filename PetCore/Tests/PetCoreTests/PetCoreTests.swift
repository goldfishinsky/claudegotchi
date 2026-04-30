import XCTest
@testable import PetCore

final class PetCoreSmokeTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(PetCore.version, "0.1.0")
    }
}
