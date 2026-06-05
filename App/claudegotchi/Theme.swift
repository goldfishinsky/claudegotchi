import SwiftUI
import AppKit

/// Minimal native palette for a clean, translucent (vibrancy) look. Colors are
/// adaptive (`.primary`/`.secondary` over a blurred backdrop) so the panels read
/// as standard macOS popovers rather than an opaque themed surface.
enum Theme {
    static let healthy  = Color(red: 0.36, green: 0.78, blue: 0.50)   // stat fill
    static let low      = Color(red: 0.92, green: 0.38, blue: 0.33)   // low / danger
    static let track    = Color.primary.opacity(0.10)                 // stat track
    static let groupFill = Color.primary.opacity(0.055)               // inset group card
    static let hairline  = Color.primary.opacity(0.10)                // row divider
}

/// Behind-window vibrancy (frosted blur over the desktop), like a native
/// menu-bar settings popover.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}

/// A rounded translucent "inset group" container whose child rows align on one
/// content box (full-bleed dividers, consistent row insets).
struct GroupCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(Theme.groupFill)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5)
            )
    }
}

/// Full-bleed hairline divider between rows in a `GroupCard`.
struct RowDivider: View {
    var body: some View { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
}

/// Thin stat fill bar (healthy / low), used in the pet panel.
struct StatTrack: View {
    let value: Double          // 0…100
    let lowThreshold: Double
    var body: some View {
        let q = min(max(value, 0), 100) / 100
        let tint = value < lowThreshold ? Theme.low : Theme.healthy
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(tint).frame(width: max(0, geo.size.width * CGFloat(q)))
            }
        }
        .frame(height: 6)
    }
}
