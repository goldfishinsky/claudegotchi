import AppKit
import SwiftUI
import PetCore

private final class FloatingPetPanel: NSPanel {
    var clampedDragOrigin: ((NSPoint, NSSize) -> NSPoint)?
    var onDragEnded: (() -> Void)?

    private var dragPanelOrigin: NSPoint?
    private var dragPointerOrigin: NSPoint?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Observe the window's raw mouse stream before SwiftUI gesture routing.
    /// Events still pass through to the pet, preserving taps and long presses.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            dragPanelOrigin = frame.origin
            dragPointerOrigin = NSEvent.mouseLocation
        case .leftMouseDragged:
            if let dragPanelOrigin, let dragPointerOrigin {
                let pointer = NSEvent.mouseLocation
                let proposed = NSPoint(
                    x: dragPanelOrigin.x + pointer.x - dragPointerOrigin.x,
                    y: dragPanelOrigin.y + pointer.y - dragPointerOrigin.y
                )
                setFrameOrigin(clampedDragOrigin?(proposed, frame.size) ?? proposed)
            }
        case .leftMouseUp:
            if dragPanelOrigin != nil { onDragEnded?() }
            dragPanelOrigin = nil
            dragPointerOrigin = nil
        default:
            break
        }
        super.sendEvent(event)
    }
}

private struct FloatingPetView: View {
    @ObservedObject var petModel: PetPanelModel
    let canReturnToIsland: Bool
    let onReturnToIsland: () -> Void
    let onOpenSettings: () -> Void
    let onHover: (Bool) -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = WarmTheme(scheme: scheme)
        Group {
            if let visual = petModel.visual {
                TheaterPetView(
                    visual: visual,
                    species: petModel.species,
                    signals: petModel.makeSignals(memPressureHigh: false),
                    theme: theme,
                    look: petModel.look,
                    onPet: { petModel.handlePetClick() },
                    onPetting: { petModel.handlePetting() },
                    onScene: { scene, nowMs in petModel.observeTheater(scene, nowMs: nowMs) },
                    sceneProvider: { signals, nowMs in
                        petModel.theaterScene(signals: signals, timeMs: nowMs)
                    }
                )
            } else {
                Text("🥚")
                    .font(.system(size: 46))
            }
        }
        .frame(width: FloatingPetController.windowSize.width,
               height: FloatingPetController.windowSize.height)
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        .contextMenu {
            if canReturnToIsland {
                Button("移回灵动岛", action: onReturnToIsland)
            }
            Button("打开设置", action: onOpenSettings)
        }
        .accessibilityLabel("桌面宠物，可拖动，右键打开菜单")
        .help("拖动宠物移动位置，右键切换展示方式")
    }
}

private struct FloatingAgentQuickList: View {
    @ObservedObject var agentModel: AgentActivityModel
    let onHover: (Bool) -> Void
    let onJump: (AgentActivity) -> Void

    @Environment(\.colorScheme) private var scheme

    private var theme: WarmTheme { WarmTheme(scheme: scheme) }
    private let rowLimit = 5

    var body: some View {
        let agents = agentModel.agents
        let t = theme
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(agents.count) 个活跃 Agent")
                    .font(WFont.caption.weight(.semibold))
                    .foregroundStyle(t.inkFaint)
                Spacer()
            }
            ForEach(Array(agents.prefix(rowLimit)), id: \.sessionId) { agent in
                FloatingAgentQuickRow(theme: t, agent: agent) { onJump(agent) }
            }
            if agents.count > rowLimit {
                Text("另有 \(agents.count - rowLimit) 个")
                    .font(WFont.caption)
                    .foregroundStyle(t.inkFaint)
                    .padding(.leading, 27)
            }
        }
        .padding(10)
        .frame(width: 310)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(
                    colors: [t.surfaceTop, t.surfaceBottom],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(t.ink.opacity(0.10), lineWidth: 0.7)
                )
        )
        .shadow(color: Color.black.opacity(t.isDark ? 0.24 : 0.10), radius: 6, y: 3)
        .padding(7)
        .onHover(perform: onHover)
    }
}

