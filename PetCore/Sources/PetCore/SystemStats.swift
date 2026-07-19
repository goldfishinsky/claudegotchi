import Foundation
import Darwin
import IOKit.ps

public enum MemPressureTier: String, Equatable, Sendable { case normal, elevated, critical }

public struct SystemSnapshot: Equatable, Sendable {
    public let memUsedBytes: UInt64
    public let memTotalBytes: UInt64
    public let memPressure: MemPressureTier
    public let downBytesPerSec: Double
    public let upBytesPerSec: Double
    public let cpuUsage: Double
    public let diskFreeBytes: UInt64
    public let diskTotalBytes: UInt64
    public let battery: (percent: Int, charging: Bool)?

    public init(
        memUsedBytes: UInt64,
        memTotalBytes: UInt64,
        memPressure: MemPressureTier,
        downBytesPerSec: Double,
        upBytesPerSec: Double,
        cpuUsage: Double,
        diskFreeBytes: UInt64,
        diskTotalBytes: UInt64,
        battery: (percent: Int, charging: Bool)?
    ) {
        self.memUsedBytes = memUsedBytes
        self.memTotalBytes = memTotalBytes
        self.memPressure = memPressure
        self.downBytesPerSec = downBytesPerSec
        self.upBytesPerSec = upBytesPerSec
        self.cpuUsage = cpuUsage
        self.diskFreeBytes = diskFreeBytes
        self.diskTotalBytes = diskTotalBytes
        self.battery = battery
    }

    public static func == (lhs: SystemSnapshot, rhs: SystemSnapshot) -> Bool {
        guard lhs.memUsedBytes == rhs.memUsedBytes,
              lhs.memTotalBytes == rhs.memTotalBytes,
              lhs.memPressure == rhs.memPressure,
              lhs.downBytesPerSec == rhs.downBytesPerSec,
              lhs.upBytesPerSec == rhs.upBytesPerSec,
              lhs.cpuUsage == rhs.cpuUsage,
              lhs.diskFreeBytes == rhs.diskFreeBytes,
              lhs.diskTotalBytes == rhs.diskTotalBytes
        else { return false }
        switch (lhs.battery, rhs.battery) {
        case (nil, nil): return true
        case let (l?, r?): return l.percent == r.percent && l.charging == r.charging
        default: return false
        }
    }
}

public enum NetRate {
    public static func compute(prevBytes: UInt64, curBytes: UInt64, dtSeconds: Double) -> Double {
        guard dtSeconds > 0, curBytes > prevBytes else { return 0 }
        return Double(curBytes - prevBytes) / dtSeconds
    }
}

public struct CPUTicks: Equatable, Sendable {
    public let user: UInt64
    public let system: UInt64
    public let idle: UInt64
    public let nice: UInt64
    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

public enum CPULoad {
    public static func compute(prevTicks: CPUTicks, curTicks: CPUTicks) -> Double {
        guard curTicks.user >= prevTicks.user, curTicks.system >= prevTicks.system,
              curTicks.idle >= prevTicks.idle, curTicks.nice >= prevTicks.nice
        else { return 0 }
        let busy = (curTicks.user - prevTicks.user) + (curTicks.system - prevTicks.system)
            + (curTicks.nice - prevTicks.nice)
        let total = busy + (curTicks.idle - prevTicks.idle)
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(busy) / Double(total)))
    }
}

public enum CPUAggregate {
    public static func sum(_ perCore: [CPUTicks]) -> CPUTicks {
        var user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0
        for c in perCore {
            user &+= c.user; system &+= c.system; idle &+= c.idle; nice &+= c.nice
        }
        return CPUTicks(user: user, system: system, idle: idle, nice: nice)
    }
}

public enum PerCoreLoad {
    public static func compute(prev: [CPUTicks], cur: [CPUTicks]) -> [Double] {
        guard prev.count == cur.count else { return [] }
        return zip(prev, cur).map { CPULoad.compute(prevTicks: $0, curTicks: $1) }
    }
}

public enum CoreBars {
    /// Per-core loads capped to `cap` segments; contiguous cores average-paired
    /// down when the machine has more cores than the display budget.
    public static func segments(_ perCore: [Double], cap: Int = 16) -> [Double] {
        guard cap > 0 else { return [] }
        guard perCore.count > cap else { return perCore }
        let n = perCore.count
        return (0..<cap).map { b in
            let lo = b * n / cap
            let hi = max(lo + 1, (b + 1) * n / cap)
            let slice = perCore[lo..<hi]
            return slice.reduce(0, +) / Double(slice.count)
        }
    }
}

public enum LoadAverage {
    public static func read() -> (one: Double, five: Double, fifteen: Double)? {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return nil }
        guard loads.allSatisfy({ $0 >= 0 && $0.isFinite }) else { return nil }
        return (loads[0], loads[1], loads[2])
    }

    public static func format(_ one: Double, _ five: Double, _ fifteen: Double) -> String {
        String(format: "%.1f · %.1f · %.1f", one, five, fifteen)
    }
}

public enum MemPressure {
    public static func tier(used: UInt64, total: UInt64, compressed: UInt64) -> MemPressureTier {
        guard total > 0 else { return .normal }
        let usedRatio = Double(used) / Double(total)
        let compressedRatio = Double(compressed) / Double(total)
        if usedRatio >= 0.95 || compressedRatio >= 0.20 { return .critical }
        if usedRatio >= 0.80 || compressedRatio >= 0.08 { return .elevated }
        return .normal
    }
}

