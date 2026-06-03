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
}

public final class FakeProcessRunner: ProcessRunner {
    public struct Call: Equatable {
        public let executable: String
        public let args: [String]
        public let cwd: URL?
    }
    public var calls: [Call] = []
    public var results: [ProcessResult] = []
    public var error: Error?
    public init() {}

    public func run(_ executable: String, _ args: [String], cwd: URL?, timeout: TimeInterval?) throws -> ProcessResult {
        calls.append(Call(executable: executable, args: args, cwd: cwd))
        if let error { throw error }
        guard !results.isEmpty else {
            return ProcessResult(status: 0, stdout: Data(), stderr: "")
        }
        return results.removeFirst()
    }
}
