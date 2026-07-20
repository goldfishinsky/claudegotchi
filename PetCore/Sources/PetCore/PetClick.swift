import Foundation

public enum PetClick {
    public static func allowed(lastClickMs: Int64?, nowMs: Int64, cooldownSeconds: Int) -> Bool {
        guard let last = lastClickMs else { return true }
        return nowMs - last >= Int64(cooldownSeconds) * 1000
    }
}

/// Rate-caps intimacy earned by long-press petting to one accrual per window
/// (default 10 min → ~+2 intimacy). The per-window bucket also names the event
/// deterministically, so replaying the spool never double-credits a bucket.
public enum PetPetting {
    public static let windowMs: Int64 = 10 * 60 * 1000

    public static func bucket(nowMs: Int64) -> Int64 { nowMs / windowMs }

    public static func shouldAccrue(lastAccrualMs: Int64?, nowMs: Int64) -> Bool {
        guard let last = lastAccrualMs else { return true }
        return bucket(nowMs: nowMs) != bucket(nowMs: last)
    }

    public static func eventId(petId: Int64, nowMs: Int64) -> String {
        "pet:\(petId):\(bucket(nowMs: nowMs))"
    }
}
