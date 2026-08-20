import SwiftUI
import AppKit
import PetCore

// Pet-focused top of the dropdown card: identity strip, hero pixel pet on a warm
// halo (keeps the SystemMood overlay + animationSpeed wiring), vitals bars, XP
// progress and one compact, decision-relevant daily usage figure.
struct PetSection: View {
    @ObservedObject var petModel: PetPanelModel
    @ObservedObject var driver: SystemStatsDriver
    let theme: WarmTheme

    private let heroWidth: CGFloat = 184
    private let heroHeight: CGFloat = 158

    var body: some View {
        VStack(spacing: 10) {
            topStrip
            if petModel.hasPet {
                heroRow
            } else {
                eggHero
            }
        }
    }

    private var heroRow: some View {
        HStack(alignment: .center, spacing: 12) {
            hero.frame(width: heroWidth)
            VStack(spacing: 10) {
                vitalRow(Candy.full, "饱食", petModel.fullness)
                vitalRow(Candy.stam, "体力", petModel.stamina)
                vitalRow(Candy.inti, "亲密", petModel.intimacy)
                xpRow
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: identity strip

    private var topStrip: some View {
        let nameZh = PixelSpeciesCatalog.def(petModel.species)?.nameZh ?? petModel.species
        return HStack(spacing: 6) {
            Text(nameZh).lineLimit(1).truncationMode(.tail)
            Text("·").opacity(0.45)
            Text("Lv \(petModel.level)").monospacedDigit()
            Spacer(minLength: 6)
            if petModel.todayTokens > 0 {
                Text("今日 \(TokenFormat.compact(petModel.todayTokens)) tokens")
                    .monospacedDigit()
            }
            if petModel.isAgentWorking {
                HStack(spacing: 4) {
                    ForEach(petModel.activePlatforms, id: \.self) { platform in
                        platformMark(platform)
                    }
                }
                .transition(.scale.combined(with: .opacity))
            } else {
                Circle().fill(statusColor).frame(width: 5, height: 5)
                Text(statusLabel)
            }
        }
        .font(WFont.strip)
        .foregroundStyle(theme.inkFaint)
        .padding(.horizontal, 2)
    }

    private var statusLabel: String {
        let a = petModel.activity
        if a.contains("休眠") { return "休眠" }
        return "空闲"
    }

    private var statusColor: Color {
        let a = petModel.activity
        if a.contains("休眠") { return rgb(0.52, 0.55, 0.90) }
        return theme.ink.opacity(0.45)
    }

    // MARK: hero pet on warm halo

    private var hero: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(
                    colors: [theme.halo.opacity(theme.isDark ? 0.28 : 0.50), theme.halo.opacity(0)],
                    center: .center, startRadius: 2, endRadius: 88))
                .frame(width: 174, height: 174)
                .blur(radius: 5)
                .offset(y: -6)
            theaterStage
        }
        .frame(width: heroWidth, height: heroHeight)
    }

    private func platformMark(_ platform: String) -> some View {
        let codex = platform == ModelPlatform.codex
        let label = codex ? "Codex" : "Claude Code"
        let mark = codex
            ? theme.inkStrong
            : Color(red: 0.85, green: 0.39, blue: 0.27)
        return AgentBrandMark(platform: platform, color: mark)
            .frame(width: 20, height: 20)
            .accessibilityLabel("\(label) 正在工作")
            .help("\(label) 正在工作")
    }

    @ViewBuilder
    private var theaterStage: some View {
        if let visual = petModel.visual {
            let memHigh = (driver.snapshot?.memPressure ?? .normal) == .critical
            TheaterPetView(
                visual: visual, species: petModel.species,
                signals: petModel.makeSignals(memPressureHigh: memHigh),
                theme: theme, look: petModel.look,
                onPet: { petModel.handlePetClick() },
                onPetting: { petModel.handlePetting() },
                onScene: { scene, nowMs in petModel.observeTheater(scene, nowMs: nowMs) }
            )
            .frame(width: heroWidth, height: heroHeight)
        } else {
            Color.clear.frame(width: heroWidth, height: heroHeight)
        }
    }

    private var eggHero: some View {
        Text("🥚 孵化中…")
            .font(.system(size: 15, weight: .medium, design: .rounded))
            .foregroundStyle(theme.inkFaint)
            .frame(height: heroHeight)
            .frame(maxWidth: .infinity)
    }

    // MARK: vitals + xp + today + activity

    private func vitalRow(_ colors: [Color], _ label: String, _ value: Double) -> some View {
        let clamped = min(max(value, 0), 100)
        return HStack(spacing: 8) {
            Circle()
                .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
                .frame(width: 7, height: 7)
                .shadow(color: colors[colors.count - 1].opacity(0.5), radius: 2, x: 0, y: 1)
                .frame(width: 12, alignment: .center)
            Text(label).font(WFont.vLabel).foregroundStyle(theme.ink)
                .frame(width: 34, alignment: .leading)
            SoftBar(fraction: clamped / 100, colors: colors, track: theme.track)
            Text("\(Int(clamped))").font(WFont.vValue).monospacedDigit()
                .foregroundStyle(theme.inkStrong).frame(width: 26, alignment: .trailing)
        }
    }

    private var xpRow: some View {
        let base = Level.xpForLevel(petModel.level)
        let next = Level.xpForLevel(petModel.level + 1)
        let span = max(1, next - base)
        let frac = min(1, max(0, Double(span - petModel.xpToNext) / Double(span)))
        return HStack(spacing: 8) {
            CandyIcon(symbol: "star.fill", colors: Candy.xp, size: 11)
                .frame(width: 12, alignment: .center)
            Text("Lv \(petModel.level)").font(WFont.vLabel).monospacedDigit()
                .foregroundStyle(theme.ink).frame(width: 34, alignment: .leading).lineLimit(1)
            SoftBar(fraction: frac, colors: Candy.xp, track: theme.track)
            Text("还需 \(petModel.xpToNext)").font(WFont.caption).monospacedDigit()
                .foregroundStyle(theme.inkFaint).lineLimit(1).fixedSize()
        }
    }

}

/// Transparent, high-resolution product marks for the compact status strip.
struct AgentBrandMark: View {
    let platform: String
    let color: Color

    private var image: NSImage? {
        let name = platform == ModelPlatform.codex ? "CodexMark" : "ClaudeMark"
        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    @ViewBuilder
    var body: some View {
        if let image {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .foregroundStyle(color)
                .accessibilityHidden(true)
        } else {
            Color.clear
        }
    }
}
