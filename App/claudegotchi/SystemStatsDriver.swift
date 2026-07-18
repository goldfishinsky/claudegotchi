import Foundation
import PetCore

@MainActor
final class SystemStatsDriver: ObservableObject {
    @Published private(set) var snapshot: SystemSnapshot?

    private let sampler: SystemSampling
    private let interval: TimeInterval
    private let slowSampleEveryTicks: Int

    private var timer: Timer?
    private var tickCount = 0
    private var prevNet: (down: UInt64, up: UInt64)?
    private var prevCPU: CPUTicks?
    private var lastSampleTime: TimeInterval?
    private var lastDisk: (free: UInt64, total: UInt64) = (0, 0)
    private var lastBattery: (percent: Int, charging: Bool)?

    init(
        sampler: SystemSampling = MachSystemSampler(),
        interval: TimeInterval = 1,
        slowSampleEveryTicks: Int = 30
    ) {
        self.sampler = sampler
        self.interval = interval
        self.slowSampleEveryTicks = slowSampleEveryTicks
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        resetBaselines()
        tick()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func resetBaselines() {
        prevNet = nil
        prevCPU = nil
        lastSampleTime = nil
        tickCount = 0
    }

    private func tick() {
        let now = Date().timeIntervalSinceReferenceDate
        let mem = sampler.sampleMemory()
        let net = sampler.sampleNetworkCounters()
        let cpuTicks = sampler.sampleCPUTicks()

        let dt = lastSampleTime.map { now - $0 } ?? interval
        let down = prevNet.map { NetRate.compute(prevBytes: $0.down, curBytes: net.down, dtSeconds: dt) } ?? 0
        let up = prevNet.map { NetRate.compute(prevBytes: $0.up, curBytes: net.up, dtSeconds: dt) } ?? 0
        let cpu = prevCPU.map { CPULoad.compute(prevTicks: $0, curTicks: cpuTicks) } ?? 0

        prevNet = net
        prevCPU = cpuTicks
        lastSampleTime = now

        if tickCount % slowSampleEveryTicks == 0 {
            lastDisk = sampler.sampleDisk()
            lastBattery = sampler.sampleBattery()
        }
        tickCount += 1

        snapshot = SystemSnapshot(
            memUsedBytes: mem.used,
            memTotalBytes: mem.total,
            memPressure: MemPressure.tier(used: mem.used, total: mem.total, compressed: mem.compressed),
            downBytesPerSec: down,
            upBytesPerSec: up,
            cpuUsage: cpu,
            diskFreeBytes: lastDisk.free,
            diskTotalBytes: lastDisk.total,
            battery: lastBattery
        )
    }
}
