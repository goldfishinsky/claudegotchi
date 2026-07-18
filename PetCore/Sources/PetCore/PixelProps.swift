import Foundation

/// Small stage props the pet acts with, drawn in the shared PixelSpeciesCatalog
/// palette. Kept ≤12×12 so they read at hero size beside a 16×16 pet.
public enum PropSprite: String, Equatable, CaseIterable {
    case laptop, foodS, foodM, foodL
}

public enum PixelProps {
    private static func idx(_ c: Character) -> UInt8 {
        switch c {
        case "#": return 1   // outline
        case "W": return 2   // rice / highlight white
        case "k": return 3   // keyboard dark
        case "V": return 8   // veggie green
        case "S": return 20  // laptop shell
        case "G": return 21  // screen glow
        case "H": return 22  // umeboshi red
        case "B": return 23  // bento tan
        case "P": return 24  // salmon
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

    /// Open laptop, 11×7: glowing screen over a keyboard base.
    public static let laptop = m([
        "#GGGGGGGGG#",
        "#GWGGGGGWG#",
        "#GGGGGGGGG#",
        "#GGGGGGGGG#",
        "###########",
        "#SSSSSSSSS#",
        "#SkkkkkkkS#",
    ])

    /// Rice ball S, 6×6.
    public static let foodS = m([
        "..##..",
        ".#WW#.",
        "#WWWW#",
        "#WWWW#",
        "#kWWk#",
        ".#kk#.",
    ])

    /// Rice ball M with umeboshi, 8×8.
    public static let foodM = m([
        "...##...",
        "..#HW#..",
        ".#WWWW#.",
        "#WWWWWW#",
        "#WWWWWW#",
        "#kWWWWk#",
        ".#kkkk#.",
        "..####..",
    ])

    /// Bento box L, 10×8: rice, salmon, veggie compartments.
    public static let foodL = m([
        ".########.",
        "#BBBBBBBB#",
        "#WWWWPPPP#",
        "#WWWWPPPP#",
        "#WWWWPPPP#",
        "#VVVVBBBB#",
        "#VVVVBBBB#",
        ".########.",
    ])
}
