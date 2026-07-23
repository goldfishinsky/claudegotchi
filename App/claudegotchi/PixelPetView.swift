import SwiftUI
import AppKit
import GRDB
import PetCore

enum PixelPalette {
    static func rgba(_ argb: UInt32) -> (r: Double, g: Double, b: Double, a: Double) {
        let a = Double((argb >> 24) & 0xFF) / 255.0
        let r = Double((argb >> 16) & 0xFF) / 255.0
        let g = Double((argb >> 8) & 0xFF) / 255.0
        let b = Double(argb & 0xFF) / 255.0
        return (r, g, b, a)
    }

    static func color(_ index: UInt8) -> Color? {
        color(index, in: PixelSpeciesCatalog.palette)
    }

    static func color(_ index: UInt8, in palette: [UInt32]) -> Color? {
        guard index != 0, Int(index) < palette.count else { return nil }
        let (r, g, b, a) = rgba(palette[Int(index)])
        return Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// Base-palette lookup with a genome hue rotation, used for particles so a
    /// pet's confetti/sparks pick up its personality tint. 0° is the identity.
    static func color(_ index: UInt8, hueShiftDegrees: Double) -> Color? {
        guard index != 0, Int(index) < PixelSpeciesCatalog.palette.count else { return nil }
        let (r, g, b, a) = rgba(PixelSpeciesCatalog.palette[Int(index)])
        guard hueShiftDegrees != 0 else { return Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
        let (h, s, v) = rgbToHSB(r, g, b)
        var nh = (h + hueShiftDegrees / 360).truncatingRemainder(dividingBy: 1)
        if nh < 0 { nh += 1 }
        return Color(hue: nh, saturation: s, brightness: v, opacity: a)
    }

    private static func rgbToHSB(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d != 0 {
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }
}

private func framesFor(visual: PetVisual, species: String) -> [PixelFrame]? {
    guard let def = PixelSpeciesCatalog.def(species) else { return nil }
    let anim = visual.animation.rawValue
    return def.frames["\(visual.stage)/\(anim)"] ?? def.frames[anim] ?? def.frames["idle"]
}

struct PixelPetView: View {
    let visual: PetVisual
    let species: String
    let animationSpeed: Double
    let appearance: PetAppearance
    var onTap: (() -> Void)?

    @State private var frameIndex = 0

    init(visual: PetVisual, species: String, animationSpeed: Double = 1.0,
         appearance: PetAppearance = .base, onTap: (() -> Void)? = nil) {
        self.visual = visual
        self.species = species
        self.animationSpeed = animationSpeed
        self.appearance = appearance
        self.onTap = onTap
    }

    private var frames: [PixelFrame]? { framesFor(visual: visual, species: species) }

    private var frameInterval: Double { 0.8 / max(0.1, animationSpeed) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: frameInterval)) { context in
            Canvas { ctx, size in
                draw(in: &ctx, size: size, tickCount: tickCount(context.date))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
    }

    private func tickCount(_ date: Date) -> Int {
        Int(date.timeIntervalSinceReferenceDate / frameInterval)
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize, tickCount: Int) {
        let side = min(size.width, size.height)
        guard let frames, !frames.isEmpty else {
            drawGenericFallback(in: &ctx, size: size)
            return
        }
        let frame = appearance.transformedFrame(frames[tickCount % frames.count])
        let gridSize = frame.count
        guard gridSize > 0 else { return }
        let cell = floor(side / CGFloat(gridSize))
        let used = cell * CGFloat(gridSize)
        let originX = (size.width - used) / 2
        let originY = (size.height - used) / 2

        for (r, row) in frame.enumerated() {
            for (c, idx) in row.enumerated() {
                guard let color = PixelPalette.color(idx, in: appearance.palette) else { continue }
                let rect = CGRect(
                    x: originX + CGFloat(c) * cell,
                    y: originY + CGFloat(r) * cell,
                    width: cell, height: cell
                )
                ctx.fill(Path(rect), with: .color(color))
            }
        }

        drawOverlay(in: &ctx, size: size, side: side)
    }

    private func drawGenericFallback(in ctx: inout GraphicsContext, size: CGSize) {
        let side = min(size.width, size.height)
        let inset = side * 0.2
        let rect = CGRect(
            x: (size.width - side) / 2 + inset,
            y: (size.height - side) / 2 + inset,
            width: side - inset * 2, height: side - inset * 2
        )
        let color = PixelPalette.color(1) ?? Color.gray
        ctx.fill(Path(roundedRect: rect, cornerRadius: inset), with: .color(color))
    }

    private func drawOverlay(in ctx: inout GraphicsContext, size: CGSize, side: CGFloat) {
        guard visual.overlay != .none else { return }
        let dotColor: Color = visual.overlay == .sweat
            ? Color(.sRGB, red: 0.3, green: 0.6, blue: 1.0, opacity: 1)
            : Color(.sRGB, red: 1.0, green: 0.8, blue: 0.2, opacity: 1)
        let dot = max(2, side * 0.18)
        let rect = CGRect(x: size.width - dot - 1, y: 1, width: dot, height: dot)
        ctx.fill(Path(ellipseIn: rect), with: .color(dotColor))
    }
}

enum PixelPetRenderer {
    static func renderToNSImage(visual: PetVisual, species: String, size: CGFloat = 18,
                                genome: Int64? = nil) -> NSImage {
        let appearance = PetLook.make(genome: genome, species: species).appearance
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }
        guard let cgctx = NSGraphicsContext.current?.cgContext else { return image }

        let frames = framesFor(visual: visual, species: species)
        if let frames, let raw = frames.first {
            let frame = appearance.transformedFrame(raw)
            let gridSize = frame.count
            guard gridSize > 0 else { return image }
            let cell = floor(size / CGFloat(gridSize))
            let used = cell * CGFloat(gridSize)
            let originX = (size - used) / 2
            let originY = (size - used) / 2
            for (r, row) in frame.enumerated() {
                for (c, idx) in row.enumerated() {
                    guard idx != 0, Int(idx) < appearance.palette.count else { continue }
                    let (cr, cg, cb, ca) = PixelPalette.rgba(appearance.palette[Int(idx)])
                    cgctx.setFillColor(red: cr, green: cg, blue: cb, alpha: ca)
                    // Canvas rows run top→bottom; NSImage origin is bottom-left.
                    let y = originY + (CGFloat(gridSize - 1 - r)) * cell
                    cgctx.fill(CGRect(x: originX + CGFloat(c) * cell, y: y, width: cell, height: cell))
                }
            }
            drawIconOverlay(cgctx, visual: visual, size: size)
        } else {
            let (cr, cg, cb, ca) = PixelPalette.rgba(PixelSpeciesCatalog.palette[1])
            cgctx.setFillColor(red: cr, green: cg, blue: cb, alpha: ca)
            let inset = size * 0.2
            cgctx.fillEllipse(in: CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2))
        }
        return image
    }

    private static func drawIconOverlay(_ cgctx: CGContext, visual: PetVisual, size: CGFloat) {
        guard visual.overlay != .none else { return }
        if visual.overlay == .sweat {
            cgctx.setFillColor(red: 0.3, green: 0.6, blue: 1.0, alpha: 1)
        } else {
            cgctx.setFillColor(red: 1.0, green: 0.8, blue: 0.2, alpha: 1)
        }
        let dot = max(2, size * 0.18)
        cgctx.fillEllipse(in: CGRect(x: size - dot - 1, y: size - dot - 1, width: dot, height: dot))
    }
}

enum PetClickGate {
    static func lastClickMs(_ db: DatabaseQueue) throws -> Int64? {
        try db.read { conn in
            try Int64.fetchOne(conn, sql: "SELECT MAX(ts) FROM event WHERE type = 'pet_click'")
        }
    }
}