public enum ByteFormat {
    private static func format(_ value: Double, suffix: String) -> String {
        let v = max(0, value)
        if v < 1_000 { return String(format: "%.0f B%@", v, suffix) }
        if v < 1_000_000 { return String(format: "%.1f KB%@", v / 1_000, suffix) }
        if v < 1_000_000_000 { return String(format: "%.1f MB%@", v / 1_000_000, suffix) }
        if v < 1_000_000_000_000 { return String(format: "%.2f GB%@", v / 1_000_000_000, suffix) }
        return String(format: "%.2f TB%@", v / 1_000_000_000_000, suffix)
    }

    public static func speed(_ bytesPerSecond: Double) -> String {
        format(bytesPerSecond, suffix: "/s")
    }

    public static func size(_ bytes: UInt64) -> String {
        format(Double(bytes), suffix: "")
    }
}

public enum ThermalTier: String, Equatable, Sendable {
    case nominal, fair, serious, critical

    public var isElevated: Bool { self == .serious || self == .critical }
}

public enum SystemMood {
    private static func severity(_ overlay: PetOverlay) -> Int {
        switch overlay {
        case .none: return 0
        case .focus: return 1
        case .sweat: return 2
        }
    }

    public static func combine(
        base: PetOverlay, mem: MemPressureTier, thermal: ThermalTier = .nominal
    ) -> PetOverlay {
        let memOverlay: PetOverlay = mem == .critical ? .sweat : .none
        let thermalOverlay: PetOverlay = thermal.isElevated ? .sweat : .none
        let system = severity(thermalOverlay) > severity(memOverlay) ? thermalOverlay : memOverlay
        return severity(system) > severity(base) ? system : base
    }

    public static func animationSpeed(downBytesPerSec: Double) -> Double {
        downBytesPerSec > 5_000_000 ? 2.0 : 1.0
    }
}

/// One-shot gate for the "机器过热" notification: fires once when the thermal
/// tier first crosses into serious/critical, stays silent until it drops back to
/// nominal/fair, then rearms.
public struct ThermalNotificationGate: Equatable, Sendable {
    private var armed: Bool
    public init() { armed = true }

    public mutating func shouldNotify(_ tier: ThermalTier) -> Bool {
        if tier.isElevated {
            guard armed else { return false }
            armed = false
            return true
        }
        armed = true
        return false
    }
}

public protocol SystemSampling: Sendable {
    func sampleMemory() -> (used: UInt64, total: UInt64, compressed: UInt64, swap: UInt64)
    func sampleNetworkCounters() -> (down: UInt64, up: UInt64)
    func sampleCPUTicks() -> CPUTicks
    func sampleCPUTicksPerCore() -> [CPUTicks]
    func sampleDisk() -> (free: UInt64, total: UInt64)
    func sampleBattery() -> (percent: Int, charging: Bool)?
}

public extension SystemSampling {
    func sampleCPUTicksPerCore() -> [CPUTicks] { [sampleCPUTicks()] }
}

public final class MachSystemSampler: SystemSampling {
    public init() {}

    public func sampleMemory() -> (used: UInt64, total: UInt64, compressed: UInt64, swap: UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, total, 0, 0) }
        let pageSize = UInt64(vm_kernel_page_size)
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count)
            + UInt64(stats.compressor_page_count)) * pageSize
        return (used, total, compressed, swapUsed())
    }

    private func swapUsed() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }

    public func sampleNetworkCounters() -> (down: UInt64, up: UInt64) {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return (0, 0) }
        defer { freeifaddrs(ifaddrPtr) }
        var down: UInt64 = 0
        var up: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let addr = cursor {
            let flags = Int32(addr.pointee.ifa_flags)
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            let isLink = addr.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK)
            if !isLoopback, isLink, let data = addr.pointee.ifa_data {
                let networkData = data.withMemoryRebound(to: if_data.self, capacity: 1) { $0.pointee }
                down += UInt64(networkData.ifi_ibytes)
                up += UInt64(networkData.ifi_obytes)
            }
            cursor = addr.pointee.ifa_next
        }
        return (down, up)
    }

    public func sampleCPUTicks() -> CPUTicks {
        CPUAggregate.sum(sampleCPUTicksPerCore())
    }

    public func sampleCPUTicksPerCore() -> [CPUTicks] {
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0
        let result = host_processor_info(
            mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUs, &cpuInfo, &numCpuInfo
        )
        guard result == KERN_SUCCESS, let info = cpuInfo else { return [] }
        defer {
            let size = vm_size_t(Int(numCpuInfo) * MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)
        }
        return (0..<Int(numCPUs)).map { i in
            let base = Int(CPU_STATE_MAX) * i
            return CPUTicks(
                user: UInt64(info[base + Int(CPU_STATE_USER)]),
                system: UInt64(info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt64(info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt64(info[base + Int(CPU_STATE_NICE)])
            )
        }
    }

    public func sampleDisk() -> (free: UInt64, total: UInt64) {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
        ]) else { return (0, 0) }
        let free = values.volumeAvailableCapacityForImportantUsage.map { UInt64($0) } ?? 0
        let total = values.volumeTotalCapacity.map { UInt64($0) } ?? 0
        return (free, total)
    }

    public func sampleBattery() -> (percent: Int, charging: Bool)? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        guard let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              !sources.isEmpty
        else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any],
                let curCap = description[kIOPSCurrentCapacityKey] as? Int,
                let maxCap = description[kIOPSMaxCapacityKey] as? Int, maxCap > 0
            else { continue }
            let percent = Int((Double(curCap) / Double(maxCap) * 100).rounded())
            let charging = (description[kIOPSIsChargingKey] as? Bool) ?? false
            return (percent, charging)
        }
        return nil
    }
}
