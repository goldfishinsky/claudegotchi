import XCTest
@testable import PetCore

final class SystemStatsTests: XCTestCase {
    // MARK: - NetRate

    func testNetRateComputesBytesPerSecond() {
        let rate = NetRate.compute(prevBytes: 1_000, curBytes: 11_000, dtSeconds: 2)
        XCTAssertEqual(rate, 5_000)
    }

    func testNetRateClampsToZeroOnCounterWraparound() {
        let rate = NetRate.compute(prevBytes: 4_000_000_000, curBytes: 100, dtSeconds: 1)
        XCTAssertEqual(rate, 0)
    }

    func testNetRateZeroWhenNoElapsedTime() {
        XCTAssertEqual(NetRate.compute(prevBytes: 100, curBytes: 200, dtSeconds: 0), 0)
    }

    func testNetRateZeroWhenNoGrowth() {
        XCTAssertEqual(NetRate.compute(prevBytes: 500, curBytes: 500, dtSeconds: 1), 0)
    }

    // MARK: - CPULoad

    func testCPULoadComputesBusyFraction() {
        let prev = CPUTicks(user: 100, system: 50, idle: 850, nice: 0)
        let cur = CPUTicks(user: 150, system: 60, idle: 890, nice: 0)
        // busy delta = 50 + 10 = 60, idle delta = 40, total = 100 -> 0.6
        XCTAssertEqual(CPULoad.compute(prevTicks: prev, curTicks: cur), 0.6, accuracy: 1e-9)
    }

    func testCPULoadZeroWhenAllIdle() {
        let prev = CPUTicks(user: 0, system: 0, idle: 100, nice: 0)
        let cur = CPUTicks(user: 0, system: 0, idle: 200, nice: 0)
        XCTAssertEqual(CPULoad.compute(prevTicks: prev, curTicks: cur), 0)
    }

    func testCPULoadFullWhenAllBusy() {
        let prev = CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
        let cur = CPUTicks(user: 100, system: 0, idle: 0, nice: 0)
        XCTAssertEqual(CPULoad.compute(prevTicks: prev, curTicks: cur), 1.0)
    }

    func testCPULoadZeroWhenNoTicksElapsed() {
        let ticks = CPUTicks(user: 10, system: 10, idle: 10, nice: 0)
        XCTAssertEqual(CPULoad.compute(prevTicks: ticks, curTicks: ticks), 0)
    }

    func testCPULoadClampsToZeroOnCounterReset() {
        let prev = CPUTicks(user: 1_000, system: 0, idle: 0, nice: 0)
        let cur = CPUTicks(user: 10, system: 0, idle: 0, nice: 0)
        XCTAssertEqual(CPULoad.compute(prevTicks: prev, curTicks: cur), 0)
    }

    // MARK: - MemPressure

    func testMemPressureNormalBelowThresholds() {
        XCTAssertEqual(MemPressure.tier(used: 4_000_000_000, total: 16_000_000_000, compressed: 0), .normal)
    }

    func testMemPressureElevatedAboveUsedThreshold() {
        XCTAssertEqual(MemPressure.tier(used: 13_000_000_000, total: 16_000_000_000, compressed: 0), .elevated)
    }

    func testMemPressureCriticalAboveUsedThreshold() {
        XCTAssertEqual(MemPressure.tier(used: 15_500_000_000, total: 16_000_000_000, compressed: 0), .critical)
    }

    func testMemPressureCriticalFromCompressionAloneEvenIfUsedIsLow() {
        XCTAssertEqual(
            MemPressure.tier(used: 4_000_000_000, total: 16_000_000_000, compressed: 3_500_000_000),
            .critical
        )
    }

    func testMemPressureZeroTotalIsNormal() {
        XCTAssertEqual(MemPressure.tier(used: 0, total: 0, compressed: 0), .normal)
    }

    // MARK: - ByteFormat

    func testByteFormatSizeZero() {
        XCTAssertEqual(ByteFormat.size(0), "0 B")
    }

    func testByteFormatSizeStaysInBytesTierUnder1000() {
        XCTAssertEqual(ByteFormat.size(999), "999 B")
    }

