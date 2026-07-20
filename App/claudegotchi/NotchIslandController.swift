import AppKit
import SwiftUI
import GRDB
import PetCore

enum IslandMetric {
    static let lobeWidth: CGFloat = 54
    static let stripWidth: CGFloat = 158
    static let topFlare: CGFloat = 7
    static let bottomCorner: CGFloat = 10
    static let bottomExtend: CGFloat = 2
}

// MARK: - notch shape

// The wrapping-island silhouette: top corners flare concavely into the menu-bar
// surface, bottom corners curve convexly (matching the physical notch). Ported
// from boring.notch / DynamicNotchKit.
private struct NotchShape: Shape {
    var topCornerRadius: CGFloat = IslandMetric.topFlare
    var bottomCornerRadius: CGFloat = IslandMetric.bottomCorner

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let top = topCornerRadius, bottom = bottomCornerRadius
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top, y: rect.minY + top),
            control: CGPoint(x: rect.minX + top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
            control: CGPoint(x: rect.minX + top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
            control: CGPoint(x: rect.maxX - top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        return path
    }
}

// MARK: - notch geometry

struct NotchGeometry {
    let screen: NSScreen
    let notchRect: NSRect
    let notchCenterX: CGFloat
    let islandHeight: CGFloat
    let lobeWidth: CGFloat

    var notchWidth: CGFloat { notchRect.width }

    /// The built-in notched display, if any: `safeAreaInsets.top > 0` is present
    /// only on the notched built-in panel. The physical cutout spans from the
    /// left auxiliary area's right edge to the right auxiliary area's left edge.
    /// `heightOffset`/`widthOffset` are the user's tuning nudges (0 = pure API
    /// geometry); the width nudge splits evenly across both lobes.
    static func builtInNotch(heightOffset: CGFloat = 0, widthOffset: CGFloat = 0) -> NotchGeometry? {
        for screen in NSScreen.screens {
            let menuBarHeight = screen.safeAreaInsets.top
            guard menuBarHeight > 0,
                  let auxLeft = screen.auxiliaryTopLeftArea,
                  let auxRight = screen.auxiliaryTopRightArea else { continue }
            let notchLeft = auxLeft.maxX
            let notchWidth = auxRight.minX - notchLeft
            guard notchWidth > 0 else { continue }
            let notchRect = NSRect(
                x: notchLeft, y: screen.frame.maxY - menuBarHeight,
                width: notchWidth, height: menuBarHeight)
            let height = max(20, menuBarHeight + IslandMetric.bottomExtend + heightOffset)
            let lobe = max(20, IslandMetric.lobeWidth + widthOffset / 2)
            return NotchGeometry(
                screen: screen, notchRect: notchRect, notchCenterX: notchRect.midX,
                islandHeight: height, lobeWidth: lobe)
        }
        return nil
    }

    /// The wrapping window frame: lobes flank the physical cutout and the island
    /// bottom hangs `bottomExtend` below the notch. The left lobe collapses when
    /// no agents are active; the alert strip extends the island rightward.
    func frame(leftLobe: Bool, alert: Bool) -> NSRect {
        let lc = leftLobe ? lobeWidth : 0
        let strip = alert ? IslandMetric.stripWidth : 0
        return NSRect(
            x: notchRect.minX - lc, y: notchRect.maxY - islandHeight,
            width: lc + notchRect.width + lobeWidth + strip,
            height: islandHeight)
    }

    /// Anchor rect that centres the dropdown card under the notch: the card's
    /// right edge lands at `notchCenterX + cardWidth/2` (position() flush-rights).
    var dropdownAnchor: NSRect {
        NSRect(x: notchCenterX - DropdownCard.cardWidth / 2, y: notchRect.minY,
               width: DropdownCard.cardWidth, height: islandHeight)
    }
}

// MARK: - model

struct CompletionReveal: Equatable {
    let sessionId: String
    let repoName: String
    let cwd: String?
}

@MainActor
final class IslandModel: ObservableObject {
    @Published private(set) var pendingPermission: PermissionRequest?
    @Published private(set) var permissionStripSuppressed = false
    @Published private(set) var completion: CompletionReveal?
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

    /// A pending permission expands the strip (pet still wobbles); a completion
    /// expands the strip only when no permission is competing. Permission always
    /// wins. Suppression hides the permission strip while keeping the wobble.
    var showPermissionStrip: Bool { pendingPermission != nil && !permissionStripSuppressed }
    var showCompletionStrip: Bool { pendingPermission == nil && completion != nil }
    var showsStrip: Bool { showPermissionStrip || showCompletionStrip }
    var hasActiveAlertState: Bool { pendingPermission != nil || completion != nil }

    /// Freshest unanswered permission request ≤ `alertWindowMs` old; nil clears
    /// the strip (superseded, or aged past the auto-dismiss window).
    func refresh(filter: SessionFilter) {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let next = (try? PermissionWatch.pending(
            db: db, nowMs: nowMs, maxAgeMs: alertWindowMs, filter: filter))?.first
        if next != pendingPermission { pendingPermission = next }
    }

    func setPermissionStripSuppressed(_ value: Bool) {
        if value != permissionStripSuppressed { permissionStripSuppressed = value }
    }

    func setCompletion(_ value: CompletionReveal?) {
        if value != completion { completion = value }
    }
}

// MARK: - island view

struct NotchIslandView: View {
    @ObservedObject var petModel: PetPanelModel
    @ObservedObject var agentModel: AgentActivityModel
    @ObservedObject var island: IslandModel
    let notchWidth: CGFloat
    let lobeWidth: CGFloat
    let height: CGFloat
    var onHover: (Bool) -> Void
    var onClick: () -> Void
    var onAlertClick: (PermissionRequest) -> Void
    var onCompletionClick: (CompletionReveal) -> Void

    private var theme: WarmTheme { WarmTheme(scheme: .dark) }
    private var hasLeftLobe: Bool { agentModel.agents.count > 0 }
    private let coral = rgb(1.0, 0.62, 0.46)
    private let mint = rgb(0.52, 0.86, 0.56)

    private var shape: NotchShape { NotchShape() }

    var body: some View {
        ZStack(alignment: .topLeading) {
            shape.fill(Color.black).frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 0) {
                badgeLobe.frame(width: hasLeftLobe ? lobeWidth : 0)
                Color.clear.frame(width: notchWidth).allowsHitTesting(false)
                petLobe.frame(width: lobeWidth)
                if island.showPermissionStrip, let req = island.pendingPermission {
                    alertStrip(req).frame(width: IslandMetric.stripWidth)
                } else if island.showCompletionStrip, let comp = island.completion {
                    completionStrip(comp).frame(width: IslandMetric.stripWidth)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(height: height)
        .contentShape(shape)
        .onHover { onHover($0) }
        .onTapGesture { onClick() }
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: hasLeftLobe)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: island.pendingPermission)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: island.showsStrip)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: island.completion)
    }

    private var badgeLobe: some View {
        let count = agentModel.agents.count
        return Text(count > 9 ? "9+" : "\(count)")
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 22, minHeight: 20)
            .background(Capsule().fill(
                LinearGradient(colors: Candy.violet, startPoint: .top, endPoint: .bottom)))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(hasLeftLobe ? 1 : 0)
    }

    @ViewBuilder
    private var petLobe: some View {
        let shaking = island.pendingPermission != nil
        Group {
            if let visual = petModel.visual {
                TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { ctx in
                    let wobble = shaking ? sin(ctx.date.timeIntervalSince1970 * 18) * 1.6 : 0
                    TheaterPetView(
                        visual: visual, species: petModel.species,
                        signals: petModel.makeSignals(memPressureHigh: false), theme: theme,
                        onTap: { onClick() }
                    )
                    .offset(x: wobble)
                }
            } else {
                Text("🥚").font(.system(size: 15))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func alertStrip(_ req: PermissionRequest) -> some View {
        HStack(spacing: 6) {
            Circle().fill(LinearGradient(colors: Candy.coral, startPoint: .top, endPoint: .bottom))
                .frame(width: 6, height: 6)
                .shadow(color: Candy.coral[1].opacity(0.7), radius: 2)
            Text("\(req.repoName) · 请求权限")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(coral)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 2)
            Image(systemName: "arrow.up.forward.app.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(coral)
        }
        .padding(.leading, 8).padding(.trailing, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { onAlertClick(req) }
        .transition(.opacity)
    }

    private func completionStrip(_ comp: CompletionReveal) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(LinearGradient(colors: Candy.stam, startPoint: .top, endPoint: .bottom))
                .shadow(color: Candy.stam[0].opacity(0.7), radius: 2)
            Text("\(comp.repoName) · 完成")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(mint)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 2)
            Image(systemName: "arrow.up.forward.app.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(mint)
        }
        .padding(.leading, 8).padding(.trailing, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { onCompletionClick(comp) }
        .transition(.opacity)
    }
}

// MARK: - panel

private final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

// MARK: - controller

@MainActor
final class NotchIslandController {
    private let dropdown: MenuDropdownController
    private let petModel: PetPanelModel
    private let agentModel: AgentActivityModel
    private let island: IslandModel
    private let db: DatabaseQueue
    private let settings: SettingsStore
    private let sound: SoundController

    private var panel: NSPanel?
    private var hosting: NSHostingController<AnyView>?
    private var geometry: NotchGeometry?
    private var appliedHeightOffset: CGFloat = .nan
    private var appliedWidthOffset: CGFloat = .nan
    private var lastLeftLobe = false
    private var lastHasStrip = false
    private var currentlyVisible = true

    private var expandWork: DispatchWorkItem?
    private var watchdog: Timer?
    private var alertTimer: Timer?
    private var outsideSince: Date?
    private var pinned = false
    private var globalClickMon: Any?
    private var localClickMon: Any?

    private var completionDetector = CompletionDetector()
    private var completionTimer: Timer?
    private var escMonitor: Any?

    init(dropdown: MenuDropdownController, petModel: PetPanelModel,
         agentModel: AgentActivityModel, island: IslandModel,
         db: DatabaseQueue, settings: SettingsStore, sound: SoundController) {
        self.dropdown = dropdown
        self.petModel = petModel
        self.agentModel = agentModel
        self.island = island
        self.db = db
        self.settings = settings
        self.sound = sound
    }

    var isPresent: Bool { panel != nil }

    func start() {
        guard island.enabled, panel == nil else { return }
        let h = CGFloat(settings.islandHeightOffset)
        let w = CGFloat(settings.islandWidthOffset)
        guard let geo = NotchGeometry.builtInNotch(heightOffset: h, widthOffset: w) else { return }
        appliedHeightOffset = h
        appliedWidthOffset = w
        geometry = geo
        buildPanel(geo)
    }

    func stop() { teardown() }

    func setEnabled(_ value: Bool) {
        island.setEnabled(value)
        if value { start() } else { teardown() }
    }

    /// Piggybacks on the app's refresh cycles (petDidChange + the 5s timer);
    /// a fast 3s poll runs only while an alert/completion is showing.
    func refresh() {
        guard panel != nil else { return }
        applyGeometryIfNeeded()
        let filter = settings.sessionFilter
        island.refresh(filter: filter)
        updatePermissionSuppression()
        detectCompletions(filter: filter)
        layout(animated: true)
    }

    /// Re-derive geometry when the user's tuning offsets change, swap the hosted
    /// root (so the SwiftUI `height`/`lobeWidth` update) and re-frame in place.
    private func applyGeometryIfNeeded() {
        let h = CGFloat(settings.islandHeightOffset)
        let w = CGFloat(settings.islandWidthOffset)
        guard h != appliedHeightOffset || w != appliedWidthOffset,
              let geo = NotchGeometry.builtInNotch(heightOffset: h, widthOffset: w) else { return }
        appliedHeightOffset = h
        appliedWidthOffset = w
        geometry = geo
        hosting?.rootView = makeRoot(geo)
        layout(animated: false)
    }

    // MARK: completion reveal

    /// Native-approval mode, a quiet scene, or already looking at the terminal all
    /// keep the strip collapsed (badge-only) and mute the alert sound.
    private func updatePermissionSuppression() {
        guard let req = island.pendingPermission else {
            island.setPermissionStripSuppressed(false)
            sound.permissionCleared()
            return
        }
        let suppressed = settings.nativeApprovalsEnabled
            || QuietSceneInspector.isActive(settings: settings)
            || (settings.focusSuppressionEnabled && FocusInspector.suppresses(cwd: req.cwd))
        island.setPermissionStripSuppressed(suppressed)
        if suppressed {
            clearCompletion()
        } else {
            sound.permissionAppeared(sessionId: req.sessionId)
        }
    }

    private func detectCompletions(filter: SessionFilter) {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let stops = (try? CompletionWatch.recentCompletions(db: db, nowMs: nowMs, filter: filter)) ?? []
        let newly = completionDetector.newlyCompleted(stops)
        guard settings.completionRevealEnabled,
              island.pendingPermission == nil,
              !QuietSceneInspector.isActive(settings: settings),
              let latest = newly.max(by: { $0.tsMs < $1.tsMs }) else { return }
        if settings.focusSuppressionEnabled && FocusInspector.suppresses(cwd: latest.cwd) { return }
        island.setCompletion(CompletionReveal(
            sessionId: latest.sessionId, repoName: latest.repoName, cwd: latest.cwd))
        sound.taskComplete()
        startCompletionDwell()
        installEscMonitor()
    }

    private func startCompletionDwell() {
        completionTimer?.invalidate()
        let timer = Timer(timeInterval: TimeInterval(settings.completionDwellSeconds), repeats: false) {
            [weak self] _ in MainActor.assumeIsolated { self?.clearCompletion() }
        }
        RunLoop.main.add(timer, forMode: .common)
        completionTimer = timer
    }

    private func clearCompletion() {
        completionTimer?.invalidate(); completionTimer = nil
        removeEscMonitor()
        if island.completion != nil {
            island.setCompletion(nil)
            layout(animated: true)
        }
    }

    private func installEscMonitor() {
        removeEscMonitor()
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self?.clearCompletion() }
            return nil
        }
    }

    private func removeEscMonitor() {
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        escMonitor = nil
    }

    // MARK: panel

    private func makeRoot(_ geo: NotchGeometry) -> AnyView {
        AnyView(NotchIslandView(
            petModel: petModel, agentModel: agentModel, island: island,
            notchWidth: geo.notchWidth, lobeWidth: geo.lobeWidth, height: geo.islandHeight,
            onHover: { [weak self] in self?.islandHover($0) },
            onClick: { [weak self] in self?.islandClick() },
            onAlertClick: { [weak self] in self?.alertClick($0) },
            onCompletionClick: { [weak self] in self?.completionClick($0) }
        ))
    }

    private func buildPanel(_ geo: NotchGeometry) {
        let hosting = NSHostingController(rootView: makeRoot(geo))
        self.hosting = hosting
        let panel = IslandPanel(
            contentRect: NSRect(origin: .zero, size: geo.frame(leftLobe: false, alert: false).size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.contentViewController = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // statusBar+1 draws over the menu bar (24); set last so nothing lowers it.
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false
        panel.orderFrontRegardless()
        self.panel = panel
        lastLeftLobe = false
        lastHasStrip = false
        currentlyVisible = true
        island.refresh(filter: settings.sessionFilter)
        layout(animated: false)
    }

    private func teardown() {
        collapse()
        clearCompletion()
        alertTimer?.invalidate(); alertTimer = nil
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
        geometry = nil
        appliedHeightOffset = .nan
        appliedWidthOffset = .nan
    }

    /// Resize the wrapping window to match the current lobe/strip state and drive
    /// the 3s poll. The SwiftUI content is leading-anchored, so a rightward grow
    /// reveals the strip while the pet/badge stay put. Auto-hide fades the whole
    /// island out when no post-filter session (or alert) remains.
    private func layout(animated: Bool) {
        guard let panel, let geo = geometry else { return }
        let leftLobe = agentModel.agents.count > 0
        let hasStrip = island.showsStrip
        let poll = island.hasActiveAlertState
        if poll != (alertTimer != nil) {
            if poll { startAlertPoll() } else { stopAlertPoll() }
        }
        applyVisibility(animated: animated)
        let changed = leftLobe != lastLeftLobe || hasStrip != lastHasStrip
        lastLeftLobe = leftLobe
        lastHasStrip = hasStrip
        let frame = geo.frame(leftLobe: leftLobe, alert: hasStrip)
        guard changed || panel.frame != frame else { return }
        panel.setFrame(frame, display: true, animate: animated && changed)
    }

    private func islandShouldBeVisible() -> Bool {
        if !settings.autoHideWhenNoSessions { return true }
        return agentModel.agents.count > 0 || island.hasActiveAlertState
    }

    private func applyVisibility(animated: Bool) {
        guard let panel else { return }
        let visible = islandShouldBeVisible()
        guard visible != currentlyVisible else { return }
        currentlyVisible = visible
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                panel.animator().alphaValue = visible ? 1 : 0
            }
        } else {
            panel.alphaValue = visible ? 1 : 0
        }
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
            DispatchQueue.main.asyncAfter(deadline: .now() + settings.hoverDelay, execute: work)
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
        jumpToSession(req.sessionId, cwd: req.cwd)
    }

    private func completionClick(_ comp: CompletionReveal) {
        clearCompletion()
        jumpToSession(comp.sessionId, cwd: comp.cwd)
    }

    private func jumpToSession(_ sessionId: String, cwd: String?) {
        let tty = (try? TTYAnchor.stored(db: db, sessionId: sessionId)) ?? nil
        SessionJumper.shared.jump(
            cwd: cwd ?? "", tty: tty,
            markerToken: TitleMarker.token(forSessionId: sessionId))
    }

    private func expand(pinned: Bool) {
        guard let geo = geometry else { return }
        self.pinned = pinned
        if !dropdown.isVisible {
            dropdown.show(anchorRect: geo.dropdownAnchor, on: geo.screen, autoDismiss: false)
        }
        startWatchdog()
        // Without hover auto-collapse, a hover-open panel dismisses on outside
        // click instead (mouse-leave alone can't close it).
        if pinned || !settings.autoCollapseOnLeave { installClickMonitors() }
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
        if pinned || !settings.autoCollapseOnLeave { return }
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
        guard dropdown.isVisible else { return }
        if !cursorInsideIslandOrCard() { collapse() }
    }
}
