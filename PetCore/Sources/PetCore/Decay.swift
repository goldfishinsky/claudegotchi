import Foundation

public enum Decay {
    /// Applies time-based stat decay/regen for the given elapsed-seconds
    /// interval. Pure: does NOT update `lastTickAt` (the caller — Chunk 3's
    /// EventApplier or the tick scheduler — is responsible for persisting
    /// the new `lastTickAt`). Pass 0 elapsed when the pet is hibernating.
    public static func apply(pet: Pet, elapsedSeconds: Double, config: ConfigYAML) -> Pet {
        guard elapsedSeconds > 0 else { return pet }
        var p = pet
        p.fullness = clamp(p.fullness - config.decay.fullnessPerSecond * elapsedSeconds)
        p.intimacy = clamp(p.intimacy - config.decay.intimacyPerSecond * elapsedSeconds)
        p.stamina  = clamp(p.stamina  + config.decay.staminaRegenPerSecond * elapsedSeconds)
        return p
    }

    private static func clamp(_ v: Double) -> Double { min(100, max(0, v)) }
}