    func testByteFormatSizeKilobyteTier() {
        XCTAssertEqual(ByteFormat.size(1_200), "1.2 KB")
    }

    func testByteFormatSizeMegabyteTier() {
        XCTAssertEqual(ByteFormat.size(12_300_000), "12.3 MB")
    }

    func testByteFormatSizeGigabyteTier() {
        XCTAssertEqual(ByteFormat.size(1_050_000_000), "1.05 GB")
    }

    func testByteFormatSizeTerabyteTier() {
        XCTAssertEqual(ByteFormat.size(8_000_000_000_000), "8.00 TB")
    }

    func testByteFormatSpeedAppendsPerSecondSuffix() {
        XCTAssertEqual(ByteFormat.speed(12_300_000), "12.3 MB/s")
    }

    func testByteFormatSpeedNeverBreaksLayoutNearMaxMegabyteTier() {
        XCTAssertEqual(ByteFormat.speed(999_900_000), "999.9 MB/s")
    }

    // MARK: - SystemMood

    func testSystemMoodCombineCriticalUpgradesNoneToSweat() {
        XCTAssertEqual(SystemMood.combine(base: .none, mem: .critical), .sweat)
    }

    func testSystemMoodCombineCriticalUpgradesFocusToSweat() {
        XCTAssertEqual(SystemMood.combine(base: .focus, mem: .critical), .sweat)
    }

    func testSystemMoodCombineNeverDowngradesExistingSweat() {
        XCTAssertEqual(SystemMood.combine(base: .sweat, mem: .normal), .sweat)
    }

    func testSystemMoodCombineNonCriticalLeavesBaseUnchanged() {
        XCTAssertEqual(SystemMood.combine(base: .focus, mem: .elevated), .focus)
        XCTAssertEqual(SystemMood.combine(base: .none, mem: .normal), .none)
    }

    func testSystemMoodAnimationSpeedFastAboveThreshold() {
        XCTAssertEqual(SystemMood.animationSpeed(downBytesPerSec: 5_000_001), 2.0)
    }

    func testSystemMoodAnimationSpeedNormalAtThreshold() {
        XCTAssertEqual(SystemMood.animationSpeed(downBytesPerSec: 5_000_000), 1.0)
    }

    func testSystemMoodAnimationSpeedNormalBelowThreshold() {
        XCTAssertEqual(SystemMood.animationSpeed(downBytesPerSec: 0), 1.0)
    }

    // MARK: - MachSystemSampler smoke (real machine)

    func testMachSystemSamplerMemoryIsInPlausibleRange() {
        let sampler = MachSystemSampler()
        let mem = sampler.sampleMemory()
        XCTAssertGreaterThan(mem.total, 0)
        XCTAssertLessThanOrEqual(mem.used, mem.total)
    }

    func testMachSystemSamplerCPULoadIsInUnitRange() {
        let sampler = MachSystemSampler()
        let prev = sampler.sampleCPUTicks()
        Thread.sleep(forTimeInterval: 0.05)
        let cur = sampler.sampleCPUTicks()
        let load = CPULoad.compute(prevTicks: prev, curTicks: cur)
        XCTAssertGreaterThanOrEqual(load, 0)
        XCTAssertLessThanOrEqual(load, 1)
    }

    func testMachSystemSamplerDiskTotalIsPositive() {
        let sampler = MachSystemSampler()
        let disk = sampler.sampleDisk()
        XCTAssertGreaterThan(disk.total, 0)
    }

    func testMachSystemSamplerNetworkCountersAreNonNegative() {
        let sampler = MachSystemSampler()
        let net = sampler.sampleNetworkCounters()
        XCTAssertGreaterThanOrEqual(net.down, 0)
        XCTAssertGreaterThanOrEqual(net.up, 0)
    }

    func testMachSystemSamplerBatteryPercentInRangeWhenPresent() {
        let sampler = MachSystemSampler()
        if let battery = sampler.sampleBattery() {
            XCTAssertGreaterThanOrEqual(battery.percent, 0)
            XCTAssertLessThanOrEqual(battery.percent, 100)
        }
    }
}
