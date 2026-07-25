import Foundation

/// Small stage props the pet acts with, drawn in the shared PixelSpeciesCatalog
/// palette. Authored on the same 32-grid as the pet sprites, so a prop pixel is
/// half a stage cell and no prop rises past ~40% of the pet's height.
public enum PropSprite: String, Equatable, CaseIterable {
    case laptop, foodS, foodM, foodL
}

public enum PixelProps {
    /// Stage units per prop pixel: props share the pet sprites' 32-grid density.
    public static let cellUnits: Double = 0.5

    private static func idx(_ c: Character) -> UInt8 {
        switch c {
        case "#": return 1   // food outline (warm brown)
        case "W": return 2   // rice / highlight white
        case "V": return 8   // veggie green
        case "S": return 20  // laptop shell
        case "G": return 21  // screen glow
        case "H": return 22  // umeboshi red
        case "B": return 23  // bento tan
        case "P": return 24  // salmon
        case "@": return 34  // laptop ink
        case "K": return 35  // keycap slate
        case "T": return 36  // terminal green
        case "N": return 37  // nori
        case "r": return 38  // rice shade
        default: return 0
        }
    }

    private static func m(_ rows: [String]) -> PixelFrame { rows.map { $0.map(idx) } }

    public static func matrix(_ p: PropSprite) -> PixelFrame {
        switch p {
        case .laptop: return laptop
        case .foodS: return foodS
        case .foodM: return foodM
        case .foodL: return foodL
        }
    }

    /// Prop footprint in stage units.
    public static func size(_ p: PropSprite) -> (width: Double, height: Double) {
        let g = matrix(p)
        return (Double(g.first?.count ?? 0) * cellUnits, Double(g.count) * cellUnits)
    }

    /// Open laptop, 18×10: lit terminal screen, hinge break, keyed deck flaring
    /// one pixel wider than the lid.
    public static let laptop = m([
        ".@@@@@@@@@@@@@@@@.",
        ".@GGGGGGGGGGGGWW@.",
        ".@GTTTTTTTTGGGGW@.",
        ".@GGGGGGGGGGGGGG@.",
        ".@GTTTTTGWGGGGGG@.",
        ".@GGGGGGGGGGGGGG@.",
        ".@@@@@@@@@@@@@@@@.",
        "@SKKKKKKKKKKKKKKS@",
        "@SSSSSSSSSSSSSSSS@",
        "@@@@@@@@@@@@@@@@@@",
    ])

    /// Onigiri S, 8×8.
    public static let foodS = m([
        "...##...",
        "..#WW#..",
        "..#WW#..",
        ".#WWWr#.",
        ".#WWWr#.",
        "#WNNNNr#",
        "#NNNNNN#",
        ".######.",
    ])

    /// Onigiri M with umeboshi, 10×10.
    public static let foodM = m([
        "....##....",
        "...#WW#...",
        "..#WHHW#..",
        "..#WHHW#..",
        ".#WWWWWr#.",
        ".#WWWWWr#.",
        "#WWWWWWWr#",
        "#NNNNNNNN#",
        "#NNNNNNNN#",
        ".########.",
    ])

    /// Bento box L, 14×10: rice with umeboshi, salmon and veggie compartments.
    public static let foodL = m([
        "##############",
        "#BBBBBBBBBBBB#",
        "#BWWWWW#PPPPB#",
        "#BWHHWW#PPPPB#",
        "#BWWWWW#PPPPB#",
        "#BWWWWW#####B#",
        "#BWWWWW#VVVVB#",
        "#BWWWWr#VVVVB#",
        "#BBBBBBBBBBBB#",
        "##############",
    ])
}
