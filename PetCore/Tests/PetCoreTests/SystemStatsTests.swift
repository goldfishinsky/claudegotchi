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

    func testMachSystemSamplerPerCoreIsNonEmptyAndAggregates() {
        let sampler = MachSystemSampler()
        let perCore = sampler.sampleCPUTicksPerCore()
        XCTAssertGreaterThan(perCore.count, 0)
        XCTAssertGreaterThan(CPUAggregate.sum(perCore).idle, 0)
    }

    func testMachSystemSamplerSwapIsNonNegative() {
        let sampler = MachSystemSampler()
        let mem = sampler.sampleMemory()
        XCTAssertGreaterThanOrEqual(mem.swap, 0)
    }

    // MARK: - CPUAggregate

    func testCPUAggregateSumsAllCores() {
        let cores = [
            CPUTicks(user: 10, system: 5, idle: 100, nice: 1),
            CPUTicks(user: 20, system: 6, idle: 200, nice: 2),
        ]
        let sum = CPUAggregate.sum(cores)
        XCTAssertEqual(sum, CPUTicks(user: 30, system: 11, idle: 300, nice: 3))
    }

    func testCPUAggregateEmptyIsZero() {
        XCTAssertEqual(CPUAggregate.sum([]), CPUTicks(user: 0, system: 0, idle: 0, nice: 0))
    }

    // MARK: - PerCoreLoad

    func testPerCoreLoadComputesEachCore() {
        let prev = [
            CPUTicks(user: 100, system: 50, idle: 850, nice: 0),
            CPUTicks(user: 0, system: 0, idle: 100, nice: 0),
        ]
        let cur = [
            CPUTicks(user: 150, system: 60, idle: 890, nice: 0),
            CPUTicks(user: 0, system: 0, idle: 200, nice: 0),
        ]
        let loads = PerCoreLoad.compute(prev: prev, cur: cur)
        XCTAssertEqual(loads.count, 2)
        XCTAssertEqual(loads[0], 0.6, accuracy: 1e-9)
        XCTAssertEqual(loads[1], 0.0, accuracy: 1e-9)
    }

    func testPerCoreLoadEmptyOnLengthMismatch() {
        let prev = [CPUTicks(user: 0, system: 0, idle: 1, nice: 0)]
        let cur = [CPUTicks(user: 0, system: 0, idle: 1, nice: 0), CPUTicks(user: 0, system: 0, idle: 1, nice: 0)]
        XCTAssertEqual(PerCoreLoad.compute(prev: prev, cur: cur), [])
    }

    // MARK: - CoreBars

    func testCoreBarsPassthroughWhenUnderCap() {
        let cores = [0.1, 0.2, 0.3]
        XCTAssertEqual(CoreBars.segments(cores, cap: 16), cores)
    }

    func testCoreBarsPassthroughAtExactlyCap() {
        let cores = Array(repeating: 0.5, count: 16)
        XCTAssertEqual(CoreBars.segments(cores, cap: 16), cores)
    }

    func testCoreBarsDownsamplesBeyondCap() {
        let cores = Array(repeating: 0.5, count: 20)
        let segs = CoreBars.segments(cores, cap: 16)
        XCTAssertEqual(segs.count, 16)
        XCTAssertTrue(segs.allSatisfy { abs($0 - 0.5) < 1e-9 })
    }

    func testCoreBarsAveragesPairs() {
        let cores = [0.0, 1.0, 0.0, 1.0]
        let segs = CoreBars.segments(cores, cap: 2)
        XCTAssertEqual(segs, [0.5, 0.5])
    }

    // MARK: - LoadAverage

    func testLoadAverageReadReturnsThreeNonNegativeValues() {
        guard let la = LoadAverage.read() else {
            return XCTFail("getloadavg returned nil on this host")
        }
        XCTAssertGreaterThanOrEqual(la.one, 0)
        XCTAssertGreaterThanOrEqual(la.five, 0)
        XCTAssertGreaterThanOrEqual(la.fifteen, 0)
    }

    func testLoadAverageFormatsWithOneDecimal() {
        XCTAssertEqual(LoadAverage.format(3.24, 4.09, 4.8), "3.2 · 4.1 · 4.8")
    }

    // MARK: - ThermalTier + SystemMood thermal

    func testThermalTierIsElevated() {
        XCTAssertFalse(ThermalTier.nominal.isElevated)
        XCTAssertFalse(ThermalTier.fair.isElevated)
        XCTAssertTrue(ThermalTier.serious.isElevated)
        XCTAssertTrue(ThermalTier.critical.isElevated)
    }

    func testSystemMoodThermalSeriousUpgradesToSweat() {
        XCTAssertEqual(SystemMood.combine(base: .none, mem: .normal, thermal: .serious), .sweat)
    }

    func testSystemMoodThermalCriticalUpgradesFocusToSweat() {
        XCTAssertEqual(SystemMood.combine(base: .focus, mem: .normal, thermal: .critical), .sweat)
    }

    func testSystemMoodThermalFairLeavesBaseUnchanged() {
        XCTAssertEqual(SystemMood.combine(base: .focus, mem: .normal, thermal: .fair), .focus)
        XCTAssertEqual(SystemMood.combine(base: .none, mem: .normal, thermal: .nominal), .none)
    }

    func testSystemMoodThermalNeverDowngradesExistingSweat() {
        XCTAssertEqual(SystemMood.combine(base: .sweat, mem: .normal, thermal: .nominal), .sweat)
    }

    func testSystemMoodMemAndThermalTogether() {
        XCTAssertEqual(SystemMood.combine(base: .none, mem: .critical, thermal: .serious), .sweat)
    }

    // MARK: - ThermalNotificationGate

    func testThermalGateFiresOnceOnElevation() {
        var gate = ThermalNotificationGate()
        XCTAssertTrue(gate.shouldNotify(.serious))
        XCTAssertFalse(gate.shouldNotify(.serious))
    }

    func testThermalGateSuppressesCriticalAfterSerious() {
        var gate = ThermalNotificationGate()
        XCTAssertTrue(gate.shouldNotify(.serious))
        XCTAssertFalse(gate.shouldNotify(.critical))
    }

    func testThermalGateRearmsAfterReturningToNominal() {
        var gate = ThermalNotificationGate()
        XCTAssertTrue(gate.shouldNotify(.serious))
        XCTAssertFalse(gate.shouldNotify(.nominal))
        XCTAssertTrue(gate.shouldNotify(.critical))
    }

    func testThermalGateRearmsViaFair() {
        var gate = ThermalNotificationGate()
        XCTAssertTrue(gate.shouldNotify(.critical))
        XCTAssertFalse(gate.shouldNotify(.fair))
        XCTAssertTrue(gate.shouldNotify(.serious))
    }

    func testThermalGateStartsSilentAtNominal() {
        var gate = ThermalNotificationGate()
        XCTAssertFalse(gate.shouldNotify(.nominal))
        XCTAssertFalse(gate.shouldNotify(.fair))
    }
}
