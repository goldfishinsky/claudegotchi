import XCTest
@testable import PetCore

final class ProcessTopTests: XCTestCase {
    private func s(_ pid: Int32, _ name: String, cpu: UInt64, rss: UInt64) -> ProcSample {
        ProcSample(pid: pid, name: name, cpuTimeNs: cpu, rssBytes: rss)
    }

    // MARK: - topByCPU

    func testTopByCPUComputesPercentFromDelta() {
        let prev = [s(1, "a", cpu: 0, rss: 0)]
        // 1 full second of CPU time over a 1s window = 100%.
        let cur = [s(1, "a", cpu: 1_000_000_000, rss: 0)]
        let top = ProcessTop.topByCPU(prev: prev, cur: cur, dtSeconds: 1)
        XCTAssertEqual(top.count, 1)
        XCTAssertEqual(top[0].percent, 100, accuracy: 1e-6)
    }

    func testTopByCPUAllowsAboveHundredOnMultipleCores() {
        let prev = [s(1, "a", cpu: 0, rss: 0)]
        let cur = [s(1, "a", cpu: 4_000_000_000, rss: 0)]
        let top = ProcessTop.topByCPU(prev: prev, cur: cur, dtSeconds: 1)
        XCTAssertEqual(top[0].percent, 400, accuracy: 1e-6)
    }

    func testTopByCPUSortsDescendingAndCaps() {
        let prev = [s(1, "a", cpu: 0, rss: 0), s(2, "b", cpu: 0, rss: 0), s(3, "c", cpu: 0, rss: 0), s(4, "d", cpu: 0, rss: 0)]
        let cur = [
            s(1, "a", cpu: 100_000_000, rss: 0),
            s(2, "b", cpu: 400_000_000, rss: 0),
            s(3, "c", cpu: 200_000_000, rss: 0),
            s(4, "d", cpu: 300_000_000, rss: 0),
        ]
        let top = ProcessTop.topByCPU(prev: prev, cur: cur, dtSeconds: 1, limit: 3)
        XCTAssertEqual(top.map(\.name), ["b", "d", "c"])
    }

    func testTopByCPUIgnoresNewProcessWithoutBaseline() {
        let prev: [ProcSample] = []
        let cur = [s(9, "new", cpu: 500_000_000, rss: 0)]
        XCTAssertTrue(ProcessTop.topByCPU(prev: prev, cur: cur, dtSeconds: 1).isEmpty)
    }

    func testTopByCPUIgnoresCounterReset() {
        let prev = [s(1, "a", cpu: 1_000_000_000, rss: 0)]
        let cur = [s(1, "a", cpu: 10, rss: 0)]
        XCTAssertTrue(ProcessTop.topByCPU(prev: prev, cur: cur, dtSeconds: 1).isEmpty)
    }

    func testTopByCPUIgnoresIdleProcesses() {
        let prev = [s(1, "a", cpu: 500, rss: 0)]
        let cur = [s(1, "a", cpu: 500, rss: 0)]
        XCTAssertTrue(ProcessTop.topByCPU(prev: prev, cur: cur, dtSeconds: 1).isEmpty)
    }

    func testTopByCPUZeroWindowIsEmpty() {
        let prev = [s(1, "a", cpu: 0, rss: 0)]
        let cur = [s(1, "a", cpu: 1_000_000_000, rss: 0)]
        XCTAssertTrue(ProcessTop.topByCPU(prev: prev, cur: cur, dtSeconds: 0).isEmpty)
    }

    // MARK: - topByRAM

    func testTopByRAMSortsDescendingAndCaps() {
        let cur = [
            s(1, "a", cpu: 0, rss: 100),
            s(2, "b", cpu: 0, rss: 400),
            s(3, "c", cpu: 0, rss: 200),
            s(4, "d", cpu: 0, rss: 300),
        ]
        let top = ProcessTop.topByRAM(cur, limit: 3)
        XCTAssertEqual(top.map(\.name), ["b", "d", "c"])
        XCTAssertEqual(top.map(\.rssBytes), [400, 300, 200])
    }

    func testTopByRAMEmptyInput() {
        XCTAssertTrue(ProcessTop.topByRAM([], limit: 3).isEmpty)
    }

    // MARK: - LibprocProcessSampler smoke (real machine)

    func testLibprocSamplerReturnsThisProcess() {
        let samples = LibprocProcessSampler().sampleProcesses()
        XCTAssertGreaterThan(samples.count, 0)
        let me = getpid()
        XCTAssertTrue(samples.contains { $0.pid == me })
    }
}
