import Foundation

public enum TickEmit: String, Equatable { case hibernateStart, hibernateEnd }

public struct TickResult: Equatable {
    public let pet: Pet
    public let emit: TickEmit?
    public init(pet: Pet, emit: TickEmit?) {
        self.pet = pet
        self.emit = emit
    }
}

public enum TickCheckpoint {
    public static func run(pet: Pet, nowMs: Int64, lastEventMs: Int64, config: ConfigYAML) -> TickResult {
        var p = pet
        let elapsedSeconds = max(0, Double(nowMs - pet.lastTickAt)) / 1000.0
        var emit: TickEmit? = nil

        if pet.hibernationSince == nil {
            if Hibernation.shouldEnter(
                nowSeconds: Double(nowMs) / 1000.0,
                lastEventSeconds: Double(lastEventMs) / 1000.0,
                config: config
            ) {
                p.hibernationSince = nowMs
                emit = .hibernateStart
            } else {
                p = Decay.apply(pet: p, elapsedSeconds: elapsedSeconds, config: config)
            }
        } else if lastEventMs > pet.hibernationSince! {
            p.hibernationSince = nil
            emit = .hibernateEnd
        }

        p.lastTickAt = nowMs
        return TickResult(pet: p, emit: emit)
    }
}
