import Foundation

public final class SpoolReader {
    private let url: URL
    private var offset: UInt64 = 0
    private var partial = ""

    public init(url: URL) {
        self.url = url
    }

    /// Reads all complete lines (terminated by \n) appended since the last
    /// call. A partial last line (no trailing newline) is buffered in memory
    /// and returned when its newline arrives.
    public func readNewLines() throws -> [String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? UInt64) ?? 0

        if size < offset {
            offset = 0
            partial = ""
        }

        guard size > offset else { return [] }

        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        try h.seek(toOffset: offset)
        let chunk = h.readDataToEndOfFile()
        offset = size

        let combined = partial + (String(data: chunk, encoding: .utf8) ?? "")
        var lines = combined.components(separatedBy: "\n")
        partial = lines.removeLast()
        return lines.filter { !$0.isEmpty }
    }
}
