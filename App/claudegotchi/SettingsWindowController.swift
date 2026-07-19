import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let store: SettingsStore

    init(store: SettingsStore) { self.store = store }

    func show() {
        store.refreshLaunchAtLogin()
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = Glass.window(SettingsView(store: store),
                               size: NSSize(width: 520, height: 640), title: "设置")
        win.minSize = NSSize(width: 480, height: 420)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }
}
