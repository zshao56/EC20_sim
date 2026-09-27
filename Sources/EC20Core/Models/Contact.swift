import Foundation

public struct Contact: Identifiable, Hashable, Equatable, Sendable, Codable {
    public let id: UUID
    public var name: String
    public var phoneNumber: String
    public var normalizedPhone: String
    public var notes: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        phoneNumber: String,
        notes: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.phoneNumber = phoneNumber
        self.normalizedPhone = PhoneNumberNormalizer.normalize(phoneNumber)
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
