import SwiftUI
import EC20Core

@MainActor
public struct CellularDataView: View {
    @ObservedObject var controller: EC20Controller

    @State private var isToggling: Bool = false
    @State private var toggleError: String? = nil

    public init(controller: EC20Controller) {
        self.controller = controller
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("蜂窝移动网络 (ECM)")
                            .font(.title2.bold())
                        Text("基于 Quectel EC20 CDC-ECM 原生以太网驱动，提供 Mac 高速蜂窝网络访问。")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: {
                        Task { await controller.refreshCellularStatus() }
                    }) {
                        Label("刷新状态", systemImage: "arrow.clockwise")
                    }
                }

                // Main Cellular Toggle Card
                VStack(spacing: 14) {
                    HStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(controller.cellularStatus.isConnected ? Color.green.opacity(0.15) : Color.gray.opacity(0.15))
                                .frame(width: 52, height: 52)
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.title2)
                                .foregroundColor(controller.cellularStatus.isConnected ? .green : .secondary)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("蜂窝数据连接")
                                .font(.headline)
                            Text(controller.cellularStatus.statusDescription)
                                .font(.subheadline)
                                .foregroundColor(controller.cellularStatus.isConnected ? .green : .secondary)
                        }

                        Spacer()

                        if isToggling {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Toggle("", isOn: Binding(
                                get: { controller.cellularStatus.isServiceEnabled },
                                set: { newValue in
                                    toggleCellular(newValue)
                                }
                            ))
                            .toggleStyle(.switch)
                            .disabled(!controller.cellularStatus.isSupported || isToggling)
                        }
                    }

                    if let err = toggleError {
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.red)
                    }

                    Divider()

                    HStack {
                        Image(systemName: "shield.checkered")
                            .foregroundColor(.blue)
                        Text("安全说明：此开关通过调整 macOS 蜂窝网络路由与网关阻断外网数据，保持 ECM 硬件链路始终就绪，绝不关断模块无线电 (CFUN=1)，通话与短信始终畅通。")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(16)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(12)

                // Network Detail Cards
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    detailCard(
                        title: "网络接口",
                        value: controller.cellularStatus.interfaceName ?? "未分配",
                        subtitle: "macOS 网络服务: \(controller.cellularStatus.serviceName ?? "无")",
                        icon: "network"
                    )

                    detailCard(
                        title: "运营商与制式",
                        value: controller.simInfo.operatorName ?? "未注册",
                        subtitle: "信号质量: \(controller.simInfo.signal.summary) (\(controller.simInfo.signal.signalBars)/4 格)",
                        icon: "cellularbars"
                    )

                    detailCard(
                        title: "IPv4 地址 (DHCP)",
                        value: controller.cellularStatus.ipv4Address ?? "未获取",
                        subtitle: "蜂窝内网/公网 IPv4",
                        icon: "globe"
                    )

                    detailCard(
                        title: "IPv6 地址",
                        value: controller.cellularStatus.ipv6Address != nil ? "已分配 (双栈)" : "未分配",
                        subtitle: controller.cellularStatus.ipv6Address ?? "-",
                        icon: "globe.asia.australia.fill"
                    )
                }

                // Diagnostic & Technical Guidance Card
                if !controller.cellularStatus.isSupported {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("蜂窝网络当前不可用原因")
                                .font(.headline)
                        }
                        Text("当前模块可能处于串口驱动模式 (AT+QCFG=\"usbnet\" 为 0)，macOS 未加载 CDC-ECM 驱动。如需使用蜂窝上网，请进入「设置与高级 ➔ AT 控制台」执行 AT+QCFG=\"usbnet\",1 并通过 AT+CFUN=1,1 重启模块。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(14)
                    .background(Color.orange.opacity(0.12))
                    .cornerRadius(10)
                }
            }
            .padding(20)
        }
    }

    private func toggleCellular(_ enable: Bool) {
        isToggling = true
        toggleError = nil
        Task {
            do {
                try await controller.setCellularDataEnabled(enable)
            } catch {
                toggleError = error.localizedDescription
            }
            isToggling = false
        }
    }

    private func detailCard(title: String, value: String, subtitle: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Image(systemName: icon)
                    .foregroundColor(.accentColor)
            }
            Text(value)
                .font(.title3.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(subtitle)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
    }
}
