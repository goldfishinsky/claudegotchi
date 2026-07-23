import SwiftUI
import PetCore

// The living-pet stage: renders a PetTheater SceneFrame — ground line, props,
// the offset+squashed pet, particles, and a warm speech chip — driven at ~11fps
// while the dropdown is open. Signals arrive from PetPanelModel; the theater
// clock runs client-side per frame so motion stays smooth between refreshes.
struct TheaterPetView: View {
    let visual: PetVisual
    let species: String
    let signals: TheaterSignals
    let theme: WarmTheme
    var look: PetLook = .base
    var onTap: (() -> Void)? = nil
    /// Interactive dropdown theater: returns whether the tap was cooldown-counted.
    var onPet: (() -> Bool)? = nil
    /// Fires once when a ≥500ms hold is recognised (intimacy accrual is capped model-side).
    var onPetting: (() -> Void)? = nil
    /// Every rendered frame, for the sound layer to observe emission/behaviour edges.
    var onScene: ((SceneFrame, Int64) -> Void)? = nil

    private let cols = 30.0
    private let rows = 22.0
    private let petHomeX = 7.0
    private let petHomeY = 4.0
    private let groundRow = 20.0
    private let fps = 11.0

    private let comboTapCount = 4
    private let comboSpanMs: Int64 = 1200
    private let comboShowMs: Int64 = 2000

    @GestureState private var pressing = false
    @State private var petting = false
    @State private var lastTapMs: Int64?
    @State private var lastTapCounted = false
    @State private var tapTimes: [Int64] = []
    @State private var comboUntilMs: Int64?

    private var interactive: Bool { onPet != nil }

    var body: some View {
        GeometryReader { geo in
            TimelineView(.periodic(from: .now, by: 1.0 / fps)) { context in
                rendered(timeMs: Int64(context.date.timeIntervalSince1970 * 1000), size: geo.size)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { handleTap() }
        .gesture(holdGesture)
        .onChange(of: pressing) { isDown in
            petting = isDown
            if isDown { onPetting?() }
        }
    }

    private func rendered(timeMs: Int64, size: CGSize) -> some View {
        var s = signals
        if interactive {
            if let lastTapMs { s.lastTapAgeMs = timeMs - lastTapMs; s.lastTapCounted = lastTapCounted }
            if petting { s.pettingActive = true }
            if let comboUntilMs, timeMs < comboUntilMs { s.comboTap = true }
        }
        let scene = PetTheater.scene(signals: s, timeMs: timeMs, personality: look.personality)
        onScene?(scene, timeMs)
        return ZStack(alignment: .topLeading) {
            Canvas { ctx, canvasSize in draw(scene, in: &ctx, size: canvasSize) }
            if let bubble = scene.bubble {
                chip(bubble).position(headPoint(scene, size: size))
            }
        }
    }

    // MARK: gestures

    private var holdGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.5)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($pressing) { value, state, _ in
                if case .second(true, _) = value { state = true } else { state = false }
            }
    }

    private func handleTap() {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        guard let onPet else { onTap?(); return }
        recordComboTap(now)
        lastTapCounted = onPet()
        lastTapMs = now
    }

    private func recordComboTap(_ now: Int64) {
        tapTimes = tapTimes.filter { now - $0 <= comboSpanMs } + [now]
        if tapTimes.count >= comboTapCount {
            comboUntilMs = now + comboShowMs
            tapTimes = []
        }
    }

    // MARK: geometry

    private func cell(_ size: CGSize) -> CGFloat { min(size.width / cols, size.height / rows) }
    private func originX(_ size: CGSize) -> CGFloat { (size.width - cell(size) * cols) / 2 }
    private func originY(_ size: CGSize) -> CGFloat { (size.height - cell(size) * rows) / 2 }

    private func headPoint(_ scene: SceneFrame, size: CGSize) -> CGPoint {
        let c = cell(size)
        let x = originX(size) + CGFloat(petHomeX + scene.petOffsetX + 8) * c
        let y = originY(size) + CGFloat(petHomeY + scene.petOffsetY - 1) * c
        return CGPoint(x: x, y: max(9, y))
    }

