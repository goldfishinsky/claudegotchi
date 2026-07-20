import SwiftUI

// MARK: - warm palette (shared design kit)
//
// The single source of the app's "dreamy warm" look: cream/ivory light and warm
// cocoa dark surfaces, muted warm-gray text, candy-gradient glyphs, soft rounded
// fills with no hairlines. Used by the menu-bar dropdown and the stats window.

struct WarmTheme {
    let scheme: ColorScheme
    var isDark: Bool { scheme == .dark }

    var surfaceTop: Color { isDark ? rgb(0.19, 0.16, 0.13) : rgb(1.0, 0.98, 0.95) }
    var surfaceBottom: Color { isDark ? rgb(0.14, 0.12, 0.095) : rgb(0.99, 0.93, 0.85) }
    var ink: Color { isDark ? rgb(0.82, 0.77, 0.69) : rgb(0.55, 0.52, 0.47) }
    var inkStrong: Color { isDark ? rgb(0.92, 0.88, 0.81) : rgb(0.40, 0.37, 0.32) }
    var inkFaint: Color { isDark ? rgb(0.62, 0.58, 0.51) : rgb(0.70, 0.66, 0.59) }
    var track: Color { ink.opacity(0.16) }
    var glow: Color { rgb(1.0, 0.72, 0.36) }
    var glowOpacity: Double { isDark ? 0.28 : 0.44 }
    var halo: Color { rgb(1.0, 0.80, 0.45) }
    var panelFill: Color { isDark ? Color.white.opacity(0.05) : Color.white.opacity(0.42) }
}

func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
    Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
}

enum Candy {
    static let memory      = [rgb(1.0, 0.75, 0.54), rgb(1.0, 0.44, 0.38)]
    static let netDown     = [rgb(0.50, 0.78, 1.0), rgb(0.30, 0.37, 0.84)]
    static let netUp       = [rgb(0.66, 0.85, 1.0), rgb(0.46, 0.52, 0.90)]
    static let cpu         = [rgb(1.0, 0.44, 0.85), rgb(0.35, 0.42, 1.0)]
    static let cpuHot      = [rgb(1.0, 0.55, 0.45), rgb(1.0, 0.34, 0.40)]
    static let disk        = [rgb(0.27, 0.84, 0.77), rgb(0.30, 0.82, 0.48)]
    static let battery     = [rgb(0.30, 0.85, 0.39), rgb(0.72, 0.91, 0.29)]
    static let bolt        = [rgb(1.0, 0.85, 0.35), rgb(1.0, 0.64, 0.22)]
    static let work        = [rgb(0.60, 0.60, 0.95), rgb(0.42, 0.44, 0.86)]
    static let full        = [rgb(1.0, 0.72, 0.50), rgb(1.0, 0.54, 0.30)]
    static let stam        = [rgb(0.46, 0.88, 0.50), rgb(0.72, 0.91, 0.29)]
    static let inti        = [rgb(1.0, 0.64, 0.78), rgb(1.0, 0.44, 0.61)]
    static let xp          = [rgb(1.0, 0.78, 0.42), rgb(1.0, 0.58, 0.30)]
    static let memNormal   = [rgb(0.36, 0.82, 0.60), rgb(0.30, 0.75, 0.52)]
    static let memElevated = [rgb(1.0, 0.74, 0.36), rgb(1.0, 0.60, 0.28)]
    static let memCritical = [rgb(1.0, 0.50, 0.42), rgb(0.94, 0.35, 0.35)]
}

enum WFont {
    static let strip   = Font.system(size: 10.5, weight: .medium, design: .rounded)
    static let label   = Font.system(size: 12, weight: .medium, design: .rounded)
    static let value   = Font.system(size: 12, weight: .semibold, design: .rounded)
    static let caption = Font.system(size: 9.5, weight: .medium, design: .rounded)
    static let vLabel  = Font.system(size: 11, weight: .medium, design: .rounded)
    static let vValue  = Font.system(size: 11, weight: .semibold, design: .rounded)
}

struct CandyIcon: View {
    let symbol: String
    let colors: [Color]
    var size: CGFloat = 16
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .shadow(color: colors[colors.count - 1].opacity(0.42), radius: 3, x: 0, y: 1)
    }
}

struct SoftPanel<Content: View>: View {
    let fill: Color
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(fill))
    }
}

struct SoftBar: View {
    let fraction: Double
    let colors: [Color]
    let track: Color
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule()
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, geo.size.width * CGFloat(min(max(fraction, 0), 1))))
            }
        }
        .frame(height: height)
    }
}

// Tiny equalizer of per-core load: one faint full-height track per core with a
// bottom-anchored gradient fill scaled to that core's usage. Unlabeled, compact.
struct CoreBar: View {
    let cores: [Double]
    let colors: [Color]
    let track: Color
    var height: CGFloat = 9

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(Array(cores.enumerated()), id: \.offset) { _, load in
                let f = CGFloat(min(1, max(0, load)))
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(track)
                    .overlay(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(LinearGradient(colors: colors, startPoint: .bottom, endPoint: .top))
                            .frame(height: max(1, height * f))
                    }
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: height)
    }
}

// Auto-scaled warm sparkline (no axes): faint gradient fill under a stroked path.
// Auto-scaling to the window's min/max keeps the shape legible at any load.
struct Sparkline: View {
    let values: [Double]
    let colors: [Color]
    var height: CGFloat = 26

