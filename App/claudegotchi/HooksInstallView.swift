import SwiftUI
import AppKit
import PetCore

@MainActor
final class HooksInstallModel: ObservableObject {
    @Published private(set) var status: HookInstallStatus = .notInstalled
    @Published private(set) var statusText: String = "未安装"
    @Published private(set) var codexStatus: HookInstallStatus = .notInstalled
    @Published private(set) var codexStatusText: String = "未安装"
    @Published private(set) var helperAvailable: Bool = true
    @Published private(set) var lastError: String?

    private let settingsURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")

    private let codexSettingsURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/hooks.json")

    private let stableBinURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("claudegotchi/bin/claudegotchi-hook")

    private var bundledHelperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/claudegotchi-hook")
    }

    func refresh() {
        helperAvailable = FileManager.default.fileExists(atPath: bundledHelperURL.path)
        do {
            status = try HooksInstaller.status(settingsPath: settingsURL)
        } catch {
            status = .notInstalled
            lastError = "读取 settings.json 失败：\(error.localizedDescription)"
        }
        codexStatus = (try? HooksInstaller.status(platform: .codex, settingsPath: codexSettingsURL)) ?? .notInstalled
        statusText = label(for: status)
        codexStatusText = label(for: codexStatus)
        if !helperAvailable { statusText = "helper 缺失，请重装 app" }
    }

    func install() {
        lastError = nil
        guard stageHelper() else { return }
        do {
            try HooksInstaller.install(settingsPath: settingsURL,
                                       hookBinaryPath: stableBinURL.path,
                                       nowISO: ISO8601DateFormatter().string(from: Date()))
        } catch {
            lastError = "安装失败：\(error.localizedDescription)"
        }
        refresh()
    }

    func installCodex() {
        lastError = nil
        guard stageHelper() else { return }
        do {
            try HooksInstaller.install(platform: .codex, settingsPath: codexSettingsURL,
                                       hookBinaryPath: stableBinURL.path,
                                       nowISO: ISO8601DateFormatter().string(from: Date()))
        } catch {
            lastError = "Codex 安装失败：\(error.localizedDescription)"
        }
        refresh()
    }

    func uninstall() {
        lastError = nil
        do {
            try HooksInstaller.uninstall(settingsPath: settingsURL)
        } catch {
            lastError = "卸载失败：\(error.localizedDescription)"
        }
        removeBinIfUnused()
        refresh()
    }

    func uninstallCodex() {
        lastError = nil
        do {
            try HooksInstaller.uninstall(platform: .codex, settingsPath: codexSettingsURL)
        } catch {
            lastError = "Codex 卸载失败：\(error.localizedDescription)"
        }
        removeBinIfUnused()
        refresh()
    }

    private func stageHelper() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: bundledHelperURL.path) else {
            helperAvailable = false
            statusText = "helper 缺失，请重装 app"
            return false
        }
        do {
            try fm.createDirectory(at: stableBinURL.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            if fm.fileExists(atPath: stableBinURL.path) {
                try fm.removeItem(at: stableBinURL)
            }
            try fm.copyItem(at: bundledHelperURL, to: stableBinURL)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stableBinURL.path)
            clearQuarantine(stableBinURL)
            return true
        } catch {
            lastError = "安装失败：\(error.localizedDescription)"
            return false
        }
    }

    private func removeBinIfUnused() {
        let claudeGone = (try? HooksInstaller.status(settingsPath: settingsURL)) == .notInstalled
        let codexGone = (try? HooksInstaller.status(platform: .codex, settingsPath: codexSettingsURL)) == .notInstalled
        if claudeGone && codexGone {
            try? FileManager.default.removeItem(at: stableBinURL)
        }
    }

    private func clearQuarantine(_ url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        p.arguments = ["-d", "com.apple.quarantine", url.path]
        p.standardError = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    private func label(for status: HookInstallStatus) -> String {
        switch status {
        case .installed: return "已安装"
        case .partiallyInstalled: return "部分安装（建议重新安装）"
        case .notInstalled: return "未安装"
        }
    }
}

