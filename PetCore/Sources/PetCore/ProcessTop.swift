import Foundation
import Darwin

public struct ProcSample: Equatable, Sendable {
    public let pid: Int32
    public let name: String
    public let cpuTimeNs: UInt64
    public let rssBytes: UInt64
    public init(pid: Int32, name: String, cpuTimeNs: UInt64, rssBytes: UInt64) {
        self.pid = pid
        self.name = name
        self.cpuTimeNs = cpuTimeNs
        self.rssBytes = rssBytes
    }
}

public struct ProcessCPUUsage: Equatable, Sendable {
    public let pid: Int32
    public let name: String
    public let percent: Double
    public init(pid: Int32, name: String, percent: Double) {
        self.pid = pid
        self.name = name
        self.percent = percent
    }
}

public struct ProcessRAMUsage: Equatable, Sendable {
    public let pid: Int32
    public let name: String
    public let rssBytes: UInt64
    public init(pid: Int32, name: String, rssBytes: UInt64) {
        self.pid = pid
        self.name = name
        self.rssBytes = rssBytes
    }
}

public enum ProcessTop {
    public static func topByCPU(
        prev: [ProcSample], cur: [ProcSample], dtSeconds: Double, limit: Int = 3
    ) -> [ProcessCPUUsage] {
        guard dtSeconds > 0, limit > 0 else { return [] }
        var prevByPid: [Int32: UInt64] = [:]
        prevByPid.reserveCapacity(prev.count)
        for p in prev { prevByPid[p.pid] = p.cpuTimeNs }
        let window = dtSeconds * 1_000_000_000
        var usages: [ProcessCPUUsage] = []
        for c in cur {
            guard let was = prevByPid[c.pid], c.cpuTimeNs > was else { continue }
            let percent = Double(c.cpuTimeNs - was) / window * 100
            guard percent > 0 else { continue }
            usages.append(ProcessCPUUsage(pid: c.pid, name: c.name, percent: percent))
        }
        return Array(usages.sorted { $0.percent > $1.percent }.prefix(limit))
    }

    public static func topByRAM(_ cur: [ProcSample], limit: Int = 3) -> [ProcessRAMUsage] {
        guard limit > 0 else { return [] }
        return cur
            .sorted { $0.rssBytes > $1.rssBytes }
            .prefix(limit)
            .map { ProcessRAMUsage(pid: $0.pid, name: $0.name, rssBytes: $0.rssBytes) }
    }
}

public protocol ProcessSampling: Sendable {
    func sampleProcesses() -> [ProcSample]
}

public final class LibprocProcessSampler: ProcessSampling {
    public init() {}

    public func sampleProcesses() -> [ProcSample] {
        let cap = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard cap > 0 else { return [] }
        let slots = Int(cap) / MemoryLayout<pid_t>.stride
        var pids = [pid_t](repeating: 0, count: slots)
        let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, cap)
        guard written > 0 else { return [] }
        let n = Int(written) / MemoryLayout<pid_t>.stride
        var out: [ProcSample] = []
        out.reserveCapacity(n)
        let infoSize = Int32(MemoryLayout<proc_taskinfo>.size)
        for i in 0..<n {
            let pid = pids[i]
            guard pid > 0 else { continue }
            var ti = proc_taskinfo()
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, infoSize) == infoSize else { continue }
            out.append(ProcSample(
                pid: pid,
                name: Self.name(of: pid),
                cpuTimeNs: ti.pti_total_user &+ ti.pti_total_system,
                rssBytes: ti.pti_resident_size
            ))
        }
        return out
    }

    private static func name(of pid: pid_t) -> String {
        var path = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
            let last = (String(cString: path) as NSString).lastPathComponent
            if !last.isEmpty { return last }
        }
        var comm = [CChar](repeating: 0, count: 256)
        proc_name(pid, &comm, UInt32(comm.count))
        return String(cString: comm)
    }
}
