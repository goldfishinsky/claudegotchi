import SwiftUI
import AppKit
import PetCore

// The dreamy "cream card + warm backlit glow" that IS the menu-bar dropdown.
// Two soft panels — a fixed-height system glance (CPU + MEM tiles above a compact
// tray, one tap opens the stats window's 系统 tab) and an agent panel (active-agent
// rows + folded usage footer) — crowned by the pet stage and closed by the footer
// actions. Rendered inside a borderless NSPanel by MenuDropdownController; the
// transparent glow margin lets the glow spill past the card edge.
struct DropdownCard: View {
    @ObservedObject var petModel: PetPanelModel
    @ObservedObject var agentModel: AgentActivityModel
    @ObservedObject var driver: SystemStatsDriver
    @ObservedObject var usageDriver: ClaudeUsageDriver
    var onOpenStats: () -> Void
    var onOpenSystemStats: () -> Void = {}
    var onOpenSettings: () -> Void
    var onJump: (AgentActivity) -> Void
    var onHeightChange: (CGFloat) -> Void = { _ in }

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var systemHovering = ProcessInfo.processInfo.environment["CGHOVER"] == "1"

    enum Metric { case cpu, mem }

    static let cardWidth: CGFloat = 400
    static let glowMargin: CGFloat = 30
    static let totalWidth: CGFloat = cardWidth + glowMargin * 2
    static let tileHeight: CGFloat = 50

    private var theme: WarmTheme { WarmTheme(scheme: scheme) }

