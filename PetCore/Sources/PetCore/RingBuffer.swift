import Foundation

/// Fixed-capacity circular buffer of samples in chronological order. Backs the
/// 1-hour CPU/memory sparklines (360 samples @ 10s).
public struct RingBuffer: Sendable {
    public let capacity: Int
    private var storage: [Double] = []
    private var head = 0

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }

    public mutating func append(_ value: Double) {
        if storage.count < capacity {
            storage.append(value)
        } else {
            storage[head] = value
            head = (head + 1) % capacity
        }
    }

    public var values: [Double] {
        guard storage.count == capacity, head > 0 else { return storage }
        return Array(storage[head...] + storage[..<head])
    }

    public func downsampled(to target: Int) -> [Double] {
        guard target > 0 else { return [] }
        let v = values
        guard v.count > target else { return v }
        let n = v.count
        return (0..<target).map { b in
            let lo = b * n / target
            let hi = max(lo + 1, (b + 1) * n / target)
            let slice = v[lo..<hi]
            return slice.reduce(0, +) / Double(slice.count)
        }
    }
}
