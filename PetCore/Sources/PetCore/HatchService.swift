import Foundation
import GRDB

public enum HatchService {
    @discardableResult
    public static func ensureAlive(_ db: DatabaseQueue, nowMs: Int64) throws -> Pet {
        if let alive = try Pet.fetchAlive(from: db) { return alive }
        var rng = SystemRandomNumberGenerator()
        let species = SpeciesRoulette.pick(fromIds: PixelSpeciesCatalog.ids, using: &rng)
        return try Pet.insert(.fresh(species: species, at: nowMs), into: db)
    }
}
