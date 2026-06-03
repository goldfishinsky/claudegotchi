import Foundation

public enum RefValidator {
    public static func isValidBranch(_ s: String) -> Bool {
        guard !s.isEmpty, !s.hasPrefix("-"), !s.contains("..") else { return false }
        for scalar in s.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return false }
            if scalar.value < 0x20 || scalar.value == 0x7F { return false }
        }
        let metachars = CharacterSet(charactersIn: "~^:?*[\\ @")
        return s.rangeOfCharacter(from: metachars) == nil
    }

    public static func isValidSlug(_ s: String) -> Bool {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return isValidSegment(String(parts[0])) && isValidSegment(String(parts[1]))
    }

    public static func isValidLogin(_ s: String) -> Bool {
        guard !s.isEmpty, !s.hasPrefix("-") else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func isValidSegment(_ s: String) -> Bool {
        guard !s.isEmpty, !s.hasPrefix("-") else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
