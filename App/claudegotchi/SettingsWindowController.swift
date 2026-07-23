import AppKit
import SwiftUI
import GRDB

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let store: SettingsStore
    private let sound: SoundController
    private let db: DatabaseQueue

    init(store: SettingsStore, sound: SoundController, db: DatabaseQueue) {
        self.store = store
        self.sound = sound
        self.db = db
    }

    func show() {
        store.refreshLaunchAtLogin()
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let size = NSSize(width: 640, height: 480)
        let win = Glass.window(SettingsView(store: store, sound: sound, db: db), size: size, title: "设置")
        win.minSize = size
        win.maxSize = size
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }
}
