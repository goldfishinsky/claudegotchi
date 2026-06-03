import Foundation

public struct ClaudeProgress: Equatable {
    public let tool: String?
    public let tokens: Int?
    public init(tool: String?, tokens: Int?) {
        self.tool = tool
        self.tokens = tokens
    }
}

public final class CancelToken {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }
    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
}

public protocol ClaudeRunner {
    func runFix(prompt: String, cwd: URL, allowedTools: String, disallowedTools: String,
                permissionMode: String, timeout: TimeInterval, logURL: URL,
                onProgress: @escaping (ClaudeProgress) -> Void, cancel: CancelToken) throws -> Int32
}

public final class CLIClaudeRunner: ClaudeRunner {
    private let runner: ProcessRunner
    public init(runner: ProcessRunner) { self.runner = runner }

    public func runFix(prompt: String, cwd: URL, allowedTools: String, disallowedTools: String,
                       permissionMode: String, timeout: TimeInterval, logURL: URL,
                       onProgress: @escaping (ClaudeProgress) -> Void, cancel: CancelToken) throws -> Int32 {
        let args = Self.fixArgs(
            prompt: prompt, allowedTools: allowedTools,
            disallowedTools: disallowedTools, permissionMode: permissionMode
        )
        let result = try runner.run("claude", args, cwd: cwd, timeout: timeout)

        let raw = String(data: result.stdout, encoding: .utf8) ?? ""
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            if let progress = Self.parseProgress(String(line)) {
                onProgress(progress)
            }
        }

        let redacted = LogRedactor.redact(raw)
        try redacted.data(using: .utf8)?.write(to: logURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)

        return result.status
    }

    public static func fixArgs(prompt: String, allowedTools: String,
                               disallowedTools: String, permissionMode: String) -> [String] {
        [
            "-p", prompt,
            "--permission-mode", permissionMode,
            "--allowedTools", allowedTools,
            "--disallowedTools", disallowedTools,
            "--output-format", "stream-json",
            "--verbose",
        ]
    }

    public static func parseProgress(_ line: String) -> ClaudeProgress? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        var tool: String?
        if let message = obj["message"] as? [String: Any],
           let content = message["content"] as? [[String: Any]] {
            tool = content.first { ($0["type"] as? String) == "tool_use" }?["name"] as? String
        }

        var tokens: Int?
        let usage = (obj["message"] as? [String: Any])?["usage"] as? [String: Any]
            ?? obj["usage"] as? [String: Any]
        if let usage {
            let input = usage["input_tokens"] as? Int ?? 0
            let output = usage["output_tokens"] as? Int ?? 0
            tokens = input + output
        }

        if tool == nil && tokens == nil { return nil }
        return ClaudeProgress(tool: tool, tokens: tokens)
    }
}
