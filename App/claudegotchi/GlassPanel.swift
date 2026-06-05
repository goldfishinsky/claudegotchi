import AppKit
import SwiftUI

/// Behind-window vibrancy (frosted glass that shows the desktop through it) — the
/// native primitive behind apps like Ice. Hosted SwiftUI content must keep a
/// transparent background so the glass reads through. Appearance follows the
/// system (dark → dark frosted glass, light → light).
enum Glass {
    /// A resizable, titled-but-transparent glass window (transparent titlebar over
    /// window vibrancy) for the stats dashboard. Appearance follows the system.
    @MainActor
    static func window<V: View>(_ content: V,
                                size: NSSize,
                                title: String,
                                material: NSVisualEffectView.Material = .underWindowBackground) -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        win.title = title
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isOpaque = false
        win.backgroundColor = .clear
        win.isReleasedWhenClosed = false

        let fx = NSVisualEffectView()
        fx.material = material
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.translatesAutoresizingMaskIntoConstraints = false

        let host = NSHostingView(rootView: content)
        host.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            host.topAnchor.constraint(equalTo: fx.topAnchor),
            host.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
        win.contentView = fx
        win.center()
        return win
    }
}
