import SwiftUI
import GRDB
import PetCore

private struct MetricCard: View {
    let symbol: String
    let colors: [Color]
    let title: String
    let value: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = WarmTheme(scheme: scheme)
        return SoftCard(fill: t.cardFill, cornerRadius: 16, padding: 12, shadow: t.cardShadow) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    CandyIcon(symbol: symbol, colors: colors, size: 14)
                        .frame(width: 18, alignment: .center)
                    Text(title).font(WFont.section).foregroundStyle(t.ink)
                        .lineLimit(1).truncationMode(.tail)
                }
                Text(value).font(WFont.metric).monospacedDigit().foregroundStyle(t.inkStrong)
                    .lineLimit(1).minimumScaleFactor(0.5)
            }
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        }
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
    @State private var heatNowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    @State private var heatTZ: TimeZone = .current
    @Environment(\.colorScheme) private var scheme

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        let t = WarmTheme(scheme: scheme)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: columns, spacing: 10) {
                    MetricCard(symbol: "infinity", colors: Candy.amber, title: "总token", value: TokenFormat.compact(lifetime))
                    MetricCard(symbol: "bolt.fill", colors: Candy.amber, title: "今日token", value: TokenFormat.compact(todayTokens))
                    MetricCard(symbol: "bubble.left.and.bubble.right.fill", colors: Candy.sky, title: "今日会话", value: PRTabFormat.cappedCount(todaySessions))
                    MetricCard(symbol: "wrench.and.screwdriver.fill", colors: Candy.teal, title: "今日工具", value: PRTabFormat.cappedCount(todayTools))
                    MetricCard(symbol: "star.fill", colors: Candy.xp, title: "当前等级", value: "Lv \(level)")
                    MetricCard(symbol: "flame.fill", colors: Candy.coral, title: "活跃天数", value: "\(streak)")
                    MetricCard(symbol: "chart.line.uptrend.xyaxis", colors: Candy.violet, title: "单日峰值token", value: TokenFormat.compact(peak))
                    MetricCard(symbol: "birthday.cake.fill", colors: Candy.rose, title: "宠物年龄(天)", value: "\(ageDays)")
                }

                Text("贡献热力图").font(WFont.section).foregroundStyle(t.ink)
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