    var body: some View {
        let t = theme
        return VStack(spacing: 12) {
            PetSection(petModel: petModel, driver: driver, theme: t)
            systemPanel(t)
            agentPanel(t)
            footer(t)
        }
        .padding(16)
        .frame(width: Self.cardWidth)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(LinearGradient(colors: [t.surfaceTop, t.surfaceBottom],
                                     startPoint: .top, endPoint: .bottom))
        )
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: t.glow.opacity(t.glowOpacity), radius: 24, x: 0, y: 8)
        .shadow(color: t.glow.opacity(t.glowOpacity * 0.7), radius: 11, x: 0, y: 3)
        .shadow(color: Color.black.opacity(t.isDark ? 0.34 : 0.10), radius: 7, x: 0, y: 4)
        .padding(Self.glowMargin)
        .frame(width: Self.totalWidth)
        .background(heightReporter)
    }

    // Reports the rendered card height (incl. glow margin) so the controller can
    // regrow the panel as a tile expands, keeping the card's top edge pinned.
    private var heightReporter: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { onHeightChange(proxy.size.height) }
                .onChange(of: proxy.size.height) { onHeightChange($0) }
        }
    }

    private func hDivider(_ t: WarmTheme) -> some View {
        RoundedRectangle(cornerRadius: 0.5, style: .continuous)
            .fill(t.ink.opacity(0.10))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }

    // MARK: system panel

    private func systemPanel(_ t: WarmTheme) -> some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                heroTile(t, .cpu)
                heroTile(t, .mem)
            }
            hDivider(t)
            trayRow(t)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(systemHovering ? t.ink.opacity(0.07) : t.panelFill))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture { onOpenSystemStats() }
        .onHover { hovering in
            systemHovering = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .help("打开系统详情")
    }

    private func heroTile(_ t: WarmTheme, _ metric: Metric) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            heroHeader(t, metric)
            heroLevel(t, metric)
            Sparkline(values: history(metric), colors: sparkColors(metric), height: 13)
        }
        .frame(maxWidth: .infinity, minHeight: Self.tileHeight, maxHeight: Self.tileHeight,
               alignment: .topLeading)
    }

    private func heroHeader(_ t: WarmTheme, _ metric: Metric) -> some View {
        HStack(spacing: 6) {
            CandyIcon(symbol: symbol(metric), colors: iconColors(metric), size: 13)
            Text(valueText(metric)).font(WFont.value).monospacedDigit()
                .foregroundStyle(valueColor(t, metric))
                .contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.7)
            PulseDot(colors: dotColors(metric), elevated: elevated(metric), reduceMotion: reduceMotion)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func heroLevel(_ t: WarmTheme, _ metric: Metric) -> some View {
        switch metric {
        case .cpu:
            let cores = driver.perCoreUsage
            if cores.isEmpty {
                Color.clear.frame(height: 9)
            } else {
                CoreBar(cores: cores,
                        colors: (driver.snapshot?.cpuUsage ?? 0) >= 0.8 ? Candy.cpuHot : Candy.cpu,
                        track: t.track)
            }
        case .mem:
            SoftBar(fraction: memFraction() ?? 0, colors: memBarColors(), track: t.track, height: 9)
        }
    }

    private func trayRow(_ t: WarmTheme) -> some View {
        let s = driver.snapshot
        return HStack(spacing: 0) {
            if let bat = s?.battery {
                trayItem(t, batterySymbol(bat.percent), Candy.battery, "\(min(100, max(0, bat.percent)))%")
                Spacer(minLength: 0)
            }
            trayItem(t, "arrow.down.circle.fill", Candy.netDown, speedText(s?.downBytesPerSec))
            Spacer(minLength: 0)
            trayItem(t, "arrow.up.circle.fill", Candy.netUp, speedText(s?.upBytesPerSec))
            Spacer(minLength: 0)
            trayItem(t, "internaldrive.fill", Candy.disk, s.map { ByteFormat.size($0.diskFreeBytes) } ?? "—")
        }
    }

    private func trayItem(_ t: WarmTheme, _ symbol: String, _ colors: [Color], _ value: String) -> some View {
        HStack(spacing: 5) {
            CandyIcon(symbol: symbol, colors: colors, size: 12)
            Text(value).font(WFont.vValue).monospacedDigit()
                .foregroundStyle(t.inkStrong)
                .contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    // MARK: agent + usage panel

    private func agentPanel(_ t: WarmTheme) -> some View {
        SoftPanel(fill: t.panelFill) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    CandyIcon(symbol: "cpu.fill", colors: Candy.violet, size: 14)
                        .frame(width: 18, alignment: .center)
                    Text("活跃 Agent").font(WFont.label).foregroundStyle(t.ink)
                    Spacer(minLength: 4)
                    if !agentModel.agents.isEmpty {
                        Text("\(WorkPanelFormat.cappedCount(agentModel.agents.count)) 个")
                            .font(WFont.caption).foregroundStyle(t.inkFaint)
                    }
                }
                agentContent(t)
                if usageDriver.usage != nil {
                    hDivider(t)
                    usageFooter(t)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func agentContent(_ t: WarmTheme) -> some View {
        if agentModel.agents.isEmpty {
            Text("没有活跃的 agent").font(WFont.caption).foregroundStyle(t.inkFaint)
        } else {
            let agents = agentModel.agents
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(agents.prefix(WorkPanelFormat.rowCap)), id: \.sessionId) { agent in
                    AgentRowView(theme: t, agent: agent, onJump: onJump)
                }
                if agents.count > WorkPanelFormat.rowCap {
                    Text("… 还有 \(WorkPanelFormat.cappedCount(agents.count - WorkPanelFormat.rowCap)) 个")
                        .font(WFont.caption).foregroundStyle(t.inkFaint)
                }
            }
        }
    }

    @ViewBuilder
    private func usageFooter(_ t: WarmTheme) -> some View {
        if let u = usageDriver.usage {
            HStack(spacing: 14) {
                CandyIcon(symbol: "speedometer", colors: Candy.amber, size: 13)
                    .frame(width: 16)
                usageSeg(t, "5h", u.fiveHourPct)
                usageSeg(t, "周", u.weeklyPct)
            }
        }
    }

    private func usageSeg(_ t: WarmTheme, _ label: String, _ pct: Double) -> some View {
        let clamped = min(100, max(0, pct))
        return HStack(spacing: 7) {
            Text(label).font(WFont.caption).foregroundStyle(t.ink)
                .frame(width: 16, alignment: .leading)
            SoftBar(fraction: clamped / 100, colors: usageColors(clamped), track: t.track, height: 5)
            Text("\(Int(clamped.rounded()))%").font(WFont.vValue).monospacedDigit()
                .foregroundStyle(t.inkStrong)
                .contentTransition(.numericText())
                .frame(width: 34, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
    }

    private func usageColors(_ pct: Double) -> [Color] {
        if pct >= 80 { return Candy.coral }
        if pct >= 50 { return Candy.memElevated }
        return Candy.amber
    }

    // MARK: footer actions

    private func footer(_ t: WarmTheme) -> some View {
        HStack(spacing: 10) {
            Button(action: onOpenStats) {
                Text("打开统计").font(WFont.label.weight(.semibold)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(rgb(1.0, 0.62, 0.34))

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(t.ink)
                    .frame(width: 30, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(t.panelFill)
                    )
            }
            .buttonStyle(.plain)
            .help("设置")
        }
    }

    // MARK: metric helpers

    private func symbol(_ m: Metric) -> String { m == .cpu ? "cpu.fill" : "memorychip.fill" }

    private func iconColors(_ m: Metric) -> [Color] {
        switch m {
        case .cpu: return (driver.snapshot?.cpuUsage ?? 0) >= 0.8 ? Candy.cpuHot : Candy.cpu
        case .mem: return Candy.memory
        }
    }

    private func valueText(_ m: Metric) -> String {
        m == .cpu ? pctText(driver.snapshot.map(\.cpuUsage)) : pctText(memFraction())
    }

    private func valueColor(_ t: WarmTheme, _ m: Metric) -> Color {
        m == .cpu ? t.inkStrong : memTierInk(t, driver.snapshot?.memPressure ?? .normal)
    }

    private func elevated(_ m: Metric) -> Bool {
        m == .cpu ? driver.thermal.isElevated : (driver.snapshot?.memPressure ?? .normal) != .normal
    }

    private func dotColors(_ m: Metric) -> [Color] {
        if m == .cpu { return Candy.cpuHot }
        return (driver.snapshot?.memPressure ?? .normal) == .critical ? Candy.memCritical : Candy.memElevated
    }

    private func history(_ m: Metric) -> [Double] { m == .cpu ? driver.cpuHistory : driver.memHistory }

    private func sparkColors(_ m: Metric) -> [Color] { m == .cpu ? Candy.cpu : Candy.memory }

    private func memBarColors() -> [Color] {
        switch driver.snapshot?.memPressure ?? .normal {
        case .normal: return Candy.memNormal
        case .elevated: return Candy.memElevated
        case .critical: return Candy.memCritical
        }
    }

    private func memFraction() -> Double? {
        guard let s = driver.snapshot, s.memTotalBytes > 0 else { return nil }
        return Double(s.memUsedBytes) / Double(s.memTotalBytes)
    }

    private func pctText(_ frac: Double?) -> String {
        guard let frac else { return "—" }
        return "\(min(100, max(0, Int((frac * 100).rounded()))))%"
    }

    private func speedText(_ bps: Double?) -> String {
        guard let bps else { return "—" }
        return ByteFormat.speed(bps)
    }

    private func memTierInk(_ t: WarmTheme, _ tier: MemPressureTier) -> Color {
        switch tier {
        case .normal: return t.good
        case .elevated: return rgb(1.0, 0.60, 0.28)
        case .critical: return t.danger
        }
    }

    private func batterySymbol(_ pct: Int) -> String {
        switch pct {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }
}

// A state dot that always reserves its 5pt frame (no data-driven layout shift):
// it fades opacity in when its metric crosses into an elevated tier and fires one
// scale+opacity pulse on that crossing — suppressed under Reduce Motion.
private struct PulseDot: View {
    let colors: [Color]
    let elevated: Bool
    let reduceMotion: Bool
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            .frame(width: 5, height: 5)
            .shadow(color: colors[colors.count - 1].opacity(0.7), radius: 2)
            .scaleEffect(pulse ? 1.9 : 1.0)
            .opacity(elevated ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: elevated)
            .onChange(of: elevated) { now in
                guard now, !reduceMotion else { return }
                withAnimation(.easeOut(duration: 0.15)) { pulse = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.5)) { pulse = false }
                }
            }
    }
}

// A whole active-agent row is the jump target: hovering warms the row and reveals
// the ↗; a click jumps to that session's host terminal (SessionJumper tier 0).
private struct AgentRowView: View {
    let theme: WarmTheme
    let agent: AgentActivity
    let onJump: (AgentActivity) -> Void
    @State private var hovering = false

    var body: some View {
        let t = theme
        let a = agent
        return HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(a.state == .working ? rgb(0.46, 0.85, 0.45) : t.inkFaint.opacity(0.55))
                        .frame(width: 6, height: 6)
                    Text(a.repoLabel).font(WFont.vLabel).foregroundStyle(t.ink)
                        .lineLimit(1).truncationMode(.middle).layoutPriority(1)
                    AgentBrandMark(
                        platform: a.platform,
                        color: a.isCodex ? t.inkStrong : rgb(0.88, 0.46, 0.30)
                    )
                    .frame(width: 12, height: 12)
                    if let model = a.model {
                        Text(model).font(WFont.caption).foregroundStyle(t.inkFaint)
                            .lineLimit(1).fixedSize()
                    }
                }
                if let title = a.title {
                    Text(title).font(WFont.caption).foregroundStyle(t.inkFaint)
                        .lineLimit(1).truncationMode(.tail)
                        .padding(.leading, 12)
                }
                if a.state == .working, let tool = a.currentTool, let started = a.currentToolStartedMs {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        let secs = max(0, Int((ctx.date.timeIntervalSince1970 * 1000 - Double(started)) / 1000))
                        Text("正在 \(tool) · \(secs)s")
                            .font(WFont.caption).monospacedDigit()
                            .foregroundStyle(t.accent)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    .padding(.leading, 12)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(a.ratePerMin > 0 ? "\(TokenFormat.compact(a.ratePerMin))/min" : "—")
                    .font(WFont.vValue).monospacedDigit().foregroundStyle(t.inkStrong)
                    .contentTransition(.numericText())
                if a.sessionTokens > 0 {
                    Text("共 \(TokenFormat.compact(a.sessionTokens))")
                        .font(WFont.caption).monospacedDigit().foregroundStyle(t.inkFaint)
                        .contentTransition(.numericText())
                }
            }
            .fixedSize()
            Image(systemName: "arrow.up.forward.app.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(t.accent)
                .opacity(hovering ? 1 : 0)
                .frame(width: 13)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(hovering ? t.ink.opacity(0.09) : .clear))
        .onHover { hovering = $0 }
        .onTapGesture { onJump(a) }
        .help(a.isCodex ? "在 Codex 中打开此任务" : "跳到发起该会话的终端窗口")
    }
}