    // MARK: chip

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(theme.isDark ? Color.white.opacity(0.16) : Color.white.opacity(0.92))
            )
            .overlay(Capsule().strokeBorder(theme.glow.opacity(0.35), lineWidth: 0.5))
            .shadow(color: theme.glow.opacity(0.25), radius: 3, y: 1)
            .fixedSize()
    }

    // MARK: canvas

    private func draw(_ scene: SceneFrame, in ctx: inout GraphicsContext, size: CGSize) {
        let c = cell(size)
        let ox = originX(size), oy = originY(size)

        func fill(_ gx: Double, _ gy: Double, _ w: Double, _ h: Double, _ color: Color) {
            let rect = CGRect(x: ox + CGFloat(gx) * c, y: oy + CGFloat(gy) * c,
                              width: CGFloat(w) * c, height: CGFloat(h) * c)
            ctx.fill(Path(rect), with: .color(color))
        }

        // warm ground line
        let ground = theme.isDark ? theme.halo.opacity(0.22) : theme.halo.opacity(0.5)
        fill(petHomeX - 4, groundRow, 24, 0.4, ground)

        for prop in scene.props where !prop.front {
            drawMatrix(PixelProps.matrix(prop.sprite), petHomeX + prop.x, petHomeY + prop.y, fill)
        }
        if let frames = framesFor(scene.frameKey), !frames.isEmpty {
            drawPet(look.appearance.transformedFrame(frames[scene.frame % frames.count]),
                    offX: scene.petOffsetX, offY: scene.petOffsetY, squash: scene.squash, fill)
        }
        for prop in scene.props where prop.front {
            drawMatrix(PixelProps.matrix(prop.sprite), petHomeX + prop.x, petHomeY + prop.y, fill)
        }
        for em in scene.emissions {
            for (i, p) in ParticleSim.particles(em).enumerated() {
                drawParticle(em.kind, p, seed: i, fill)
            }
        }
    }

    private func framesFor(_ key: String) -> [PixelFrame]? {
        guard let def = PixelSpeciesCatalog.def(species) else { return nil }
        return def.frames["\(visual.stage)/\(key)"] ?? def.frames[key] ?? def.frames["idle"]
    }

    private func drawMatrix(_ m: PixelFrame, _ ox: Double, _ oy: Double,
                            _ fill: (Double, Double, Double, Double, Color) -> Void) {
        for (r, row) in m.enumerated() {
            for (col, idx) in row.enumerated() {
                guard let color = PixelPalette.color(idx) else { continue }
                fill(ox + Double(col), oy + Double(r), 1, 1, color)
            }
        }
    }

    private func drawPet(_ frame: PixelFrame, offX: Double, offY: Double, squash: Double,
                         _ fill: (Double, Double, Double, Double, Color) -> Void) {
        let n = frame.count
        guard n > 0 else { return }
        let s = 16.0 / Double(n)            // stage-units per sprite cell: keeps a 32×32 pet the same footprint as 16×16
        let half = Double(n) / 2
        let squashX = min(1.3, max(0.75, 2 - squash))
        let anchorGX = petHomeX + offX + 8
        let anchorGY = petHomeY + offY + 16
        for (r, row) in frame.enumerated() {
            for (col, idx) in row.enumerated() {
                guard let color = PixelPalette.color(idx, in: look.appearance.palette) else { continue }
                let gx = anchorGX + (Double(col) - half) * squashX * s
                let gy = anchorGY + (Double(r) - Double(n)) * squash * s
                fill(gx, gy, squashX * s, squash * s, color)
            }
        }
    }

    private let heartShape: [(Int, Int)] = [(0, 0), (0, 2), (1, 0), (1, 1), (1, 2), (2, 1)]
    private let zShape: [(Int, Int)] = [(0, 0), (0, 1), (0, 2), (1, 1), (2, 0), (2, 1), (2, 2)]

    private func drawParticle(_ kind: ParticleKind, _ p: ParticleSim.P, seed: Int,
                              _ fill: (Double, Double, Double, Double, Color) -> Void) {
        let a = max(0, min(1, p.alpha))
        if a <= 0.02 { return }
        let hue = look.personality.particleHueShift
        func tint(_ idx: UInt8, _ fallback: Color) -> Color {
            (PixelPalette.color(idx, hueShiftDegrees: hue) ?? fallback).opacity(a)
        }
        let ax = petHomeX + p.x, ay = petHomeY + p.y
        switch kind {
        case .heartRise:
            let col = tint(22, .pink)
            for (dr, dc) in heartShape { fill(ax + Double(dc) * 0.6, ay + Double(dr) * 0.6, 0.6, 0.6, col) }
        case .zDrift:
            let col = tint(5, .blue)
            for (dr, dc) in zShape { fill(ax + Double(dc) * 0.55, ay + Double(dr) * 0.55, 0.55, 0.55, col) }
        case .confettiFall:
            let cols: [UInt8] = [22, 25, 8, 4, 21]
            fill(ax, ay, 1, 1, tint(cols[seed % cols.count], .orange))
        case .keystrokeSparks:
            fill(ax, ay, 0.7, 0.7, tint(21, .cyan))
        case .crumbBurst:
            fill(ax, ay, 0.7, 0.7, tint(23, .brown))
        case .tapDust:
            fill(ax, ay, 0.55, 0.55, tint(20, .gray))
        }
    }
}
