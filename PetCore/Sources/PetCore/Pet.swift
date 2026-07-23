import Foundation
import GRDB

public struct Pet: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    public var id: Int64?
    public var species: String
    public var name: String?
    public var birthday: Int64
    public var deathAt: Int64?
    public var fullness: Double
    public var stamina: Double
    public var intimacy: Double
    public var xp: Int64
    public var lastTickAt: Int64
    public var lastAppliedEventId: Int64
    public var hibernationSince: Int64?
    public var lastStaminaChargeAt: Int64?
    public var deathWindowState: String
    public var lastEventAt: Int64
    public var uid: String?
    public var genome: Int64?

    public static let databaseTableName = "pet"

    enum CodingKeys: String, CodingKey {
        case id, species, name, birthday
        case deathAt = "death_at"
        case fullness, stamina, intimacy, xp
        case lastTickAt = "last_tick_at"
        case lastAppliedEventId = "last_applied_event_id"
        case hibernationSince = "hibernation_since"
        case lastStaminaChargeAt = "last_stamina_charge_at"
        case deathWindowState = "death_window_state"
        case lastEventAt = "last_event_at"
        case uid, genome
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static func fresh(
        species: String, at ts: Int64, uid: String = ULID.generate(),
        genomeSeed: UInt64 = UInt64.random(in: UInt64.min...UInt64.max)
    ) -> Pet {
        Pet(
            id: nil, species: species, name: nil,
            birthday: ts, deathAt: nil,
            fullness: 100, stamina: 100, intimacy: 50,
            xp: 0, lastTickAt: ts, lastAppliedEventId: 0,
            hibernationSince: nil, lastStaminaChargeAt: nil, deathWindowState: "[]",
            lastEventAt: ts, uid: uid, genome: Genome.pack(genomeSeed)
        )
    }

    @discardableResult
    public static func insert(_ pet: Pet, into db: DatabaseQueue) throws -> Pet {
        try db.write { conn in
            var copy = pet
            try copy.insert(conn)
            return copy
        }
    }

    public static func fetchAlive(from db: DatabaseQueue) throws -> Pet? {
        try db.read { conn in
            try Pet.filter(Column("death_at") == nil).fetchOne(conn)
        }
    }

    public static func fetchAllDead(from db: DatabaseQueue) throws -> [Pet] {
        try db.read { conn in
            try Pet.filter(Column("death_at") != nil)
                .order(Column("death_at").desc)
                .fetchAll(conn)
        }
    }

    public static func markDead(id: Int64, at ts: Int64, in db: DatabaseQueue) throws {
        try db.write { conn in
            try conn.execute(
                sql: "UPDATE pet SET death_at = ? WHERE id = ?",
                arguments: [ts, id]
            )
        }
    }

    public static func update(_ pet: Pet, in db: DatabaseQueue) throws {
        try db.write { conn in
            try pet.update(conn)
        }
    }
}
