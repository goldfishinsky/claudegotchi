import Foundation
import Darwin

enum ControllingTTY {
    // stdin is a pipe, so the tty comes from the kernel's controlling-terminal
    // record (e_tdev), not ttyname(stdin); nil means headless (NODEV).
    static func current() -> String? {
        path(forPID: getpid())
    }

    static func path(forPID pid: Int32) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let dev = info.e_tdev
        if dev == UInt32.max { return nil }
        guard let name = devname(dev_t(dev), S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }

    // Non-blocking, no controlling-terminal side effect, failures swallowed: a title
    // write must never block or disrupt the hook.
    static func writeTitle(_ escape: String, toTTY tty: String) {
        let fd = open(tty, O_WRONLY | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = escape.utf8CString.withUnsafeBufferPointer { buf -> Int in
            guard let base = buf.baseAddress else { return 0 }
            return write(fd, base, buf.count - 1)
        }
    }
}
