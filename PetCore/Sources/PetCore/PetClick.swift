import Foundation

public enum PetClick {
    public static func allowed(lastClickMs: Int64?, nowMs: Int64, cooldownSeconds: Int) -> Bool {
        guard let last = lastClickMs else { return true }
        return nowMs - last >= Int64(cooldownSeconds) * 1000
    }
}
