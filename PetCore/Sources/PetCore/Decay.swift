import Foundation

public enum Decay {
    /// Applies time-based stat decay/regen for the given elapsed-seconds
    /// interval. Pure: does NOT update `lastTickAt` (the caller — Chunk 3's
    /// EventApplier or the tick scheduler — is responsible for persisting
    /// the new `lastTickAt`). Pass 0 elapsed when the pet is hibernating.
    public static func apply(pet: Pet, elapsedSeconds: Double, config: ConfigYAML, hibernating: Bool = false) -> Pet {
        guard elapsedSeconds > 0 else { return pet }
        var p = pet
        // While hibernating, hunger/affection freeze but stamina regenerates at 2×.
        let staminaRegen = config.decay.staminaRegenPerSecond * (hibernating ? 2 : 1)
        if !hibernating {
            p.fullness = clamp(p.fullness - config.decay.fullnessPerSecond * elapsedSeconds)
            p.intimacy = clamp(p.intimacy - config.decay.intimacyPerSecond * elapsedSeconds)
        }
        p.stamina = clamp(p.stamina + staminaRegen * elapsedSeconds)
        return p
    }

    private static func clamp(_ v: Double) -> Double { min(100, max(0, v)) }
}
