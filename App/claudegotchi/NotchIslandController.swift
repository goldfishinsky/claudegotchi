import AppKit
import SwiftUI
import GRDB
import PetCore

enum IslandMetric {
    static let pillWidth: CGFloat = 56
    static let stripWidth: CGFloat = 150
    static let corner: CGFloat = 10
}

// MARK: - notch geometry

struct NotchGeometry {
    let screen: NSScreen
    let islandFrame: NSRect

    /// The built-in notched display, if any: `safeAreaInsets.top > 0` is present
    /// only on the notched built-in panel (external displays never have a notch).
    /// The pill hugs the notch's right edge, top flush with the screen top,
    /// height = the menu-bar band.
    static func builtInNotch(pillWidth: CGFloat = IslandMetric.pillWidth) -> NotchGeometry? {
        for screen in NSScreen.screens {
            let menuBarHeight = screen.safeAreaInsets.top
            guard menuBarHeight > 0, let auxRight = screen.auxiliaryTopRightArea else { continue }
            let frame = NSRect(
                x: auxRight.minX, y: screen.frame.maxY - menuBarHeight,
                width: pillWidth, height: menuBarHeight
            )
            return NotchGeometry(screen: screen, islandFrame: frame)
        }
        return nil
    }
}

// MARK: - model

@MainActor
final class IslandModel: ObservableObject {
    @Published private(set) var pendingPermission: PermissionRequest?
    @Published private(set) var enabled: Bool

    let notchAvailable: Bool
    private let db: DatabaseQueue
    private let alertWindowMs: Int64
    static let enabledKey = "claudegotchi.island.enabled"

    init(db: DatabaseQueue, notchAvailable: Bool, alertWindowMs: Int64 = 60_000) {
        self.db = db
        self.notchAvailable = notchAvailable
        self.alertWindowMs = alertWindowMs
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.enabledKey) == nil { defaults.set(true, forKey: Self.enabledKey) }
        enabled = defaults.bool(forKey: Self.enabledKey)
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        UserDefaults.standard.set(value, forKey: Self.enabledKey)
    }

    /// Freshest unanswered permission request ≤ `alertWindowMs` old; nil clears
    /// the strip (superseded, or aged past the auto-dismiss window).
    func refresh() {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let next = (try? PermissionWatch.pending(db: db, nowMs: nowMs, maxAgeMs: alertWindowMs))?.first
        if next != pendingPermission { pendingPermission = next }
    }
}

// MARK: - island view

struct NotchIslandView: View {
    @ObservedObject var petModel: PetPanelModel
    @ObservedObject var agentModel: AgentActivityModel
    @ObservedObject var island: IslandModel
    let height: CGFloat
    var onHover: (Bool) -> Void
    var onClick: () -> Void
    var onAlertClick: (PermissionRequest) -> Void

    private var theme: WarmTheme { WarmTheme(scheme: .dark) }

    var body: some View {
        HStack(spacing: 0) {
            pill
            if let req = island.pendingPermission { strip(req) }
        }
        .frame(height: height)
        .background(
            UnevenRoundedRectangle(
                bottomLeadingRadius: IslandMetric.corner, bottomTrailingRadius: IslandMetric.corner,
                style: .continuous
            )
            .fill(Color.black)
        )
        .clipShape(UnevenRoundedRectangle(
            bottomLeadingRadius: IslandMetric.corner, bottomTrailingRadius: IslandMetric.corner,
            style: .continuous
        ))
        .onHover { onHover($0) }
    }

    private var pill: some View {
        ZStack {
            miniTheater
            if agentModel.agents.count > 0 { badge }
        }
        .frame(width: IslandMetric.pillWidth, height: height)
        .contentShape(Rectangle())
        .onTapGesture { onClick() }
    }

