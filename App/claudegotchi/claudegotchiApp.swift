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
    let github: GitHubClient
    let git: GitRunner
    let coordinator: FixCoordinator
    let midnight: MidnightDriver
    let tick: TickDriver
    let leaderboard: LeaderboardService
    let syncDriver: LeaderboardSyncDriver
    let systemStats: SystemStatsDriver
    let claudeUsage: ClaudeUsageDriver
    let thermal: ThermalMonitor

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
        github = GHCLIClient(runner: processRunner)
        git = CLIGitRunner(runner: processRunner)
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
            makeRunner: { [git, github] in
                FixRunner(git: git, claude: claude, gh: github,
                          db: sharedDB, config: sharedConfig, worktreesRoot: worktreesRoot)
            },
            git: git,
            config: config
        )

        let resolvedLeaderboard = config.resolvedLeaderboard
        let leaderboardClient = HTTPLeaderboardClient(
            transport: URLSessionTransport(),
            baseURL: URL(string: resolvedLeaderboard.baseURL)
                ?? URL(string: ConfigYAML.placeholderLeaderboardBaseURL)!,
            githubClientID: resolvedLeaderboard.githubClientID
        )
        leaderboard = leaderboardClient
        let sync = LeaderboardSyncDriver(
            db: db, service: leaderboardClient,
            credentials: KeychainCredentialsStore(),
            syncIntervalSeconds: resolvedLeaderboard.syncIntervalSeconds
        )
        syncDriver = sync

        let sharedDB2 = db
        midnight = MidnightDriver(db: db, config: config, onDeath: {
            try? HatchService.ensureAlive(sharedDB2, nowMs: Int64(Date().timeIntervalSince1970 * 1000))
            postPetDidChange()
            Task { @MainActor in sync.syncNow() }
        })

        tick = TickDriver(db: db, applier: applier, config: config, pausedProvider: pausedRef)

        let shotHist = ProcessInfo.processInfo.environment["CGSHOT"] != nil ? 2 : 10
        systemStats = SystemStatsDriver(historyEveryTicks: shotHist)
        claudeUsage = ClaudeUsageDriver()
        thermal = ThermalMonitor()
    }

    /// Order matters: reconcile stale/queued fix jobs (and clean their worktrees)
    /// BEFORE the watcher starts polling or any new fix is enqueued, so a crash
    /// can't leave a registered worktree blocking the next job. Spec §8.
    func start() {
        coordinator.reconcileOnLaunch()
        try? HatchService.ensureAlive(db, nowMs: Int64(Date().timeIntervalSince1970 * 1000))
        try? spool.pump()
        spool.startWatching()
        watcher.start()
        midnight.start()
        tick.start()
        syncDriver.start()
        thermal.start()
    }

    /// Spec §8: terminate every live fix child via its process group on quit.
    func terminate() {
        thermal.stop()
        syncDriver.stop()
        tick.stop()
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
    private var statsSelection: StatsSelection?
    private var statusItem: NSStatusItem?
    private var dropdown: MenuDropdownController?
    private var petPanelModel: PetPanelModel?
    private var agentActivityModel: AgentActivityModel?
    private var islandModel: IslandModel?
    private var islandController: NotchIslandController?
    private var floatingPetController: FloatingPetController?
    private var activePetDisplayMode: PetDisplayMode?
    private var settings: SettingsStore?
    private var sound: SoundController?
    private var settingsWindow: SettingsWindowController?
    private var panelRefreshTimer: Timer?
    private var iconTimer: Timer?
    private var petChangeObserver: NSObjectProtocol?

    private var shotWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let services = try? AppServices() else { return }
        self.services = services
        services.start()
        installMenuBar(services)
        if let mode = ProcessInfo.processInfo.environment["CGSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.presentScreenshotHarness(mode)
            }
        }
    }

    private func presentScreenshotHarness(_ mode: String) {
        guard let services, let petModel = petPanelModel, let agentModel = agentActivityModel else { return }
        services.systemStats.start()
        if mode == "settings" {
            settingsWindow?.show(tab: .general)
            return
        }
        let statsTabs: [String: StatsTab] = [
            "overview": .overview, "system": .system, "models": .models,
            "growth": .growth, "work": .work, "leaderboard": .leaderboard,
        ]
        if let tab = statsTabs[mode] {
            openStats(services, select: tab)
            return
        }
        let card = DropdownCard(
            petModel: petModel, agentModel: agentModel,
            driver: services.systemStats, usageDriver: services.claudeUsage,
            onOpenStats: {}, onOpenSystemStats: {},
            onOpenSettings: {}, onJump: { _ in })
        let hosting = NSHostingController(rootView: card)
        hosting.view.layoutSubtreeIfNeeded()
        let size = hosting.view.fittingSize
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.contentViewController = hosting
        win.isOpaque = false
        win.backgroundColor = .clear
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        shotWindow = win
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelRefreshTimer?.invalidate()
        iconTimer?.invalidate()
        if let petChangeObserver { NotificationCenter.default.removeObserver(petChangeObserver) }
        islandController?.stop()
        floatingPetController?.stop()
        dropdown?.hide()
        services?.terminate()
    }

    // MARK: Menu-bar dropdown (spec §1/§10)

    private func installMenuBar(_ services: AppServices) {
        let petModel = PetPanelModel(db: services.db, config: services.config)
        let statsDriver = services.systemStats
        petModel.systemMemPressure = { [weak statsDriver] in
            guard let statsDriver, statsDriver.isRunning else { return nil }
            return statsDriver.snapshot?.memPressure
        }
        let thermalMonitor = services.thermal
        petModel.systemThermal = { [weak thermalMonitor] in thermalMonitor?.tier }
        petPanelModel = petModel
        let settingsStore = SettingsStore()
        settings = settingsStore
        let island = IslandModel(db: services.db, notchAvailable: NotchGeometry.builtInNotch() != nil)
        islandModel = island
        let soundController = SoundController(settings: settingsStore)
        sound = soundController
        petModel.theaterSound = { [weak soundController] scene, nowMs in
            soundController?.theaterScene(scene, nowMs: nowMs)
        }
        settingsWindow = SettingsWindowController(
            store: settingsStore,
            sound: soundController,
            db: services.db,
            syncDriver: services.syncDriver,
            watcher: services.watcher,
            leaderboard: services.leaderboard,
            config: services.config,
            github: services.github,
            git: services.git
        )

        let agentModel = AgentActivityModel(db: services.db)
        agentModel.filterProvider = { [weak settingsStore] in settingsStore?.sessionFilter ?? .empty }
        agentActivityModel = agentModel

        services.claudeUsage.isEnabled = { [weak settingsStore] in
            settingsStore?.showSubscriptionUsage ?? false
        }

        settingsStore.onChange = { [weak self] in
            MainActor.assumeIsolated {
                self?.agentActivityModel?.refresh()
                self?.islandController?.refresh()
                self?.applyPetDisplayMode()
                self?.syncUsageDriver()
            }
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = ""
        item.button?.action = #selector(toggleDropdown(_:))
        item.button?.target = self
        statusItem = item

        let usageDriver = services.claudeUsage
        dropdown = MenuDropdownController(
            driver: statsDriver, usageDriver: usageDriver, petModel: petModel
        ) {
            AnyView(DropdownCard(
                petModel: petModel,
                agentModel: agentModel,
                driver: statsDriver,
                usageDriver: usageDriver,
                onOpenStats: { [weak self] in
                    self?.dropdown?.hide()
                    self?.openStats(services, select: .overview)
                },
                onOpenSystemStats: { [weak self] in
                    self?.dropdown?.hide()
                    self?.openStats(services, select: .system)
                },
                onOpenSettings: { [weak self] in
                    self?.dropdown?.hide()
                    self?.settingsWindow?.show()
                },
                onJump: { [weak self] agent in
                    self?.dropdown?.hide()
                    self?.jumpToAgent(agent, db: services.db)
                },
                onHeightChange: { [weak self] h in
                    self?.dropdown?.setContentHeight(h)
                },
                onPetFrameChange: { [weak self] rect in
                    self?.dropdown?.setPetHitRect(rect)
                }
            ))
        }

        if let dropdown {
            let controller = NotchIslandController(
                dropdown: dropdown, petModel: petModel, agentModel: agentModel, island: island,
                db: services.db, settings: settingsStore, sound: soundController
            )
            islandController = controller
            controller.onPresenceChange = { [weak self] in self?.syncStatusItemVisibility() }
        }
        let floatingPet = FloatingPetController(
            petModel: petModel,
            agentModel: agentModel,
            onJumpAgent: { [weak self] agent in self?.jumpToAgent(agent, db: services.db) },
            onReturnToIsland: { [weak settingsStore] in
                settingsStore?.petDisplayMode = .island
            },
            onOpenSettings: { [weak self] in self?.settingsWindow?.show() }
        )
        floatingPetController = floatingPet
        islandController?.onPetDraggedOut = { [weak settingsStore, weak floatingPet] point in
            floatingPet?.placeCentered(at: point)
            settingsStore?.petDisplayMode = .floating
        }
        dropdown?.onPetDraggedOut = { [weak settingsStore, weak floatingPet] point in
            floatingPet?.placeCentered(at: point)
            settingsStore?.petDisplayMode = .floating
        }
        applyPetDisplayMode()
        syncStatusItemVisibility()

        refreshPanels()
        redrawStatusIcon()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPanels() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        panelRefreshTimer = timer

        let icon = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.redrawStatusIcon() }
        }
        icon.tolerance = 1
        RunLoop.main.add(icon, forMode: .common)
        iconTimer = icon

        petChangeObserver = NotificationCenter.default.addObserver(
            forName: .claudegotchiPetDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshPanels()
                self?.redrawStatusIcon()
            }
        }
    }

    private func jumpToAgent(_ agent: AgentActivity, db: DatabaseQueue) {
        if agent.isCodex, SessionJumper.shared.jumpToCodex(sessionId: agent.sessionId) { return }
        let tty = (try? TTYAnchor.stored(db: db, sessionId: agent.sessionId)) ?? nil
        SessionJumper.shared.jump(
            cwd: agent.cwd ?? "",
            tty: tty,
            markerToken: TitleMarker.token(forSessionId: agent.sessionId)
        )
    }

    /// The status item and the island are mutually exclusive: the menu-bar icon
    /// shows only while the island is absent (no notch, or island disabled). The
    /// island's auto-hide (no sessions) keeps the panel present, so the status
    /// item stays hidden through it.
    private func syncStatusItemVisibility() {
        statusItem?.isVisible = !(islandController?.isPresent ?? false)
    }

    /// Exactly one pet presentation is active. On Macs without a built-in notch,
    /// the floating pet is the useful fallback even if an older preference says
    /// "island".
    private func applyPetDisplayMode() {
        guard let settings, let islandModel, let islandController, let floatingPetController else { return }
        let desired: PetDisplayMode = settings.petDisplayMode == .island && islandModel.notchAvailable
            ? .island
            : .floating
        guard desired != activePetDisplayMode else { return }
        activePetDisplayMode = desired
        switch desired {
        case .island:
            floatingPetController.stop()
            islandController.setEnabled(true)
        case .floating:
            islandController.setEnabled(false)
            floatingPetController.start()
        }
        syncStatusItemVisibility()
    }

    /// Opting out of 「显示订阅用量」 drops the keychain-reading poller and any last
    /// reading at once; opting in while the card is open starts it immediately.
    private func syncUsageDriver() {
        guard let driver = services?.claudeUsage else { return }
        if settings?.showSubscriptionUsage == true {
            if dropdown?.isVisible == true { driver.start() }
        } else {
            driver.stopAndClear()
        }
    }

    private func refreshPanels() {
        guard services != nil else { return }
        petPanelModel?.refresh()
        agentActivityModel?.refresh()
        islandController?.refresh()
        if let agents = agentActivityModel?.agents { sound?.observeSessions(agents.map(\.sessionId)) }
        if let level = petPanelModel?.level { sound?.observeLevel(level) }
    }

    private func redrawStatusIcon() {
        guard let services = services,
              let pet = try? Pet.fetchAlive(from: services.db) else { return }
        let tier = WorkPressure.tier((try? PRStore.allPRs(in: services.db)) ?? [], config: services.config)
        let visual = PetMood.derive(pet: pet, pressure: tier)
        let image = PixelPetRenderer.renderToNSImage(
            visual: visual, species: pet.species, size: 18, genome: pet.genome)
        image.isTemplate = false
        statusItem?.button?.image = image
    }

    @objc private func toggleDropdown(_ sender: Any?) {
        guard let dropdown, let button = statusItem?.button else { return }
        if !dropdown.isVisible { refreshPanels() }
        dropdown.toggle(relativeTo: button)
    }

    private func openStats(_ services: AppServices, select tab: StatsTab) {
        if let win = window {
            statsSelection?.tab = tab
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let holder = StatsSelection(tab)
        statsSelection = holder
        let root = StatsWindowView(
            selection: holder,
            watcher: services.watcher,
            coordinator: services.coordinator,
            syncDriver: services.syncDriver,
            systemStats: services.systemStats,
            db: services.db,
            leaderboard: services.leaderboard,
            onOpenIntegrationSettings: { [weak self] in
                self?.settingsWindow?.show(tab: .integrations)
            }
        )
        let win = Glass.window(root, size: NSSize(width: 720, height: 600), title: "claudegotchi")
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }
}
