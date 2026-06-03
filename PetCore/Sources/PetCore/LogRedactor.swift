import Foundation

public enum LogRedactor {
    private static let patterns: [String] = [
        #"gh[pousr]_[A-Za-z0-9]{20,}"#,
        #"github_pat_[A-Za-z0-9_]{20,}"#,
        #"AKIA[0-9A-Z]{16}"#,
        #"(?i)authorization:\s*.+"#,
        #"[A-Za-z0-9._%-]+:[^@\s/]+@"#,
    ]

    public static func redact(_ s: String) -> String {
        var out = s
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            out = re.stringByReplacingMatches(
                in: out, range: range,
                withTemplate: replacement(for: pattern)
            )
        }
        return out
    }

    private static func replacement(for pattern: String) -> String {
        if pattern.contains("authorization") { return "Authorization: [REDACTED]" }
        if pattern.hasSuffix("@") { return "[REDACTED]@" }
        return "[REDACTED]"
    }
}
