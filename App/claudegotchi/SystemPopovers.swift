import SwiftUI

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

// Floating warm card for a hover popover; opaque enough to read over the card
// content it overlays.
struct MetricPopover<Content: View>: View {
    let theme: WarmTheme
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) { content }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(theme.isDark ? rgb(0.23, 0.20, 0.16) : rgb(1.0, 0.995, 0.97))
                    .shadow(color: theme.cardShadow, radius: 12, x: 0, y: 5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(theme.ink.opacity(0.10), lineWidth: 0.5)
            )
    }
}
