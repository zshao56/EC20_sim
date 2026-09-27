import Foundation

public final class PhoneAttributionLookup: @unchecked Sendable {
    public static let shared = PhoneAttributionLookup()

    private let lock = NSLock()
    private var phoneDatData: Data? = nil

    // In-memory trie / prefix map for fast built-in offline resolution
    private let mobilePrefixes: [String: (province: String, city: String, isp: String)] = [
        // Beijing
        "1380000": ("北京", "北京", "中国移动"),
        "1380100": ("北京", "北京", "中国移动"),
        "1300100": ("北京", "北京", "中国联通"),
        "1330100": ("北京", "北京", "中国电信"),
        // Shanghai
        "1380160": ("上海", "上海", "中国移动"),
        "1300210": ("上海", "上海", "中国联通"),
        "1330160": ("上海", "上海", "中国电信"),
        // Guangdong (Guangzhou, Shenzhen)
        "1380013": ("广东", "广州", "中国移动"),
        "1380020": ("广东", "广州", "中国移动"),
        "1380075": ("广东", "深圳", "中国移动"),
        "1382370": ("广东", "深圳", "中国移动"),
        "1300755": ("广东", "深圳", "中国联通"),
        // Zhejiang (Hangzhou)
        "1926702": ("浙江", "杭州", "中国广电"),
        "1380571": ("浙江", "杭州", "中国移动"),
        "1300571": ("浙江", "杭州", "中国联通"),
        // Jiangsu
        "1381234": ("江苏", "无锡", "中国移动"),
        "1380516": ("江苏", "徐州", "中国移动"),
        "1380250": ("江苏", "南京", "中国移动"),
        // Sichuan
        "1380280": ("四川", "成都", "中国移动"),
        // Hubei
        "1380270": ("湖北", "武汉", "中国移动"),
        // Shaanxi
        "1380290": ("陕西", "西安", "中国移动")
    ]

    // Landline area codes
    private let landlineAreaCodes: [(prefix: String, province: String, city: String)] = [
        ("010", "北京", "北京"),
        ("020", "广东", "广州"),
        ("021", "上海", "上海"),
        ("022", "天津", "天津"),
        ("023", "重庆", "重庆"),
        ("024", "辽宁", "沈阳"),
        ("025", "江苏", "南京"),
        ("027", "湖北", "武汉"),
        ("028", "四川", "成都"),
        ("029", "陕西", "西安"),
        ("0755", "广东", "深圳"),
        ("0769", "广东", "东莞"),
        ("0757", "广东", "佛山"),
        ("0571", "浙江", "杭州"),
        ("0574", "浙江", "宁波"),
        ("0577", "浙江", "温州"),
        ("0512", "江苏", "苏州"),
        ("0510", "江苏", "无锡"),
        ("0519", "江苏", "常州"),
        ("0592", "福建", "厦门"),
        ("0591", "福建", "福州"),
        ("0532", "山东", "青岛"),
        ("0531", "山东", "济南"),
        ("0311", "河北", "石家庄"),
        ("0371", "河南", "郑州"),
        ("0731", "湖南", "长沙"),
        ("0551", "安徽", "合肥"),
        ("0791", "江西", "南昌"),
        ("0431", "吉林", "长春"),
        ("0451", "黑龙江", "哈尔滨"),
        ("0898", "海南", "海口"),
        ("0771", "广西", "南宁"),
        ("0871", "云南", "昆明"),
        ("0851", "贵州", "贵阳"),
        ("0931", "甘肃", "兰州"),
        ("0971", "青海", "西宁"),
        ("0951", "宁夏", "银川"),
        ("0991", "新疆", "乌鲁木齐"),
        ("0891", "西藏", "拉萨"),
        ("0471", "内蒙古", "呼和浩特")
    ]

    // Service numbers
    private let serviceNumbers: [String: String] = [
        "10010": "中国联通 官方客服",
        "10011": "中国联通 话费充值专线",
        "10086": "中国移动 官方客服",
        "1008611": "中国移动 话费查询",
        "10000": "中国电信 官方客服",
        "10001": "中国电信 充值专线",
        "10099": "中国广电 官方客服",
        "95588": "中国工商银行 客服",
        "95533": "中国建设银行 客服",
        "95566": "中国银行 客服",
        "95599": "中国农业银行 客服",
        "95555": "招商银行 客服",
        "95511": "中国平安 客服",
        "95508": "广发银行 客服",
        "95568": "民生银行 客服",
        "95528": "浦发银行 客服",
        "95559": "交通银行 客服",
        "95558": "中信银行 客服",
        "95595": "光大银行 客服",
        "95580": "邮政储蓄银行 客服",
        "12306": "中国铁路 客户服务",
        "12315": "消费者投诉举报专线",
        "12345": "政务便民服务热线",
        "12329": "住房公积金热线",
        "12333": "人力资源社会保障热线"
    ]

