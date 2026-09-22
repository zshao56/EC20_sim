import Foundation

public enum CallStatus: String, Sendable {
    case idle = "IDLE"
    case dialing = "DIALING"
    case ringingIncoming = "RINGING"
    case active = "ACTIVE"
    case held = "HELD"
    case ended = "ENDED"
}

public enum CallDirection: String, Sendable {
    case incoming = "INCOMING"
    case outgoing = "OUTGOING"
}

public struct CallRecord: Identifiable, Equatable, Sendable {
    public let id: Int
    public let direction: CallDirection
    public var status: CallStatus
    public let phoneNumber: String
    public var startedAt: Date?
    public var endedAt: Date?
    
    public init(id: Int, direction: CallDirection, status: CallStatus, phoneNumber: String, startedAt: Date? = nil, endedAt: Date? = nil) {
        self.id = id
        self.direction = direction
        self.status = status
        self.phoneNumber = phoneNumber
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
    
    public var maskedPhoneNumber: String {
        SensitiveMasker.mask(phoneNumber: phoneNumber)
    }
}
