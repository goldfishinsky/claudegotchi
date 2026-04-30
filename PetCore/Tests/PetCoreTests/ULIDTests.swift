import XCTest
@testable import PetCore

final class ULIDTests: XCTestCase {
    func testULIDIs26Chars() {
        let ulid = ULID.generate()
        XCTAssertEqual(ulid.count, 26)
    }

    func testULIDUsesCrockfordAlphabet() {
        let ulid = ULID.generate()
        let allowed = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        XCTAssertTrue(ulid.allSatisfy { allowed.contains($0) })
    }

    func testULIDsAreUnique() {
        let n = 1000
        var seen = Set<String>()
        for _ in 0..<n { seen.insert(ULID.generate()) }
        XCTAssertEqual(seen.count, n)
    }

    func testULIDsAreLexicographicallyOrdered() {
        let a = ULID.generate()
        Thread.sleep(forTimeInterval: 0.010)
        let b = ULID.generate()
        XCTAssertLessThan(a, b)
    }

    func testULIDTimestampPrefixDecodes() {
        let before = UInt64(Date().timeIntervalSince1970 * 1000)
        let ulid = ULID.generate()
        let decoded = ULID.timestampMs(from: ulid)!
        let after = UInt64(Date().timeIntervalSince1970 * 1000)
        XCTAssertGreaterThanOrEqual(decoded, before)
        XCTAssertLessThanOrEqual(decoded, after)
    }
}