    // Emergency numbers
    private let emergencyNumbers: [String: String] = [
        "110": "公安报警",
        "119": "火警电话",
        "120": "急救中心",
        "122": "交通事故报警"
    ]

    // International country codes
    private let internationalCodes: [(code: String, country: String)] = [
        ("+1", "美国/加拿大"),
        ("+44", "英国"),
        ("+81", "日本"),
        ("+82", "韩国"),
        ("+65", "新加坡"),
        ("+852", "中国香港"),
        ("+853", "中国澳门"),
        ("+886", "中国台湾"),
        ("+61", "澳大利亚"),
        ("+49", "德国"),
        ("+33", "法国"),
        ("+39", "意大利"),
        ("+7", "俄罗斯"),
        ("+91", "印度"),
        ("+60", "马来西亚"),
        ("+66", "泰国"),
        ("+62", "印度尼西亚"),
        ("+63", "菲律宾"),
        ("+84", "越南")
    ]

    public init(phoneDatPath: String? = nil) {
        if let path = phoneDatPath, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            self.phoneDatData = data
        }
    }

    /// Loads external phone.dat binary data
    public func loadPhoneDat(data: Data) {
        lock.lock()
        self.phoneDatData = data
        lock.unlock()
    }

    /// Resolves attribution for any given telephone number
    public func lookup(_ raw: String) -> PhoneAttribution {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == "未知号码" {
            return PhoneAttribution(category: .unknown, rawInput: raw)
        }

        // 1. Emergency Numbers (110, 119, 120, 122)
        if let desc = emergencyNumbers[cleaned] {
            return PhoneAttribution(province: "全国", city: "", isp: desc, category: .emergency, rawInput: raw)
        }

        // 2. Service Numbers (10010, 10086, 95588, etc.)
        if let desc = serviceNumbers[cleaned] {
            return PhoneAttribution(province: "全国", city: "", isp: desc, category: .service, rawInput: raw)
        }
        if (cleaned.count == 5 && (cleaned.hasPrefix("95") || cleaned.hasPrefix("96"))) ||
           (cleaned.count == 3 && cleaned.hasPrefix("1") && cleaned.allSatisfy({ $0.isNumber })) {
            return PhoneAttribution(province: "全国", city: "", isp: "服务热线", category: .service, rawInput: raw)
        }

        // 3. Toll-Free Numbers (400, 800)
        let pureDigits = cleaned.filter { $0.isNumber }
        if pureDigits.hasPrefix("400") && pureDigits.count == 10 {
            return PhoneAttribution(province: "全国", city: "", isp: "400 企业服务", category: .tollFree, rawInput: raw)
        }
        if pureDigits.hasPrefix("800") && pureDigits.count == 10 {
            return PhoneAttribution(province: "全国", city: "", isp: "800 免费服务", category: .tollFree, rawInput: raw)
        }

        // 4. International Numbers (starts with + or 00, but not +86 / 0086)
        if (cleaned.hasPrefix("+") && !cleaned.hasPrefix("+86")) ||
           (cleaned.hasPrefix("00") && !cleaned.hasPrefix("0086")) {
            let intlClean = cleaned.hasPrefix("00") ? ("+" + cleaned.dropFirst(2)) : cleaned
            for (code, country) in internationalCodes {
                if intlClean.hasPrefix(code) {
                    return PhoneAttribution(province: "\(country) (\(code))", city: "", isp: "境外号码", category: .international, rawInput: raw)
                }
            }
            return PhoneAttribution(province: "境外", city: "", isp: "境外号码", category: .international, rawInput: raw)
        }

        // Normalize Chinese number: remove +86 or 0086
        var localDigits = pureDigits
        if localDigits.hasPrefix("0086") {
            localDigits = String(localDigits.dropFirst(4))
        } else if localDigits.hasPrefix("86") && localDigits.count > 10 {
            localDigits = String(localDigits.dropFirst(2))
        }

        // 5. Landline Numbers with Area Code
        let landlineCandidate = localDigits.hasPrefix("0") ? localDigits : ("0" + localDigits)
        if localDigits.hasPrefix("0") || (!localDigits.hasPrefix("1") && localDigits.count >= 9 && localDigits.count <= 12) {
            // Sort by prefix length descending for longest prefix match
            for item in landlineAreaCodes.sorted(by: { $0.prefix.count > $1.prefix.count }) {
                if landlineCandidate.hasPrefix(item.prefix) {
                    return PhoneAttribution(
                        province: item.province,
                        city: item.city,
                        isp: "固定电话",
                        category: .landline,
                        rawInput: raw
                    )
                }
            }
            if localDigits.hasPrefix("0") {
                return PhoneAttribution(province: "中国大陆", city: "", isp: "固定电话", category: .landline, rawInput: raw)
            }
        }

        // 6. Mainland 11-digit mobile numbers (starts with 1)
        if localDigits.count == 11 && localDigits.hasPrefix("1") {
            let carrier = determineCarrier(for: localDigits)

            // Try phone.dat binary lookup if loaded
            if let dat = getPhoneDatData(), let resolved = lookupPhoneDat(digits: localDigits, data: dat) {
                return PhoneAttribution(
                    province: resolved.province,
                    city: resolved.city,
                    isp: resolved.isp.isEmpty ? carrier : resolved.isp,
                    category: .mobile,
                    rawInput: raw
                )
            }

            // Try in-memory 7-digit segment lookup
            let prefix7 = String(localDigits.prefix(7))
            if let entry = mobilePrefixes[prefix7] {
                return PhoneAttribution(
                    province: entry.province,
                    city: entry.city,
                    isp: entry.isp,
                    category: .mobile,
                    rawInput: raw
                )
            }

            // Safe fallback when 7-digit detail is not in embedded segment map
            return PhoneAttribution(
                province: "中国大陆",
                city: "",
                isp: carrier,
                category: .mobile,
                rawInput: raw
            )
        }

        return PhoneAttribution(category: .unknown, rawInput: raw)
    }

    private func getPhoneDatData() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return phoneDatData
    }

    private func determineCarrier(for mobile11: String) -> String {
        let prefix3 = String(mobile11.prefix(3))
        switch prefix3 {
        case "134", "135", "136", "137", "138", "139", "147", "150", "151", "152", "157", "158", "159", "172", "178", "182", "183", "184", "187", "188", "195", "197", "198":
            return "中国移动"
        case "130", "131", "132", "145", "155", "156", "166", "171", "175", "176", "185", "186", "196":
            return "中国联通"
        case "133", "149", "153", "173", "177", "180", "181", "189", "190", "191", "193", "199":
            return "中国电信"
        case "192":
            return "中国广电"
        default:
            return "中国大陆"
        }
    }

    /// Binary search in standard phone.dat format
    /// Format: [header: 4B "phone.dat" tag or offset] + [index area: phone (4B), offset (4B), type (1B)]
    private func lookupPhoneDat(digits: String, data: Data) -> (province: String, city: String, isp: String)? {
        guard data.count >= 32 else { return nil }
        guard let phoneInt = UInt32(digits.prefix(7)) else { return nil }

        // Read total index count and offset from header
        let totalRecords = data.withUnsafeBytes { ptr -> UInt32 in
            ptr.load(fromByteOffset: 4, as: UInt32.self)
        }
        guard totalRecords > 0 && totalRecords < 1_000_000 else { return nil }

        var left: Int = 0
        var right: Int = Int(totalRecords) - 1

        while left <= right {
            let mid = (left + right) / 2
            let entryOffset = 8 + mid * 9
            guard entryOffset + 9 <= data.count else { break }

            let (targetPhone, recordOffset, _) = data.withUnsafeBytes { ptr -> (UInt32, UInt32, UInt8) in
                let p = ptr.load(fromByteOffset: entryOffset, as: UInt32.self)
                let o = ptr.load(fromByteOffset: entryOffset + 4, as: UInt32.self)
                let t = ptr.load(fromByteOffset: entryOffset + 8, as: UInt8.self)
                return (p, o, t)
            }

            if targetPhone == phoneInt {
                // Found record; read null-terminated string at recordOffset
                let offset = Int(recordOffset)
                guard offset < data.count else { return nil }
                var end = offset
                while end < data.count && data[end] != 0 {
                    end += 1
                }
                guard let text = String(data: data[offset..<end], encoding: .utf8) ?? String(data: data[offset..<end], encoding: .isoLatin1) else {
                    return nil
                }
                // String usually formatted as "Province|City|Zip|AreaCode"
                let parts = text.components(separatedBy: "|")
                let prov = parts.count > 0 ? parts[0] : ""
                let city = parts.count > 1 ? parts[1] : ""
                return (province: prov, city: city, isp: "")
            } else if targetPhone < phoneInt {
                left = mid + 1
            } else {
                right = mid - 1
            }
        }
        return nil
    }
}
