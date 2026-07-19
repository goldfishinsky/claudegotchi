import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let store: SettingsStore
    private let sound: SoundController

    init(store: SettingsStore, sound: SoundController) {
        self.store = store
        self.sound = sound
    }

    func show() {
        store.refreshLaunchAtLogin()
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let size = NSSize(width: 640, height: 480)
        let win = Glass.window(SettingsView(store: store, sound: sound), size: size, title: "设置")
        win.minSize = size
        win.maxSize = size
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }
}
