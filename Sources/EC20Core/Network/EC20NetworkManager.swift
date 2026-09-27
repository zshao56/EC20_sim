import Foundation

public struct CellularNetworkStatus: Equatable, Sendable {
    public let isSupported: Bool
    public let isServiceEnabled: Bool
    public let isServiceDisabledExternally: Bool
    public let isLinkActive: Bool
    public let interfaceName: String?
    public let serviceName: String?
    public let ipv4Address: String?
    public let ipv6Address: String?
    public let subnetMask: String?
    public let routerAddress: String?
    public let hardwareMAC: String?
    public let statusDescription: String

    public init(
        isSupported: Bool = false,
        isServiceEnabled: Bool = false,
        isServiceDisabledExternally: Bool = false,
        isLinkActive: Bool = false,
        interfaceName: String? = nil,
        serviceName: String? = nil,
        ipv4Address: String? = nil,
        ipv6Address: String? = nil,
        subnetMask: String? = nil,
        routerAddress: String? = nil,
        hardwareMAC: String? = nil,
        statusDescription: String = "未检测到蜂窝网络接口"
    ) {
        self.isSupported = isSupported
        self.isServiceEnabled = isServiceEnabled
        self.isServiceDisabledExternally = isServiceDisabledExternally
        self.isLinkActive = isLinkActive
        self.interfaceName = interfaceName
        self.serviceName = serviceName
        self.ipv4Address = ipv4Address
        self.ipv6Address = ipv6Address
        self.subnetMask = subnetMask
        self.routerAddress = routerAddress
        self.hardwareMAC = hardwareMAC
        self.statusDescription = statusDescription
    }

    public var isConnected: Bool {
        return isSupported && isServiceEnabled && !isServiceDisabledExternally && isLinkActive && (ipv4Address != nil || ipv6Address != nil)
    }
}

public final class EC20NetworkManager: @unchecked Sendable {
    public static let shared = EC20NetworkManager()

    public init() {}

    /// Converts hex netmask representation like "0xffffff00" into dotted-decimal "255.255.255.0"
    public static func convertHexNetmask(_ hex: String) -> String {
        let cleanHex = hex.lowercased().replacingOccurrences(of: "0x", with: "")
        guard cleanHex.count == 8, let num = UInt32(cleanHex, radix: 16) else {
            return hex
        }
        let b1 = (num >> 24) & 0xff
        let b2 = (num >> 16) & 0xff
        let b3 = (num >> 8) & 0xff
        let b4 = num & 0xff
        return "\(b1).\(b2).\(b3).\(b4)"
    }

