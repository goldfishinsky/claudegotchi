import Foundation
import GRDB
import PetCore

@MainActor
final class AgentActivityModel: ObservableObject {
    @Published private(set) var agents: [AgentActivity] = []

    private let db: DatabaseQueue
    private let sessionWindowMs: Int64
    var filterProvider: () -> SessionFilter = { .empty }

    init(db: DatabaseQueue, sessionWindowMs: Int64 = 15 * 60 * 1000) {
        self.db = db
        self.sessionWindowMs = sessionWindowMs
    }

    func refresh() {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        agents = (try? AgentActivityTracker.activeAgents(
            db: db, nowMs: nowMs, windowMs: sessionWindowMs, filter: filterProvider()
        )) ?? []
    }
}
