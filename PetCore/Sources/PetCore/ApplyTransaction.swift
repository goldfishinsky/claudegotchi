import Foundation
import GRDB

public final class ApplyTransaction {
    private let db: DatabaseQueue
    private let applier: EventApplier
    private let paused: Bool

    public init(db: DatabaseQueue, applier: EventApplier, paused: Bool) {
        self.db = db
        self.applier = applier
        self.paused = paused
    }

    public func process(jsonLine: String) throws {
        let event = try Event.parse(jsonLine)

        let didApply: Bool = try db.write { conn in
            var pet = try aliveOrThrow(in: conn)

            do {
                try conn.execute(sql: """
                    INSERT INTO event (helper_event_id, ts, type, pet_id, payload, session_id, cwd)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                    event.eventId,
                    event.ts,
                    event.type.rawValue,
                    pet.id!,
                    jsonLine,
                    event.sessionId,
                    event.cwd
                ])
            } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
                return false
            }

            try conn.execute(
                sql: "UPDATE pet SET last_event_at = MAX(last_event_at, ?) WHERE id = ?",
                arguments: [event.ts, pet.id!]
            )
            // applier.apply + pet.update(conn) persist the full record; sync the
            // in-memory copy so that write does not clobber last_event_at back.
            pet.lastEventAt = max(pet.lastEventAt, event.ts)
            if event.type == .postToolUse || event.type == .stop, let model = event.model {
                try ModelUsageStore.bump(
                    platform: event.platform ?? ModelPlatform.infer(model: model),
                    model: model,
                    tokensIn: event.tokensIn ?? 0,
                    tokensOut: event.tokensOut ?? 0,
                    in: conn
                )
            }

            let date = localDate(fromUnixMs: event.ts)
            try DailyRollup.upsert(
                eventDate: date, type: event.type,
                tokensIn: event.tokensIn ?? 0,
                tokensOut: event.tokensOut ?? 0,
                tool: event.tool, in: conn
            )

            if !paused {
                pet = applier.apply(event: event, to: pet)
                try pet.update(conn)
            }

            let eventDbId = try Int64.fetchOne(conn, sql: "SELECT MAX(id) FROM event")!
            try conn.execute(
                sql: "UPDATE pet SET last_applied_event_id = ? WHERE id = ?",
                arguments: [eventDbId, pet.id!]
            )
            return true
        }

        if didApply { postPetDidChange() }
    }

    public func process(event: Event) throws {
        try db.write { conn in
            var pet = try aliveOrThrow(in: conn)

            do {
                try conn.execute(sql: """
                    INSERT INTO event (helper_event_id, ts, type, pet_id, payload, session_id, cwd)
                    VALUES (?, ?, ?, ?, ?, NULL, NULL)
                    """, arguments: [
                    event.eventId,
                    event.ts,
                    event.type.rawValue,
                    pet.id!,
                    try event.encodeJSON()
                ])
            } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
                return
            }

            if !paused {
                pet = applier.apply(event: event, to: pet)
                try pet.update(conn)
            }

            let eventDbId = try Int64.fetchOne(conn, sql: "SELECT MAX(id) FROM event")!
            try conn.execute(
                sql: "UPDATE pet SET last_applied_event_id = ? WHERE id = ?",
                arguments: [eventDbId, pet.id!]
            )
        }
    }

    private func aliveOrThrow(in conn: GRDB.Database) throws -> Pet {
        guard let p = try Pet.filter(Column("death_at") == nil).fetchOne(conn) else {
            throw ApplyTransactionError.noAlivePet
        }
        return p
    }

    private func localDate(fromUnixMs ts: Int64) -> String {
        LocalDay.key(unixMs: ts, timeZone: TimeZone.current)
    }
}

public enum ApplyTransactionError: Error {
    case noAlivePet
}
