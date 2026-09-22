import Foundation

public struct SMSMessage: Identifiable, Hashable, Equatable, Sendable {
    public let id: UUID
    public var storageIndex: Int?
    public var storageArea: String? // "SM", "ME"
    public var senderOrRecipient: String
    public var text: String
    public var timestamp: Date
    public var isIncoming: Bool
    public var isRead: Bool
    public var rawPDU: String?
    public var multipartInfo: PDUCodec.MultipartInfo?
    
    public init(
        id: UUID = UUID(),
        storageIndex: Int? = nil,
        storageArea: String? = nil,
        senderOrRecipient: String,
        text: String,
        timestamp: Date = Date(),
        isIncoming: Bool = true,
        isRead: Bool = true,
        rawPDU: String? = nil,
        multipartInfo: PDUCodec.MultipartInfo? = nil
    ) {
        self.id = id
        self.storageIndex = storageIndex
        self.storageArea = storageArea
        self.senderOrRecipient = senderOrRecipient
        self.text = text
        self.timestamp = timestamp
        self.isIncoming = isIncoming
        self.isRead = isRead
        self.rawPDU = rawPDU
        self.multipartInfo = multipartInfo
    }
    
    public var maskedNumber: String {
        SensitiveMasker.mask(phoneNumber: senderOrRecipient)
    }
}
