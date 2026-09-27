import Foundation

public enum PhoneNumberCategory: String, Sendable, Codable {
    case mobile = "MOBILE"                   // 蜂窝移动电话
    case landline = "LANDLINE"               // 固定电话 (如 010, 021, 0755)
    case service = "SERVICE"                 // 常用服务号 / 客服号 (如 10086, 10010, 95588)
    case emergency = "EMERGENCY"             // 紧急特服号 (110, 119, 120, 122)
    case tollFree = "TOLL_FREE"               // 400 / 800 企业服务热线
    case international = "INTERNATIONAL"     // 国际 / 境外号码
    case unknown = "UNKNOWN"                 // 未知类别
}

public struct PhoneAttribution: Equatable, Sendable, Codable {
    public let province: String
    public let city: String
    public let isp: String
    public let category: PhoneNumberCategory
    public let rawInput: String

    public init(
        province: String = "",
        city: String = "",
        isp: String = "",
        category: PhoneNumberCategory = .unknown,
        rawInput: String = ""
    ) {
        self.province = province
        self.city = city
        self.isp = isp
        self.category = category
        self.rawInput = rawInput
    }

    public var carrier: String { isp }
    public var country: String? { category == .international ? province : nil }

    /// User-facing short formatted attribution string (e.g. "北京 移动", "广东深圳 联通", "中国建设银行客服")
    public var displayString: String {
        switch category {
        case .emergency:
            return province.isEmpty ? "\(isp) (紧急电话)" : "\(province) \(isp)"
        case .service:
            if !isp.isEmpty { return isp }
            return "服务热线"
        case .tollFree:
            return isp.isEmpty ? "企业服务热线" : isp
        case .international:
            return province.isEmpty ? "境外号码" : "境外号码 (\(province))"
        case .landline:
            var parts: [String] = []
            if !province.isEmpty { parts.append(province) }
            if !city.isEmpty && city != province { parts.append(city) }
            if !isp.isEmpty { parts.append(isp) }
            return parts.isEmpty ? "固定电话" : parts.joined(separator: " ")
        case .mobile:
            var parts: [String] = []
            if !province.isEmpty { parts.append(province) }
            if !city.isEmpty && city != province { parts.append(city) }
            if !isp.isEmpty { parts.append(isp) }
            return parts.isEmpty ? "中国大陆移动号码" : parts.joined(separator: " ")
        case .unknown:
            return "未知归属地"
        }
    }
}
