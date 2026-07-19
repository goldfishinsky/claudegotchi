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
    var onOpenStats: () -> Void

    @Environment(\.colorScheme) private var scheme

    static let cardWidth: CGFloat = 400
    static let glowMargin: CGFloat = 30
    static let totalWidth: CGFloat = cardWidth + glowMargin * 2

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
            columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .leading), count: 3),
            alignment: .leading, spacing: 7
        ) {
            ForEach(metricCells(t)) { c in
                HStack(spacing: 6) {
                    CandyIcon(symbol: c.symbol, colors: c.colors, size: 13)
                    Text(c.value).font(WFont.value).monospacedDigit()
                        .foregroundStyle(c.valueColor)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(t.panelFill))
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
        HStack(spacing: 12) {
            Button(action: onOpenStats) {
                Text("打开统计").font(WFont.label.weight(.semibold)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(rgb(1.0, 0.62, 0.34))

            HStack(spacing: 6) {
                Toggle(isOn: Binding(get: { services.paused }, set: { services.setPaused($0) })) {
                    Text("暂停").font(WFont.label).foregroundStyle(t.ink)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .fixedSize()
                if services.paused {
                    Text("已暂停").font(WFont.caption).foregroundStyle(rgb(1.0, 0.55, 0.35))
                }
            }
            .fixedSize()
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
