import Foundation

public enum SpeciesRoulette {
    public struct Pick {
        public let id: String
        public let species: Species?
        public let usedFallback: Bool
    }

    /// Uniform random pick across all loaded species. If the registry is empty,
    /// returns the hardcoded fallback id "frog" with `usedFallback = true`.
    public static func pick<G: RandomNumberGenerator>(
        from registry: SpeciesRegistry,
        using rng: inout G
    ) -> Pick {
        guard !registry.all.isEmpty else {
            return Pick(id: "frog", species: nil, usedFallback: true)
        }
        let idx = Int.random(in: 0..<registry.all.count, using: &rng)
        let s = registry.all[idx]
        return Pick(id: s.id, species: s, usedFallback: false)
    }
}

extension SpeciesRoulette {
    public static func pick<G: RandomNumberGenerator>(fromIds ids: [String], using gen: inout G) -> String {
        precondition(!ids.isEmpty, "pick(fromIds:) requires a non-empty id list")
        let idx = Int.random(in: 0..<ids.count, using: &gen)
        return ids[idx]
    }
}
