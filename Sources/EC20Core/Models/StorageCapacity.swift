import Foundation

public struct StorageCapacity: Identifiable, Hashable, Equatable, Sendable, Codable {
    public var id: String { area }
    public let area: String // "SM", "ME"
    public let used: Int
    public let total: Int
    public let updatedAt: Date

    public init(area: String, used: Int, total: Int, updatedAt: Date = Date()) {
        self.area = area
        self.used = used
        self.total = total
        self.updatedAt = updatedAt
    }

    public var percent: Double {
        guard total > 0 else { return 0 }
        return min(1.0, max(0.0, Double(used) / Double(total)))
    }

    public var areaDisplayName: String {
        switch area {
        case "SM": return "SIM 卡短信存储"
        case "ME": return "模块终端存储 (ME)"
        default: return "\(area) 存储"
        }
    }
}
