import AppKit
import SwiftUI
import GRDB
import PetCore

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, integrations, notifications, sound, filters
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .integrations: return "连接与同步"
        case .notifications: return "通知"
        case .sound: return "音效"
        case .filters: return "会话过滤"
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .integrations: return "link.circle.fill"
        case .notifications: return "bell.fill"
        case .sound: return "speaker.wave.2.fill"
        case .filters: return "line.3.horizontal.decrease.circle.fill"
        }
    }
    var colors: [Color] {
        switch self {
        case .general: return Candy.violet
        case .integrations: return Candy.teal
        case .notifications: return Candy.coral
        case .sound: return Candy.lime
        case .filters: return Candy.teal
        }
    }
}

final class SettingsSelection: ObservableObject {
    @Published var tab: SettingsTab
    init(_ tab: SettingsTab = .general) { self.tab = tab }
}

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var selection: SettingsSelection
    @ObservedObject var syncDriver: LeaderboardSyncDriver
    @ObservedObject var watcher: PRWatcher
    let sound: SoundController
    let db: DatabaseQueue
    let leaderboard: LeaderboardService
    let config: ConfigYAML
    let github: GitHubClient
    let git: GitRunner
    @Environment(\.colorScheme) private var scheme
    @StateObject private var hooks = HooksInstallModel()
    @State private var showHooks = false
    @State private var showLeaderboard = false
    @State private var showWatchSettings = false
    @State private var watchedRepoCount = 0
    @State private var rerolling = false

    private var tab: SettingsTab { selection.tab }

    var body: some View {
        let t = WarmTheme(scheme: scheme)
        HStack(spacing: 0) {
            sidebar(t)
            Divider().overlay(t.track)
            content(t)
        }
        .frame(width: 640, height: 480)
        .background { t.windowFill.ignoresSafeArea() }
        .onAppear {
            store.refreshPreciseJump()
            hooks.refresh()
            reloadWatchedRepoCount()
        }
        .sheet(isPresented: $showHooks, onDismiss: { hooks.refresh() }) {
            HooksInstallView()
        }
        .sheet(isPresented: $showLeaderboard) {
            LeaderboardSettingsView(driver: syncDriver, service: leaderboard)
        }
        .sheet(isPresented: $showWatchSettings, onDismiss: {
            reloadWatchedRepoCount()
            Task { await watcher.pollOnce() }
        }) {
            WatchSettingsView(db: db, github: github, git: git, config: config)
        }
    }

    // MARK: sidebar

    private func sidebar(_ t: WarmTheme) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SettingsTab.allCases) { item in
                sidebarRow(t, item)
            }
            Spacer(minLength: 0)
            Divider().overlay(t.track.opacity(0.7))
                .padding(.vertical, 6)
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "power")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(t.inkFaint)
                        .frame(width: 20)
                    Text("退出应用")
                        .font(WFont.label.weight(.medium))
                        .foregroundStyle(t.ink)
                    Spacer(minLength: 4)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(t.pillActive.opacity(0.45))
            )
            .keyboardShortcut("q", modifiers: .command)
            .help("退出应用，不会删除本地数据")
        }
        .padding(.horizontal, 10)
        .padding(.top, 36)
        .padding(.bottom, 12)
        .frame(width: 172, alignment: .leading)
        .background(t.pillTrack.opacity(0.5).ignoresSafeArea())
    }

    private func sidebarRow(_ t: WarmTheme, _ item: SettingsTab) -> some View {
        let active = selection.tab == item
        return HStack(spacing: 10) {
            CandyIcon(symbol: item.symbol, colors: item.colors, size: 13)
                .frame(width: 20)
            Text(item.title)
                .font(WFont.label.weight(active ? .semibold : .medium))
                .foregroundStyle(active ? t.inkStrong : t.ink)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(active ? t.pillActive : Color.clear)
                .shadow(color: active ? t.pillShadow : .clear, radius: 4, x: 0, y: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { withAnimation(.easeOut(duration: 0.14)) { selection.tab = item } }
    }

    // MARK: content

    private func content(_ t: WarmTheme) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pageHeader(t)
                switch tab {
                case .general: generalTab(t)
                case .integrations: integrationsTab(t)
                case .notifications: notificationTab(t)
                case .sound: soundTab(t)
                case .filters: filterTab(t)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 34)
            .padding(.bottom, 26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func pageHeader(_ t: WarmTheme) -> some View {
        HStack(spacing: 10) {
            CandyIcon(symbol: tab.symbol, colors: tab.colors, size: 18)
            Text(tab.title).font(WFont.title).foregroundStyle(t.inkStrong)
        }
    }

    // MARK: 连接与同步

    private func integrationsTab(_ t: WarmTheme) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            group(t, "Agent 接入") {
                integrationStatusRow(
                    t, title: "Claude Code",
                    subtitle: "通过生命周期钩子统计会话、工具调用与 Token",
                    status: hooks.statusText,
                    connected: hooks.status == .installed
                )
                Divider().overlay(t.track)
                integrationStatusRow(
                    t, title: "OpenAI Codex",
                    subtitle: "支持 CLI 与桌面端本地任务；安装后需在 Codex 中信任",
                    status: hooks.codexStatusText,
                    connected: hooks.codexStatus == .installed
                )
                Divider().overlay(t.track)
                HStack {
                    Text("Claude 与 Codex 可同时启用，统计会按平台分别记录。")
                        .font(WFont.caption).foregroundStyle(t.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Button("管理钩子") { showHooks = true }
                        .buttonStyle(WarmButtonStyle(prominent: true))
                }
                .padding(.vertical, 4)
            }

            group(t, "全球排行榜") {
                integrationStatusRow(
                    t, title: "排行榜同步",
                    subtitle: "仅上传聚合统计与宠物信息，不包含代码或会话内容",
                    status: syncDriver.snapshot.account == nil
                        ? "未登录"
                        : "@\(syncDriver.snapshot.account?.githubLogin ?? "")",
                    connected: syncDriver.snapshot.account != nil
                )
                Divider().overlay(t.track)
                HStack {
                    Text("登录 GitHub 后可同步数据并查看自己的全球排名。")
                        .font(WFont.caption).foregroundStyle(t.inkFaint)
                    Spacer(minLength: 12)
                    Button(syncDriver.snapshot.account == nil ? "登录与同步" : "管理同步") {
                        showLeaderboard = true
                    }
                    .buttonStyle(WarmButtonStyle())
                }
                .padding(.vertical, 4)
            }

            group(t, "GitHub 工作台") {
                integrationStatusRow(
                    t, title: "PR 监控仓库",
                    subtitle: "配置要显示在工作台中的仓库、作者与本地路径",
                    status: watchedRepoCount == 0 ? "未配置" : "\(watchedRepoCount) 个仓库",
                    connected: watchedRepoCount > 0
                )
                Divider().overlay(t.track)
                HStack {
                    Text("GitHub 连接、监控范围和本地仓库映射统一在这里管理。")
                        .font(WFont.caption).foregroundStyle(t.inkFaint)
                    Spacer(minLength: 12)
                    Button("管理仓库") { showWatchSettings = true }
                        .buttonStyle(WarmButtonStyle())
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func reloadWatchedRepoCount() {
        watchedRepoCount = ((try? PRStore.watchedRepos(in: db)) ?? []).count
    }

    private func integrationStatusRow(
        _ t: WarmTheme, title: String, subtitle: String, status: String, connected: Bool
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(connected ? t.good : t.inkFaint.opacity(0.35))
                .frame(width: 8, height: 8)
            settingLabel(t, title, subtitle)
            Spacer(minLength: 8)
            Text(status)
                .font(WFont.caption)
                .foregroundStyle(connected ? t.good : t.inkFaint)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }

    // MARK: 通用

    private func generalTab(_ t: WarmTheme) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            group(t, "宠物展示") {
                HStack(alignment: .center, spacing: 12) {
                    settingLabel(
                        t, "展示位置",
                        store.petDisplayMode == .island
                            ? "宠物停留在 MacBook 凹口旁"
                            : "宠物悬浮在普通窗口之上，可拖到桌面任意位置")
                    Spacer(minLength: 8)
                    Picker("展示位置", selection: $store.petDisplayMode) {
                        ForEach(PetDisplayMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 190)
                }
                .padding(.vertical, 4)
            }
            group(t, "系统") {
                SettingsToggleRow(
                    t: t, title: "登录时启动", subtitle: "开机后自动运行 claudegotchi",
                    isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
            }
            group(t, "精确跳转") {
                SettingsToggleRow(
                    t: t, title: "启用标题标记",
                    subtitle: "会话开始与每次发消息时，在终端标题写入一个唯一标记；点提醒时据此精确定位到发起请求的那个窗口",
                    isOn: $store.titleMarkersEnabled)
                Divider().overlay(t.track)
                SettingsToggleRow(
                    t: t, title: "禁用 Claude Code 原生标题",
                    subtitle: "Warp、Ghostty 等只有一个终端标题，Claude 自带的标题会不断覆盖标记；开启后写入 ~/.claude/settings.json（自动备份）以保证这些终端里也能精确跳转",
                    isOn: $store.disableClaudeNativeTitle)
            }
            if store.petDisplayMode == .island {
                group(t, "灵动岛行为") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            settingLabel(t, "悬停展开延时", "指向灵动岛后延迟多久展开面板")
                            Spacer(minLength: 8)
                            Text(String(format: "%.2fs", store.hoverDelay))
                                .font(WFont.value).monospacedDigit().foregroundStyle(t.inkStrong)
                        }
                        Slider(value: $store.hoverDelay, in: 0.1...1.0, step: 0.05).tint(t.accent)
                    }
                    .padding(.vertical, 4)
                    Divider().overlay(t.track)
                    SettingsToggleRow(
                        t: t, title: "鼠标移开自动收起", subtitle: "指针离开后自动收起悬停展开的面板",
                        isOn: $store.autoCollapseOnLeave)
                    Divider().overlay(t.track)
                    SettingsToggleRow(
                        t: t, title: "无活跃会话时隐藏灵动岛", subtitle: "没有会话时淡出灵动岛，宠物仅留在下拉面板",
                        isOn: $store.autoHideWhenNoSessions)
                }
                group(t, "灵动岛微调") {
                    offsetRow(
                        t, title: "高度偏移", subtitle: "在系统凹口高度基础上加减，0 为自动",
                        value: $store.islandHeightOffset, range: SettingsStore.heightOffsetRange, step: 1)
                    Divider().overlay(t.track)
                    offsetRow(
                        t, title: "宽度偏移", subtitle: "微调左右两侧耳朵的总宽度，0 为自动",
                        value: $store.islandWidthOffset, range: SettingsStore.widthOffsetRange, step: 2)
                }
            }
            group(t, "订阅用量") {
                SettingsToggleRow(
                    t: t, title: "显示订阅用量",
                    subtitle: "需要读取 Claude Code 的钥匙串凭证，可能触发系统授权弹窗",
                    isOn: $store.showSubscriptionUsage)
            }
            group(t, "宠物") {
                HStack(alignment: .center, spacing: 10) {
                    settingLabel(t, "重抽宠物（测试）", "随机换一只宠物，成长数值不变")
                    Spacer(minLength: 8)
                    Button { rerollPet() } label: {
                        Text("🎲 重抽宠物（测试）")
                    }
                    .buttonStyle(WarmButtonStyle())
                    .disabled(rerolling)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func rerollPet() {
        guard !rerolling else { return }
        rerolling = true
        try? PetGenomeReroll.reroll(db: db, seed: UInt64.random(in: UInt64.min...UInt64.max))
        postPetDidChange()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { rerolling = false }
    }

    private func offsetRow(
        _ t: WarmTheme, title: String, subtitle: String,
        value: Binding<Int>, range: ClosedRange<Int>, step: Int
    ) -> some View {
        let isAuto = value.wrappedValue == 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                settingLabel(t, title, subtitle)
                Spacer(minLength: 8)
                Button { value.wrappedValue = 0 } label: {
                    Text(isAuto ? "0 · 自动" : String(format: "%+dpt", value.wrappedValue))
                        .font(WFont.value).monospacedDigit()
                        .foregroundStyle(isAuto ? t.inkFaint : t.inkStrong)
                }
                .buttonStyle(.plain)
                .help("点按恢复自动 (0)")
                Button { value.wrappedValue = 0 } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(t.inkFaint)
                .opacity(isAuto ? 0.25 : 1)
                .disabled(isAuto)
                .help("重置")
            }
            Slider(
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { value.wrappedValue = Int($0.rounded()) }),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: Double(step)
            ).tint(t.accent)
        }
        .padding(.vertical, 4)
    }

    // MARK: 通知

    private func notificationTab(_ t: WarmTheme) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            group(t, "完成提醒") {
                SettingsToggleRow(
                    t: t, title: "完成时展开提醒", subtitle: "会话完成一轮时，灵动岛短暂展开绿色提示条",
                    isOn: $store.completionRevealEnabled)
                if store.completionRevealEnabled {
                    Divider().overlay(t.track)
                    HStack {
                        settingLabel(t, "停留时长", "提示条自动收起前的停留秒数，按 ESC 可提前关闭")
                        Spacer(minLength: 8)
                        Stepper(value: $store.completionDwellSeconds, in: SettingsStore.dwellRange) {
                            Text("\(store.completionDwellSeconds)s")
                                .font(WFont.value).monospacedDigit().foregroundStyle(t.inkStrong)
                                .frame(minWidth: 30, alignment: .trailing)
                        }
                        .fixedSize()
                    }
                    .padding(.vertical, 4)
                }
            }
            group(t, "静默场景") {
                SettingsToggleRow(
                    t: t, title: "专注抑制",
                    subtitle: "正盯着该会话的终端窗口时不自动展开（需已授权辅助功能，否则不生效）",
                    isOn: $store.focusSuppressionEnabled)
                Divider().overlay(t.track)
                SettingsToggleRow(
                    t: t, title: "锁屏或休眠时静默", subtitle: "屏幕锁定或休眠期间不自动展开、不播放音效",
                    isOn: $store.quietOnLock)
                Divider().overlay(t.track)
                SettingsToggleRow(
                    t: t, title: "录屏或共享时静默", subtitle: "检测到屏幕录制或共享时不自动展开、不播放音效",
                    isOn: $store.quietOnCapture)
            }
            group(t, "审批") {
                SettingsToggleRow(
                    t: t, title: "使用 Claude Code 原生审批",
                    subtitle: "开启后权限请求不再展开灵动岛，只在原生终端里处理（同时适用于 Codex）",
                    isOn: $store.nativeApprovalsEnabled)
            }
        }
    }

    // MARK: 音效

    private func soundTab(_ t: WarmTheme) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            group(t, "总开关") {
                SettingsToggleRow(
                    t: t, title: "启用音效", subtitle: "为会话与宠物事件播放 8-bit 芯片音效",
                    isOn: $store.soundEnabled)
                Divider().overlay(t.track)
                HStack(spacing: 10) {
                    settingLabel(t, "音量", "所有音效的播放音量")
                    Spacer(minLength: 8)
                    Image(systemName: "speaker.fill").font(.system(size: 10)).foregroundStyle(t.inkFaint)
                    Slider(value: $store.soundVolume, in: 0.0...1.0).tint(t.accent).frame(width: 150)
                    Text("\(Int((store.soundVolume * 100).rounded()))%")
                        .font(WFont.value).monospacedDigit().foregroundStyle(t.inkStrong)
                        .frame(width: 42, alignment: .trailing)
                }
                .padding(.vertical, 4)
                .disabled(!store.soundEnabled)
                .opacity(store.soundEnabled ? 1 : 0.4)
            }
            VStack(alignment: .leading, spacing: 8) {
                group(t, "事件音效") {
                    soundRow(t, "会话开始", "新的 Claude / Codex 会话启动", .sessionStart, $store.soundSessionStart)
                    Divider().overlay(t.track)
                    soundRow(t, "任务完成", "会话完成一轮工作", .taskComplete, $store.soundTaskComplete)
                    Divider().overlay(t.track)
                    soundRow(t, "请求权限", "会话等待你的批准", .permission, $store.soundPermission)
                    Divider().overlay(t.track)
                    soundRow(t, "宠物升级", "宠物等级提升时的号角", .levelUp, $store.soundLevelUp)
                    Divider().overlay(t.track)
                    soundRow(t, "剧场音效", "下拉剧场里的互动音效：吃食、爱心、庆祝、打字",
                             .petChirp, $store.soundTheater)
                }
                Text("多会话并发时建议只保留 任务完成 与 请求权限")
                    .font(WFont.caption).foregroundStyle(t.inkFaint)
                    .padding(.horizontal, 2)
            }
            .disabled(!store.soundEnabled)
            .opacity(store.soundEnabled ? 1 : 0.5)
        }
    }

    private func soundRow(
        _ t: WarmTheme, _ title: String, _ subtitle: String,
        _ event: ChiptuneEvent, _ isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(WFont.label.weight(.semibold)).foregroundStyle(t.inkStrong)
                Text(subtitle).font(WFont.caption).foregroundStyle(t.inkFaint)
            }
            Spacer(minLength: 8)
            Button { sound.preview(event) } label: {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(LinearGradient(colors: Candy.lime, startPoint: .top, endPoint: .bottom))
            }
            .buttonStyle(.plain)
            .help("试听")
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).tint(t.accent)
        }
        .padding(.vertical, 4)
    }

    // MARK: 会话过滤

    private func filterTab(_ t: WarmTheme) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            group(t, "目录包含") {
                filterGroup(
                    t, kind: .directory,
                    hint: "工作目录包含该文本的会话将被隐藏",
                    placeholder: "例如 /experiments",
                    userPatterns: store.userDirectoryPatterns)
            }
            group(t, "首条消息前缀") {
                filterGroup(
                    t, kind: .promptPrefix,
                    hint: "首条消息以该前缀开头的会话将被隐藏",
                    placeholder: "例如 <task-notification>",
                    userPatterns: store.userPromptPrefixPatterns)
            }
        }
    }

    @ViewBuilder
    private func filterGroup(
        _ t: WarmTheme, kind: SessionFilterPreset.Kind,
        hint: String, placeholder: String, userPatterns: [String]
    ) -> some View {
        let presets = SessionFilterPresets.all.filter { $0.kind == kind }
        VStack(alignment: .leading, spacing: 8) {
            Text(hint).font(WFont.caption).foregroundStyle(t.inkFaint)
            PatternAddField(t: t, placeholder: placeholder) { store.addUserPattern($0, kind: kind) }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(presets) { preset in
                        PatternRow(
                            t: t, pattern: preset.pattern, label: preset.label, isPreset: true,
                            control: .toggle(Binding(
                                get: { store.isPresetEnabled(preset.id) },
                                set: { store.setPreset(preset.id, $0) })))
                        rowDivider(t)
                    }
                    if userPatterns.isEmpty {
                        Text("暂无自定义规则")
                            .font(WFont.caption).foregroundStyle(t.inkFaint)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8).padding(.horizontal, 2)
                    } else {
                        ForEach(Array(userPatterns.enumerated()), id: \.element) { idx, pattern in
                            PatternRow(
                                t: t, pattern: pattern, label: nil, isPreset: false,
                                control: .delete { store.removeUserPattern(pattern, kind: kind) })
                            if idx < userPatterns.count - 1 { rowDivider(t) }
                        }
                    }
                }
            }
            .frame(maxHeight: rowScrollHeight(presets.count + max(1, userPatterns.count)))
        }
    }

    private func rowDivider(_ t: WarmTheme) -> some View {
        Divider().overlay(t.track.opacity(0.6))
    }

    /// Caps the list at ~6 rows tall; longer lists scroll.
    private func rowScrollHeight(_ rows: Int) -> CGFloat {
        CGFloat(min(rows, 6)) * 34 + 6
    }

    private func settingLabel(_ t: WarmTheme, _ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(WFont.label.weight(.semibold)).foregroundStyle(t.inkStrong)
            Text(subtitle).font(WFont.caption).foregroundStyle(t.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func group<Content: View>(
        _ t: WarmTheme, _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(WFont.section).foregroundStyle(t.inkStrong)
                .textCase(nil).kerning(0.4)
            SoftCard(fill: t.cardFill, cornerRadius: 18, padding: 14, shadow: t.cardShadow) {
                VStack(alignment: .leading, spacing: 6) { content() }
            }
        }
    }
}

