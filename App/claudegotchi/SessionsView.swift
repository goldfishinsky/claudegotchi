import SwiftUI
import GRDB
import PetCore

enum SessionFormat {
    static let rowCap = 50
    static let countCap = 99

    static func cappedCount(_ n: Int) -> String {
        n > countCap ? "\(countCap)+" : "\(n)"
    }

    static func duration(_ ms: Int64) -> String {
        let totalSeconds = max(0, ms / 1000)
        let minutes = totalSeconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let rem = minutes % 60
        return rem == 0 ? "\(hours)h" : "\(hours)h\(rem)m"
    }

    static func shortSessionId(_ id: String) -> String {
        String(id.prefix(6))
    }
}

struct SessionsView: View {
    let db: DatabaseQueue
    var windowMs: Int64 = 15 * 60 * 1000
    var refreshInterval: TimeInterval = 30

    @State private var sessions: [ActiveSession] = []

    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if sessions.isEmpty {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("本地会话").font(.subheadline.bold())
                        Text("🟢 \(SessionFormat.cappedCount(sessions.count))")
                            .font(.caption).foregroundColor(.green)
                    }
                    sessionList
                }
            }
        }
        .onAppear(perform: reload)
        .onReceive(ticker) { _ in reload() }
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(Array(sessions.prefix(SessionFormat.rowCap)), id: \.sessionId) { s in
                    sessionRow(s)
                }
                if sessions.count > SessionFormat.rowCap {
                    Text("… 还有 \(sessions.count - SessionFormat.rowCap) 个会话")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 160)
    }

    @ViewBuilder
    private func sessionRow(_ s: ActiveSession) -> some View {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        HStack(spacing: 6) {
            Text("🟢").font(.caption)
            Text(s.repo).font(.caption.bold()).lineLimit(1).truncationMode(.tail)
            Text(SessionFormat.shortSessionId(s.sessionId))
                .font(.caption.monospaced()).foregroundColor(.secondary)
            Text("运行 \(SessionFormat.duration(nowMs - s.startedAtMs))")
                .font(.caption).foregroundColor(.secondary)
            if let tool = s.lastTool {
                Text("最近:\(tool)").font(.caption).foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
        }
    }

    private func reload() {
        let repoPaths = (try? PRStore.watchedRepos(in: db))?
            .compactMap { repo -> (slug: String, path: String)? in
                guard let path = repo.localPath, !path.isEmpty else { return nil }
                return (slug: repo.slug, path: path)
            } ?? []
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        sessions = (try? SessionTracker.activeSessions(
            db: db, nowMs: nowMs, windowMs: windowMs, repoPaths: repoPaths
        )) ?? []
    }
}
