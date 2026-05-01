import Foundation

public enum DeathWindow {
    public static func parse(_ json: String) -> [Bool] {
        guard let data = json.data(using: .utf8) else { return [] }
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        var out: [Bool] = []
        for v in arr {
            guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else {
                return []
            }
            out.append(n.boolValue)
        }
        return out
    }

    public static func serialize(_ window: [Bool]) -> String {
        let parts = window.map { $0 ? "true" : "false" }
        return "[" + parts.joined(separator: ",") + "]"
    }

    public static func appendDay(pet: Pet, lowToday: Bool) -> Pet {
        var window = parse(pet.deathWindowState)
        window.append(lowToday)
        if window.count > 5 { window = Array(window.suffix(5)) }
        var p = pet
        p.deathWindowState = serialize(window)
        return p
    }

    public static func shouldDie(pet: Pet) -> Bool {
        let window = parse(pet.deathWindowState)
        return window.count == 5 && window.allSatisfy { $0 }
    }

    public static func isLowDay(pet: Pet, threshold: Double, requiredCount: Int) -> Bool {
        var lowCount = 0
        if pet.fullness <= threshold { lowCount += 1 }
        if pet.stamina  <= threshold { lowCount += 1 }
        if pet.intimacy <= threshold { lowCount += 1 }
        return lowCount >= requiredCount
    }
}