    @ViewBuilder
    private var miniTheater: some View {
        let alert = island.pendingPermission != nil
        Group {
            if let visual = petModel.visual {
                TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { ctx in
                    let wobble = alert ? sin(ctx.date.timeIntervalSince1970 * 18) * 1.6 : 0
                    TheaterPetView(
                        visual: visual, species: petModel.species,
                        signals: petModel.makeSignals(memPressureHigh: false), theme: theme,
                        onTap: { onClick() }
                    )
                    .offset(x: wobble)
                }
            } else {
                Text("🥚").font(.system(size: 14))
            }
        }
        .frame(width: IslandMetric.pillWidth - 6, height: height)
    }

    private var badge: some View {
        let count = agentModel.agents.count
        return Text(count > 9 ? "9+" : "\(count)")
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 3)
            .frame(minWidth: 12, minHeight: 12)
            .background(Circle().fill(LinearGradient(colors: Candy.violet, startPoint: .top, endPoint: .bottom)))
            .overlay(Circle().stroke(Color.black, lineWidth: 1))
            .offset(x: IslandMetric.pillWidth / 2 - 8, y: -height / 2 + 8)
    }

    private func strip(_ req: PermissionRequest) -> some View {
        HStack(spacing: 5) {
            Circle().fill(LinearGradient(colors: Candy.coral, startPoint: .top, endPoint: .bottom))
                .frame(width: 6, height: 6)
                .shadow(color: Candy.coral[1].opacity(0.7), radius: 2)
            VStack(alignment: .leading, spacing: 0) {
                Text(req.repoName)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1).truncationMode(.middle)
                Text("请求权限")
                    .font(.system(size: 8.5, weight: .medium, design: .rounded))
                    .foregroundStyle(rgb(1.0, 0.62, 0.46))
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.forward.app.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(rgb(1.0, 0.62, 0.46))
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .frame(width: IslandMetric.stripWidth, height: height)
        .background(Color.white.opacity(0.06))
        .contentShape(Rectangle())
        .onTapGesture { onAlertClick(req) }
    }
}

// MARK: - panel

private final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

// MARK: - controller

@MainActor
final class NotchIslandController {
    private let dropdown: MenuDropdownController
    private let petModel: PetPanelModel
    private let agentModel: AgentActivityModel
    private let island: IslandModel

    private var panel: NSPanel?
    private var geometry: NotchGeometry?
    private var lastHasAlert = false

    private var expandWork: DispatchWorkItem?
    private var watchdog: Timer?
    private var alertTimer: Timer?
    private var outsideSince: Date?
    private var pinned = false
    private var globalClickMon: Any?
    private var localClickMon: Any?

    init(dropdown: MenuDropdownController, petModel: PetPanelModel,
         agentModel: AgentActivityModel, island: IslandModel) {
        self.dropdown = dropdown
        self.petModel = petModel
        self.agentModel = agentModel
        self.island = island
    }

    var isPresent: Bool { panel != nil }

    func start() {
        guard island.enabled, panel == nil, let geo = NotchGeometry.builtInNotch() else { return }
        geometry = geo
        buildPanel(geo)
    }

    func stop() { teardown() }

    func setEnabled(_ value: Bool) {
        island.setEnabled(value)
        if value { start() } else { teardown() }
    }

    /// Piggybacks on the app's refresh cycles (petDidChange + the 5s timer);
    /// a fast 3s poll runs only while an alert is showing.
    func refresh() {
        guard panel != nil else { return }
        island.refresh()
        syncAlertState()
    }

    // MARK: panel

