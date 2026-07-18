import SwiftUI
import GRDB
import PetCore

struct ModelsTab: View {
    let db: DatabaseQueue

    @State private var rows: [ModelUsage] = []
    @State private var showAll = false
    @Environment(\.colorScheme) private var scheme

    private let inlineCap = 20

    private var totalTokens: Int64 {
        rows.reduce(0) { $0 + $1.tokensIn + $1.tokensOut }
    }

    var body: some View {
        let t = WarmTheme(scheme: scheme)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("模型用量").font(WFont.title).foregroundStyle(t.inkStrong)
                Spacer()
                Text("累计(lifetime)").font(WFont.section).foregroundStyle(t.inkFaint)
            }

            if rows.isEmpty {
                Text("暂无模型数据").font(WFont.body).foregroundStyle(t.inkFaint)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 24)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(visibleRows, id: \.model) { row in modelRow(row, t) }
                        if rows.count > inlineCap {
                            Button(showAll ? "收起" : "查看全部 (\(rows.count))") { showAll.toggle() }
                                .buttonStyle(.plain)
                                .font(WFont.section).foregroundStyle(t.accent)
                                .padding(.top, 2)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 380)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .claudegotchiPetDidChange)) { _ in
            DispatchQueue.main.async { reload() }
        }
    }

    private var visibleRows: [ModelUsage] {
        showAll ? rows : Array(rows.prefix(inlineCap))
    }

    @ViewBuilder
    private func modelRow(_ row: ModelUsage, _ t: WarmTheme) -> some View {
        let tokens = row.tokensIn + row.tokensOut
        let frac = totalTokens > 0 ? Double(tokens) / Double(totalTokens) : 0
        SoftCard(fill: t.cardFill, cornerRadius: 14, padding: 11, shadow: t.cardShadow) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(row.model).font(WFont.label).foregroundStyle(t.inkStrong)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(TokenFormat.compact(tokens) + " tok")
                        .font(WFont.value).monospacedDigit().foregroundStyle(t.ink)
                }
                SoftBar(fraction: frac, colors: Candy.amber, track: t.track)
                HStack(spacing: 8) {
                    Text("\(PRTabFormat.cappedCount(Int(min(row.calls, Int64(Int.max))))) 次调用")
                        .font(WFont.caption).foregroundStyle(t.inkFaint)
                    Spacer()
                    Text(String(format: "%.1f%%", frac * 100))
                        .font(WFont.caption).monospacedDigit().foregroundStyle(t.inkFaint)
                }
            }
        }
    }

    private func reload() {
        rows = (try? StatsQueries.modelUsage(db)) ?? []
    }
}
