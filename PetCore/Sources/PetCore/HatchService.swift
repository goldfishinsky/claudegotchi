import Foundation
import GRDB

public enum HatchService {
    @discardableResult
    public static func ensureAlive(_ db: DatabaseQueue, nowMs: Int64) throws -> Pet {
        if let alive = try Pet.fetchAlive(from: db) { return alive }
        let seed = UInt64.random(in: UInt64.min...UInt64.max)
        let species = Genome.species(seed: seed, availableIDs: PixelSpeciesCatalog.ids)
        return try Pet.insert(.fresh(species: species, at: nowMs, genomeSeed: seed), into: db)
    }
}
