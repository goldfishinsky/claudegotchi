import AppKit

guard CommandLine.arguments.count == 2 else {
    fputs("usage: swift generate_app_icon.swift <output.png>\n", stderr)
    exit(2)
}

let size = CGFloat(1024)
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size),
    pixelsHigh: Int(size),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("failed to create icon canvas\n", stderr)
    exit(1)
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
defer { NSGraphicsContext.restoreGraphicsState() }

NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: size, height: size).fill()

let tileRect = NSRect(x: 72, y: 72, width: 880, height: 880)
let tile = NSBezierPath(roundedRect: tileRect, xRadius: 210, yRadius: 210)
NSGraphicsContext.current?.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor(calibratedWhite: 0.18, alpha: 0.20)
shadow.shadowBlurRadius = 38
shadow.shadowOffset = NSSize(width: 0, height: -18)
shadow.set()
NSColor(calibratedRed: 1.00, green: 0.94, blue: 0.84, alpha: 1).setFill()
tile.fill()
NSGraphicsContext.current?.restoreGraphicsState()

let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 1.00, green: 0.97, blue: 0.91, alpha: 1),
    NSColor(calibratedRed: 1.00, green: 0.78, blue: 0.49, alpha: 1),
])!
gradient.draw(in: tile, angle: -72)

NSColor(calibratedWhite: 1, alpha: 0.38).setStroke()
tile.lineWidth = 8
tile.stroke()

let hamster = [
    "................................",
    "................................",
    "................................",
    ".......####..........####.......",
    "......#O^^O##########O^^O#......",
    "......#O^^OOOOOOOOOOOO^^O#......",
    ".......#^^LLLLLOOOOOOO^^#.......",
    "......#OLLLLLLLLOOOOOOOOO#......",
    ".....#OLLLLLLLLLLOOOOOOOOO#.....",
    ".....#OLLLLLLLLLLOOOOOOOOO#.....",
    "....#OOLLLLLLLLLLOOOOOOOOOO#....",
    "....#OOLLLLLLLLLLOOOOOOOOOO#....",
    "....#OOLLwxLLLLLLOOOOwxOOOO#....",
    "....#OOOLxxLLLLLOOOOOxxOOOO#....",
    "....#OOOOxxLLLLSSSSOoxxooOO#....",
    ".....#OOOOOOSSSSSSSSoooooo#.....",
    ".....#OOOOOSSSSSSSSSSooooo#.....",
    "......#OOOSSSS^^SSSSSSooo#......",
    "......#OOOSSSS^^SSSSSSooo#......",
    "......#OOSSSSSSSSSSSSSSoo#......",
    ".....#OOOSSSSSSSSSSSSSSooo#.....",
    "......#OOSSSSSSSSSSSSSSoo#......",
    "......#OOSSSSSSSSSSSSSSoo#......",
    "......#OOSSSSSSSSSSSSSSoo#......",
    "......#OOOSddddddddddSooo#......",
    ".......#OOddddddddddddoo#.......",
    "........#OOddddddddddoo#........",
    ".........#OOddddddddoo#.........",
    ".........#.dddd..dddd.#.........",
    "........#SDSS##..##SSDS#........",
    ".........####......####.........",
    "................................",
]

let palette: [Character: NSColor] = [
    "#": NSColor(calibratedRed: 0.23, green: 0.18, blue: 0.15, alpha: 1),
    "O": NSColor(calibratedRed: 0.91, green: 0.71, blue: 0.39, alpha: 1),
    "o": NSColor(calibratedRed: 0.69, green: 0.45, blue: 0.22, alpha: 1),
    "L": NSColor(calibratedRed: 0.98, green: 0.92, blue: 0.78, alpha: 1),
    "S": NSColor(calibratedRed: 0.95, green: 0.75, blue: 0.53, alpha: 1),
    "d": NSColor(calibratedRed: 0.76, green: 0.48, blue: 0.28, alpha: 1),
    "D": NSColor(calibratedRed: 0.36, green: 0.25, blue: 0.18, alpha: 1),
    "^": NSColor(calibratedRed: 0.94, green: 0.58, blue: 0.39, alpha: 1),
    "w": NSColor.white,
    "x": NSColor(calibratedRed: 0.20, green: 0.15, blue: 0.13, alpha: 1),
]

let cell = CGFloat(20)
let spriteSide = cell * 32
let origin = NSPoint(x: (size - spriteSide) / 2, y: 190)
for (row, line) in hamster.enumerated() {
    for (column, symbol) in line.enumerated() {
        guard let color = palette[symbol] else { continue }
        color.setFill()
        NSRect(
            x: origin.x + CGFloat(column) * cell,
            y: origin.y + CGFloat(31 - row) * cell,
            width: cell,
            height: cell
        ).fill()
    }
}

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("failed to encode icon\n", stderr)
    exit(1)
}

try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
