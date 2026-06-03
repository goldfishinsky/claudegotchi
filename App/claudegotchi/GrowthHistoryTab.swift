import SwiftUI
import GRDB
import PetCore

struct GrowthHistoryTab: View {
    let db: DatabaseQueue

    @State private var alive: Pet?
    @State private var history: [GrowthEntry] = []
    @State private var showAll = false

    private let inlineCap = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            currentStageSection
            Divider()
            memorialSection
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .claudegotchiPetDidChange)) { _ in
            DispatchQueue.main.async { reload() }
        }
    }

    @ViewBuilder
    private var currentStageSection: some View {
        if let pet = alive {
            let def = PixelSpeciesCatalog.def(pet.species)
            let stageId = PixelSpeciesCatalog.stage(id: pet.species, xp: pet.xp)
            let nextMinXp = def?.stages
                .first { Int64($0.minXp) > pet.xp }
                .map { Int64($0.minXp) }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(def?.nameZh ?? pet.species).font(.headline)
                    Text("· \(stageId)").font(.subheadline).foregroundColor(.secondary)
                    Spacer()
                    Text("XP \(TokenFormat.compactXP(pet.xp))").font(.caption).foregroundColor(.secondary)
                }
                if let next = nextMinXp, next > pet.xp {
                    ProgressView(value: Double(pet.xp), total: Double(next))
                    Text("距下一阶段 \(TokenFormat.compactXP(next - pet.xp))")
                        .font(.caption2).foregroundColor(.secondary)
                } else {
                    Text("已达最终阶段").font(.caption).foregroundColor(.secondary)
                }
            }
        } else {
            Text("暂无存活宠物").font(.subheadline).foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var memorialSection: some View {
        Text("成长史").font(.caption.bold()).foregroundColor(.secondary)
        if history.isEmpty {
            Text("还没有逝去的宠物").font(.caption).foregroundColor(.secondary)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(visibleHistory.indices, id: \.self) { i in entryRow(visibleHistory[i]) }
                    if history.count > inlineCap {
                        Button(showAll ? "收起" : "查看全部 (\(history.count))") { showAll.toggle() }
                            .buttonStyle(.link).font(.caption)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 160)
        }
    }

    private var visibleHistory: [GrowthEntry] {
        showAll ? history : Array(history.prefix(inlineCap))
    }

    @ViewBuilder
    private func entryRow(_ e: GrowthEntry) -> some View {
        let label = PixelSpeciesCatalog.def(e.species)?.nameZh ?? e.species
        HStack(spacing: 8) {
            Text(label).lineLimit(1).truncationMode(.middle)
            if let name = e.name, !name.isEmpty {
                Text("「\(name)」").font(.caption).foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer()
            Text(Self.dateLabel(e.bornMs) + (e.diedMs.map { " – " + Self.dateLabel($0) } ?? " – 在世"))
                .font(.caption2).foregroundColor(.secondary)
            Text("XP \(TokenFormat.compactXP(e.xp))").font(.caption2.monospacedDigit()).foregroundColor(.secondary)
        }
    }

    static func dateLabel(_ ms: Int64) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    private func reload() {
        alive = (try? Pet.fetchAlive(from: db)) ?? nil
        history = (try? StatsQueries.growthHistory(db, limit: inlineCap)) ?? []
    }
}
