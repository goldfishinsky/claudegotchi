import SwiftUI
import GRDB
import PetCore

struct ModelsTab: View {
    let db: DatabaseQueue

    @State private var rows: [ModelUsage] = []
    @State private var showAll = false

    private let inlineCap = 20

    private var totalTokens: Int64 {
        rows.reduce(0) { $0 + $1.tokensIn + $1.tokensOut }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("模型用量").font(.headline)
                Spacer()
                Text("累计(lifetime)").font(.caption).foregroundColor(.secondary)
            }

            if rows.isEmpty {
                Text("暂无模型数据").font(.subheadline).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 24)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(visibleRows, id: \.model) { row in modelRow(row) }
                        if rows.count > inlineCap {
                            Button(showAll ? "收起" : "查看全部 (\(rows.count))") { showAll.toggle() }
                                .buttonStyle(.link).font(.caption)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 360)
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
    private func modelRow(_ row: ModelUsage) -> some View {
        let tokens = row.tokensIn + row.tokensOut
        let share = totalTokens > 0 ? Double(tokens) / Double(totalTokens) * 100 : 0
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(row.model).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(TokenFormat.compact(tokens) + " tok")
                    .font(.caption.monospacedDigit()).foregroundColor(.secondary)
            }
            HStack(spacing: 8) {
                Text("\(PRTabFormat.cappedCount(Int(min(row.calls, Int64(Int.max))))) 次调用")
                    .font(.caption2).foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.1f%%", share))
                    .font(.caption2.monospacedDigit()).foregroundColor(.secondary)
            }
        }
    }

    private func reload() {
        rows = (try? StatsQueries.modelUsage(db)) ?? []
    }
}
