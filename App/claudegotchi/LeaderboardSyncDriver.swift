import Foundation
import GRDB
import PetCore

@MainActor
final class LeaderboardSyncDriver: ObservableObject {
    struct Snapshot {
        var account: LeaderboardAccount?
        var lastSyncAtMs: Int64?
        var lastError: String?
        var me: MeResponse?
        var syncing: Bool = false
    }

    @Published private(set) var snapshot = Snapshot()

    private nonisolated let db: DatabaseQueue
    private nonisolated let service: LeaderboardService
    private nonisolated let credentials: LeaderboardCredentialsStore
    private nonisolated let syncIntervalSeconds: Int
    private nonisolated let nowMsProvider: () -> Int64

    private var timer: Timer?
    private var lastSyncedPayload: SyncPayload?
    private var rateLimitedUntilMs: Int64?

    init(
        db: DatabaseQueue,
        service: LeaderboardService,
        credentials: LeaderboardCredentialsStore,
        syncIntervalSeconds: Int,
        nowMsProvider: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.db = db
        self.service = service
        self.credentials = credentials
        self.syncIntervalSeconds = syncIntervalSeconds
        self.nowMsProvider = nowMsProvider
    }

    func start() {
        snapshot.account = (try? credentials.load()) ?? nil
        requestSync()
        let interval = TimeInterval(max(1, syncIntervalSeconds))
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestSync() }
        }
        t.tolerance = interval * 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func syncNow() {
        Task { await performSync(force: true) }
    }

    func didLogin(_ account: LeaderboardAccount) {
        try? credentials.save(account)
        snapshot.account = account
        snapshot.lastError = nil
        lastSyncedPayload = nil
        rateLimitedUntilMs = nil
        syncNow()
    }

    func logout() {
        try? credentials.clear()
        snapshot = Snapshot()
        lastSyncedPayload = nil
        rateLimitedUntilMs = nil
    }

    private func requestSync() {
        Task { await performSync(force: false) }
    }

    private func performSync(force: Bool) async {
        guard let account = snapshot.account else { return }
        guard !snapshot.syncing else { return }
        if !force, let notBefore = rateLimitedUntilMs, nowMsProvider() < notBefore { return }

        snapshot.syncing = true
        defer { snapshot.syncing = false }

        let db = self.db
        let builtAtMs = nowMsProvider()
        let payload = await Task.detached { try? LeaderboardPayload.build(db: db, nowMs: builtAtMs) }.value
        guard let payload else { return }
        if payload == lastSyncedPayload { return }

        do {
            _ = try await service.sync(payload, token: account.token)
            lastSyncedPayload = payload
            rateLimitedUntilMs = nil
            snapshot.lastSyncAtMs = nowMsProvider()
            snapshot.lastError = nil
            if let me = try? await service.me(token: account.token) {
                snapshot.me = me
            }
        } catch LeaderboardError.unauthorized {
            try? credentials.clear()
            snapshot.account = nil
            snapshot.me = nil
            lastSyncedPayload = nil
            snapshot.lastError = "登录已失效，请重新登录"
        } catch LeaderboardError.rateLimited(let retryAfterMs) {
            rateLimitedUntilMs = nowMsProvider() + (retryAfterMs ?? 15 * 60 * 1000)
        } catch {
            snapshot.lastError = "同步失败，稍后重试"
        }
    }
}