    var body: some View {
        Canvas { ctx, size in
            guard values.count >= 2 else { return }
            let lo = values.min() ?? 0
            let hi = values.max() ?? 1
            let span = max(hi - lo, 1e-6)
            let n = values.count
            func point(_ i: Int) -> CGPoint {
                let x = size.width * CGFloat(i) / CGFloat(n - 1)
                let norm = CGFloat((values[i] - lo) / span)
                let y = size.height * (0.92 - norm * 0.84)
                return CGPoint(x: x, y: y)
            }
            var line = Path()
            line.move(to: point(0))
            for i in 1..<n { line.addLine(to: point(i)) }
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(
                Gradient(colors: [colors[0].opacity(0.30), colors[0].opacity(0.02)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(line, with: .linearGradient(
                Gradient(colors: colors), startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)),
                lineWidth: 1.5)
        }
        .frame(height: height)
    }
}

// MARK: - stats-window additions (larger surfaces, controls, buttons)

extension WarmTheme {
    var windowFill: LinearGradient {
        LinearGradient(colors: [surfaceTop, surfaceBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    /// Raised soft card resting on the cream surface.
    var cardFill: Color { isDark ? Color.white.opacity(0.055) : Color.white.opacity(0.60) }
    var cardShadow: Color { isDark ? Color.black.opacity(0.28) : rgb(0.85, 0.66, 0.45).opacity(0.24) }
    /// Inset track behind a segmented control.
    var pillTrack: Color { isDark ? Color.black.opacity(0.22) : rgb(0.95, 0.89, 0.81).opacity(0.75) }
    /// The selected segment / soft button surface.
    var pillActive: Color { isDark ? Color.white.opacity(0.12) : rgb(1.0, 0.995, 0.98) }
    var pillShadow: Color { isDark ? Color.black.opacity(0.35) : rgb(0.82, 0.62, 0.40).opacity(0.30) }
    /// Amber highlight for the viewer's own leaderboard row / selected states.
    var highlight: Color { rgb(1.0, 0.72, 0.36).opacity(isDark ? 0.18 : 0.22) }
    var accent: Color { isDark ? rgb(1.0, 0.66, 0.42) : rgb(0.94, 0.52, 0.28) }
    var good: Color { isDark ? rgb(0.54, 0.84, 0.56) : rgb(0.34, 0.68, 0.42) }
    var danger: Color { isDark ? rgb(1.0, 0.54, 0.48) : rgb(0.84, 0.34, 0.32) }
}

extension Candy {
    static let amber  = [rgb(1.0, 0.78, 0.42), rgb(1.0, 0.56, 0.28)]
    static let sky    = [rgb(0.46, 0.80, 1.0), rgb(0.32, 0.53, 0.96)]
    static let teal   = [rgb(0.30, 0.85, 0.74), rgb(0.22, 0.72, 0.62)]
    static let violet = [rgb(0.72, 0.57, 1.0), rgb(0.50, 0.40, 0.95)]
    static let coral  = [rgb(1.0, 0.62, 0.46), rgb(1.0, 0.42, 0.42)]
    static let rose   = [rgb(1.0, 0.64, 0.78), rgb(1.0, 0.44, 0.61)]
    static let lime   = [rgb(0.66, 0.86, 0.36), rgb(0.44, 0.76, 0.34)]
}

extension WFont {
    static let metric  = Font.system(size: 23, weight: .semibold, design: .rounded)
    static let title   = Font.system(size: 15, weight: .semibold, design: .rounded)
    static let section = Font.system(size: 11, weight: .semibold, design: .rounded)
    static let body    = Font.system(size: 12, weight: .regular, design: .rounded)
    static let segment = Font.system(size: 12, weight: .medium, design: .rounded)
}

/// A raised soft card. Per-call corner radius / padding so metric tiles, list
/// rows, and banners share one warm surface.
struct SoftCard<Content: View>: View {
    var fill: Color
    var cornerRadius: CGFloat = 16
    var padding: CGFloat = 12
    var shadow: Color = .clear
    var alignment: Alignment = .leading
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: alignment)
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(fill))
            .shadow(color: shadow, radius: 6, x: 0, y: 2)
    }
}

/// Soft warm "pill" segmented control (candy replacement for `.segmented` Picker).
struct WarmSegmented<T: Hashable>: View {
    @Binding var selection: T
    let items: [(value: T, label: String)]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = WarmTheme(scheme: scheme)
        HStack(spacing: 3) {
            ForEach(items, id: \.value) { item in
                let active = item.value == selection
                Text(item.label)
                    .font(WFont.segment.weight(active ? .semibold : .medium))
                    .foregroundStyle(active ? t.inkStrong : t.ink)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(active ? t.pillActive : Color.clear)
                            .shadow(color: active ? t.pillShadow : .clear, radius: 4, x: 0, y: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.14)) { selection = item.value }
                    }
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(t.pillTrack))
    }
}

struct WarmButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        WarmButton(configuration: configuration, prominent: prominent)
    }

    struct WarmButton: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        @Environment(\.colorScheme) private var scheme
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let t = WarmTheme(scheme: scheme)
            configuration.label
                .font(WFont.label.weight(.semibold))
                .foregroundStyle(prominent ? Color.white : t.inkStrong)
                .padding(.horizontal, 13)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(fill(t))
                        .shadow(color: t.pillShadow, radius: prominent ? 5 : 3, x: 0, y: 1)
                )
                .opacity(enabled ? (configuration.isPressed ? 0.7 : 1.0) : 0.4)
                .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
        }

        private func fill(_ t: WarmTheme) -> AnyShapeStyle {
            prominent
                ? AnyShapeStyle(LinearGradient(colors: Candy.amber, startPoint: .top, endPoint: .bottom))
                : AnyShapeStyle(t.pillActive)
        }
    }
}
