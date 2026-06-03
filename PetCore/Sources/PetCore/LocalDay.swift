import Foundation

public enum LocalDay {
    public static func key(unixMs: Int64, timeZone: TimeZone) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unixMs) / 1000.0)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        return f.string(from: date)
    }

    public static func dayIndex(unixMs: Int64, timeZone: TimeZone) -> Int {
        let date = Date(timeIntervalSince1970: TimeInterval(unixMs) / 1000.0)
        let offsetMs = Int64(timeZone.secondsFromGMT(for: date)) * 1000
        return Int((unixMs + offsetMs) / 86_400_000)
    }
}
