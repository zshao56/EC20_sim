import Foundation

public enum CPINStatus: String, Sendable {
    case ready = "READY"
    case simPin = "SIM PIN"
    case simPuk = "SIM PUK"
    case notInserted = "NOT INSERTED"
    case unknown = "UNKNOWN"
}

public enum NetworkRegStatus: Int, Sendable {
    case notRegistered = 0
    case registeredHome = 1
    case searching = 2
    case denied = 3
    case unknown = 4
    case roaming = 5
    
    public var description: String {
        switch self {
        case .notRegistered: return "Not Registered"
        case .registeredHome: return "Registered (Home)"
        case .searching: return "Searching..."
        case .denied: return "Registration Denied"
        case .unknown: return "Unknown"
        case .roaming: return "Registered (Roaming)"
        }
    }
}

public struct SignalInfo: Equatable, Sendable {
    public let csq: Int // 0-31, 99
    public let rssi_dBm: Int?
    
    public init(csq: Int) {
        self.csq = csq
        if csq == 99 || csq < 0 {
            self.rssi_dBm = nil
        } else {
            // CSQ 0 = -113 dBm, CSQ 31 = -51 dBm: dBm = -113 + 2 * csq
            self.rssi_dBm = -113 + (2 * csq)
        }
    }
    
    public var signalBars: Int {
        switch csq {
        case 20...31: return 4
        case 14...19: return 3
        case 8...13: return 2
        case 1...7: return 1
        default: return 0
        }
    }
    
    public var summary: String {
        if let dbm = rssi_dBm {
            return "\(dbm) dBm (\(csq)/31)"
        } else {
            return "No Signal (99)"
        }
    }
}

public struct SIMCardInfo: Equatable, Sendable {
    public var cpinStatus: CPINStatus = .unknown
    public var cregStatus: NetworkRegStatus = .unknown
    public var ceregStatus: NetworkRegStatus = .unknown
    public var signal: SignalInfo = SignalInfo(csq: 99)
    public var operatorName: String? = nil
    public var iccid: String? = nil
    public var imsi: String? = nil
    public var imei: String? = nil
    public var model: String? = nil
    public var revision: String? = nil
    
    public init() {}
    
    // Masked properties for UI and logs
    public var maskedICCID: String {
        SensitiveMasker.mask(identifier: iccid)
    }
    
    public var maskedIMSI: String {
        SensitiveMasker.mask(identifier: imsi)
    }
    
    public var maskedIMEI: String {
        SensitiveMasker.mask(identifier: imei)
    }
    
    public var isRegistered: Bool {
        cregStatus == .registeredHome || cregStatus == .roaming ||
        ceregStatus == .registeredHome || ceregStatus == .roaming
    }
}
