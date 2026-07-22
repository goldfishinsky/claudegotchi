import AppKit
import SwiftUI
import GRDB
import PetCore

enum IslandMetric {
    static let lobeWidth: CGFloat = 54
    static let topFlare: CGFloat = 7
    static let bottomCorner: CGFloat = 10
    static let bottomExtend: CGFloat = 2
    // Transparent breathing room around the tight island so the arrival pulse,
    // hover glow, and auto-hide slide are not clipped by the hosting window.
    static let motionPadX: CGFloat = 14
    static let motionPadTop: CGFloat = 8
    static let motionPadBottom: CGFloat = 14

    // Alert/completion banner that drops below the island (the island's own width
    // never changes for alerts). The window reserves `bannerReserve` extra height
    // downward while a banner is mounted; the banner hangs `bannerGap` under the
    // island bottom and slides out from behind it.
    static let bannerHeight: CGFloat = 30
    static let bannerGap: CGFloat = 5
    static let bannerCorner: CGFloat = 12
    static let bannerSideInset: CGFloat = 2
    static var bannerReserve: CGFloat { bannerGap + bannerHeight }

    // Right-lobe collision clamp: keep the pet lobe this far clear of the nearest
    // menu-bar status item, and hide the pet entirely once the clamped lobe would
    // fall below the floor rather than overlap.
    static let lobeGap: CGFloat = 6
    static let lobeFloor: CGFloat = 30
}

// MARK: - motion

// Event-driven Dynamic-Island curves. The morph carries a jelly overshoot
// (low damping); settle retracts calmly. Every value is spring(response:damping:)
// so it stays available on the macOS 13 deployment floor.
enum IslandMotion {
    static let morph = Animation.spring(response: 0.42, dampingFraction: 0.74, blendDuration: 0)
    static let settle = Animation.spring(response: 0.40, dampingFraction: 0.84, blendDuration: 0)
    static let content = Animation.spring(response: 0.32, dampingFraction: 0.82, blendDuration: 0)
    static let hover = Animation.spring(response: 0.26, dampingFraction: 0.72, blendDuration: 0)
    static let badge = Animation.spring(response: 0.30, dampingFraction: 0.6, blendDuration: 0)
    static let pulseUp = Animation.spring(response: 0.13, dampingFraction: 0.68, blendDuration: 0)
    static let pulseDown = Animation.spring(response: 0.19, dampingFraction: 0.8, blendDuration: 0)
    static let bounceUp = Animation.spring(response: 0.16, dampingFraction: 0.5, blendDuration: 0)
    static let bounceDown = Animation.spring(response: 0.26, dampingFraction: 0.62, blendDuration: 0)

    static let pulsePeak: TimeInterval = 0.11
    static let contentStagger: TimeInterval = 0.08
    static let departClear: TimeInterval = 0.5

    static let hoverScale: CGFloat = 1.03
    static let pulseScale: CGFloat = 1.045
    static let bounceScaleY: CGFloat = 1.035
    static let hideSlide: CGFloat = 6
    static let wobbleCooldown: TimeInterval = 5
}

// MARK: - notch shape

// The wrapping-island silhouette: top corners flare concavely into the menu-bar
// surface, bottom corners curve convexly (matching the physical notch). Ported
// from boring.notch / DynamicNotchKit.
private struct NotchShape: Shape {
    var topCornerRadius: CGFloat = IslandMetric.topFlare
    var bottomCornerRadius: CGFloat = IslandMetric.bottomCorner

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topCornerRadius, bottomCornerRadius) }
        set { topCornerRadius = newValue.first; bottomCornerRadius = newValue.second }
    }

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

/// Presentation state the controller drives and the view animates: whether the
/// dropdown is open (so hover-bloom yields to it) and whether auto-hide has
/// tucked the island away.
@MainActor
final class IslandChrome: ObservableObject {
    @Published var dropdownOpen = false
    @Published var hidden = false
}

// MARK: - island view

private struct DisplayStrip: Equatable {
    let key: String
    let isCompletion: Bool
    let repoName: String
    let permission: PermissionRequest?
    let completion: CompletionReveal?
}

private enum MetricEdge: Hashable { case left, drop }

