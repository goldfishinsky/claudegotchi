import SwiftUI
import PetCore

struct PetPanelView: View {
    @ObservedObject var model: PetPanelModel
    private let lowThreshold = 25.0

    var body: some View {
        VStack(spacing: 12) {
            if model.hasPet {
                petArt
                statsCard
                infoCard
            } else {
                Text("🥚 孵化中…")
                    .font(.headline).foregroundStyle(.secondary)
                    .frame(height: 100)
            }
        }
    }

    @ViewBuilder
    private var petArt: some View {
        if let visual = model.visual {
            PixelPetView(visual: visual, species: model.species) {
                model.handlePetClick()
            }
            .frame(width: 84, height: 84)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.groupFill)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            Color.clear.frame(height: 84)
        }
    }

    private var statsCard: some View {
        GroupCard {
            statRow("🍞", model.fullness)
            RowDivider()
            statRow("💪", model.stamina)
            RowDivider()
            statRow("💖", model.intimacy)
        }
    }

    private func statRow(_ icon: String, _ value: Double) -> some View {
        let clamped = min(max(value, 0), 100)
        return HStack(spacing: 10) {
            Text(icon).font(.system(size: 13)).frame(width: 18, alignment: .leading)
            StatTrack(value: clamped, lowThreshold: lowThreshold)
            Text("\(Int(clamped))")
                .font(.callout.monospacedDigit())
                .foregroundColor(clamped < lowThreshold ? Theme.low : Color.secondary)
                .frame(width: 30, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private var infoCard: some View {
        GroupCard {
            levelRow
            RowDivider()
            todayRow
            RowDivider()
            activityRow
        }
    }

    private var levelRow: some View {
        let nameZh = PixelSpeciesCatalog.def(model.species)?.nameZh ?? model.species
        return HStack(spacing: 8) {
            Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.yellow)
            Text("Lv \(model.level)").font(.callout.weight(.semibold))
            Text(nameZh).font(.callout).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            Text("还需 \(model.xpToNext) xp").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private var todayRow: some View {
        let tok = PRTabFormat.tokenLabel(Int(model.todayTokens))
        return HStack(spacing: 0) {
            todayMetric(tok.isEmpty ? "0" : tok, "今日")
            Spacer()
            todayMetric(PRTabFormat.cappedCount(model.todaySessions), "会话")
            Spacer()
            todayMetric(PRTabFormat.cappedCount(model.todayTools), "工具")
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    private func todayMetric(_ value: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(value).font(.callout.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var activityRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.activity.contains("正在") ? Theme.healthy : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
            Text(model.activity).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }
}
