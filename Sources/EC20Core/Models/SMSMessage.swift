import Foundation

public enum MessageSendStatus: String, Sendable, Codable {
    case sending = "SENDING"
    case sent = "SENT"
    case failed = "FAILED"
}

public struct SMSMessage: Identifiable, Hashable, Equatable, Sendable, Codable {
    public let id: UUID
    public var threadId: String
    public var storageIndex: Int?
    public var storageArea: String? // "SM", "ME"
    public var senderOrRecipient: String
    public var text: String
    public var timestamp: Date
    public var isIncoming: Bool
    public var isRead: Bool
    public var sendStatus: MessageSendStatus
    public var sendError: String?
    public var rawPDU: String?
    public var multipartInfo: PDUCodec.MultipartInfo?

    public init(
        id: UUID = UUID(),
        threadId: String? = nil,
        storageIndex: Int? = nil,
        storageArea: String? = nil,
        senderOrRecipient: String,
        text: String,
        timestamp: Date = Date(),
        isIncoming: Bool = true,
        isRead: Bool = true,
        sendStatus: MessageSendStatus = .sent,
        sendError: String? = nil,
        rawPDU: String? = nil,
        multipartInfo: PDUCodec.MultipartInfo? = nil
    ) {
        self.id = id
        self.senderOrRecipient = senderOrRecipient
        self.threadId = threadId ?? PhoneNumberNormalizer.normalize(senderOrRecipient)
        self.storageIndex = storageIndex
        self.storageArea = storageArea
        self.text = text
        self.timestamp = timestamp
        self.isIncoming = isIncoming
        self.isRead = isRead
        self.sendStatus = sendStatus
        self.sendError = sendError
        self.rawPDU = rawPDU
        self.multipartInfo = multipartInfo
    }

    /// Stable deduplication key.
    /// Note: `String.hashValue` is randomly seeded per process, so it must never be
    /// used here; a deterministic FNV-1a hash keeps the key identical across restarts.
    public var dedupKey: String {
        let millis = Int((timestamp.timeIntervalSince1970 * 1000).rounded())
        let pduSig = Self.stableHash(rawPDU ?? text)
        if let area = storageArea, let idx = storageIndex {
            return "\(area):\(idx)|\(threadId)|\(millis)|\(pduSig)"
        }
        return "\(threadId)|\(millis)|\(isIncoming ? "IN" : "OUT")|\(pduSig)"
    }

    /// Deterministic 64-bit FNV-1a hash rendered as lowercase hex.
    public static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    public var maskedNumber: String {
        SensitiveMasker.mask(phoneNumber: senderOrRecipient)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: SMSMessage, rhs: SMSMessage) -> Bool {
        lhs.id == rhs.id
    }
}

public struct SMSConversation: Identifiable, Equatable, Sendable {
    public var id: String { threadId }
    public let threadId: String
    public let displayRecipient: String
    public var contactName: String?
    public var latestMessage: SMSMessage
    public var unreadCount: Int
    public var totalCount: Int

    public init(
        threadId: String,
        displayRecipient: String,
        contactName: String? = nil,
        latestMessage: SMSMessage,
        unreadCount: Int,
        totalCount: Int
    ) {
        self.threadId = threadId
        self.displayRecipient = displayRecipient
        self.contactName = contactName
        self.latestMessage = latestMessage
        self.unreadCount = unreadCount
        self.totalCount = totalCount
    }

    public var title: String {
        if let contactName = contactName, !contactName.isEmpty {
            return contactName
        }
        return displayRecipient
    }
}
