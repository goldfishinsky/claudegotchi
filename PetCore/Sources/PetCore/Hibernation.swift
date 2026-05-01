import Foundation

public enum Hibernation {
    /// True when (now - lastEvent) ≥ configured threshold.
    public static func shouldEnter(nowSeconds: Double, lastEventSeconds: Double, config: ConfigYAML) -> Bool {
        let elapsed = nowSeconds - lastEventSeconds
        return elapsed >= Double(config.thresholds.hibernationAfterSeconds)
    }

    /// True iff the pet is currently hibernating. Any inbound event wakes
    /// the pet in the current design, so the caller (EventApplier in
    /// Chunk 3) treats this as "needs wake" without further checks.
    public static func shouldWake(pet: Pet) -> Bool {
        pet.hibernationSince != nil
    }
}