// MARK: - rows

private struct SettingsToggleRow: View {
    let t: WarmTheme
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(WFont.label.weight(.semibold)).foregroundStyle(t.inkStrong)
                Text(subtitle).font(WFont.caption).foregroundStyle(t.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(t.accent)
        }
        .padding(.vertical, 4)
    }
}

private struct PatternAddField: View {
    let t: WarmTheme
    let placeholder: String
    let onAdd: (String) -> Void
    @State private var text = ""
    var body: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(WFont.body.monospaced())
                .foregroundStyle(t.inkStrong)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(t.pillTrack))
                .onSubmit(commit)
            Button(action: commit) {
                Image(systemName: "plus").font(.system(size: 12, weight: .bold))
            }
            .buttonStyle(WarmButtonStyle())
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
    private func commit() {
        onAdd(text)
        text = ""
    }
}

private struct PatternRow: View {
    enum Control {
        case toggle(Binding<Bool>)
        case delete(() -> Void)
    }
    let t: WarmTheme
    let pattern: String
    let label: String?
    let isPreset: Bool
    let control: Control

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "number")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(t.inkFaint)
            VStack(alignment: .leading, spacing: 1) {
                if let label {
                    HStack(spacing: 5) {
                        Text(label).font(WFont.vLabel).foregroundStyle(t.ink).lineLimit(1)
                        if isPreset {
                            Text("预设").font(.system(size: 8.5, weight: .bold, design: .rounded))
                                .foregroundStyle(t.accent)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Capsule().fill(t.highlight))
                        }
                    }
                }
                Text(pattern).font(WFont.caption.monospaced()).foregroundStyle(t.inkFaint)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            switch control {
            case .toggle(let binding):
                Toggle("", isOn: binding).labelsHidden().toggleStyle(.switch)
                    .controlSize(.mini).tint(t.accent)
            case .delete(let action):
                Button(action: action) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13)).foregroundStyle(t.inkFaint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 7).padding(.horizontal, 2)
        .frame(minHeight: 34)
    }
}