    /// Detects EC20 network device, service name, routing configuration, and real IP addresses
    public func detectNetworkStatus() async -> CellularNetworkStatus {
        return await Task.detached(priority: .userInitiated) {
            // 1. Run networksetup -listallhardwareports
            let (_, hwOutput) = self.runShellCommand("/usr/sbin/networksetup", ["-listallhardwareports"])
            var ec20Iface: String? = nil
            var ec20ServiceCandidate: String? = nil
            var ec20Mac: String? = nil

            let blocks = hwOutput.components(separatedBy: "\n\n")
            for block in blocks {
                if block.contains("EC20") || block.contains("Quectel") {
                    let lines = block.components(separatedBy: .newlines)
                    for line in lines {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.hasPrefix("Hardware Port:") {
                            ec20ServiceCandidate = trimmed.replacingOccurrences(of: "Hardware Port:", with: "").trimmingCharacters(in: .whitespaces)
                        } else if trimmed.hasPrefix("Device:") {
                            ec20Iface = trimmed.replacingOccurrences(of: "Device:", with: "").trimmingCharacters(in: .whitespaces)
                        } else if trimmed.hasPrefix("Ethernet Address:") {
                            ec20Mac = trimmed.replacingOccurrences(of: "Ethernet Address:", with: "").trimmingCharacters(in: .whitespaces)
                        }
                    }
                    break
                }
            }

            guard let iface = ec20Iface else {
                return CellularNetworkStatus(
                    isSupported: false,
                    isServiceEnabled: false,
                    statusDescription: "模块未启用 ECM 模式 (AT+QCFG=\"usbnet\",1) 或 macOS 未识别到网卡"
                )
            }

            let actualServiceName = ec20ServiceCandidate ?? "EC20-CE-HDLG"

            // 2. Check external service enabled state (via -getnetworkserviceenabled)
            let (_, enCheck) = self.runShellCommand("/usr/sbin/networksetup", ["-getnetworkserviceenabled", actualServiceName])
            let isExternallyDisabled = enCheck.lowercased().contains("disabled")

            // 3. Check service configuration & routing
            let (_, getInfo) = self.runShellCommand("/usr/sbin/networksetup", ["-getinfo", actualServiceName])
            var router: String? = nil
            var infoMask: String? = nil
            var isDHCP = false
            for line in getInfo.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("DHCP Configuration") {
                    isDHCP = true
                }
                if trimmed.hasPrefix("Subnet mask:") {
                    let val = trimmed.replacingOccurrences(of: "Subnet mask:", with: "").trimmingCharacters(in: .whitespaces)
                    if !val.isEmpty && val != "none" {
                        infoMask = val
                    }
                }
                if trimmed.hasPrefix("Router:") {
                    let rVal = trimmed.replacingOccurrences(of: "Router:", with: "").trimmingCharacters(in: .whitespaces)
                    if !rVal.isEmpty && rVal != "(null)" && rVal != "none" {
                        router = rVal
                    }
                }
            }

            // 4. Query IP configuration using ifconfig <iface> (authoritative live link state)
            let (_, ifOutput) = self.runShellCommand("/sbin/ifconfig", [iface])
            var ifconfigIP: String? = nil
            var ifconfigMask: String? = nil
            var ipv6: String? = nil
            let isActive = ifOutput.contains("status: active")

            for line in ifOutput.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("inet ") && !trimmed.contains("127.0.0.1") {
                    let parts = trimmed.components(separatedBy: " ")
                    if parts.count >= 2 {
                        ifconfigIP = parts[1]
                    }
                    if let netmaskIdx = parts.firstIndex(of: "netmask"), netmaskIdx + 1 < parts.count {
                        let hexMask = parts[netmaskIdx + 1]
                        ifconfigMask = Self.convertHexNetmask(hexMask)
                    }
                } else if trimmed.hasPrefix("inet6 ") && !trimmed.contains("fe80:") {
                    let parts = trimmed.components(separatedBy: " ")
                    if parts.count >= 2 {
                        ipv6 = parts[1]
                    }
                }
            }

            // Use authoritative live ifconfig IP; do not fall back to stale getinfo cache
            let resolvedIPv4 = ifconfigIP
            let resolvedMask = ifconfigMask ?? infoMask
            let isDataRoutingActive = !isExternallyDisabled && (isDHCP || router != nil)

            let desc: String
            if isExternallyDisabled {
                desc = "macOS 网络服务已在系统设置中禁用 (需在系统设置启用后重启模块)"
            } else if !isActive {
                desc = "网卡物理链路断开 (需重启模块恢复 ECM)"
            } else if !isDataRoutingActive {
                desc = "蜂窝数据已暂停 (外网路由已阻断，硬件保持就绪)"
            } else if resolvedIPv4 != nil || ipv6 != nil {
                desc = "已连接蜂窝网络 (\(iface))"
            } else {
                desc = "等待蜂窝 DHCP 获取网关与 IP..."
            }

