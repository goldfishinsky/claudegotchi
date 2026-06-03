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

/// The app's single composition root. Owns the one shared DatabaseQueue and
/// EventApplier (§3 shared-instance invariant): SpoolWatcher, PRWatcher, and
/// FixCoordinator all reuse these, never constructing fresh ones, so the
/// in-memory pending tracker and write serialization stay coherent.
@MainActor
final class AppServices {
    let db: DatabaseQueue
    let config: ConfigYAML
    let applier: EventApplier
    let spool: SpoolWatcher
    let watcher: PRWatcher
    let coordinator: FixCoordinator

    private var paused = false

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

        spool = SpoolWatcher(
            db: db, applier: applier,
            spoolURL: support.appendingPathComponent("spool.jsonl"),
            spoolLockURL: support.appendingPathComponent("spool.lock"),
            pausedProvider: { false },
            config: config
        )

        watcher = PRWatcher(db: db, applier: applier, github: github, config: config)

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
    }

    /// Order matters: reconcile stale/queued fix jobs (and clean their worktrees)
    /// BEFORE the watcher starts polling or any new fix is enqueued, so a crash
    /// can't leave a registered worktree blocking the next job. Spec §8.
    func start() {
        coordinator.reconcileOnLaunch()
        try? spool.pump()
        watcher.start()
    }

    /// Spec §8: terminate every live fix child via its process group on quit.
    func terminate() {
        watcher.stop()
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var services: AppServices?
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let services = try? AppServices() else { return }
        self.services = services
        services.start()
        showWorkbench(services)
    }

    func applicationWillTerminate(_ notification: Notification) {
        services?.terminate()
    }

    private func showWorkbench(_ services: AppServices) {
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
        win.center()
        win.makeKeyAndOrderFront(nil)
        window = win
    }
}
