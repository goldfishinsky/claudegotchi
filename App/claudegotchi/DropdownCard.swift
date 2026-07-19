import SwiftUI
import PetCore

// The dreamy "cream card + warm backlit glow" that IS the menu-bar dropdown.
// Composes the pet section, live system metrics, the work/PR section, and the
// footer actions (打开统计 / 暂停). Rendered inside a borderless NSPanel by
// MenuDropdownController; the transparent glow margin lets the glow spill past
// the card edge.
struct DropdownCard: View {
    @ObservedObject var petModel: PetPanelModel
    @ObservedObject var workModel: WorkPanelModel
    @ObservedObject var agentModel: AgentActivityModel
    @ObservedObject var services: AppServices
    @ObservedObject var driver: SystemStatsDriver
    @ObservedObject var usageDriver: ClaudeUsageDriver
    @ObservedObject var islandModel: IslandModel
    var onOpenStats: () -> Void
    var onToggleIsland: (Bool) -> Void
    var onOpenSettings: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var hoverTarget: HoverTarget?
    @State private var pendingHover: DispatchWorkItem?

    static let cardWidth: CGFloat = 400
    static let glowMargin: CGFloat = 30
    static let totalWidth: CGFloat = cardWidth + glowMargin * 2
    private static let cardSpace = "dropdownCard"

    enum HoverTarget: Hashable { case cpu, mem }

    struct CellAnchorKey: PreferenceKey {
        static var defaultValue: [HoverTarget: Anchor<CGRect>] = [:]
        static func reduce(value: inout Value, nextValue: () -> Value) {
            value.merge(nextValue()) { $1 }
        }
    }

    private var theme: WarmTheme { WarmTheme(scheme: scheme) }

    var body: some View {
        let t = theme
        return VStack(spacing: 12) {
            PetSection(petModel: petModel, driver: driver, theme: t)
            systemPanel(t)
            workPanel(t)
            agentPanel(t)
            usageStrip(t)
            footer(t)
        }
        .padding(16)
        .frame(width: Self.cardWidth)
        .coordinateSpace(name: Self.cardSpace)
        .overlayPreferenceValue(CellAnchorKey.self) { anchors in
            popoverOverlay(t, anchors)
        }
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
    }

    // MARK: system metrics (compact icon grid)

    private struct MetricCell: Identifiable {
        let id: String
        let symbol: String
        let colors: [Color]
        let value: String
        let valueColor: Color
    }

