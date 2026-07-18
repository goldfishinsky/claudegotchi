import AppKit
import SwiftUI

/// A resizable window with native chrome (traffic lights, draggable titlebar) whose
/// warm cream/cocoa surface — painted by the hosted SwiftUI content — spills to the
/// window edges under a transparent, full-size-content titlebar. Appearance follows
/// the system (light → cream, dark → warm cocoa).
enum Glass {
    @MainActor
    static func window<V: View>(_ content: V, size: NSSize, title: String) -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        win.title = title
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isOpaque = false
        win.backgroundColor = .clear
        win.isReleasedWhenClosed = false

        let host = NSHostingView(rootView: content)
        host.translatesAutoresizingMaskIntoConstraints = false
        win.contentView = host
        win.center()
        return win
    }
}
