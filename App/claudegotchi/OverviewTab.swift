import SwiftUI
import GRDB
import PetCore

private struct MetricCard: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundColor(.secondary)
                .lineLimit(1).truncationMode(.tail)
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}

struct OverviewTab: View {
    let db: DatabaseQueue

    @State private var lifetime: Int64 = 0
    @State private var todayTokens: Int64 = 0
    @State private var todaySessions: Int = 0
    @State private var todayTools: Int = 0
    @State private var level: Int = 0
    @State private var streak: Int = 0
    @State private var peak: Int64 = 0
    @State private var ageDays: Int = 0
    @State private var heatNowMs: Int64 = 0
    @State private var heatTZ: TimeZone = .current

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                LazyVGrid(columns: columns, spacing: 10) {
                    MetricCard(title: "总token", value: TokenFormat.compact(lifetime))
                    MetricCard(title: "今日token", value: TokenFormat.compact(todayTokens))
                    MetricCard(title: "今日会话", value: PRTabFormat.cappedCount(todaySessions))
                    MetricCard(title: "今日工具", value: PRTabFormat.cappedCount(todayTools))
                    MetricCard(title: "当前等级", value: "Lv \(level)")
                    MetricCard(title: "活跃天数", value: "\(streak)")
                    MetricCard(title: "单日峰值token", value: TokenFormat.compact(peak))
                    MetricCard(title: "宠物年龄(天)", value: "\(ageDays)")
                }

                Text("贡献热力图").font(.caption).foregroundColor(.secondary)
                HeatmapView(db: db, weeks: 53, nowMs: heatNowMs, tz: heatTZ)
            }
            .padding(16)
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .claudegotchiPetDidChange)) { _ in
            DispatchQueue.main.async { reload() }
        }
    }

    private func reload() {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let tz = TimeZone.current
        heatNowMs = nowMs
        heatTZ = tz
        lifetime = (try? StatsQueries.lifetimeTokens(db)) ?? 0
        let totals = try? StatsQueries.todayTotals(db, nowMs: nowMs, tz: tz)
        todayTokens = totals?.tokens ?? 0
        todaySessions = totals?.sessions ?? 0
        todayTools = totals?.tools ?? 0
        let xp = (try? Pet.fetchAlive(from: db))??.xp ?? 0
        level = Level.compute(xp: xp)
        streak = (try? StatsQueries.activeStreakDays(db, nowMs: nowMs, tz: tz)) ?? 0
        peak = (try? StatsQueries.peakDayTokens(db)) ?? 0
        ageDays = (try? StatsQueries.petAgeDays(db, nowMs: nowMs)) ?? 0
    }
}
