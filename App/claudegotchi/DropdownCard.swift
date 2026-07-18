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

    // MARK: system metrics

    private func systemPanel(_ t: WarmTheme) -> some View {
        let s = driver.snapshot
        return SoftPanel(fill: t.panelFill) {
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 16) {
                    memCell(t, s)
                    cpuCell(t, s)
                }
                HStack(spacing: 16) {
                    netCell(t, "arrow.down.circle.fill", Candy.netDown, "下行", s?.downBytesPerSec)
                    netCell(t, "arrow.up.circle.fill", Candy.netUp, "上行", s?.upBytesPerSec)
                }
                HStack(spacing: 16) {
                    diskCell(t, s)
                    if let bat = s?.battery { batteryCell(t, bat) }
                }
            }
        }
    }

    private func barCell(_ t: WarmTheme, _ symbol: String, _ iconColors: [Color], _ label: String,
                         _ frac: Double, _ barColors: [Color], _ valueText: String) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                CandyIcon(symbol: symbol, colors: iconColors, size: 15)
                    .frame(width: 18, alignment: .center)
                Text(label).font(WFont.label).foregroundStyle(t.ink)
                Spacer(minLength: 4)
                Text(valueText).font(WFont.value).monospacedDigit().foregroundStyle(t.inkStrong)
            }
            SoftBar(fraction: frac, colors: barColors, track: t.track)
        }
        .frame(maxWidth: .infinity)
    }

    private func memCell(_ t: WarmTheme, _ s: SystemSnapshot?) -> some View {
        let used = s?.memUsedBytes ?? 0
        let total = s?.memTotalBytes ?? 0
        let frac = total > 0 ? Double(used) / Double(total) : 0
        return VStack(spacing: 6) {
            barCell(t, "memorychip.fill", Candy.memory, "内存", frac,
                    memTierColors(s?.memPressure ?? .normal), pctText(s == nil ? nil : frac))
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Text(s == nil ? "— / —" : "\(ByteFormat.size(used)) / \(ByteFormat.size(total))")
                    .font(WFont.caption).monospacedDigit().foregroundStyle(t.inkFaint).lineLimit(1)
            }
        }
    }

    private func cpuCell(_ t: WarmTheme, _ s: SystemSnapshot?) -> some View {
        let cpu = s?.cpuUsage ?? 0
        return barCell(t, "cpu.fill", Candy.cpu, "CPU", cpu,
                       cpu >= 0.8 ? Candy.cpuHot : Candy.cpu, pctText(s == nil ? nil : cpu))
    }

    private func netCell(_ t: WarmTheme, _ symbol: String, _ colors: [Color], _ label: String, _ bps: Double?) -> some View {
        HStack(spacing: 8) {
            CandyIcon(symbol: symbol, colors: colors, size: 15)
                .frame(width: 18, alignment: .center)
            Text(label).font(WFont.label).foregroundStyle(t.ink)
            Spacer(minLength: 4)
            Text(bps == nil ? "—" : ByteFormat.speed(bps!)).font(WFont.value).monospacedDigit()
                .foregroundStyle(t.inkStrong).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func diskCell(_ t: WarmTheme, _ s: SystemSnapshot?) -> some View {
        HStack(spacing: 8) {
            CandyIcon(symbol: "internaldrive.fill", colors: Candy.disk, size: 15)
                .frame(width: 18, alignment: .center)
            Text("磁盘可用").font(WFont.label).foregroundStyle(t.ink)
            Spacer(minLength: 4)
            Text(s == nil ? "—" : ByteFormat.size(s!.diskFreeBytes)).font(WFont.value).monospacedDigit()
                .foregroundStyle(t.inkStrong).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func batteryCell(_ t: WarmTheme, _ bat: (percent: Int, charging: Bool)) -> some View {
        let pct = min(100, max(0, bat.percent))
        return HStack(spacing: 8) {
            CandyIcon(symbol: batterySymbol(pct), colors: Candy.battery, size: 15)
                .frame(width: 18, alignment: .center)
            Text("电量").font(WFont.label).foregroundStyle(t.ink)
            Spacer(minLength: 4)
            if bat.charging {
                CandyIcon(symbol: "bolt.fill", colors: Candy.bolt, size: 10)
            }
            Text("\(pct)%").font(WFont.value).monospacedDigit().foregroundStyle(t.inkStrong)
        }
        .frame(maxWidth: .infinity)
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

    private func memTierColors(_ tier: MemPressureTier) -> [Color] {
        switch tier {
        case .normal: return Candy.memNormal
        case .elevated: return Candy.memElevated
        case .critical: return Candy.memCritical
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
