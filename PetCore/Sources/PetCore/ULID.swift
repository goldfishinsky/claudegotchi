import Foundation
import Security

/// Standard ULID: 48-bit ms timestamp prefix + 80-bit random suffix, encoded
/// as 26 chars of Crockford base32. The 10-char prefix encodes 50 bits but
/// real-world ms timestamps fit in 48 bits until year 10889, so the first
/// char only uses values 0-7 — matching the spec.
public enum ULID {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public static func generate() -> String {
        let ms = UInt64(Date().timeIntervalSince1970 * 1000)
        var rand = [UInt8](repeating: 0, count: 10)
        let result = SecRandomCopyBytes(kSecRandomDefault, rand.count, &rand)
        precondition(result == errSecSuccess,
                     "SecRandomCopyBytes failed (\(result)); cannot produce a valid ULID")
        return encodeTime(ms) + encodeRandom(rand)
    }

    public static func timestampMs(from ulid: String) -> UInt64? {
        guard ulid.count == 26 else { return nil }
        var v: UInt64 = 0
        for c in ulid.prefix(10) {
            guard let i = alphabet.firstIndex(of: c) else { return nil }
            v = v * 32 + UInt64(i)
        }
        return v
    }

    private static func encodeTime(_ ms: UInt64) -> String {
        var ms = ms
        var out = [Character](repeating: "0", count: 10)
        for i in (0..<10).reversed() {
            out[i] = alphabet[Int(ms & 0x1f)]
            ms >>= 5
        }
        return String(out)
    }

    /// Encodes 80 random bits (10 bytes) as exactly 16 base32 chars.
    private static func encodeRandom(_ bytes: [UInt8]) -> String {
        precondition(bytes.count == 10)
        var out = ""
        var buffer: UInt64 = 0
        var bits: UInt64 = 0
        for b in bytes {
            buffer = (buffer << 8) | UInt64(b)
            bits += 8
            while bits >= 5 {
                bits -= 5
                let idx = Int((buffer >> bits) & 0x1f)
                out.append(alphabet[idx])
            }
        }
        // 80 bits ≡ 0 mod 5, so no leftover bits to flush.
        return out
    }
}
