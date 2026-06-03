import Foundation

public struct ProcessResult: Equatable {
    public let status: Int32
    public let stdout: Data
    public let stderr: String
    public init(status: Int32, stdout: Data, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol ProcessRunner {
    func run(_ executable: String, _ args: [String], cwd: URL?, timeout: TimeInterval?) throws -> ProcessResult

    /// Long-running variant that drains stdout concurrently (per-line callback as
    /// data arrives, so >pipe-buffer output never deadlocks), spawns the child in
    /// its own process group, and tears that group down on cancel/timeout.
    func runStreaming(_ executable: String, _ args: [String], cwd: URL?, timeout: TimeInterval?,
                      cancel: CancelToken?, onStdoutLine: ((String) -> Void)?) throws -> ProcessResult
}

public extension ProcessRunner {
    func runStreaming(_ executable: String, _ args: [String], cwd: URL?, timeout: TimeInterval?,
                      cancel: CancelToken?, onStdoutLine: ((String) -> Void)?) throws -> ProcessResult {
        let result = try run(executable, args, cwd: cwd, timeout: timeout)
        if let onStdoutLine {
            let text = String(data: result.stdout, encoding: .utf8) ?? ""
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                onStdoutLine(String(line))
            }
        }
        return result
    }
}

public enum ProcessRunnerError: Error, Equatable {
    case spawnFailed(String)
    case timedOut
}

public final class SystemProcessRunner: ProcessRunner {
    public init() {}

    public func run(_ executable: String, _ args: [String], cwd: URL?, timeout: TimeInterval?) throws -> ProcessResult {
        let process = Process()
        if executable.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + args
        }
        if let cwd { process.currentDirectoryURL = cwd }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw ProcessRunnerError.spawnFailed("\(error)")
        }

        let timedOut = waitOrKill(process, timeout: timeout)
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        if timedOut { throw ProcessRunnerError.timedOut }

        return ProcessResult(
            status: process.terminationStatus,
            stdout: outData,
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    private func waitOrKill(_ process: Process, timeout: TimeInterval?) -> Bool {
        guard let timeout else {
            process.waitUntilExit()
            return false
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                process.waitUntilExit()
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        process.waitUntilExit()
        return false
    }

    public func runStreaming(_ executable: String, _ args: [String], cwd: URL?, timeout: TimeInterval?,
                             cancel: CancelToken?, onStdoutLine: ((String) -> Void)?) throws -> ProcessResult {
        let spawned = try Spawned.start(executable: executable, args: args, cwd: cwd)
        let killGrace: TimeInterval = 2.0
        let deadline = timeout.map { Date().addingTimeInterval($0) }

        let drain = StdoutDrain(fd: spawned.stdoutRead, onLine: onStdoutLine)
        drain.start()

        var timedOut = false
        var canceled = false
        var sentTerm = false
        var termAt: Date?
        while true {
            if let exited = spawned.reapIfExited() {
                _ = exited
                break
            }
            if let deadline, Date() >= deadline, !sentTerm {
                timedOut = true
                spawned.signalGroup(SIGTERM); sentTerm = true; termAt = Date()
            }
            if let cancel, cancel.isCancelled, !sentTerm {
                canceled = true
                spawned.signalGroup(SIGTERM); sentTerm = true; termAt = Date()
            }
            if let termAt, Date() >= termAt.addingTimeInterval(killGrace) {
                spawned.signalGroup(SIGKILL)
            }
            Thread.sleep(forTimeInterval: 0.01)
        }

        let outData = drain.finish()
        if timedOut { throw ProcessRunnerError.timedOut }
        _ = canceled
        return ProcessResult(status: spawned.exitStatus, stdout: outData, stderr: "")
    }
}

/// A child spawned into its own process group via posix_spawn, with stdout+stderr
/// merged onto a single read fd. The whole group can be signaled with killpg.
private final class Spawned {
    let pid: pid_t
    let stdoutRead: Int32
    private var reaped = false
    private(set) var exitStatus: Int32 = -1

    private init(pid: pid_t, stdoutRead: Int32) {
        self.pid = pid
        self.stdoutRead = stdoutRead
    }

    static func start(executable: String, args: [String], cwd: URL?) throws -> Spawned {
        let resolved = resolvePath(executable)
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw ProcessRunnerError.spawnFailed("pipe") }
        let readEnd = fds[0], writeEnd = fds[1]

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, writeEnd, 1)
        posix_spawn_file_actions_adddup2(&fileActions, writeEnd, 2)
        posix_spawn_file_actions_addclose(&fileActions, readEnd)
        posix_spawn_file_actions_addclose(&fileActions, writeEnd)
        if let cwd {
            posix_spawn_file_actions_addchdir_np(&fileActions, cwd.path)
        }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)