private struct MetricKey: PreferenceKey {
    static var defaultValue: [MetricEdge: CGFloat] = [:]
    static func reduce(value: inout [MetricEdge: CGFloat], nextValue: () -> [MetricEdge: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Bookkeeping the pet-wobble edge detector mutates every rendered frame without
/// invalidating the view (a reference held by @State, not @Published).
private final class MotionBook {
    var lastBehavior: TheaterBehavior?
    var lastWobbleAt = Date.distantPast
}

struct NotchIslandView: View {
    @ObservedObject var petModel: PetPanelModel
    @ObservedObject var agentModel: AgentActivityModel
    @ObservedObject var island: IslandModel
    @ObservedObject var chrome: IslandChrome
    let notchWidth: CGFloat
    let lobeWidth: CGFloat
    let petLobeWidth: CGFloat
    let height: CGFloat
    var onHover: (Bool) -> Void
    var onClick: () -> Void
    var onAlertClick: (PermissionRequest) -> Void
    var onCompletionClick: (CompletionReveal) -> Void
    var onMetrics: (CGFloat, CGFloat) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shownStrip: DisplayStrip?
    @State private var bannerDown = false
    @State private var bannerTextIn = false
    @State private var pulse: CGFloat = 1
    @State private var wobbleY: CGFloat = 1
    @State private var hovering = false
    @State private var book = MotionBook()

    private var theme: WarmTheme { WarmTheme(scheme: .dark) }
    private var hasLeftLobe: Bool { agentModel.agents.count > 0 }
    private let coral = rgb(1.0, 0.62, 0.46)
    private let mint = rgb(0.52, 0.86, 0.56)
    private let glow = rgb(1.0, 0.72, 0.36)

    private var blooming: Bool { hovering && !chrome.dropdownOpen }

    private var desiredStrip: DisplayStrip? {
        if island.showPermissionStrip, let req = island.pendingPermission {
            return DisplayStrip(
                key: "p:\(req.sessionId)", isCompletion: false,
                repoName: req.repoName, permission: req, completion: nil)
        }
        if island.showCompletionStrip, let comp = island.completion {
            return DisplayStrip(
                key: "c:\(comp.sessionId)", isCompletion: true,
                repoName: comp.repoName, permission: nil, completion: comp)
        }
        return nil
    }

    // A stable, non-transformed clear base fills the window so the hosting view
    // never mirrors the island's own scale/offset onto the borderless panel (which
    // throws during the display cycle). All motion transforms stay interior.
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.allowsHitTesting(false)
                .preference(key: MetricKey.self,
                            value: [.drop: shownStrip != nil ? IslandMetric.bannerReserve : 0])
            bannerLayer
            islandChrome
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onPreferenceChange(MetricKey.self) { m in onMetrics(m[.left] ?? 0, m[.drop] ?? 0) }
        .onChange(of: desiredStrip?.key ?? "") { _ in syncStrip() }
        .onAppear { syncStrip() }
    }

    private var islandChrome: some View {
        islandArea
            .scaleEffect(reduceMotion ? 1 : pulse, anchor: .top)
            .scaleEffect(x: 1, y: reduceMotion ? 1 : wobbleY, anchor: .top)
            .scaleEffect(!reduceMotion && blooming ? IslandMotion.hoverScale : 1, anchor: .top)
            .shadow(color: glow.opacity(blooming ? 0.55 : 0), radius: blooming ? 12 : 0)
            .animation(IslandMotion.hover, value: hovering)
            .animation(IslandMotion.hover, value: chrome.dropdownOpen)
            .opacity(chrome.hidden ? 0 : 1)
            .offset(y: chrome.hidden && !reduceMotion ? -IslandMotion.hideSlide : 0)
            .animation(reduceMotion ? .easeInOut(duration: 0.25) : IslandMotion.settle, value: chrome.hidden)
            .allowsHitTesting(!chrome.hidden)
            .padding(.top, IslandMetric.motionPadTop)
            .padding(.horizontal, IslandMetric.motionPadX)
            .padding(.bottom, IslandMetric.motionPadBottom)
    }

    private var islandArea: some View {
        HStack(spacing: 0) {
            badgeLobe
                .frame(width: hasLeftLobe ? lobeWidth : 0)
                .background(measure(.left))
            Color.clear.frame(width: notchWidth).allowsHitTesting(false)
            petLobe.frame(width: petLobeWidth)
        }
        .frame(height: height)
        .background(
            NotchShape(
                topCornerRadius: IslandMetric.topFlare,
                bottomCornerRadius: IslandMetric.bottomCorner
            ).fill(Color.black)
        )
        .contentShape(NotchShape(
            topCornerRadius: IslandMetric.topFlare,
            bottomCornerRadius: IslandMetric.bottomCorner))
        .onHover { hovering = $0; onHover($0) }
        .onTapGesture { onClick() }
        .animation(IslandMotion.morph, value: hasLeftLobe)
    }

    private func measure(_ edge: MetricEdge) -> some View {
        GeometryReader { g in
            Color.clear.preference(key: MetricKey.self, value: [edge: g.size.width])
        }
    }

    private var badgeLobe: some View {
        let count = agentModel.agents.count
        return Text(count > 9 ? "9+" : "\(count)")
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .contentTransition(.numericText())
            .animation(IslandMotion.badge, value: count)
            .padding(.horizontal, 5)
            .frame(minWidth: 22, minHeight: 20)
            .background(Capsule().fill(
                LinearGradient(colors: Candy.violet, startPoint: .top, endPoint: .bottom)))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scaleEffect(hasLeftLobe ? 1 : 0.4)
            .opacity(hasLeftLobe ? 1 : 0)
    }

    @ViewBuilder
    private var petLobe: some View {
        let shaking = island.pendingPermission != nil
        Group {
            if petLobeWidth <= 1 {
                Color.clear
            } else if let visual = petModel.visual {
                TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { ctx in
                    let wobble = shaking ? sin(ctx.date.timeIntervalSince1970 * 18) * 1.6 : 0
                    TheaterPetView(
                        visual: visual, species: petModel.species,
                        signals: petModel.makeSignals(memPressureHigh: false), theme: theme,
                        onTap: { onClick() },
                        onScene: { scene, _ in reactToPet(scene.behavior) }
                    )
                    .offset(x: wobble)
                }
            } else {
                Text("🥚").font(.system(size: 15))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    // The island bottom (with the motion pad) and the resting/tucked banner tops,
    // in the window's top-leading coordinate space.
    private var islandBottomY: CGFloat { IslandMetric.motionPadTop + height }
    private var bannerRestY: CGFloat { islandBottomY + IslandMetric.bannerGap }
    private var bannerTuckY: CGFloat { islandBottomY - IslandMetric.bannerHeight }

    @ViewBuilder
    private var bannerLayer: some View {
        if let strip = shownStrip {
            let color = strip.isCompletion ? mint : coral
            HStack(spacing: 6) {
                if strip.isCompletion {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(LinearGradient(colors: Candy.stam, startPoint: .top, endPoint: .bottom))
                        .shadow(color: Candy.stam[0].opacity(0.7), radius: 2)
                } else {
                    Circle().fill(LinearGradient(colors: Candy.coral, startPoint: .top, endPoint: .bottom))
                        .frame(width: 6, height: 6)
                        .shadow(color: Candy.coral[1].opacity(0.7), radius: 2)
                }
                Text("\(strip.repoName) · \(strip.isCompletion ? "完成" : "请求权限")")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(color)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 2)
                Image(systemName: "arrow.up.forward.app.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(color)
            }
            .padding(.leading, 11).padding(.trailing, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(bannerTextIn ? 1 : 0)
            .background(
                RoundedRectangle(cornerRadius: IslandMetric.bannerCorner, style: .continuous)
                    .fill(Color.black)
                    .overlay(
                        RoundedRectangle(cornerRadius: IslandMetric.bannerCorner, style: .continuous)
                            .strokeBorder(color.opacity(0.4), lineWidth: 1))
                    .shadow(color: color.opacity(0.28), radius: 7, x: 0, y: 3)
            )
            .frame(maxWidth: .infinity)
            .frame(height: IslandMetric.bannerHeight)
            .padding(.horizontal, IslandMetric.bannerSideInset)
            .contentShape(RoundedRectangle(cornerRadius: IslandMetric.bannerCorner, style: .continuous))
            .onTapGesture {
                if let comp = strip.completion { onCompletionClick(comp) }
                else if let req = strip.permission { onAlertClick(req) }
            }
            .opacity(bannerDown ? 1 : 0)
            .offset(y: bannerDown ? bannerRestY : bannerTuckY)
            .allowsHitTesting(bannerDown && bannerTextIn)
        }
    }

    // MARK: strip choreography

    private func syncStrip() {
        if let want = desiredStrip {
            let wasDown = bannerDown
            shownStrip = want
            if wasDown {
                guard !reduceMotion else { return }
                withAnimation(IslandMotion.content) { bannerTextIn = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
                    guard desiredStrip != nil else { return }
                    withAnimation(IslandMotion.content) { bannerTextIn = true }
                }
                return
            }
            if reduceMotion {
                withAnimation(.easeOut(duration: 0.2)) { bannerDown = true; bannerTextIn = true }
                return
            }
            firePulse()
            DispatchQueue.main.asyncAfter(deadline: .now() + IslandMotion.pulsePeak) {
                guard desiredStrip != nil else { return }
                withAnimation(IslandMotion.morph) { bannerDown = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + IslandMotion.contentStagger) {
                    guard desiredStrip != nil else { return }
                    withAnimation(IslandMotion.content) { bannerTextIn = true }
                }
            }
        } else {
            guard shownStrip != nil else { return }
            if reduceMotion {
                withAnimation(.easeOut(duration: 0.2)) { bannerTextIn = false; bannerDown = false }
            } else {
                withAnimation(IslandMotion.content) { bannerTextIn = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + IslandMotion.contentStagger) {
                    guard desiredStrip == nil else { return }
                    withAnimation(IslandMotion.settle) { bannerDown = false }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + IslandMotion.departClear) {
                if desiredStrip == nil { shownStrip = nil }
            }
        }
    }

    private func firePulse() {
        withAnimation(IslandMotion.pulseUp) { pulse = IslandMotion.pulseScale }
        DispatchQueue.main.asyncAfter(deadline: .now() + IslandMotion.pulsePeak) {
            withAnimation(IslandMotion.pulseDown) { pulse = 1 }
        }
    }

    // MARK: pet-reactive wobble

    private func reactToPet(_ behavior: TheaterBehavior) {
        guard behavior != book.lastBehavior else { return }
        book.lastBehavior = behavior
        guard behavior == .celebrate || behavior == .greet, !reduceMotion else { return }
        let now = Date()
        guard now.timeIntervalSince(book.lastWobbleAt) >= IslandMotion.wobbleCooldown else { return }
        book.lastWobbleAt = now
        DispatchQueue.main.async {
            withAnimation(IslandMotion.bounceUp) { wobbleY = IslandMotion.bounceScaleY }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(IslandMotion.bounceDown) { wobbleY = 1 }
            }
        }
    }
}

// MARK: - panel

private final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

// MARK: - menu-bar collision probe

/// Finds the nearest right-of-notch menu-bar status item so the pet lobe can be
/// clamped clear of it. `CGWindowListCopyWindowInfo` exposes window bounds, layer,
/// and owning PID without Screen Recording permission (only window *names* need
/// it, which this never reads). Status items live at layer 25 (`NSStatusWindowLevel`);
/// the full-width Window Server "Menubar" backdrop sits at layer 24 and the island
/// itself at 26, so a strict layer-25 filter excludes both. Left-side app menus are
/// drawn inside that single backdrop window, not as probeable items, so only the
/// right side can be clamped.
enum MenuBarProbe {
    static let statusLayer = 25
    static let backdropLayer = 24

    struct Result {
        /// minX of the nearest right-of-notch status item, or nil when the bar is
        /// genuinely clear on the right.
        let nearestMinX: CGFloat?
        /// False when the window list looked degenerate (nil, or no menu-bar-level
        /// window at all) — a transient the caller must not treat as "no obstacle",
        /// or it would briefly un-clamp the lobe back over an icon.
        let trustworthy: Bool
    }

    static func probe(
        notchCenterX: CGFloat, notchMaxX: CGFloat, menuBarHeight: CGFloat,
        screenMaxX: CGFloat, myPID: Int
    ) -> Result {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return Result(nearestMinX: nil, trustworthy: false)
        }
        var nearest = CGFloat.greatestFiniteMagnitude
        var sawMenuBarLevel = false
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let x = bounds["X"] ?? 0
            let y = bounds["Y"] ?? 0
            let h = bounds["Height"] ?? 0
            guard y <= 2, h <= menuBarHeight + 4 else { continue }
            if layer == backdropLayer || layer == statusLayer { sawMenuBarLevel = true }
            guard layer == statusLayer,
                  let pid = info[kCGWindowOwnerPID as String] as? Int, pid != myPID else { continue }
            guard x >= notchCenterX, x < screenMaxX else { continue }
            if x < nearest { nearest = x }
        }
        guard sawMenuBarLevel else { return Result(nearestMinX: nil, trustworthy: false) }
        return Result(nearestMinX: nearest.isFinite ? nearest : nil, trustworthy: true)
    }
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

    private let chrome = IslandChrome()
    private var panel: NSPanel?
    private var hosting: NSHostingController<AnyView>?
    private var geometry: NotchGeometry?
    private var appliedHeightOffset: CGFloat = .nan
    private var appliedWidthOffset: CGFloat = .nan
    // Latest left-lobe width the SwiftUI layer measured mid-spring plus the
    // downward banner reserve; the window frame tracks these so its bounds follow
    // the animated shape and the banner has room to drop below.
    private var lastLobeW: CGFloat = 0
    private var lastDrop: CGFloat = 0
    private var repositionScheduled = false

    // Max width the right (pet) lobe may take before it would overlap the nearest
    // menu-bar status item; refreshed by the collision probe.
    private var rightLobeAllowance: CGFloat = .greatestFiniteMagnitude
    private var clampTimer: Timer?
    private var alertActive = false

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
    private var screenObserver: Any?

    /// Fires whenever the island's on-screen presence may have changed (built,
    /// torn down, or a screen-topology shift added/removed the notch) so the
    /// status item can mirror it: shown only while the island is absent.
    var onPresenceChange: (() -> Void)?

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
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenParametersChanged() }
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    var isPresent: Bool { panel != nil }

    private func notifyPresence() { onPresenceChange?() }

    /// A monitor plugged/unplugged can add or remove the built-in notch. Rebuild,
    /// tear down, or re-derive geometry to match, then report the new presence.
    private func screenParametersChanged() {
        let h = CGFloat(settings.islandHeightOffset)
        let w = CGFloat(settings.islandWidthOffset)
        let geoNow = NotchGeometry.builtInNotch(heightOffset: h, widthOffset: w)
        if geoNow == nil {
            if panel != nil { teardown() } else { notifyPresence() }
        } else if island.enabled {
            if panel == nil {
                start()
            } else {
                geometry = geoNow
                appliedHeightOffset = h
                appliedWidthOffset = w
                hosting?.rootView = makeRoot(geoNow!)
                positionWindow()
                layout(animated: false)
                probeClamp()
                notifyPresence()
            }
        } else {
            notifyPresence()
        }
    }

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
        positionWindow()
        layout(animated: false)
        probeClamp()
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
            petModel: petModel, agentModel: agentModel, island: island, chrome: chrome,
            notchWidth: geo.notchWidth, lobeWidth: geo.lobeWidth,
            petLobeWidth: effectivePetLobe(geo), height: geo.islandHeight,
            onHover: { [weak self] in self?.islandHover($0) },
            onClick: { [weak self] in self?.islandClick() },
            onAlertClick: { [weak self] in self?.alertClick($0) },
            onCompletionClick: { [weak self] in self?.completionClick($0) },
            onMetrics: { [weak self] lobe, drop in self?.islandMetrics(leftLobe: lobe, drop: drop) }
        ))
    }