struct HooksInstallView: View {
    @StateObject private var model = HooksInstallModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = WarmTheme(scheme: scheme)
        return VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    claudeSection(t)
                    Divider().overlay(t.inkFaint.opacity(0.3))
                    codexSection(t)
                    if let err = model.lastError {
                        Text(err)
                            .font(WFont.caption)
                            .foregroundStyle(t.danger)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
            }
            .frame(maxHeight: 480)

            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(WarmButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 340)
        .background(t.windowFill.ignoresSafeArea())
        .onAppear { model.refresh() }
    }

    private func claudeSection(_ t: WarmTheme) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(t, "Claude Code 钩子", model.statusText, installed: model.status == .installed)
            Text("安装后，Claude Code 的使用会喂养宠物。")
                .font(WFont.body)
                .foregroundStyle(t.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(model.status == .notInstalled ? "安装钩子" : "重新安装") { model.install() }
                    .buttonStyle(WarmButtonStyle(prominent: true))
                    .disabled(!model.helperAvailable)
                Button("卸载") { model.uninstall() }
                    .buttonStyle(WarmButtonStyle())
                    .disabled(model.status == .notInstalled)
            }
        }
    }

    private func codexSection(_ t: WarmTheme) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(t, "Codex 钩子", model.codexStatusText, installed: model.codexStatus == .installed)
            Text("安装后，OpenAI Codex 的会话会喂养宠物，并自动出现在 agent 列表与灵动岛提醒中。")
                .font(WFont.body)
                .foregroundStyle(t.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(model.codexStatus == .notInstalled ? "安装钩子" : "重新安装") { model.installCodex() }
                    .buttonStyle(WarmButtonStyle(prominent: true))
                    .disabled(!model.helperAvailable)
                Button("卸载") { model.uninstallCodex() }
                    .buttonStyle(WarmButtonStyle())
                    .disabled(model.codexStatus == .notInstalled)
            }
            if model.codexStatus != .notInstalled {
                trustStep(t)
            }
        }
    }

    private func trustStep(_ t: WarmTheme) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最后一步：在 Codex 中信任钩子")
                .font(WFont.label).foregroundStyle(t.inkStrong)
            trustLine(t, "1.", "打开终端运行", command: "codex")
            trustLine(t, "2.", "在会话里输入", command: "/hooks")
            trustLine(t, "3.", "选中 claudegotchi 条目", command: nil)
            trustLine(t, "4.", "按 t 信任（Codex 不允许程序自动信任）", command: nil)
            Text("信任后，新的 Codex 会话会自动被追踪，无需其它操作。")
                .font(WFont.caption).foregroundStyle(t.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(rgb(0.72, 0.57, 1.0).opacity(0.12)))
    }

    private func trustLine(_ t: WarmTheme, _ index: String, _ text: String, command: String?) -> some View {
        HStack(spacing: 6) {
            Text(index).font(WFont.caption).monospacedDigit().foregroundStyle(t.inkFaint)
                .frame(width: 14, alignment: .leading)
            Text(text).font(WFont.caption).foregroundStyle(t.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let command {
                Text(command)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(t.inkStrong)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(t.panelFill))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 9))
                        .foregroundStyle(t.inkFaint)
                }
                .buttonStyle(.plain)
                .help("复制")
            }
            Spacer(minLength: 0)
        }
    }

    private func sectionHeader(_ t: WarmTheme, _ title: String, _ status: String, installed: Bool) -> some View {
        HStack(spacing: 8) {
            Text(title).font(WFont.title).foregroundStyle(t.inkStrong)
            Spacer()
            Text(status)
                .font(WFont.caption)
                .foregroundStyle(installed ? t.good : t.inkFaint)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}
