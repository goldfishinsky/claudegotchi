import SwiftUI
import PetCore

// Pet-focused top of the dropdown card: identity strip, hero pixel pet on a warm
// halo (keeps the SystemMood overlay + animationSpeed wiring), vitals bars, XP
// progress, today's numbers, and the current activity line.
struct PetSection: View {
    @ObservedObject var petModel: PetPanelModel
    @ObservedObject var driver: SystemStatsDriver
    let theme: WarmTheme

    var body: some View {
        VStack(spacing: 10) {
            topStrip
            if petModel.hasPet {
                heroRow
                todayRow
                activityRow
            } else {
                eggHero
            }
        }
    }

    private var heroRow: some View {
        HStack(alignment: .center, spacing: 16) {
            hero.frame(width: 120)
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
            Circle().fill(statusColor).frame(width: 5, height: 5)
            Text(statusLabel)
        }
        .font(WFont.strip)
        .foregroundStyle(theme.inkFaint)
        .padding(.horizontal, 2)
    }

    private var statusLabel: String {
        let a = petModel.activity
        if a.contains("休眠") { return "休眠" }
        if a.contains("正在") { return "工作" }
        return "空闲"
    }

    private var statusColor: Color {
        let a = petModel.activity
        if a.contains("休眠") { return rgb(0.52, 0.55, 0.90) }
        if a.contains("正在") { return rgb(1.0, 0.62, 0.30) }
        return theme.ink.opacity(0.45)
    }

    // MARK: hero pet on warm halo

    private var hero: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(
                    colors: [theme.halo.opacity(theme.isDark ? 0.28 : 0.50), theme.halo.opacity(0)],
                    center: .center, startRadius: 2, endRadius: 58))
                .frame(width: 112, height: 112)
                .blur(radius: 4)
                .offset(y: -4)
            theaterStage
        }
        .frame(width: 120, height: 90)
    }

    @ViewBuilder
    private var theaterStage: some View {
        if let visual = petModel.visual {
            let memHigh = (driver.snapshot?.memPressure ?? .normal) == .critical
            TheaterPetView(
                visual: visual, species: petModel.species,
                signals: petModel.makeSignals(memPressureHigh: memHigh),
                theme: theme
            ) {
                petModel.handlePetClick()
            }
            .frame(width: 120, height: 90)
        } else {
            Color.clear.frame(width: 120, height: 90)
        }
    }

    private var eggHero: some View {
        Text("🥚 孵化中…")
            .font(.system(size: 15, weight: .medium, design: .rounded))
            .foregroundStyle(theme.inkFaint)
            .frame(height: 92)
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

    private var todayRow: some View {
        HStack(spacing: 0) {
            todayMetric(TokenFormat.compact(petModel.todayTokens), "今日")
            Spacer(minLength: 0)
            todayMetric(WorkPanelFormat.cappedCount(petModel.todaySessions), "会话")
            Spacer(minLength: 0)
            todayMetric(WorkPanelFormat.cappedCount(petModel.todayTools), "工具")
        }
        .padding(.top, 1)
    }

    private func todayMetric(_ value: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(value).font(WFont.vValue).monospacedDigit().foregroundStyle(theme.inkStrong)
            Text(label).font(WFont.caption).foregroundStyle(theme.ink)
        }
    }

    private var activityRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(petModel.activity.contains("正在") ? rgb(0.46, 0.85, 0.45) : theme.ink.opacity(0.4))
                .frame(width: 6, height: 6)
            Text(petModel.activity).font(WFont.caption).foregroundStyle(theme.ink)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }
}
