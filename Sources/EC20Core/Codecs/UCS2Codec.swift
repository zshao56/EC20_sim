import Foundation

/// UCS2 (UTF-16 Big Endian) encoder and decoder commonly used in GSM/3GPP AT commands and PDU.
public enum UCS2Codec {
    
    /// Encodes a Swift string into uppercase hexadecimal UTF-16BE representation.
    /// Example: "你好" -> "4F60597D"
    public static func encode(_ text: String) -> String {
        var hex = ""
        for codePoint in text.utf16 {
            hex += String(format: "%04X", codePoint)
        }
        return hex
    }
    
    /// Decodes a hexadecimal UTF-16BE string into a Swift string.
    /// Example: "4F60597D" -> "你好"
    public static func decode(_ hex: String) -> String? {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count % 4 == 0 else { return nil }
        
        var utf16Units: [UInt16] = []
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let nextIndex = cleaned.index(index, offsetBy: 4)
            let substring = cleaned[index..<nextIndex]
            guard let val = UInt16(substring, radix: 16) else { return nil }
            utf16Units.append(val)
            index = nextIndex
        }
        
        return String(utf16CodeUnits: utf16Units, count: utf16Units.count)
    }
    
    /// Checks if a string contains non-GSM 7-bit characters (requiring UCS2 encoding)
    public static func requiresUCS2(_ text: String) -> Bool {
        // GSM 7-bit basic characters (roughly ASCII subset plus Greek/accented letters)
        // If any character is outside standard ASCII or is Chinese/CJK/Emoji, UCS2 is required.
        for scalar in text.unicodeScalars {
            if scalar.value > 0x7E || (scalar.value < 0x20 && scalar.value != 0x0A && scalar.value != 0x0D) {
                return true
            }
            // Some ASCII characters not in standard 7-bit GSM default alphabet
            if scalar == "`" || scalar == "{" || scalar == "}" || scalar == "\\" || scalar == "[" || scalar == "]" || scalar == "~" || scalar == "|" {
                // Extended table or UCS2
            }
        }
        return false
    }
}
