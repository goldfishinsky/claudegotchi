import SwiftUI
import GRDB
import PetCore

struct HeatmapView: View {
    let db: DatabaseQueue
    let weeks: Int
    let nowMs: Int64
    let tz: TimeZone

    private let cell: CGFloat = 9
    private let gap: CGFloat = 2
    private let gutter: CGFloat = 28

    @State private var tokensByDay: [String: Int64] = [:]
    @State private var maxTokens: Int64 = 0
    @Environment(\.colorScheme) private var scheme

    private var gridWidth: CGFloat {
        CGFloat(weeks) * cell + CGFloat(max(0, weeks - 1)) * gap
    }

    var body: some View {
        GeometryReader { geo in
            let available = geo.size.width - gutter
            if gridWidth <= available {
                HStack(alignment: .top, spacing: 6) { weekdayGutter; gridBody }
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(alignment: .top, spacing: 6) { weekdayGutter; gridBody }
                }
            }
        }
        .frame(height: cell * 7 + gap * 6 + 4)
        .onAppear(perform: reload)
        .onChange(of: nowMs) { _ in reload() }
        .onChange(of: tz) { _ in reload() }
    }

    private var weekdayGutter: some View {
        let t = WarmTheme(scheme: scheme)
        return VStack(spacing: gap) {
            ForEach(0..<7, id: \.self) { row in
                Text(["日","一","二","三","四","五","六"][row])
                    .font(.system(size: 6, design: .rounded)).foregroundStyle(t.inkFaint)
                    .frame(width: gutter - 4, height: cell, alignment: .trailing)
            }
        }
    }

    private var gridBody: some View {
        HStack(alignment: .top, spacing: gap) {
            ForEach(0..<weeks, id: \.self) { col in
                VStack(spacing: gap) {
                    ForEach(0..<7, id: \.self) { row in
                        cellView(weekFromEnd: col, weekday: row)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cellView(weekFromEnd col: Int, weekday row: Int) -> some View {
        let key = dayKey(weekFromEnd: col, weekday: row)
        let tokens = tokensByDay[key] ?? 0
        RoundedRectangle(cornerRadius: 2)
            .fill(color(for: tokens))
            .frame(width: cell, height: cell)
            .help("\(key) · \(TokenFormat.compact(tokens)) tok")
    }

    private func dayKey(weekFromEnd col: Int, weekday row: Int) -> String {
        let todayWeekday = weekdayIndex(nowMs)
        let daysBack = (weeks - 1 - col) * 7 + (todayWeekday - row)
        let ms = nowMs - Int64(daysBack) * 86_400_000
        return LocalDay.key(unixMs: ms, timeZone: tz)
    }

    private func weekdayIndex(_ ms: Int64) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        return cal.component(.weekday, from: date) - 1
    }

    // Warm single-hue ramp: faint cream (empty) → light amber → saturated coral.
    private func color(for tokens: Int64) -> Color {
        let empty = scheme == .dark ? rgb(0.25, 0.22, 0.19) : rgb(0.92, 0.88, 0.82)
        guard tokens > 0, maxTokens > 0 else { return empty }
        let q = Double(tokens) / Double(maxTokens)
        switch q {
        case ..<0.25: return rgb(1.0, 0.86, 0.58)
        case ..<0.50: return rgb(1.0, 0.74, 0.42)
        case ..<0.75: return rgb(1.0, 0.58, 0.34)
        default:      return rgb(0.98, 0.42, 0.34)
        }
    }

    private func reload() {
        let rows = (try? StatsQueries.heatmapSeries(db, weeks: weeks, nowMs: nowMs, tz: tz)) ?? []
        var map: [String: Int64] = [:]
        var mx: Int64 = 0
        for r in rows { map[r.day] = r.tokens; mx = max(mx, r.tokens) }
        tokensByDay = map
        maxTokens = mx
    }
}
