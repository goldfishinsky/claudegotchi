import Foundation
import SwiftUI
import PetCore

@MainActor
final class SystemStatsDriver: ObservableObject {
    struct LoadAvg: Equatable { let one: Double; let five: Double; let fifteen: Double }

    @Published private(set) var snapshot: SystemSnapshot?
    @Published private(set) var perCoreUsage: [Double] = []
    @Published private(set) var loadAverage: LoadAvg?
    @Published private(set) var thermal: ThermalTier = .nominal
    @Published private(set) var swapBytes: UInt64 = 0
    @Published private(set) var compressedBytes: UInt64 = 0
    @Published private(set) var topCPU: [ProcessCPUUsage] = []
    @Published private(set) var topRAM: [ProcessRAMUsage] = []
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memHistory: [Double] = []

    static let topProcessCount = 5

    let coreCount = ProcessInfo.processInfo.activeProcessorCount

    private let sampler: SystemSampling
    private let processSampler: ProcessSampling
    private let interval: TimeInterval
    private let slowSampleEveryTicks: Int
    private let processSampleEveryTicks: Int
    private let historyEveryTicks: Int

    private var timer: Timer?
    private var startCount = 0
    private var tickCount = 0
    private var prevNet: (down: UInt64, up: UInt64)?
    private var prevCPUPerCore: [CPUTicks]?
    private var lastSampleTime: TimeInterval?
    private var lastDisk: (free: UInt64, total: UInt64) = (0, 0)
    private var lastBattery: (percent: Int, charging: Bool)?
    private var prevProc: [ProcSample]?
    private var lastProcSampleTime: TimeInterval?

    // Persist across open/close so the 1-hour sparkline keeps filling over a day
    // of occasional dropdown opens rather than resetting each time.
    private var cpuRing = RingBuffer(capacity: 360)
    private var memRing = RingBuffer(capacity: 360)

    init(
        sampler: SystemSampling = MachSystemSampler(),
        processSampler: ProcessSampling = LibprocProcessSampler(),
        interval: TimeInterval = 1,
        slowSampleEveryTicks: Int = 30,
        processSampleEveryTicks: Int = 5,
        historyEveryTicks: Int = 10
    ) {
        self.sampler = sampler
        self.processSampler = processSampler
        self.interval = interval
        self.slowSampleEveryTicks = slowSampleEveryTicks
        self.processSampleEveryTicks = processSampleEveryTicks
        self.historyEveryTicks = historyEveryTicks
    }

    var isRunning: Bool { timer != nil }

    // Refcounted so overlapping owners (dropdown open + 系统 tab visible) share one
    // timer; only the first start samples, only the last stop tears down.
    func start() {
        startCount += 1
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
        startCount = max(0, startCount - 1)
        guard startCount == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    private func resetBaselines() {
        prevNet = nil
        prevCPUPerCore = nil
        lastSampleTime = nil
        prevProc = nil
        lastProcSampleTime = nil
        tickCount = 0
    }

    private func tick() {
        let now = Date().timeIntervalSinceReferenceDate
        let mem = sampler.sampleMemory()
        let net = sampler.sampleNetworkCounters()
        let cpuPerCore = sampler.sampleCPUTicksPerCore()
        let cpuTicks = CPUAggregate.sum(cpuPerCore)

        let dt = lastSampleTime.map { now - $0 } ?? interval
        let down = prevNet.map { NetRate.compute(prevBytes: $0.down, curBytes: net.down, dtSeconds: dt) } ?? 0
        let up = prevNet.map { NetRate.compute(prevBytes: $0.up, curBytes: net.up, dtSeconds: dt) } ?? 0
        let prevAggregate = prevCPUPerCore.map(CPUAggregate.sum)
        let cpu = prevAggregate.map { CPULoad.compute(prevTicks: $0, curTicks: cpuTicks) } ?? 0
        if let prev = prevCPUPerCore {
            perCoreUsage = CoreBars.segments(PerCoreLoad.compute(prev: prev, cur: cpuPerCore))
        }

        prevNet = net
        prevCPUPerCore = cpuPerCore
        lastSampleTime = now

        swapBytes = mem.swap
        compressedBytes = mem.compressed
        thermal = ThermalReading.tier(ProcessInfo.processInfo.thermalState)
        if let la = LoadAverage.read() {
            loadAverage = LoadAvg(one: la.one, five: la.five, fifteen: la.fifteen)
        }

        if tickCount % slowSampleEveryTicks == 0 {
            lastDisk = sampler.sampleDisk()
            lastBattery = sampler.sampleBattery()
        }
        if tickCount % processSampleEveryTicks == 0 {
            sampleProcesses(now: now)
        }
        if tickCount % historyEveryTicks == 0 {
            let memFrac = mem.total > 0 ? Double(mem.used) / Double(mem.total) : 0
            cpuRing.append(cpu)
            memRing.append(memFrac)
            cpuHistory = cpuRing.downsampled(to: 90)
            memHistory = memRing.downsampled(to: 90)
        }
        tickCount += 1

        withAnimation(.snappy(duration: 0.25)) {
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

    private func sampleProcesses(now: TimeInterval) {
        let cur = processSampler.sampleProcesses()
        if let prev = prevProc, let last = lastProcSampleTime {
            let dt = now - last
            topCPU = ProcessTop.topByCPU(prev: prev, cur: cur, dtSeconds: dt, limit: Self.topProcessCount)
        }
        topRAM = ProcessTop.topByRAM(cur, limit: Self.topProcessCount)
        prevProc = cur
        lastProcSampleTime = now
    }
}
