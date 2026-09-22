import Foundation

/// Utility to mask sensitive identifiers such as ICCID, IMSI, IMEI, phone numbers, and serial numbers.
/// Required by project security constraints: "日志与文档须遮盖 ICCID/IMSI/手机号/设备序列号。"
public enum SensitiveMasker {
    
    /// Mask general numeric strings that represent ICCID (18-22 digits), IMSI (15 digits), IMEI (15 digits)
    public static func mask(identifier: String?) -> String {
        guard let s = identifier?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return "-"
        }
        if s.count <= 6 {
            return String(repeating: "*", count: s.count)
        }
        let prefixLen = min(4, s.count / 3)
        let suffixLen = min(4, s.count / 3)
        let prefix = s.prefix(prefixLen)
        let suffix = s.suffix(suffixLen)
        let maskedCount = max(4, s.count - prefixLen - suffixLen)
        return "\(prefix)\(String(repeating: "*", count: maskedCount))\(suffix)"
    }
    
    /// Mask phone number (+8613812345678 -> +86 138****5678 or 138****5678)
    public static func mask(phoneNumber: String?) -> String {
        guard let raw = phoneNumber?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return "-"
        }
        // Handle international prefix
        var number = raw
        var prefix = ""
        if number.hasPrefix("+") {
            prefix = "+"
            number.removeFirst()
        }
        
        let digits = number.filter { $0.isNumber }
        if digits.count < 7 {
            return prefix + String(repeating: "*", count: digits.count)
        }
        
        if digits.count == 13 && digits.hasPrefix("86") {
            let mobile = digits.dropFirst(2)
            let start = mobile.prefix(3)
            let end = mobile.suffix(4)
            return "\(prefix)86\(start)****\(end)"
        } else if digits.count == 11 {
            // Standard Chinese mobile number: 13812345678 -> 138****5678
            let start = digits.prefix(3)
            let end = digits.suffix(4)
            return "\(prefix)\(start)****\(end)"
        } else if digits.count > 11 {
            let start = digits.prefix(3)
            let end = digits.suffix(3)
            return "\(prefix)\(start)****\(end)"
        } else {
            let start = digits.prefix(2)
            let end = digits.suffix(2)
            let mid = String(repeating: "*", count: digits.count - 4)
            return "\(prefix)\(start)\(mid)\(end)"
        }
    }
    
    /// Regex-based sanitizer for raw log strings (AT traces, URC responses, system output)
    public static func sanitizeLog(_ text: String) -> String {
        var result = text
        
        // 1. Mask +QCCID: <digits>
        let qccidRegex = try? NSRegularExpression(pattern: #"(\+QCCID:\s*)([0-9A-Fa-f]{10,22})"#)
        if let matches = qccidRegex?.matches(in: result, range: NSRange(result.startIndex..., in: result)) {
            for match in matches.reversed() {
                if let range = Range(match.range(at: 2), in: result) {
                    let rawVal = String(result[range])
                    let masked = mask(identifier: rawVal)
                    result.replaceSubrange(range, with: masked)
                }
            }
        }
        
        // 2. Mask +CIMI / IMSI: 15 digits
        let cimiRegex = try? NSRegularExpression(pattern: #"(\b460\d{12}\b)"#)
        if let matches = cimiRegex?.matches(in: result, range: NSRange(result.startIndex..., in: result)) {
            for match in matches.reversed() {
                if let range = Range(match.range(at: 1), in: result) {
                    let rawVal = String(result[range])
                    let masked = mask(identifier: rawVal)
                    result.replaceSubrange(range, with: masked)
                }
            }
        }
        
        // 3. Mask +GSN / IMEI: 14-17 digits
        let gsnRegex = try? NSRegularExpression(pattern: #"(\b86\d{12,15}\b)"#)
        if let matches = gsnRegex?.matches(in: result, range: NSRange(result.startIndex..., in: result)) {
            for match in matches.reversed() {
                if let range = Range(match.range(at: 1), in: result) {
                    let rawVal = String(result[range])
                    let masked = mask(identifier: rawVal)
                    result.replaceSubrange(range, with: masked)
                }
            }
        }
        
        // 4. Mask CLIP / CMTI phone numbers: +CLIP: "13812345678"...
        let clipRegex = try? NSRegularExpression(pattern: #"(\+CLIP:\s*"?)(\+?\d{7,15})"?([,\s])"#)
        if let matches = clipRegex?.matches(in: result, range: NSRange(result.startIndex..., in: result)) {
            for match in matches.reversed() {
                if let range = Range(match.range(at: 2), in: result) {
                    let rawVal = String(result[range])
                    let masked = mask(phoneNumber: rawVal)
                    result.replaceSubrange(range, with: masked)
                }
            }
        }
        
        // 5. Mask CLCC phone numbers: +CLCC: 1,0,0,0,0,"13812345678"...
        let clccRegex = try? NSRegularExpression(pattern: #"(\+CLCC:\s*\d+,\d+,\d+,\d+,\d+,\")(\+?\d{7,15})(\")"#)
        if let matches = clccRegex?.matches(in: result, range: NSRange(result.startIndex..., in: result)) {
            for match in matches.reversed() {
                if let range = Range(match.range(at: 2), in: result) {
                    let rawVal = String(result[range])
                    let masked = mask(phoneNumber: rawVal)
                    result.replaceSubrange(range, with: masked)
                }
            }
        }

        return result
    }
}
