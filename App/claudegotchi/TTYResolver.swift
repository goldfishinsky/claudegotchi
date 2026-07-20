import AppKit
import Darwin

// MARK: - process snapshot

struct ProcInfo: Equatable {
    let pid: Int32
    let ppid: Int32
    let tty: String?
}

protocol ProcessTableProviding {
    func processes() -> [ProcInfo]
    func guiApps() -> [Int32: String]
}

// MARK: - pure resolution (unit-tested)

/// Maps a tty to its owning app: a process on that tty walked up the parent chain
/// reaches the first GUI app — the host emulator (or an Electron editor).
enum TTYOwnerResolver {
    static let maxHops = 40

    static func resolve(tty: String, processes: [ProcInfo], guiApps: [Int32: String]) -> String? {
        guard !tty.isEmpty else { return nil }
        var byPid: [Int32: ProcInfo] = [:]
        byPid.reserveCapacity(processes.count)
        for p in processes { byPid[p.pid] = p }
        for start in processes where start.tty == tty {
            var cur: Int32? = start.pid
            var hops = 0
            while let pid = cur, hops < maxHops {
                if let bundle = guiApps[pid] { return bundle }
                let next = byPid[pid]?.ppid
                if next == nil || next == 0 || next == pid { break }
                cur = next
                hops += 1
            }
        }
        return nil
    }
}

// MARK: - sysctl-backed provider

// sysctl, not proc_pidinfo: the parent walk crosses root-owned /usr/bin/login,
// which proc_pidinfo can't read cross-user (EPERM) — that gap would break the chain.
final class SysctlProcessTable: ProcessTableProviding {
    func processes() -> [ProcInfo] {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var len = 0
        guard sysctl(&name, 4, nil, &len, nil, 0) == 0, len > 0 else { return [] }
        let slack = 32 * MemoryLayout<kinfo_proc>.stride
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: (len + slack) / MemoryLayout<kinfo_proc>.stride)
        var got = buffer.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&name, 4, &buffer, &got, nil, 0) == 0 else { return [] }
        let n = got / MemoryLayout<kinfo_proc>.stride
        var out: [ProcInfo] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let kp = buffer[i]
            let pid = kp.kp_proc.p_pid
            guard pid > 0 else { continue }
            out.append(ProcInfo(pid: pid, ppid: kp.kp_eproc.e_ppid, tty: Self.ttyPath(kp.kp_eproc.e_tdev)))
        }
        return out
    }

    func guiApps() -> [Int32: String] {
        var map: [Int32: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let bundle = app.bundleIdentifier else { continue }
            map[app.processIdentifier] = bundle
        }
        return map
    }

    private static func ttyPath(_ dev: dev_t) -> String? {
        if dev == -1 { return nil }
        guard let name = devname(dev, S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }
}