    private func buildPanel(_ geo: NotchGeometry) {
        let hosting = NSHostingController(rootView: makeRoot(geo))
        // The controller owns the window frame; without this the hosting view also
        // tries to drive window-size constraints from its content.
        hosting.sizingOptions = []
        self.hosting = hosting
        let contentRect = paddedFrame(geo, lobeW: 0, drop: 0)
        let panel = IslandPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        // Host the SwiftUI view inside a plain autoresizing container rather than as
        // the window's contentView: per-frame panel resizes and transform animations
        // then never post window-level constraint updates (which throw on a
        // borderless panel mid display-cycle).
        let container = NSView(frame: NSRect(origin: .zero, size: contentRect.size))
        container.autoresizesSubviews = true
        hosting.view.translatesAutoresizingMaskIntoConstraints = true
        hosting.view.frame = container.bounds
        hosting.view.autoresizingMask = [.width, .height]
        container.addSubview(hosting.view)
        panel.contentView = container
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
        lastLobeW = 0
        lastDrop = 0
        chrome.dropdownOpen = false
        startClampProbe()
        positionWindow()
        island.refresh(filter: settings.sessionFilter)
        layout(animated: false)
        notifyPresence()
    }

    private func teardown() {
        collapse()
        clearCompletion()
        alertTimer?.invalidate(); alertTimer = nil
        stopClampProbe()
        rightLobeAllowance = .greatestFiniteMagnitude
        alertActive = false
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
        geometry = nil
        appliedHeightOffset = .nan
        appliedWidthOffset = .nan
        notifyPresence()
    }

