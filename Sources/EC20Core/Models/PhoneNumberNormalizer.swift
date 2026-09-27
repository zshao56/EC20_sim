import Foundation

public struct PhoneNumberNormalizer: Sendable {
    /// Normalizes phone numbers to standard format for thread grouping and contact matching.
    /// In particular:
    /// - Strips whitespace, dashes, slashes, brackets.
    /// - Normalizes Chinese 11-digit numbers (1xx xxxx xxxx) to "+861xxxxxxxxxx".
    /// - Normalizes "0086" to "+86".
    /// - Preserves standard shortcodes (e.g. "10010", "10086", "95588").
    public static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if trimmed == "未知号码" { return "未知号码" }

        // Remove standard phone formatting characters: spaces, '-', '(', ')', '.', '/'
        var cleaned = ""
        for ch in trimmed {
            if ch.isNumber || ch == "+" {
                cleaned.append(ch)
            }
        }

        // Normalize 0086 prefix to +86
        if cleaned.hasPrefix("0086") {
            cleaned = "+86" + cleaned.dropFirst(4)
        }

        // China mainland mobile numbers: 11 digits starting with 1 (e.g. 13800000000)
        // Normalize to +8613800000000 so threads match whether incoming (+86) or dialed locally (138)
        if cleaned.count == 11 && cleaned.hasPrefix("1") && cleaned.allSatisfy({ $0.isNumber }) {
            return "+86" + cleaned
        }

        return cleaned.isEmpty ? trimmed : cleaned
    }

    /// User-friendly display format. Guaranteed to never return empty string when input is missing or empty.
    public static func displayFormat(_ number: String) -> String {
        let trimmed = number.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "未知号码" {
            return "未知号码"
        }
        let norm = normalize(trimmed)
        if norm.isEmpty || norm == "未知号码" {
            return "未知号码"
        }
        if norm.hasPrefix("+86") && norm.count == 14 {
            // +86 138 0000 0000
            let p1 = norm.prefix(3)
            let p2 = norm.dropFirst(3).prefix(3)
            let p3 = norm.dropFirst(6).prefix(4)
            let p4 = norm.dropFirst(10)
            return "\(p1) \(p2) \(p3) \(p4)"
        }
        return norm
    }

    /// Checks if two phone numbers refer to the same recipient/sender
    public static func isSameNumber(_ a: String, _ b: String) -> Bool {
        let na = normalize(a)
        let nb = normalize(b)
        if na == nb { return true }
        if na.hasPrefix("+86") && na.dropFirst(3) == nb { return true }
        if nb.hasPrefix("+86") && nb.dropFirst(3) == na { return true }
        return false
    }
}
