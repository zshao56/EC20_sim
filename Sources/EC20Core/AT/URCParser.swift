import Foundation

public enum URCEvent: Equatable, Sendable {
    case incomingSMS(storage: String, index: Int)
    case incomingCall(callerNumber: String?)
    case ring
    case callEnded(reason: String)
    case cregChanged(status: NetworkRegStatus)
    case ceregChanged(status: NetworkRegStatus)
    case signalChanged(csq: Int)
    case simStatusChanged(cpin: CPINStatus)
    case systemIndication(String)
    case unhandled(String)
}

public enum URCParser {
    
    public static func isURC(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if trimmed == "RING" || trimmed == "NO CARRIER" || trimmed == "BUSY" {
            return true
        }
        if trimmed.hasPrefix("+CMTI:") ||
           trimmed.hasPrefix("+CLIP:") ||
           trimmed.hasPrefix("+CREG:") ||
           trimmed.hasPrefix("+CEREG:") ||
           trimmed.hasPrefix("+CSQ:") ||
           trimmed.hasPrefix("+CPIN:") ||
           trimmed.hasPrefix("+QIND:") ||
           trimmed.hasPrefix("+QIURC:") {
            return true
        }
        return false
    }
    
    public static func parse(_ line: String) -> URCEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        
        // 1. RING
        if trimmed == "RING" {
            return .ring
        }
        
        // 2. NO CARRIER / BUSY
        if trimmed == "NO CARRIER" || trimmed == "BUSY" {
            return .callEnded(reason: trimmed)
        }
        
        // 3. +CLIP: "13800000000",129,...
        if trimmed.hasPrefix("+CLIP:") {
            let content = trimmed.dropFirst("+CLIP:".count).trimmingCharacters(in: .whitespaces)
            let parts = content.components(separatedBy: ",")
            if let first = parts.first {
                let number = first.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)
                return .incomingCall(callerNumber: number.isEmpty ? nil : number)
            }
            return .incomingCall(callerNumber: nil)
        }
        
        // 4. +CMTI: "ME",1 or +CMTI: "SM",2
        if trimmed.hasPrefix("+CMTI:") {
            let content = trimmed.dropFirst("+CMTI:".count).trimmingCharacters(in: .whitespaces)
            let parts = content.components(separatedBy: ",")
            if parts.count >= 2 {
                let storage = parts[0].replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)
                let indexStr = parts[1].trimmingCharacters(in: .whitespaces)
                if let index = Int(indexStr) {
                    return .incomingSMS(storage: storage, index: index)
                }
            }
        }
        
        // 5. +CREG: <n>,<stat> or +CREG: <stat>
        if trimmed.hasPrefix("+CREG:") {
            let content = trimmed.dropFirst("+CREG:".count).trimmingCharacters(in: .whitespaces)
            let parts = content.components(separatedBy: ",")
            let statStr = (parts.count >= 2) ? parts[1].trimmingCharacters(in: .whitespaces) : parts[0].trimmingCharacters(in: .whitespaces)
            if let statInt = Int(statStr), let reg = NetworkRegStatus(rawValue: statInt) {
                return .cregChanged(status: reg)
            }
        }
        
        // 6. +CEREG: <n>,<stat> or +CEREG: <stat>
        if trimmed.hasPrefix("+CEREG:") {
            let content = trimmed.dropFirst("+CEREG:".count).trimmingCharacters(in: .whitespaces)
            let parts = content.components(separatedBy: ",")
            let statStr = (parts.count >= 2) ? parts[1].trimmingCharacters(in: .whitespaces) : parts[0].trimmingCharacters(in: .whitespaces)
            if let statInt = Int(statStr), let reg = NetworkRegStatus(rawValue: statInt) {
                return .ceregChanged(status: reg)
            }
        }
        
        // 7. +CSQ: <rssi>,<ber>
        if trimmed.hasPrefix("+CSQ:") {
            let content = trimmed.dropFirst("+CSQ:".count).trimmingCharacters(in: .whitespaces)
            let parts = content.components(separatedBy: ",")
            if let first = parts.first, let csq = Int(first.trimmingCharacters(in: .whitespaces)) {
                return .signalChanged(csq: csq)
            }
        }
        
        // 8. +CPIN: ...
        if trimmed.hasPrefix("+CPIN:") {
            let content = trimmed.dropFirst("+CPIN:".count).trimmingCharacters(in: .whitespaces)
            let status = CPINStatus(rawValue: content) ?? .unknown
            return .simStatusChanged(cpin: status)
        }
        
        // 9. +QIND: ...
        if trimmed.hasPrefix("+QIND:") {
            return .systemIndication(trimmed)
        }
        
        return .unhandled(trimmed)
    }
}
