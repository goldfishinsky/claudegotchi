import SwiftUI
import PetCore

struct PetPanelView: View {
    @ObservedObject var model: PetPanelModel

    private let lowThreshold: Double = 25
    private let panelWidth: CGFloat = 276

    init(model: PetPanelModel) {
        self.model = model
    }

    var body: some View {
        VStack(spacing: 8) {
            if model.hasPet {
                petArt
                statBars
                levelLine
                todayRow
                activityLine
            } else {
                Text("🥚 孵化中…")
                    .font(.headline)
                    .frame(height: 96)
            }
        }
        .frame(width: panelWidth)
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var petArt: some View {
        if let visual = model.visual {
            PixelPetView(visual: visual, species: model.species) {
                model.handlePetClick()
            }
            .frame(width: 96, height: 96)
        } else {
            Color.clear.frame(width: 96, height: 96)
        }
    }

    private var statBars: some View {
        VStack(spacing: 4) {
            statBar(icon: "🍞", label: "饱食", value: model.fullness)
            statBar(icon: "💪", label: "体力", value: model.stamina)
            statBar(icon: "💖", label: "亲密", value: model.intimacy)
            wisdomBar
        }
    }

    private func statBar(icon: String, label: String, value: Double) -> some View {
        let clamped = min(max(value, 0), 100)
        let tint: Color = clamped < lowThreshold ? .red : .green
        return HStack(spacing: 6) {
            Text(icon).font(.caption)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule().fill(tint)
                        .frame(width: geo.size.width * CGFloat(clamped / 100))
                }
            }
            .frame(height: 8)
            Text("\(Int(clamped))")
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 28, alignment: .trailing)
        }
    }

    private var wisdomBar: some View {
        HStack(spacing: 6) {
            Text("🌟").font(.caption)
            Text("Lv \(model.level)").font(.caption.bold())
            Spacer()
            Text("还需 \(model.xpToNext) xp")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var levelLine: some View {
        let nameZh = PixelSpeciesCatalog.def(model.species)?.nameZh ?? model.species
        return Text("Lv \(model.level) · \(nameZh)")
            .font(.caption)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var todayRow: some View {
        let tok = PRTabFormat.tokenLabel(Int(model.todayTokens))
        return HStack(spacing: 6) {
            Text("今日 \(tok.isEmpty ? "0" : tok)")
            Text("·")
            Text("会话 \(PRTabFormat.cappedCount(model.todaySessions))")
            Text("·")
            Text("工具 \(PRTabFormat.cappedCount(model.todayTools))")
        }
        .font(.caption2)
        .foregroundColor(.secondary)
        .lineLimit(1)
    }

    private var activityLine: some View {
        Text(model.activity)
            .font(.caption)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
