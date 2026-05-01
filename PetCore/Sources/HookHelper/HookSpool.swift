import Foundation

public enum HookSpool {
    /// Appends one line + '\n' to the spool file using O_APPEND | O_CREAT
    /// with mode 0600. Atomic on macOS for writes ≤ PIPE_BUF (4096 bytes).
    public static func append(_ line: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else {
            throw HookSpoolError.openFailed(errno: errno)
        }
        defer { close(fd) }

        var data = Data(line.utf8)
        data.append(0x0A)
        let written = data.withUnsafeBytes { ptr in
            Darwin.write(fd, ptr.baseAddress, data.count)
        }
        guard written == data.count else {
            throw HookSpoolError.writeFailed(errno: errno)
        }
        _ = fsync(fd)
    }
}

public enum HookSpoolError: Error, Equatable {
    case openFailed(errno: Int32)
    case writeFailed(errno: Int32)
}