    private func systemPanel(_ t: WarmTheme) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .topLeading), count: 3),
            alignment: .leading, spacing: 7
        ) {
            ForEach(metricCells(t)) { c in
                metricCell(t, c)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(t.panelFill))
    }

    @ViewBuilder
    private func metricCell(_ t: WarmTheme, _ c: MetricCell) -> some View {
        switch c.id {
        case "cpu": cpuCell(t, c)
        case "mem": hoverable(.mem, metricRow(t, c))
        default: metricRow(t, c)
        }
    }

    private func metricRow(_ t: WarmTheme, _ c: MetricCell) -> some View {
        HStack(spacing: 6) {
            CandyIcon(symbol: c.symbol, colors: c.colors, size: 13)
            Text(c.value).font(WFont.value).monospacedDigit()
                .foregroundStyle(c.valueColor)
                .lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 0)
        }
    }

    private func cpuCell(_ t: WarmTheme, _ c: MetricCell) -> some View {
        let cores = driver.perCoreUsage
        return hoverable(.cpu, VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                CandyIcon(symbol: c.symbol, colors: c.colors, size: 13)
                Text(c.value).font(WFont.value).monospacedDigit()
                    .foregroundStyle(c.valueColor)
                    .lineLimit(1).minimumScaleFactor(0.7)
                if driver.thermal.isElevated {
                    Circle().fill(LinearGradient(colors: Candy.cpuHot, startPoint: .top, endPoint: .bottom))
                        .frame(width: 5, height: 5)
                        .shadow(color: Candy.cpuHot[1].opacity(0.7), radius: 2)
                }
                Spacer(minLength: 0)
            }
            if !cores.isEmpty {
                CoreBar(cores: cores,
                        colors: (driver.snapshot?.cpuUsage ?? 0) >= 0.8 ? Candy.cpuHot : Candy.cpu,
                        track: t.track)
            }
        })
    }

    private func hoverable<V: View>(_ target: HoverTarget, _ content: V) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
            .anchorPreference(key: CellAnchorKey.self, value: .bounds) { [target: $0] }
            .onHover { scheduleHover(target, $0) }
    }

    private func metricCells(_ t: WarmTheme) -> [MetricCell] {
        let s = driver.snapshot
        let memFrac: Double? = {
            guard let s, s.memTotalBytes > 0 else { return nil }
            return Double(s.memUsedBytes) / Double(s.memTotalBytes)
        }()
        var cells: [MetricCell] = [
            MetricCell(id: "mem", symbol: "memorychip.fill", colors: Candy.memory,
                       value: pctText(memFrac), valueColor: memTierInk(t, s?.memPressure ?? .normal)),
            MetricCell(id: "cpu", symbol: "cpu.fill",
                       colors: (s?.cpuUsage ?? 0) >= 0.8 ? Candy.cpuHot : Candy.cpu,
                       value: pctText(s.map(\.cpuUsage)), valueColor: t.inkStrong),
        ]
        if let bat = s?.battery {
            cells.append(MetricCell(id: "bat", symbol: batterySymbol(bat.percent), colors: Candy.battery,
                                    value: "\(min(100, max(0, bat.percent)))%", valueColor: t.inkStrong))
        }
        cells.append(contentsOf: [
            MetricCell(id: "down", symbol: "arrow.down.circle.fill", colors: Candy.netDown,
                       value: speedText(s?.downBytesPerSec), valueColor: t.inkStrong),
            MetricCell(id: "up", symbol: "arrow.up.circle.fill", colors: Candy.netUp,
                       value: speedText(s?.upBytesPerSec), valueColor: t.inkStrong),
            MetricCell(id: "disk", symbol: "internaldrive.fill", colors: Candy.disk,
                       value: s.map { ByteFormat.size($0.diskFreeBytes) } ?? "—", valueColor: t.inkStrong),
        ])
        return cells
    }

    // MARK: hover popovers

    private func scheduleHover(_ target: HoverTarget, _ hovering: Bool) {
        pendingHover?.cancel()
        let work: DispatchWorkItem
        if hovering {
            work = DispatchWorkItem { withAnimation(.easeOut(duration: 0.12)) { hoverTarget = target } }
        } else {
            work = DispatchWorkItem {
                if hoverTarget == target { withAnimation(.easeOut(duration: 0.12)) { hoverTarget = nil } }
            }
        }
        pendingHover = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (hovering ? 0.3 : 0.2), execute: work)
    }

    @ViewBuilder
    private func popoverOverlay(_ t: WarmTheme, _ anchors: [HoverTarget: Anchor<CGRect>]) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.clear
                if let target = hoverTarget, let anchor = anchors[target] {
                    let rect = proxy[anchor]
                    let popW: CGFloat = 220
                    let x = min(max(0, rect.minX - 6), max(0, proxy.size.width - popW))
                    popoverContent(t, target)
                        .frame(width: popW)
                        .offset(x: x, y: rect.maxY + 6)
                        .onHover { scheduleHover(target, $0) }
                        .transition(.opacity)
                }
            }
        }
    }

    @ViewBuilder
    private func popoverContent(_ t: WarmTheme, _ target: HoverTarget) -> some View {
        switch target {
        case .cpu: cpuPopover(t)
        case .mem: memPopover(t)
        }
    }

    private func cpuPopover(_ t: WarmTheme) -> some View {
        MetricPopover(theme: t) {
            popoverHeader(t, "cpu.fill", Candy.cpu, "处理器", pctText(driver.snapshot?.cpuUsage))
            if let la = driver.loadAverage {
                Text("负载 \(LoadAverage.format(la.one, la.five, la.fifteen)) / \(driver.coreCount) 核")
                    .font(WFont.caption).monospacedDigit().foregroundStyle(t.inkFaint)
            }
            Sparkline(values: driver.cpuHistory, colors: Candy.cpu)
            procList(t, driver.topCPU.map { ($0.name, cpuPercentText($0.percent)) })
        }
    }

    private func memPopover(_ t: WarmTheme) -> some View {
        MetricPopover(theme: t) {
            popoverHeader(t, "memorychip.fill", Candy.memory, "内存", memUsedText())
            Text("压缩 \(ByteFormat.size(driver.compressedBytes)) · 交换 \(ByteFormat.size(driver.swapBytes))")
                .font(WFont.caption).monospacedDigit().foregroundStyle(t.inkFaint)
            Sparkline(values: driver.memHistory, colors: Candy.memory)
            procList(t, driver.topRAM.map { ($0.name, ByteFormat.size($0.rssBytes)) })
        }
    }

    private func popoverHeader(
        _ t: WarmTheme, _ symbol: String, _ colors: [Color], _ title: String, _ value: String
    ) -> some View {
        HStack(spacing: 6) {
            CandyIcon(symbol: symbol, colors: colors, size: 12)
            Text(title).font(WFont.label).foregroundStyle(t.ink)
            Spacer(minLength: 6)
            Text(value).font(WFont.value).monospacedDigit().foregroundStyle(t.inkStrong)
        }
    }

    @ViewBuilder
    private func procList(_ t: WarmTheme, _ rows: [(String, String)]) -> some View {
        if rows.isEmpty {
            Text("采样中…").font(WFont.caption).foregroundStyle(t.inkFaint)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 5) {
                        Text(row.1).font(WFont.caption).monospacedDigit()
                            .foregroundStyle(t.inkStrong).fixedSize()
                        Text("/").font(WFont.caption).foregroundStyle(t.inkFaint.opacity(0.6))
                        Text(row.0).font(WFont.caption).foregroundStyle(t.ink)
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func memUsedText() -> String {
        guard let s = driver.snapshot else { return "—" }
        return "\(ByteFormat.size(s.memUsedBytes)) / \(ByteFormat.size(s.memTotalBytes))"
    }

    private func cpuPercentText(_ percent: Double) -> String {
        "\(Int(percent.rounded()))%"
    }

    // MARK: work / PR section

    private func workPanel(_ t: WarmTheme) -> some View {
        SoftPanel(fill: t.panelFill) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    CandyIcon(symbol: "briefcase.fill", colors: Candy.work, size: 14)
                        .frame(width: 18, alignment: .center)
                    Text("工作").font(WFont.label).foregroundStyle(t.ink)
                    Spacer(minLength: 4)
                    if workModel.firstPollComplete && workModel.pendingCount > 0 {
                        Text("\(WorkPanelFormat.cappedCount(workModel.pendingCount)) 待处理")
                            .font(WFont.caption).foregroundStyle(rgb(1.0, 0.55, 0.35))
                    }
                }
                workContent(t)
                if workModel.runningRepoCount > 0 {
                    HStack(spacing: 5) {
                        Circle().fill(rgb(0.46, 0.85, 0.45)).frame(width: 6, height: 6)
                        Text("Claude 在 \(WorkPanelFormat.cappedCount(workModel.runningRepoCount)) 个仓库运行")
                            .font(WFont.caption).foregroundStyle(t.inkFaint).lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func workContent(_ t: WarmTheme) -> some View {
        if !workModel.firstPollComplete {
            Text("正在加载…").font(WFont.caption).foregroundStyle(t.inkFaint)
        } else if workModel.pendingCount == 0 {
            Text("✅ 全部清空").font(WFont.caption).foregroundStyle(t.inkFaint)
        } else {
            let ordered = WorkPanelFormat.ordered(workModel.prs)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(ordered.prefix(WorkPanelFormat.rowCap)), id: \.id) { pr in
                    HStack(spacing: 6) {
                        Text(pr.title).font(WFont.vLabel).foregroundStyle(t.ink)
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 6)
                        Text(WorkPanelFormat.chip(for: pr)).font(WFont.caption)
                            .foregroundStyle(t.inkFaint).lineLimit(1)
                    }
                }
                if ordered.count > WorkPanelFormat.rowCap {
                    Text("… 还有 \(WorkPanelFormat.cappedCount(ordered.count - WorkPanelFormat.rowCap)) 个")
                        .font(WFont.caption).foregroundStyle(t.inkFaint)
                }
            }
        }
    }

    // MARK: active-agent section

    private func agentPanel(_ t: WarmTheme) -> some View {
        SoftPanel(fill: t.panelFill) {
            VStack(alignment: .leading, spacing: 7) {
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
                    agentRow(t, agent)
                }
                if agents.count > WorkPanelFormat.rowCap {
                    Text("… 还有 \(WorkPanelFormat.cappedCount(agents.count - WorkPanelFormat.rowCap)) 个")
                        .font(WFont.caption).foregroundStyle(t.inkFaint)
                }
            }
        }
    }

    private func agentRow(_ t: WarmTheme, _ a: AgentActivity) -> some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(a.state == .working ? rgb(0.46, 0.85, 0.45) : t.inkFaint.opacity(0.55))
                        .frame(width: 6, height: 6)
                    Text(a.repoName).font(WFont.vLabel).foregroundStyle(t.ink)
                        .lineLimit(1).truncationMode(.middle).layoutPriority(1)
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
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(a.ratePerMin > 0 ? "\(TokenFormat.compact(a.ratePerMin))/min" : "—")
                    .font(WFont.vValue).monospacedDigit().foregroundStyle(t.inkStrong)
                if a.sessionTokens > 0 {
                    Text("共 \(TokenFormat.compact(a.sessionTokens))")
                        .font(WFont.caption).monospacedDigit().foregroundStyle(t.inkFaint)
                }
            }
            .fixedSize()
        }
    }

    // MARK: claude subscription usage

    @ViewBuilder
    private func usageStrip(_ t: WarmTheme) -> some View {
        if let u = usageDriver.usage {
            HStack(spacing: 14) {
                CandyIcon(symbol: "speedometer", colors: Candy.amber, size: 13)
                    .frame(width: 16)
                usageSeg(t, "5h", u.fiveHourPct)
                usageSeg(t, "周", u.weeklyPct)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(t.panelFill))
        }
    }

    private func usageSeg(_ t: WarmTheme, _ label: String, _ pct: Double) -> some View {
        let clamped = min(100, max(0, pct))
        return HStack(spacing: 7) {
            Text(label).font(WFont.caption).foregroundStyle(t.ink)
                .frame(width: 16, alignment: .leading)
            SoftBar(fraction: clamped / 100, colors: usageColors(clamped), track: t.track, height: 5)
            Text("\(Int(clamped.rounded()))%").font(WFont.vValue).monospacedDigit()
                .foregroundStyle(t.inkStrong).frame(width: 34, alignment: .trailing)
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

            if islandModel.notchAvailable {
                Toggle(isOn: Binding(get: { islandModel.enabled }, set: { onToggleIsland($0) })) {
                    Text("灵动岛").font(WFont.label).foregroundStyle(t.ink)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .fixedSize()
            }

            Toggle(isOn: Binding(get: { services.paused }, set: { services.setPaused($0) })) {
                Text("暂停").font(WFont.label).foregroundStyle(t.ink)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .fixedSize()

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(t.ink)
            }
            .buttonStyle(.plain)
            .help("设置")
        }
    }

    // MARK: helpers

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
