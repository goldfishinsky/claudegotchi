import SwiftUI
import AppKit
import GRDB
import PetCore

@main
struct claudegotchiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// Lock-guarded boolean shared between the main actor (toggle) and the
/// watcher background queues that read it via `pausedProvider`.
final class PauseFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return flag }
        set { lock.lock(); flag = newValue; lock.unlock() }
    }
}

/// The app's single composition root. Owns the one shared DatabaseQueue and
/// EventApplier (§3 shared-instance invariant): SpoolWatcher, PRWatcher, and
/// FixCoordinator all reuse these, never constructing fresh ones, so the
/// in-memory pending tracker and write serialization stay coherent.
@MainActor
final class AppServices: ObservableObject {
    let db: DatabaseQueue
    let config: ConfigYAML
    let applier: EventApplier
    let spool: SpoolWatcher
    let watcher: PRWatcher
    let coordinator: FixCoordinator
    let midnight: MidnightDriver

    /// Thread-safe pause flag shared by both watchers (§7 pause semantics):
    /// while paused, synthetic PR nudges and hook events are still written and
    /// the watermark advances, but the applier is skipped. Read off background
    /// queues (PRWatcher pollQueue, SpoolWatcher FSEvents callback).
    private nonisolated let pauseFlag = PauseFlag()
    @Published private(set) var paused = false

    func setPaused(_ value: Bool) {
        pauseFlag.value = value
        paused = value
    }

    init() throws {
        let support = AppServices.supportDir()
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        let dbURL = support.appendingPathComponent("pet.sqlite")
        db = try Database.open(at: dbURL.path)

        config = AppServices.loadConfig(support: support)
        applier = EventApplier(config: config)

        let processRunner = SystemProcessRunner()
        let github = GHCLIClient(runner: processRunner)
        let git = CLIGitRunner(runner: processRunner)
        let claude = CLIClaudeRunner(runner: processRunner)

        // Both watchers read the same flag instance; no `self` capture needed.
        let flag = pauseFlag
        let pausedRef: () -> Bool = { flag.value }

        spool = SpoolWatcher(
            db: db, applier: applier,
            spoolURL: support.appendingPathComponent("spool.jsonl"),
            spoolLockURL: support.appendingPathComponent("spool.lock"),
            pausedProvider: pausedRef,
            config: config
        )

        watcher = PRWatcher(db: db, applier: applier, github: github, config: config,
                            pausedProvider: pausedRef)

        let worktreesRoot = support.appendingPathComponent("worktrees", isDirectory: true)
        let sharedDB = db
        let sharedConfig = config
        coordinator = FixCoordinator(
            db: db,
            makeRunner: {
                FixRunner(git: git, claude: claude, gh: github,
                          db: sharedDB, config: sharedConfig, worktreesRoot: worktreesRoot)
            },
            git: git,
            config: config
        )

        midnight = MidnightDriver(db: db, config: config)
    }

    /// Order matters: reconcile stale/queued fix jobs (and clean their worktrees)
    /// BEFORE the watcher starts polling or any new fix is enqueued, so a crash
    /// can't leave a registered worktree blocking the next job. Spec §8.
    func start() {
        coordinator.reconcileOnLaunch()
        try? spool.pump()
        spool.startWatching()
        watcher.start()
        midnight.start()
    }

    /// Spec §8: terminate every live fix child via its process group on quit.
    func terminate() {
        midnight.stop()
        watcher.stop()
        spool.stopWatching()
        coordinator.terminateAll()
    }

    private static func supportDir() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("claudegotchi", isDirectory: true)
    }

    private static func loadConfig(support: URL) -> ConfigYAML {
        let url = support.appendingPathComponent("config.yaml")
        return (try? ConfigYAML.load(from: url)) ?? .defaults
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var services: AppServices?
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var workPanelModel: WorkPanelModel?
    private var panelRefreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let services = try? AppServices() else { return }
        self.services = services
        services.start()
        installMenuBar(services)
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelRefreshTimer?.invalidate()
        services?.terminate()
    }

    // MARK: Menu-bar dropdown (spec §1/§10)

    private func installMenuBar(_ services: AppServices) {
        let model = WorkPanelModel(db: services.db, config: services.config)
        workPanelModel = model

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🐤"
        item.button?.action = #selector(togglePopover(_:))
        item.button?.target = self
        statusItem = item

        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentSize = NSSize(width: 276, height: 240)
        pop.contentViewController = NSHostingController(
            rootView: WorkPanelRoot(
                model: model,
                services: services,
                onOpenWorktable: { [weak self] in
                    self?.popover?.performClose(nil)
                    self?.showWorkbench(services)
                }
            )
        )
        popover = pop

        refreshWorkPanel()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWorkPanel() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        panelRefreshTimer = timer
    }

    private func refreshWorkPanel() {
        guard let model = workPanelModel, let services = services else { return }
        model.refresh(firstPollComplete: services.watcher.snapshot.firstPollComplete)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let pop = popover, let button = statusItem?.button else { return }
        if pop.isShown {
            pop.performClose(sender)
        } else {
            refreshWorkPanel()
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func showWorkbench(_ services: AppServices) {
        if let win = window {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = PRTabView(
            watcher: services.watcher,
            coordinator: services.coordinator,
            db: services.db,
            config: services.config
        )
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        win.title = "claudegotchi"
        win.contentView = NSHostingView(rootView: root)
        win.isReleasedWhenClosed = false
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }
}

/// Hosts the dropdown 工作 section plus a pause toggle so the §7 pause gate is
/// reachable from the menu bar (the toggle is the thing that mutates
/// `AppServices.paused`, which both watchers read via `pausedProvider`).
private struct WorkPanelRoot: View {
    @ObservedObject var model: WorkPanelModel
    @ObservedObject var services: AppServices
    var onOpenWorktable: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            WorkPanelView(model: model, onOpenWorktable: onOpenWorktable)
            Divider()
            Toggle(isOn: Binding(
                get: { services.paused },
                set: { services.setPaused($0) }
            )) {
                Text("暂停宠物耦合").font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(width: 276)
    }
}
