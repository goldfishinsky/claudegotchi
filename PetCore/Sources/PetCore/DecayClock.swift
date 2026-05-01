import Foundation

/// Source of wall-clock time. Production uses `mach_continuous_time`, which
/// continues to advance during macOS sleep and is monotonic. Tests inject
/// `FixedClock` for deterministic time travel.
public protocol Clock {
    func nowSeconds() -> Double
}

public struct MachClock: Clock {
    public init() {}
    public func nowSeconds() -> Double {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        let raw = mach_continuous_time()
        let nanos = Double(raw) * Double(info.numer) / Double(info.denom)
        return nanos / 1_000_000_000.0
    }
}

public final class FixedClock: Clock {
    private var t: Double
    public init(start: Double = 0) { self.t = start }
    public func nowSeconds() -> Double { t }
    public func advance(seconds: Double) { t += seconds }
    public func set(seconds: Double) { t = seconds }
}
