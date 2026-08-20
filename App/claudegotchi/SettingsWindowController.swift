import AppKit
import SwiftUI
import GRDB
import PetCore

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let store: SettingsStore
    private let sound: SoundController
    private let db: DatabaseQueue
    private let syncDriver: LeaderboardSyncDriver
    private let watcher: PRWatcher
    private let leaderboard: LeaderboardService
    private let config: ConfigYAML
    private let github: GitHubClient
    private let git: GitRunner
    private let selection = SettingsSelection()

    init(
        store: SettingsStore, sound: SoundController, db: DatabaseQueue,
        syncDriver: LeaderboardSyncDriver, watcher: PRWatcher,
        leaderboard: LeaderboardService,
        config: ConfigYAML, github: GitHubClient, git: GitRunner
    ) {
        self.store = store
        self.sound = sound
        self.db = db
        self.syncDriver = syncDriver
        self.watcher = watcher
        self.leaderboard = leaderboard
        self.config = config
        self.github = github
        self.git = git
    }

    func show(tab: SettingsTab? = nil) {
        if let tab { selection.tab = tab }
        store.refreshLaunchAtLogin()
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let size = NSSize(width: 640, height: 480)
        let root = SettingsView(
            store: store, selection: selection, syncDriver: syncDriver, watcher: watcher,
            sound: sound, db: db, leaderboard: leaderboard,
            config: config, github: github, git: git
        )
        let win = Glass.window(root, size: size, title: "设置")
        win.minSize = size
        win.maxSize = size
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }
}
