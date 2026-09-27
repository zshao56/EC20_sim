import Foundation

public enum CallHistoryType: String, Sendable, Codable {
    case outgoing = "OUTGOING"
    case incoming = "INCOMING"
    case missed = "MISSED"
    case rejected = "REJECTED"
}

public enum CallRecordSource: String, Sendable, Codable {
    case local = "LOCAL"
    case moduleDC = "MODULE_DC" // Dialed Calls from modem
    case moduleMC = "MODULE_MC" // Missed Calls from modem
    case moduleRC = "MODULE_RC" // Received Calls from modem
}

public struct CallHistoryItem: Identifiable, Hashable, Equatable, Sendable, Codable {
    public let id: UUID
    public var phoneNumber: String
    public var normalizedPhone: String
    public var contactName: String?
    public var type: CallHistoryType
    public var timestamp: Date?
    public var durationSeconds: Int?
    public var source: CallRecordSource
    public var hasExactTimestamp: Bool

    public init(
        id: UUID = UUID(),
        phoneNumber: String,
        contactName: String? = nil,
        type: CallHistoryType,
        timestamp: Date? = Date(),
        durationSeconds: Int? = nil,
        source: CallRecordSource = .local,
        hasExactTimestamp: Bool = true
    ) {
        self.id = id
        let clean = phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalPhone = clean.isEmpty ? "未知号码" : clean
        self.phoneNumber = finalPhone
        let norm = PhoneNumberNormalizer.normalize(finalPhone)
        self.normalizedPhone = norm.isEmpty ? "未知号码" : norm
        self.contactName = contactName
        self.type = type
        self.timestamp = timestamp
        self.durationSeconds = durationSeconds
        self.source = source
        self.hasExactTimestamp = hasExactTimestamp
    }

    public var maskedPhoneNumber: String {
        SensitiveMasker.mask(phoneNumber: phoneNumber)
    }
}