    /// The window frame for the measured left-lobe width and downward banner
    /// reserve: the tight island pinned to the notch, outset by the motion pad so
    /// the pulse, glow, and slide have room, and extended downward by `drop` so the
    /// banner can hang below. Left/right edges are computed from the notch, never
    /// from the leading edge, so the notch-clear column always aligns with the
    /// cutout; the right edge honours the collision-clamped pet lobe.
    private func paddedFrame(_ geo: NotchGeometry, lobeW: CGFloat, drop: CGFloat) -> NSRect {
        let n = geo.notchRect
        let left = n.minX - lobeW - IslandMetric.motionPadX
        let right = n.minX + geo.notchWidth + effectivePetLobe(geo) + IslandMetric.motionPadX
        let originY = n.maxY - geo.islandHeight - IslandMetric.motionPadBottom - drop
        let heightTotal = geo.islandHeight + IslandMetric.motionPadTop + IslandMetric.motionPadBottom + drop
        return NSRect(x: left, y: originY, width: right - left, height: heightTotal)
    }

    /// The SwiftUI layer measures the animating left-lobe width and the banner
    /// reserve every frame; the window bounds follow so the black shape morphs with
    /// visible overshoot and the banner has room to drop, without ever clipping. The
    /// resize is coalesced onto the next runloop hop so it never reenters the
    /// SwiftUI display cycle that emitted the measurement.
    private func islandMetrics(leftLobe lobe: CGFloat, drop: CGFloat) {
        guard lobe != lastLobeW || drop != lastDrop else { return }
        lastLobeW = lobe
        lastDrop = drop
        guard !repositionScheduled else { return }
        repositionScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.repositionScheduled = false
            self?.positionWindow()
        }
    }

    private func positionWindow() {
        guard let panel, let geo = geometry else { return }
        let frame = paddedFrame(geo, lobeW: lastLobeW, drop: lastDrop)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
    }

    /// Drive the 3s alert poll and hand the auto-hide decision to the SwiftUI layer
    /// (fade + upward slide). The window frame itself is driven by measured widths.
    /// A fresh collision probe runs the moment an alert becomes active.
    private func layout(animated: Bool) {
        guard panel != nil else { return }
        let poll = island.hasActiveAlertState
        if poll != (alertTimer != nil) {
            if poll { startAlertPoll() } else { stopAlertPoll() }
        }
        if poll && !alertActive { probeClamp() }
        alertActive = poll
        chrome.hidden = !islandShouldBeVisible()
    }

    private func islandShouldBeVisible() -> Bool {
        if !settings.autoHideWhenNoSessions { return true }
        return agentModel.agents.count > 0 || island.hasActiveAlertState
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

    // MARK: right-lobe collision clamp

    /// The pet lobe width after clamping against the nearest menu-bar item: the
    /// full lobe when there is room, a shrunk lobe down to the floor, or 0 (pet
    /// hidden) once even the floor would overlap.
    private func effectivePetLobe(_ geo: NotchGeometry) -> CGFloat {
        let base = geo.lobeWidth
        if rightLobeAllowance >= base { return base }
        if rightLobeAllowance < IslandMetric.lobeFloor { return 0 }
        return rightLobeAllowance
    }

    /// Probe the menu bar for the nearest right-side status item and re-derive how
    /// wide the pet lobe may be. Only rebuilds/repositions when the effective lobe
    /// actually changes, so the slow poll is cheap and flicker-free.
    private func probeClamp() {
        guard let geo = geometry, panel != nil else { return }
        let result = MenuBarProbe.probe(
            notchCenterX: geo.notchCenterX,
            notchMaxX: geo.notchRect.maxX,
            menuBarHeight: geo.notchRect.height,
            screenMaxX: geo.screen.frame.maxX,
            myPID: Int(ProcessInfo.processInfo.processIdentifier))
        guard result.trustworthy else { return }
        let allowance = result.nearestMinX.map { $0 - geo.notchRect.maxX - IslandMetric.lobeGap }
            ?? .greatestFiniteMagnitude
        let oldLobe = effectivePetLobe(geo)
        rightLobeAllowance = allowance
        guard effectivePetLobe(geo) != oldLobe else { return }
        hosting?.rootView = makeRoot(geo)
        positionWindow()
    }

    private func startClampProbe() {
        probeClamp()
        guard clampTimer == nil else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.probeClamp() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        clampTimer = timer
    }

    private func stopClampProbe() { clampTimer?.invalidate(); clampTimer = nil }

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
        chrome.dropdownOpen = true
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
        chrome.dropdownOpen = false
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
