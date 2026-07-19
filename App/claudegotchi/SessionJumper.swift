import AppKit
import ApplicationServices

// MARK: - known terminal hosts

enum TerminalHost {
    // Priority order used as a tie-break when several terminals are running and
    // none is frontmost. Bundle IDs of the hosts we can jump to.
    static let bundleIDs: [String] = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "com.github.wez.wezterm",
    ]
    static let fallbackBundleID = "com.apple.Terminal"
}

// MARK: - pure tier logic (unit-tested)

struct JumpContext: Equatable {
    let axTrusted: Bool
    let matchedWindowBundleID: String?
    let runningTerminalBundleIDs: [String]
}

enum JumpDecision: Equatable {
    case raiseWindow(bundleID: String)
    case activateApp(bundleID: String)
    case openInTerminal
}

protocol TerminalEnvironment {
    var axTrusted: Bool { get }
    func runningTerminalBundleIDs() -> [String]
    func windowBundleID(matching targets: [String]) -> String?
}

enum TerminalJumpPlanner {
    static func decide(_ ctx: JumpContext) -> JumpDecision {
        if ctx.axTrusted, let bundleID = ctx.matchedWindowBundleID {
            return .raiseWindow(bundleID: bundleID)
        }
        if let first = ctx.runningTerminalBundleIDs.first {
            return .activateApp(bundleID: first)
        }
        return .openInTerminal
    }

    static func plan(cwd: String, env: TerminalEnvironment) -> JumpDecision {
        let targets = matchTargets(cwd: cwd)
        let matched = env.axTrusted ? env.windowBundleID(matching: targets) : nil
        return decide(JumpContext(
            axTrusted: env.axTrusted,
            matchedWindowBundleID: matched,
            runningTerminalBundleIDs: env.runningTerminalBundleIDs()
        ))
    }

    /// Title probes derived from the cwd: the basename and the last two path
    /// components — terminal titles usually show one or the other.
    static func matchTargets(cwd: String) -> [String] {
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        let parts = trimmed.split(separator: "/").map(String.init)
        guard let last = parts.last else { return [] }
        var out = [last]
        if parts.count >= 2 { out.append(parts[parts.count - 2] + "/" + last) }
        return out
    }

    static func titleMatches(_ title: String, targets: [String]) -> Bool {
        let lower = title.lowercased()
        return targets.contains { !$0.isEmpty && lower.contains($0.lowercased()) }
    }

    static func shouldPromptAX(axTrusted: Bool, alreadyPrompted: Bool) -> Bool {
        !axTrusted && !alreadyPrompted
    }
}

// MARK: - live controller

@MainActor
final class SessionJumper {
    static let shared = SessionJumper()
    private let promptedKey = "claudegotchi.jumper.axPrompted"

    func jump(cwd: String) {
        guard !cwd.isEmpty else { return }
        let env = AppKitTerminalEnvironment()
        if TerminalJumpPlanner.shouldPromptAX(
            axTrusted: env.axTrusted,
            alreadyPrompted: UserDefaults.standard.bool(forKey: promptedKey)
        ) {
            UserDefaults.standard.set(true, forKey: promptedKey)
            presentAXSheet()
        }
        execute(TerminalJumpPlanner.plan(cwd: cwd, env: env), cwd: cwd, env: env)
    }

    private func execute(_ decision: JumpDecision, cwd: String, env: AppKitTerminalEnvironment) {
        switch decision {
        case .raiseWindow(let bundleID):
            env.raiseMatchedWindow()
            activate(bundleID: bundleID)
        case .activateApp(let bundleID):
            activate(bundleID: bundleID)
        case .openInTerminal:
            openInTerminal(cwd: cwd)
        }
    }

    private func activate(bundleID: String) {
        guard let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleID }) else { return }
        app.activate(options: [.activateIgnoringOtherApps])
    }

    private func openInTerminal(cwd: String) {
        let dir = URL(fileURLWithPath: cwd, isDirectory: true)
        let ws = NSWorkspace.shared
        if let term = ws.urlForApplication(withBundleIdentifier: TerminalHost.fallbackBundleID) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            ws.open([dir], withApplicationAt: term, configuration: config)
        } else {
            ws.open(dir)
        }
    }

    private func presentAXSheet() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "开启辅助功能授权"
        alert.informativeText = "授权后，claudegotchi 能直接跳到发起请求的那个终端窗口。未授权时，只会把终端应用切到前台。"
        alert.addButton(withTitle: "打开设置")
        alert.addButton(withTitle: "以后再说")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - AppKit-backed environment (thin AX/NSWorkspace glue)

final class AppKitTerminalEnvironment: TerminalEnvironment {
    private var matched: (window: AXUIElement, app: NSRunningApplication)?

    var axTrusted: Bool { AXIsProcessTrusted() }

    func runningTerminalBundleIDs() -> [String] {
        let known = TerminalHost.bundleIDs
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        var ordered: [String] = []
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           known.contains(front) {
            ordered.append(front)
        }
        for id in known where running.contains(id) && !ordered.contains(id) { ordered.append(id) }
        return ordered
    }

    func windowBundleID(matching targets: [String]) -> String? {
        guard axTrusted, !targets.isEmpty else { return nil }
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier.map(TerminalHost.bundleIDs.contains) ?? false
        }
        for app in apps {
            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let windows = windowsRef as? [AXUIElement] else { continue }
            for window in windows {
                var titleRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
                      let title = titleRef as? String else { continue }
                if TerminalJumpPlanner.titleMatches(title, targets: targets) {
                    matched = (window, app)
                    return app.bundleIdentifier
                }
            }
        }
        return nil
    }

    func raiseMatchedWindow() {
        guard let matched else { return }
        AXUIElementSetAttributeValue(matched.window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(matched.window, kAXRaiseAction as CFString)
    }
}
