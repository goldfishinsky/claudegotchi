import SwiftUI
import PetCore

// The stats window's 系统 tab: the full-depth home for system metrics that the
// dropdown's fixed glance deliberately omits. Live only while visible — it drives
// the shared sampler via refcounted start/stop so it can overlap the dropdown.
struct SystemTab: View {
    @ObservedObject var driver: SystemStatsDriver
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = WarmTheme(scheme: scheme)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                cpuCard(t)
                memCard(t)
            }
            .padding(16)
        }
        .onAppear { driver.start() }
        .onDisappear { driver.stop() }
    }

    // MARK: CPU

    private func cpuCard(_ t: WarmTheme) -> some View {
        let hot = (driver.snapshot?.cpuUsage ?? 0) >= 0.8
        return SoftCard(fill: t.cardFill, cornerRadius: 16, padding: 14, shadow: t.cardShadow) {
            VStack(alignment: .leading, spacing: 12) {
                cardHeader(t, "cpu.fill", hot ? Candy.cpuHot : Candy.cpu, "处理器",
                           pctText(driver.snapshot.map(\.cpuUsage)), t.inkStrong)
                bigGraph(t, driver.cpuHistory, Candy.cpu)
                loadLine(t)
                coreGrid(t)
                Divider().background(t.ink.opacity(0.08))
                procTable(t, title: "占用最高进程",
                          rows: driver.topCPU.map { ($0.name, "\(Int($0.percent.rounded()))%", $0.percent) },
                          colors: Candy.cpu)
            }
        }
    }

    private func loadLine(_ t: WarmTheme) -> some View {
        HStack(spacing: 6) {
            if let la = driver.loadAverage {
                Text("负载 \(LoadAverage.format(la.one, la.five, la.fifteen))")
                    .font(WFont.section).monospacedDigit().foregroundStyle(t.ink)
                Text("·").foregroundStyle(t.inkFaint.opacity(0.6))
            }
            Text("\(driver.coreCount) 核").font(WFont.section).monospacedDigit()
                .foregroundStyle(t.inkFaint)
            Spacer(minLength: 0)
        }
    }

    private func coreGrid(_ t: WarmTheme) -> some View {
        let cores = driver.perCoreUsage
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6),
                            count: min(8, max(1, cores.count)))
        return Group {
            if cores.isEmpty {
                Text("采样中…").font(WFont.caption).foregroundStyle(t.inkFaint)
            } else {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(Array(cores.enumerated()), id: \.offset) { idx, load in
                        CoreCell(index: idx, load: load,
                                 colors: load >= 0.8 ? Candy.cpuHot : Candy.cpu, track: t.track,
                                 label: t.inkFaint)
                    }
                }
            }
        }
    }

    // MARK: MEM

    private func memCard(_ t: WarmTheme) -> some View {
        let tier = driver.snapshot?.memPressure ?? .normal
        return SoftCard(fill: t.cardFill, cornerRadius: 16, padding: 14, shadow: t.cardShadow) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    CandyIcon(symbol: "memorychip.fill", colors: Candy.memory, size: 15)
                        .frame(width: 20, alignment: .center)
                    Text("内存").font(WFont.title).foregroundStyle(t.inkStrong)
                    pressureBadge(t, tier)
                    Spacer(minLength: 8)
                    Text(pctText(memFraction())).font(WFont.metric).monospacedDigit()
                        .foregroundStyle(memTierInk(t, tier))
                        .lineLimit(1).minimumScaleFactor(0.5)
                }
                bigGraph(t, driver.memHistory, Candy.memory)
                memBreakdown(t)
                Divider().background(t.ink.opacity(0.08))
                procTable(t, title: "占用最高进程",
                          rows: driver.topRAM.map { ($0.name, ByteFormat.size($0.rssBytes), Double($0.rssBytes)) },
                          colors: Candy.memory)
            }
        }
    }

    private func memBreakdown(_ t: WarmTheme) -> some View {
        HStack(spacing: 14) {
            if let s = driver.snapshot {
                statChip(t, "已用", "\(ByteFormat.size(s.memUsedBytes)) / \(ByteFormat.size(s.memTotalBytes))")
            }
            statChip(t, "压缩", ByteFormat.size(driver.compressedBytes))
            statChip(t, "交换", ByteFormat.size(driver.swapBytes))
            Spacer(minLength: 0)
        }
    }

    private func statChip(_ t: WarmTheme, _ label: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(label).font(WFont.caption).foregroundStyle(t.inkFaint)
            Text(value).font(WFont.section).monospacedDigit().foregroundStyle(t.ink)
        }
    }

    private func pressureBadge(_ t: WarmTheme, _ tier: MemPressureTier) -> some View {
        let (text, colors): (String, [Color]) = {
            switch tier {
            case .normal: return ("正常", Candy.memNormal)
            case .elevated: return ("偏高", Candy.memElevated)
            case .critical: return ("紧张", Candy.memCritical)
            }
        }()
        return Text(text).font(WFont.caption.weight(.semibold)).foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)))
    }

    // MARK: shared pieces

    private func cardHeader(
        _ t: WarmTheme, _ symbol: String, _ iconColors: [Color], _ title: String,
        _ value: String, _ valueColor: Color
    ) -> some View {
        HStack(spacing: 6) {
            CandyIcon(symbol: symbol, colors: iconColors, size: 15)
                .frame(width: 20, alignment: .center)
            Text(title).font(WFont.title).foregroundStyle(t.inkStrong)
            Spacer(minLength: 8)
            Text(value).font(WFont.metric).monospacedDigit().foregroundStyle(valueColor)
                .lineLimit(1).minimumScaleFactor(0.5)
        }
    }

    private func bigGraph(_ t: WarmTheme, _ values: [Double], _ colors: [Color]) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(t.track.opacity(0.5))
            if values.count >= 2 {
                Sparkline(values: values, colors: colors, height: 84)
                    .padding(.horizontal, 8).padding(.vertical, 6)
            } else {
                Text("采样中…").font(WFont.caption).foregroundStyle(t.inkFaint)
            }
            VStack {
                HStack {
                    Spacer()
                    Text("过去 1 小时").font(WFont.caption).foregroundStyle(t.inkFaint.opacity(0.8))
                        .padding(.trailing, 10).padding(.top, 6)
                }
                Spacer()
            }
        }
        .frame(height: 96)
    }

    private func procTable(
        _ t: WarmTheme, title: String, rows: [(name: String, value: String, weight: Double)], colors: [Color]
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(WFont.section).foregroundStyle(t.inkFaint)
            if rows.isEmpty {
                Text("采样中…").font(WFont.body).foregroundStyle(t.inkFaint)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 10)
            } else {
                let peak = max(rows.map(\.weight).max() ?? 1, 1e-9)
                ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                    HStack(spacing: 10) {
                        Text("\(idx + 1)").font(WFont.caption).monospacedDigit()
                            .foregroundStyle(t.inkFaint).frame(width: 14, alignment: .trailing)
                        Text(row.name).font(WFont.body).foregroundStyle(t.inkStrong)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        SoftBar(fraction: row.weight / peak, colors: colors, track: t.track, height: 5)
                            .frame(width: 90)
                        Text(row.value).font(WFont.value).monospacedDigit()
                            .foregroundStyle(t.ink).frame(width: 66, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: metric helpers

    private func memFraction() -> Double? {
        guard let s = driver.snapshot, s.memTotalBytes > 0 else { return nil }
        return Double(s.memUsedBytes) / Double(s.memTotalBytes)
    }

    private func pctText(_ frac: Double?) -> String {
        guard let frac else { return "—" }
        return "\(min(100, max(0, Int((frac * 100).rounded()))))%"
    }

    private func memTierInk(_ t: WarmTheme, _ tier: MemPressureTier) -> Color {
        switch tier {
        case .normal: return t.good
        case .elevated: return rgb(1.0, 0.60, 0.28)
        case .critical: return t.danger
        }
    }
}

// One core's load as a small bottom-anchored vertical bar with its index below.
private struct CoreCell: View {
    let index: Int
    let load: Double
    let colors: [Color]
    let track: Color
    let label: Color

    var body: some View {
        let f = CGFloat(min(1, max(0, load)))
        return VStack(spacing: 3) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(track)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(LinearGradient(colors: colors, startPoint: .bottom, endPoint: .top))
                    .frame(height: max(3, 34 * f))
            }
            .frame(height: 34)
            Text("\(index)").font(WFont.caption).monospacedDigit().foregroundStyle(label)
        }
    }
}
