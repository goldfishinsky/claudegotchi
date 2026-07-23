import Foundation

/// A species' four authored base colours. The renderer never indexes these
/// directly; `PaletteRamp.expand` derives the eight slot colours the sprite
/// grids actually reference.
public struct SpeciesBase4: Equatable {
    public let body, dark, light, accent: UInt32
    public init(body: UInt32, dark: UInt32, light: UInt32, accent: UInt32) {
        self.body = body
        self.dark = dark
        self.light = light
        self.accent = accent
    }
}

/// Derives the eight per-species render slots from four base colours. The four
/// carried-over slots (body, bodyDark, light, accent) are returned bit-identical
/// so a grid touching only the legacy symbols renders exactly as before; the
/// four new slots (bodyLight, outline, secondary, secondaryDark) are computed in
/// HSB space so they track any base recolour deterministically.
public enum PaletteRamp {
    /// Returned in slot order: body, bodyDark, bodyLight, outline, light,
    /// secondary, secondaryDark, accent.
    public static func expand(body: UInt32, dark: UInt32, light: UInt32, accent: UInt32) -> [UInt32] {
        [
            body,                     // body
            dark,                     // bodyDark
            lighten(body, 0.18),      // bodyLight
            darken(dark, 0.35),       // outline (selout: a dark neighbour, not pure black)
            light,                    // light
            light,                    // secondary (defaults to the light region base)
            mix(light, dark, 0.5),    // secondaryDark
            accent,                   // accent
        ]
    }

    public static func expand(_ base: SpeciesBase4) -> [UInt32] {
        expand(body: base.body, dark: base.dark, light: base.light, accent: base.accent)
    }

    static func lighten(_ color: UInt32, _ amount: Double) -> UInt32 {
        var (h, s, b, a) = hsb(color)
        b = min(1, b + (1 - b) * amount)
        s = max(0, s * (1 - amount * 0.5))
        return fromHSB(h, s, b, a)
    }

    static func darken(_ color: UInt32, _ amount: Double) -> UInt32 {
        var (h, s, b, a) = hsb(color)
        b = max(0, b * (1 - amount))
        s = min(1, s + (1 - s) * amount * 0.4)
        return fromHSB(h, s, b, a)
    }

    static func mix(_ x: UInt32, _ y: UInt32, _ t: Double) -> UInt32 {
        func ch(_ v: UInt32, _ shift: UInt32) -> Double { Double((v >> shift) & 0xFF) }
        let a = ch(x, 24) * (1 - t) + ch(y, 24) * t
        let r = ch(x, 16) * (1 - t) + ch(y, 16) * t
        let g = ch(x, 8) * (1 - t) + ch(y, 8) * t
        let b = ch(x, 0) * (1 - t) + ch(y, 0) * t
        return pack(a, r, g, b)
    }

    // MARK: - colour space

    private static func hsb(_ argb: UInt32) -> (Double, Double, Double, Double) {
        let a = Double((argb >> 24) & 0xFF) / 255
        let r = Double((argb >> 16) & 0xFF) / 255
        let g = Double((argb >> 8) & 0xFF) / 255
        let b = Double(argb & 0xFF) / 255
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d != 0 {
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, mx == 0 ? 0 : d / mx, mx, a)
    }

    private static func fromHSB(_ h: Double, _ s: Double, _ v: Double, _ a: Double) -> UInt32 {
        let i = Int(floor(h * 6)) % 6
        let f = h * 6 - floor(h * 6)
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        let (r, g, b): (Double, Double, Double)
        switch (i + 6) % 6 {
        case 0: (r, g, b) = (v, t, p)
        case 1: (r, g, b) = (q, v, p)
        case 2: (r, g, b) = (p, v, t)
        case 3: (r, g, b) = (p, q, v)
        case 4: (r, g, b) = (t, p, v)
        default: (r, g, b) = (v, p, q)
        }
        return pack(a * 255, r * 255, g * 255, b * 255)
    }

    private static func pack(_ a: Double, _ r: Double, _ g: Double, _ b: Double) -> UInt32 {
        func byte(_ v: Double) -> UInt32 { UInt32(max(0, min(255, (v).rounded()))) }
        return (byte(a) << 24) | (byte(r) << 16) | (byte(g) << 8) | byte(b)
    }
}
