import XCTest
@testable import PetCore

final class RingBufferTests: XCTestCase {
    func testAppendBelowCapacityKeepsOrder() {
        var rb = RingBuffer(capacity: 5)
        [1, 2, 3].forEach { rb.append(Double($0)) }
        XCTAssertEqual(rb.values, [1, 2, 3])
        XCTAssertEqual(rb.count, 3)
    }

    func testWrapDropsOldest() {
        var rb = RingBuffer(capacity: 3)
        [1, 2, 3, 4, 5].forEach { rb.append(Double($0)) }
        XCTAssertEqual(rb.values, [3, 4, 5])
        XCTAssertEqual(rb.count, 3)
    }

    func testWrapChronologicalAcrossMultipleLaps() {
        var rb = RingBuffer(capacity: 4)
        (1...10).forEach { rb.append(Double($0)) }
        XCTAssertEqual(rb.values, [7, 8, 9, 10])
    }

    func testExactlyFullKeepsOrder() {
        var rb = RingBuffer(capacity: 3)
        [1, 2, 3].forEach { rb.append(Double($0)) }
        XCTAssertEqual(rb.values, [1, 2, 3])
    }

    func testEmptyState() {
        let rb = RingBuffer(capacity: 4)
        XCTAssertTrue(rb.isEmpty)
        XCTAssertEqual(rb.values, [])
        XCTAssertEqual(rb.downsampled(to: 10), [])
    }

    func testCapacityClampedToAtLeastOne() {
        var rb = RingBuffer(capacity: 0)
        rb.append(1)
        rb.append(2)
        XCTAssertEqual(rb.values, [2])
    }

    func testDownsamplePassthroughWhenUnderTarget() {
        var rb = RingBuffer(capacity: 10)
        [1, 2, 3].forEach { rb.append(Double($0)) }
        XCTAssertEqual(rb.downsampled(to: 60), [1, 2, 3])
    }

    func testDownsampleAveragesBuckets() {
        var rb = RingBuffer(capacity: 4)
        [0, 2, 0, 2].forEach { rb.append(Double($0)) }
        XCTAssertEqual(rb.downsampled(to: 2), [1, 1])
    }

    func testDownsampleToTargetCount() {
        var rb = RingBuffer(capacity: 100)
        (0..<100).forEach { rb.append(Double($0)) }
        XCTAssertEqual(rb.downsampled(to: 20).count, 20)
    }
}
