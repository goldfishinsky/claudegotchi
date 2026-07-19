import SwiftUI
import PetCore

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = WarmTheme(scheme: scheme)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header(t)
                generalSection(t)
                notificationSection(t)
                filterSection(t)
            }
            .padding(.horizontal, 22)
            .padding(.top, 34)
            .padding(.bottom, 26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background { t.windowFill.ignoresSafeArea() }
    }

    private func header(_ t: WarmTheme) -> some View {
        HStack(spacing: 10) {
            CandyIcon(symbol: "gearshape.fill", colors: Candy.amber, size: 18)
            Text("设置").font(WFont.title).foregroundStyle(t.inkStrong)
        }
    }

    // MARK: 通用

    private func generalSection(_ t: WarmTheme) -> some View {
        settingsCard(t, "通用", "gearshape.fill", Candy.violet) {
            SettingsToggleRow(
                t: t, title: "登录时启动", subtitle: "开机后自动运行 claudegotchi",
                isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
            Divider().overlay(t.track)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    settingLabel(t, "悬停展开延时", "指向灵动岛后延迟多久展开面板")
                    Spacer(minLength: 8)
                    Text(String(format: "%.2fs", store.hoverDelay))
                        .font(WFont.value).monospacedDigit().foregroundStyle(t.inkStrong)
                }
                Slider(value: $store.hoverDelay, in: 0.1...1.0, step: 0.05)
                    .tint(t.accent)
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
    }

    // MARK: 通知

    private func notificationSection(_ t: WarmTheme) -> some View {
        settingsCard(t, "通知", "bell.fill", Candy.coral) {
            VStack(alignment: .leading, spacing: 8) {
                SettingsToggleRow(
                    t: t, title: "完成时展开提醒", subtitle: "会话完成一轮时，灵动岛短暂展开绿色提示条",
                    isOn: $store.completionRevealEnabled)
                if store.completionRevealEnabled {
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
                    .padding(.leading, 4)
                }
            }
            Divider().overlay(t.track)
            SettingsToggleRow(
                t: t, title: "专注抑制",
                subtitle: "正盯着该会话的终端窗口时不自动展开（需已授权辅助功能，否则不生效）",
                isOn: $store.focusSuppressionEnabled)
        }
    }

    // MARK: 会话过滤

    private func filterSection(_ t: WarmTheme) -> some View {
        settingsCard(t, "会话过滤", "line.3.horizontal.decrease.circle.fill", Candy.teal) {
            filterGroup(
                t, title: "目录包含", kind: .directory,
                hint: "工作目录包含该文本的会话将被隐藏",
                placeholder: "例如 /experiments",
                userPatterns: store.userDirectoryPatterns)
            Divider().overlay(t.track).padding(.vertical, 2)
            filterGroup(
                t, title: "首条消息前缀", kind: .promptPrefix,
                hint: "首条消息以该前缀开头的会话将被隐藏",
                placeholder: "例如 <task-notification>",
                userPatterns: store.userPromptPrefixPatterns)
        }
    }

    @ViewBuilder
    private func filterGroup(
        _ t: WarmTheme, title: String, kind: SessionFilterPreset.Kind,
        hint: String, placeholder: String, userPatterns: [String]
    ) -> some View {
        let presets = SessionFilterPresets.all.filter { $0.kind == kind }
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(WFont.label.weight(.semibold)).foregroundStyle(t.inkStrong)
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
    private func settingsCard<Content: View>(
        _ t: WarmTheme, _ title: String, _ symbol: String, _ colors: [Color],
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                CandyIcon(symbol: symbol, colors: colors, size: 13)
                Text(title).font(WFont.section).foregroundStyle(t.inkStrong)
                    .textCase(nil).kerning(0.4)
            }
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