        let argv = [resolved] + args
        let cargv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { for p in cargv where p != nil { free(p) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, resolved, &fileActions, &attr, cargv, environ)
        posix_spawn_file_actions_destroy(&fileActions)
        posix_spawnattr_destroy(&attr)
        close(writeEnd)
        guard rc == 0 else {
            close(readEnd)
            throw ProcessRunnerError.spawnFailed("posix_spawn \(rc)")
        }
        return Spawned(pid: pid, stdoutRead: readEnd)
    }

    func signalGroup(_ sig: Int32) {
        _ = killpg(pid, sig)
    }

    /// Non-blocking reap. Returns the raw wait status once the child has exited.
    func reapIfExited() -> Int32? {
        if reaped { return exitStatus }
        var status: Int32 = 0
        let rc = waitpid(pid, &status, WNOHANG)
        guard rc == pid else { return nil }
        reaped = true
        if (status & 0x7f) == 0 {
            exitStatus = (status >> 8) & 0xff
        } else {
            exitStatus = 128 + (status & 0x7f)
        }
        return status
    }

    private static func resolvePath(_ executable: String) -> String {
        if executable.hasPrefix("/") { return executable }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin"
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(executable)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return executable
    }
}

/// Drains a read fd on a background thread, accumulating all bytes and emitting
/// complete UTF-8 lines as they arrive so progress can be reported live.
private final class StdoutDrain {
    private let fd: Int32
    private let onLine: ((String) -> Void)?
    private let lock = NSLock()
    private var collected = Data()
    private var pending = Data()
    private var thread: Thread?
    private let done = DispatchSemaphore(value: 0)

    init(fd: Int32, onLine: ((String) -> Void)?) {
        self.fd = fd
        self.onLine = onLine
    }

    func start() {
        let t = Thread { [weak self] in self?.loop() }
        t.stackSize = 1 << 20
        thread = t
        t.start()
    }

    private func loop() {
        let bufSize = 65536
        var buffer = [UInt8](repeating: 0, count: bufSize)
        while true {
            let n = read(fd, &buffer, bufSize)
            if n > 0 {
                let chunk = Data(buffer[0..<n])
                lock.lock(); collected.append(chunk); lock.unlock()
                emitLines(from: chunk)
            } else {
                break
            }
        }
        flushPending()
        close(fd)
        done.signal()
    }

    private func emitLines(from chunk: Data) {
        guard onLine != nil else { return }
        pending.append(chunk)
        while let nl = pending.firstIndex(of: 0x0a) {
            let lineData = pending.subdata(in: pending.startIndex..<nl)
            pending.removeSubrange(pending.startIndex...nl)
            if let s = String(data: lineData, encoding: .utf8) { onLine?(s) }
        }
    }

    private func flushPending() {
        guard onLine != nil, !pending.isEmpty else { return }
        if let s = String(data: pending, encoding: .utf8), !s.isEmpty { onLine?(s) }
        pending.removeAll()
    }

    func finish() -> Data {
        done.wait()
        lock.lock(); defer { lock.unlock() }
        return collected
    }
}

public final class FakeProcessRunner: ProcessRunner {
    public struct Call: Equatable {
        public let executable: String
        public let args: [String]
        public let cwd: URL?
    }
    public var calls: [Call] = []
    public var results: [ProcessResult] = []
    public var streamLines: [String] = []
    public var error: Error?
    /// When set, runStreaming spins until the injected token is cancelled, so tests
    /// can exercise mid-run cancel teardown without a real subprocess.
    public var blockUntilCancelled = false
    public init() {}

    public func run(_ executable: String, _ args: [String], cwd: URL?, timeout: TimeInterval?) throws -> ProcessResult {
        calls.append(Call(executable: executable, args: args, cwd: cwd))
        if let error { throw error }
        guard !results.isEmpty else {
            return ProcessResult(status: 0, stdout: Data(), stderr: "")
        }
        return results.removeFirst()
    }

    public func runStreaming(_ executable: String, _ args: [String], cwd: URL?, timeout: TimeInterval?,
                             cancel: CancelToken?, onStdoutLine: ((String) -> Void)?) throws -> ProcessResult {
        calls.append(Call(executable: executable, args: args, cwd: cwd))
        if let error { throw error }
        for line in streamLines { onStdoutLine?(line) }
        if blockUntilCancelled {
            while !(cancel?.isCancelled ?? false) { Thread.sleep(forTimeInterval: 0.005) }
            return ProcessResult(status: 143, stdout: Data(), stderr: "")
        }
        guard !results.isEmpty else {
            return ProcessResult(status: 0, stdout: Data(), stderr: "")
        }
        return results.removeFirst()
    }
}
