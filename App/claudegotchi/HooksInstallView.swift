import SwiftUI
import AppKit
import PetCore

@MainActor
final class HooksInstallModel: ObservableObject {
    @Published private(set) var status: HookInstallStatus = .notInstalled
    @Published private(set) var statusText: String = "未安装"
    @Published private(set) var helperAvailable: Bool = true
    @Published private(set) var lastError: String?

    private let settingsURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")

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
        statusText = label(for: status)
        if !helperAvailable { statusText = "helper 缺失，请重装 app" }
    }

    func install() {
        lastError = nil
        let fm = FileManager.default
        guard fm.fileExists(atPath: bundledHelperURL.path) else {
            helperAvailable = false
            statusText = "helper 缺失，请重装 app"
            return
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

            let nowISO = ISO8601DateFormatter().string(from: Date())
            try HooksInstaller.install(settingsPath: settingsURL,
                                       hookBinaryPath: stableBinURL.path,
                                       nowISO: nowISO)
        } catch {
            lastError = "安装失败：\(error.localizedDescription)"
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
        try? FileManager.default.removeItem(at: stableBinURL)
        refresh()
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
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Claude Code 钩子")
                    .font(WFont.title).foregroundStyle(t.inkStrong)
                Spacer()
                Text(model.statusText)
                    .font(WFont.caption)
                    .foregroundStyle(model.status == .installed ? t.good : t.inkFaint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Text("安装后，Claude Code 的使用会喂养宠物。")
                .font(WFont.body)
                .foregroundStyle(t.ink)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(model.status == .notInstalled ? "安装钩子" : "重新安装") {
                    model.install()
                }
                .buttonStyle(WarmButtonStyle(prominent: true))
                .disabled(!model.helperAvailable)

                Button("卸载") { model.uninstall() }
                    .buttonStyle(WarmButtonStyle())
                    .disabled(model.status == .notInstalled)
            }

            if let err = model.lastError {
                Text(err)
                    .font(WFont.caption)
                    .foregroundStyle(t.danger)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(WarmButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(t.windowFill.ignoresSafeArea())
        .onAppear { model.refresh() }
    }
}
