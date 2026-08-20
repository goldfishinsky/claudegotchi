import SwiftUI
import GRDB
import PetCore

struct GrowthHistoryTab: View {
    let db: DatabaseQueue

    @State private var alive: Pet?
    @State private var history: [GrowthEntry] = []
    @State private var showAll = false
    @Environment(\.colorScheme) private var scheme

    private let inlineCap = 20
    private let fetchCap = 500

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            currentStageSection
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
        let t = WarmTheme(scheme: scheme)
        if let pet = alive {
            let def = PixelSpeciesCatalog.def(pet.species)
            let milestone = GrowthJourney.current(xp: pet.xp)
            let next = GrowthJourney.next(xp: pet.xp)
            let level = Level.compute(xp: pet.xp)
            SoftCard(fill: t.cardFill, cornerRadius: 16, padding: 14, shadow: t.cardShadow) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        CandyIcon(symbol: "sparkles", colors: Candy.xp, size: 14)
                        Text(def?.nameZh ?? pet.species).font(WFont.title).foregroundStyle(t.inkStrong)
                            .lineLimit(1).truncationMode(.tail)
                        Text("· \(milestone.nameZh)").font(WFont.section).foregroundStyle(t.ink)
                            .lineLimit(1).truncationMode(.tail)
                        Spacer()
                        Text("Lv \(level) · XP \(TokenFormat.compactXP(pet.xp))")
                            .font(WFont.value).monospacedDigit().foregroundStyle(t.ink)
                    }
                    if let next {
                        SoftBar(fraction: GrowthJourney.progress(xp: pet.xp), colors: Candy.xp, track: t.track, height: 8)
                        Text("距「\(next.nameZh)」还需 \(TokenFormat.compactXP(next.minXp - pet.xp)) XP")
                            .font(WFont.caption).monospacedDigit().foregroundStyle(t.inkFaint)
                    } else {
                        Text("已达终极里程碑，等级仍会继续提升")
                            .font(WFont.caption).foregroundStyle(t.inkFaint)
                    }
                }
            }
        } else {
            SoftCard(fill: t.cardFill, cornerRadius: 16, padding: 14, shadow: t.cardShadow, alignment: .center) {
                Text("暂无存活宠物").font(WFont.body).foregroundStyle(t.inkFaint)
            }
        }
    }

    @ViewBuilder
    private var memorialSection: some View {
        let t = WarmTheme(scheme: scheme)
        Text("成长史").font(WFont.section).foregroundStyle(t.ink)
        if history.isEmpty {
            Text("还没有逝去的宠物").font(WFont.body).foregroundStyle(t.inkFaint)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(visibleHistory.indices, id: \.self) { i in entryRow(visibleHistory[i], t) }
                    if history.count > inlineCap {
                        Button(showAll ? "收起" : "查看全部 (\(history.count))") { showAll.toggle() }
                            .buttonStyle(.plain).font(WFont.section).foregroundStyle(t.accent).padding(.top, 2)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 260)
        }
    }

    private var visibleHistory: [GrowthEntry] {
        showAll ? history : Array(history.prefix(inlineCap))
    }

    @ViewBuilder
    private func entryRow(_ e: GrowthEntry, _ t: WarmTheme) -> some View {
        let label = PixelSpeciesCatalog.def(e.species)?.nameZh ?? e.species
        SoftCard(fill: t.cardFill, cornerRadius: 12, padding: 10, shadow: t.cardShadow) {
            HStack(spacing: 8) {
                Text(label).font(WFont.label).foregroundStyle(t.inkStrong)
                    .lineLimit(1).truncationMode(.middle)
                if let name = e.name, !name.isEmpty {
                    Text("「\(name)」").font(WFont.caption).foregroundStyle(t.ink)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer()
                Text(Self.dateLabel(e.bornMs) + (e.diedMs.map { " – " + Self.dateLabel($0) } ?? " – 在世"))
                    .font(WFont.caption).monospacedDigit().foregroundStyle(t.inkFaint)
                Text("XP \(TokenFormat.compactXP(e.xp))")
                    .font(WFont.caption).monospacedDigit().foregroundStyle(t.inkFaint)
            }
        }
    }

    static func dateLabel(_ ms: Int64) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    private func reload() {
        alive = (try? Pet.fetchAlive(from: db)) ?? nil
        history = (try? StatsQueries.growthHistory(db, limit: fetchCap)) ?? []
    }
}