private struct FloatingAgentQuickRow: View {
    let theme: WarmTheme
    let agent: AgentActivity
    let onJump: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onJump) {
            HStack(spacing: 8) {
                AgentBrandMark(
                    platform: agent.platform,
                    color: agent.isCodex ? theme.inkStrong : rgb(0.88, 0.46, 0.30)
                )
                .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(agent.state == .working ? rgb(0.46, 0.85, 0.45) : theme.inkFaint)
                            .frame(width: 5, height: 5)
                        Text(agent.title ?? agent.repoLabel)
                            .font(WFont.vLabel)
                            .foregroundStyle(theme.ink)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Text(detail)
                        .font(WFont.caption)
                        .foregroundStyle(agent.state == .working ? theme.accent : theme.inkFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 6)
                Image(systemName: "arrow.up.forward.app.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .opacity(hovering ? 1 : 0.45)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(hovering ? theme.ink.opacity(0.08) : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(agent.isCodex ? "在 Codex 中打开此任务" : "跳到发起该会话的终端窗口")
    }

    private var detail: String {
        if agent.state == .working, let tool = agent.currentTool { return "正在 \(tool) · \(agent.repoLabel)" }
        if agent.title != nil { return agent.repoLabel }
        if let model = agent.model { return model }
        return agent.state == .working ? "正在工作" : "等待下一步"
    }
}

@MainActor
private final class FloatingAgentPanelController {
    private let agentModel: AgentActivityModel
    private let onJump: (AgentActivity) -> Void
    private var panel: NSPanel?
    private var hosting: NSHostingController<FloatingAgentQuickList>?
    private var sourceHovering = false
    private var panelHovering = false
    private var hideWork: DispatchWorkItem?

    init(agentModel: AgentActivityModel, onJump: @escaping (AgentActivity) -> Void) {
        self.agentModel = agentModel
        self.onJump = onJump
    }

    func sourceHover(_ hovering: Bool, relativeTo anchor: NSRect?) {
        sourceHovering = hovering
        if hovering, let anchor, !agentModel.agents.isEmpty {
            hideWork?.cancel()
            show(relativeTo: anchor)
        } else {
            scheduleHide()
        }
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
        panelHovering = false
    }

    private func show(relativeTo anchor: NSRect) {
        if let panel {
            position(panel, relativeTo: anchor)
            panel.orderFrontRegardless()
            return
        }
        let root = FloatingAgentQuickList(
            agentModel: agentModel,
            onHover: { [weak self] in self?.panelHover($0) },
            onJump: { [weak self] agent in
                self?.hide()
                self?.onJump(agent)
            }
        )
        let hosting = NSHostingController(rootView: root)
        hosting.view.layoutSubtreeIfNeeded()
        var size = hosting.view.fittingSize
        if size.width < 1 || size.height < 1 { size = NSSize(width: 334, height: 110) }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        self.hosting = hosting
        self.panel = panel
        position(panel, relativeTo: anchor)
        panel.orderFrontRegardless()
    }

    private func position(_ panel: NSPanel, relativeTo anchor: NSRect) {
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? anchor
        let size = panel.frame.size
        let gap: CGFloat = 7
        let proposedX = anchor.maxX + gap + size.width <= visible.maxX
            ? anchor.maxX + gap
            : anchor.minX - gap - size.width
        let x = min(max(proposedX, visible.minX + 6), visible.maxX - size.width - 6)
        let y = min(
            max(anchor.midY - size.height / 2, visible.minY + 6),
            visible.maxY - size.height - 6
        )
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func panelHover(_ hovering: Bool) {
        panelHovering = hovering
        if hovering { hideWork?.cancel() } else { scheduleHide() }
    }

    private func scheduleHide() {
        hideWork?.cancel()
        guard !sourceHovering, !panelHovering else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.sourceHovering, !self.panelHovering else { return }
            self.hide()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }
}

/// Transparent QQ-pet-style presentation: draggable on any Space, above normal
/// app windows, and restored at the user's last position on the next launch.
@MainActor
final class FloatingPetController {
    static let windowSize = NSSize(width: 220, height: 180)

    private enum Key {
        static let originX = "claudegotchi.floatingPet.originX"
        static let originY = "claudegotchi.floatingPet.originY"
    }

    private let petModel: PetPanelModel
    private let agentPanel: FloatingAgentPanelController
    private let onReturnToIsland: () -> Void
    private let onOpenSettings: () -> Void
    private var panel: NSPanel?
    private var hosting: NSHostingController<FloatingPetView>?
    private var screenObserver: NSObjectProtocol?
    private lazy var environmentSensor = DesktopEnvironmentSensor(
        frameProvider: { [weak self] in self?.panel?.frame },
        onUpdate: { [weak self] environment in
            self?.petModel.updateDesktopEnvironment(environment)
        }
    )

    init(
        petModel: PetPanelModel,
        agentModel: AgentActivityModel,
        onJumpAgent: @escaping (AgentActivity) -> Void,
        onReturnToIsland: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.petModel = petModel
        self.agentPanel = FloatingAgentPanelController(agentModel: agentModel, onJump: onJumpAgent)
        self.onReturnToIsland = onReturnToIsland
        self.onOpenSettings = onOpenSettings
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepOnScreen() }
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    var isVisible: Bool { panel != nil }

    func start() {
        guard panel == nil else { return }
        petModel.refresh()

        let root = FloatingPetView(
            petModel: petModel,
            canReturnToIsland: NotchGeometry.builtInNotch() != nil,
            onReturnToIsland: onReturnToIsland,
            onOpenSettings: onOpenSettings,
            onHover: { [weak self] in self?.petHover($0) }
        )
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = []
        self.hosting = hosting

        let frame = restoredFrame()
        let panel = FloatingPetPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.title = "桌面宠物"
        self.panel = panel
        panel.clampedDragOrigin = { [weak self] origin, size in
            self?.clampedOrigin(origin, size: size) ?? origin
        }
        panel.onDragEnded = { [weak self] in self?.finishDrag(userInitiated: true) }
        // Assigning a hosting controller can let AppKit rebase a borderless
        // panel by one content height during its first layout pass. Re-assert
        // the screen-space frame now, then clamp once more on the next run loop.
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        environmentSensor.start()
        DispatchQueue.main.async { [weak self] in self?.keepOnScreen() }
    }

    func stop() {
        agentPanel.hide()
        environmentSensor.stop()
        finishDrag(userInitiated: false)
        petModel.leaveDesktopEnvironment()
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
    }

    private func petHover(_ hovering: Bool) {
        // Use the visual pet core rather than the transparent 220×180 window
        // bounds as the anchor, keeping the quick list close to the character.
        let anchor = panel?.frame.insetBy(dx: 42, dy: 24)
        agentPanel.sourceHover(hovering, relativeTo: anchor)
    }

    /// Seeds the desktop pet at the point where it was released from the island.
    /// This is persisted before `start()` so the first floating frame appears in
    /// the right place instead of flashing at the previous saved position.
    func placeCentered(at screenPoint: NSPoint) {
        let size = Self.windowSize
        let proposed = NSPoint(
            x: screenPoint.x - size.width / 2,
            y: screenPoint.y - size.height / 2
        )
        let origin = clampedOrigin(proposed, size: size)
        panel?.setFrameOrigin(origin)
        persist(origin)
        petModel.recordDragLanding()
    }

    private func finishDrag(userInitiated: Bool) {
        guard let origin = panel?.frame.origin else { return }
        persist(origin)
        if userInitiated { petModel.recordDragLanding() }
    }

    private func persist(_ origin: NSPoint) {
        let defaults = UserDefaults.standard
        defaults.set(Double(origin.x), forKey: Key.originX)
        defaults.set(Double(origin.y), forKey: Key.originY)
    }

    private func restoredFrame() -> NSRect {
        let defaults = UserDefaults.standard
        let hasSaved = defaults.object(forKey: Key.originX) != nil
            && defaults.object(forKey: Key.originY) != nil
        let size = Self.windowSize
        let origin: NSPoint
        if hasSaved {
            origin = NSPoint(
                x: defaults.double(forKey: Key.originX),
                y: defaults.double(forKey: Key.originY))
        } else {
            let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
            origin = NSPoint(x: visible.maxX - size.width - 28, y: visible.minY + 36)
        }
        return NSRect(origin: clampedOrigin(origin, size: size), size: size)
    }

    private func keepOnScreen() {
        guard let panel else { return }
        panel.setFrameOrigin(clampedOrigin(panel.frame.origin, size: panel.frame.size))
        finishDrag(userInitiated: false)
    }

    private func clampedOrigin(_ origin: NSPoint, size: NSSize) -> NSPoint {
        let center = NSPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(center) })
            ?? panel?.screen
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame.insetBy(dx: 4, dy: 4) else { return origin }
        return NSPoint(
            x: min(max(origin.x, visible.minX), visible.maxX - size.width),
            y: min(max(origin.y, visible.minY), visible.maxY - size.height)
        )
    }
}