    private func buildPanel(_ geo: NotchGeometry) {
        let root = NotchIslandView(
            petModel: petModel, agentModel: agentModel, island: island,
            height: geo.islandFrame.height,
            onHover: { [weak self] in self?.islandHover($0) },
            onClick: { [weak self] in self?.islandClick() },
            onAlertClick: { [weak self] in self?.alertClick($0) }
        )
        let hosting = NSHostingController(rootView: AnyView(root))
        let panel = IslandPanel(
            contentRect: NSRect(origin: .zero, size: geo.islandFrame.size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.contentViewController = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // isFloatingPanel forces NSFloatingWindowLevel (3), which sits *behind*
        // the menu bar (24); set the level last so the pill draws over it.
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false
        panel.setFrame(geo.islandFrame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel
        lastHasAlert = false
        island.refresh()
        syncAlertState()
    }

    private func teardown() {
        collapse()
        alertTimer?.invalidate(); alertTimer = nil
        panel?.orderOut(nil)
        panel = nil
        geometry = nil
    }

    /// Widen the window for the alert strip and drive the 3s alert poll.
    private func syncAlertState() {
        guard let panel, let geo = geometry else { return }
        let hasAlert = island.pendingPermission != nil
        guard hasAlert != lastHasAlert else { return }
        lastHasAlert = hasAlert
        var frame = geo.islandFrame
        frame.size.width = geo.islandFrame.width + (hasAlert ? IslandMetric.stripWidth : 0)
        panel.setFrame(frame, display: true)
        if hasAlert { startAlertPoll() } else { stopAlertPoll() }
    }

    private func startAlertPoll() {
        guard alertTimer == nil else { return }
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        alertTimer = timer
    }

    private func stopAlertPoll() { alertTimer?.invalidate(); alertTimer = nil }

    // MARK: hover / click

    private func islandHover(_ hovering: Bool) {
        if hovering {
            guard !dropdown.isVisible else { return }
            let work = DispatchWorkItem { [weak self] in self?.expand(pinned: false) }
            expandWork?.cancel(); expandWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        } else {
            expandWork?.cancel(); expandWork = nil
        }
    }

    private func islandClick() {
        expandWork?.cancel(); expandWork = nil
        if dropdown.isVisible {
            if pinned { collapse() } else { pinned = true; installClickMonitors() }
        } else {
            expand(pinned: true)
        }
    }

    private func alertClick(_ req: PermissionRequest) {
        SessionJumper.shared.jump(cwd: req.cwd ?? "")
    }

    private func expand(pinned: Bool) {
        guard let geo = geometry else { return }
        self.pinned = pinned
        if !dropdown.isVisible {
            dropdown.show(anchorRect: geo.islandFrame, on: geo.screen, autoDismiss: false)
        }
        startWatchdog()
        if pinned { installClickMonitors() }
    }

    private func collapse() {
        expandWork?.cancel(); expandWork = nil
        dropdown.hide()
        pinned = false
        outsideSince = nil
        stopWatchdog()
        removeClickMonitors()
    }

    // MARK: hover-out watchdog

    private func startWatchdog() {
        outsideSince = nil
        watchdog?.invalidate()
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchdogTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func stopWatchdog() { watchdog?.invalidate(); watchdog = nil }

    private func watchdogTick() {
        guard dropdown.isVisible else { collapse(); return }
        if pinned { return }
        if cursorInsideIslandOrCard() { outsideSince = nil; return }
        if let since = outsideSince {
            if Date().timeIntervalSince(since) >= 0.4 { collapse() }
        } else {
            outsideSince = Date()
        }
    }

    private func cursorInsideIslandOrCard() -> Bool {
        let mouse = NSEvent.mouseLocation
        return (panel?.frame.contains(mouse) ?? false)
            || (dropdown.currentPanelFrame?.contains(mouse) ?? false)
    }

    // MARK: pinned outside-click dismissal

    private func installClickMonitors() {
        removeClickMonitors()
        globalClickMon = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissIfOutside() }
        }
        localClickMon = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.dismissIfOutside() }
            return event
        }
    }

    private func removeClickMonitors() {
        if let globalClickMon { NSEvent.removeMonitor(globalClickMon) }
        if let localClickMon { NSEvent.removeMonitor(localClickMon) }
        globalClickMon = nil
        localClickMon = nil
    }

    private func dismissIfOutside() {
        guard pinned, dropdown.isVisible else { return }
        if !cursorInsideIslandOrCard() { collapse() }
    }
}
