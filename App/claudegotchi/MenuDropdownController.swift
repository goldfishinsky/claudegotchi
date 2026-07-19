import AppKit
import SwiftUI
import PetCore

// Opts out of the menu-bar clamp so the card's transparent glow margin may
// overlap the menu bar and the visible card hang flush beneath it.
private final class DropdownPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

// Anchors the dreamy card under the status-item button as a borderless,
// non-activating panel (transparent so the warm glow spills past the card).
// Dismisses on any click outside the panel; runs the system-stats sampler only
// while visible.
@MainActor
final class MenuDropdownController {
    private let driver: SystemStatsDriver
    private let usageDriver: ClaudeUsageDriver
    private let makeRoot: () -> AnyView

    private var panel: NSPanel?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    // Guards the reopen that would otherwise fire when the click on the status
    // item both dismisses (via the monitor) and re-toggles the panel.
    private var closedAt = Date.distantPast

    init(driver: SystemStatsDriver, usageDriver: ClaudeUsageDriver, root: @escaping () -> AnyView) {
        self.driver = driver
        self.usageDriver = usageDriver
        self.makeRoot = root
    }

    var isVisible: Bool { panel != nil }

    func toggle(relativeTo button: NSStatusBarButton) {
        if isVisible { hide() } else { show(relativeTo: button) }
    }

    func show(relativeTo button: NSStatusBarButton) {
        guard panel == nil else { return }
        guard Date().timeIntervalSince(closedAt) > 0.15 else { return }
        driver.start()
        usageDriver.start()

        let hosting = NSHostingController(rootView: makeRoot())
        hosting.view.layoutSubtreeIfNeeded()
        let size = hosting.view.fittingSize

        let panel = DropdownPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.contentViewController = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false

        position(panel, under: button, size: size)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        installMonitors()
    }

    func hide() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        panel?.orderOut(nil)
        panel = nil
        closedAt = Date()
        driver.stop()
        usageDriver.stop()
    }

    private func position(_ panel: NSPanel, under button: NSStatusBarButton, size: NSSize) {
        guard let buttonWindow = button.window else { return }
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let vf = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? buttonRect
        let margin = DropdownCard.glowMargin
        let cardW = DropdownCard.cardWidth
        let cardH = size.height - margin * 2

        // Work in the visual card's own frame, then inset by `margin` for the
        // window: the transparent glow border is 30pt on every side, so the
        // window sits that far below/left of the card's visible bottom-left.
        let cardRight = min(buttonRect.maxX, vf.maxX - 6)
        let cardLeft = max(vf.minX + 6, cardRight - cardW)

        // Menu-bar bottom off the physical frame, not visibleFrame: a non-notch
        // aware app gets a visibleFrame shrunk below the notch, so on notched
        // displays trust safeAreaInsets.top. Card top hangs 4pt under it; clamp
        // up only if too tall, so the footer stays on-screen.
        let scr = buttonWindow.screen ?? NSScreen.main
        let frame = scr?.frame ?? vf
        let safeTop = scr?.safeAreaInsets.top ?? 0
        let menuBarBottom = frame.maxY - (safeTop > 0 ? safeTop : frame.maxY - vf.maxY)
        let cardTop = max(menuBarBottom - 4, vf.minY + 6 + cardH)

        let originX = cardLeft - margin
        let originY = (cardTop - cardH) - margin
        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
    }

    private func installMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                if event.window !== panel { self.hide() }
            }
            return event
        }
    }
}