            return CellularNetworkStatus(
                isSupported: true,
                isServiceEnabled: isDataRoutingActive,
                isServiceDisabledExternally: isExternallyDisabled,
                isLinkActive: isActive,
                interfaceName: iface,
                serviceName: actualServiceName,
                ipv4Address: resolvedIPv4,
                ipv6Address: ipv6,
                subnetMask: resolvedMask,
                routerAddress: router,
                hardwareMAC: ec20Mac,
                statusDescription: desc
            )
        }.value
    }

    /// Enables or disables macOS cellular network routing safely without tearing down
    /// the DriverKit USB ECM physical link or requiring module reboots.
    public func setCellularDataEnabled(_ enabled: Bool) async throws {
        let status = await detectNetworkStatus()
        guard let service = status.serviceName else {
            throw NSError(
                domain: "EC20NetworkManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "未找到 EC20 蜂窝网络服务 (请检查 ECM 驱动或系统网络设置)"]
            )
        }

        try await Task.detached(priority: .userInitiated) {
            if enabled {
                // If service is disabled externally in macOS, do NOT silently turn on (which hangs DriverKit ECM)
                if status.isServiceDisabledExternally {
                    throw NSError(
                        domain: "EC20NetworkManager",
                        code: -5,
                        userInfo: [NSLocalizedDescriptionKey: "macOS 蜂窝网络服务此前已在系统设置中被停用。由于 macOS DriverKit 限制，请先在「系统设置 -> 网络」中启用 \(service) 网络服务，再到本应用「设置与高级」中执行 AT+CFUN=1,1 软件重启模块，以重新枚举恢复网卡。"]
                    )
                }

                // Restore full DHCP routing and Automatic IPv6
                let (code1, out1) = self.runShellCommand("/usr/sbin/networksetup", ["-setdhcp", service])
                let (code2, out2) = self.runShellCommand("/usr/sbin/networksetup", ["-setv6automatic", service])
                if code1 != 0 {
                    throw NSError(
                        domain: "EC20NetworkManager",
                        code: Int(code1),
                        userInfo: [NSLocalizedDescriptionKey: "启用蜂窝 DHCP 失败: \(out1)"]
                    )
                }
                if code2 != 0 {
                    throw NSError(
                        domain: "EC20NetworkManager",
                        code: Int(code2),
                        userInfo: [NSLocalizedDescriptionKey: "配置 IPv6 自动获取失败: \(out2)"]
                    )
                }
            } else {
                if status.isServiceDisabledExternally {
                    throw NSError(
                        domain: "EC20NetworkManager",
                        code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "当前 macOS 蜂窝网络服务已被系统外部禁用，无需再暂停"]
                    )
                }

                // Require live active link to pause routing safely
                guard status.isLinkActive else {
                    throw NSError(
                        domain: "EC20NetworkManager",
                        code: -4,
                        userInfo: [NSLocalizedDescriptionKey: "当前蜂窝网卡物理链路未就绪 (status: inactive)，无法暂停数据路由"]
                    )
                }

                // Must read real live IP from ifconfig. Never use stale getinfo cache or fake/hardcoded addresses!
                guard let realIP = status.ipv4Address, !realIP.isEmpty,
                      let realMask = status.subnetMask, !realMask.isEmpty else {
                    throw NSError(
                        domain: "EC20NetworkManager",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "当前蜂窝网卡未分配有效 IP 地址或子网掩码，无法安全暂停数据路由"]
                    )
                }

                // Pause cellular data: set IPv4 with real IP/mask and null router, and set IPv6 to link-local only.
                // Keeps DriverKit ECM link permanently active (status: active) with zero downtime,
                // while completely removing the default route so no cellular data is consumed.
                let (code1, out1) = self.runShellCommand("/usr/sbin/networksetup", ["-setmanual", service, realIP, realMask, ""])
                let (code2, out2) = self.runShellCommand("/usr/sbin/networksetup", ["-setv6LinkLocal", service])
                if code1 != 0 {
                    throw NSError(
                        domain: "EC20NetworkManager",
                        code: Int(code1),
                        userInfo: [NSLocalizedDescriptionKey: "暂停蜂窝数据路由失败: \(out1)"]
                    )
                }
                if code2 != 0 {
                    throw NSError(
                        domain: "EC20NetworkManager",
                        code: Int(code2),
                        userInfo: [NSLocalizedDescriptionKey: "限制 IPv6 本地链路失败: \(out2)"]
                    )
                }
            }
        }.value
    }

    private func runShellCommand(_ launchPath: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let str = String(data: data, encoding: .utf8) ?? ""
            return (process.terminationStatus, str.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return (-1, error.localizedDescription)
        }
    }
}
