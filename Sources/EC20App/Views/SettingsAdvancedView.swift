import SwiftUI
import EC20Core
import EC20Transport
import EC20BridgeProtocol

@MainActor
public struct SettingsAdvancedView: View {
    @ObservedObject var controller: EC20Controller
    @ObservedObject var uiState: AppUIState
    @ObservedObject var launchManager = LaunchAtLoginManager.shared
    @ObservedObject var gateway = EC20GatewayServer.shared
    public let audioBridge: EC20AudioBridge

    @State private var showSensitiveData: Bool = false

    public init(controller: EC20Controller, uiState: AppUIState, audioBridge: EC20AudioBridge) {
        self.controller = controller
        self.uiState = uiState
        self.audioBridge = audioBridge
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("系统设置与高级管理")
                            .font(.title2.bold())
                        Text("包含硬件诊断、存储监测、语音音频桥、AT 终端及开机自启配置。")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: {
                        Task { await controller.initializeModem() }
                    }) {
                        Label("刷新硬件信息", systemImage: "arrow.clockwise")
                    }
                }

                // Section 1: General & Launch at Login
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("常规设置", icon: "gearshape")

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("登录系统时自动启动")
                                .font(.subheadline.bold())
                            Text("系统开机登录后在菜单栏常驻后台运行，接收电话与短信通知")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { launchManager.isEnabled },
                            set: { launchManager.setEnabled($0) }
                        ))
                        .toggleStyle(.switch)
                    }

                    Divider()

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("模拟仿真模式 (Mock Modem)")
                                .font(.subheadline.bold())
                            Text(uiState.useSimulation ? "当前正在使用模拟猫进行测试" : "当前正在连接真实 EC20 USB 硬件")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $uiState.useSimulation)
                            .toggleStyle(.switch)
                    }
                }
                .padding(16)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(12)

                // Section 2: iPhone Local Network Gateway
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("iPhone 局域网互联 (Mac 桥接网关)", icon: "iphone.gen3")

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("启用 iPhone 互联服务")
                                .font(.subheadline.bold())
                            Text(gateway.isRunning ? gateway.status.displayDescription : "在局域网内提供 Bonjour 服务广播与安全加密通信 (默认关闭)")
                                .font(.caption)
                                .foregroundColor(gateway.isRunning ? .green : .secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { gateway.isRunning },
                            set: { enabled in
                                if enabled {
                                    gateway.configure(with: controller)
                                    gateway.start()
                                    _ = gateway.generateNewOTP()
                                } else {
                                    gateway.stop()
                                }
                            }
                        ))
                        .toggleStyle(.switch)
                    }

                    if gateway.isRunning {
                        Divider()

                        HStack(alignment: .center, spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("16 位安全配对密钥 (有效时间 5 分钟)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                HStack(spacing: 8) {
                                    Text(gateway.currentOTP ?? "----------------")
                                        .font(.system(size: 19, weight: .bold, design: .monospaced))
                                        .textSelection(.enabled)
                                        .foregroundColor(.accentColor)
                                    if gateway.otpSecondsRemaining > 0 {
                                        Text("(\(gateway.otpSecondsRemaining)s)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }

                            Spacer()

                            Button(action: {
                                _ = gateway.generateNewOTP()
                            }) {
                                Label("刷新配对码", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("已配对设备 (\(gateway.pairedDevices.count))")
                                    .font(.subheadline.bold())
                                Spacer()
                                Text("在线客户端: \(gateway.connectedClientsCount)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            if gateway.pairedDevices.isEmpty {
                                Text("暂无配对的 iPhone 设备。请在 iPhone 配套 App 打开并输入上方 16 位安全密钥。")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                ForEach(gateway.pairedDevices) { dev in
                                    HStack {
                                        Image(systemName: "iphone")
                                            .foregroundColor(.secondary)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(dev.deviceName)
                                                .font(.subheadline.bold())
                                            Text("配对时间: \(Date(timeIntervalSince1970: dev.pairedAt).formatted())")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        Button("解除配对") {
                                            gateway.revokeDevice(deviceId: dev.deviceId)
                                        }
                                        .buttonStyle(.borderless)
                                        .foregroundColor(.red)
                                        .font(.caption)
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 4) {
                            Text("安全边界与使用说明")
                                .font(.caption.bold())
                                .foregroundColor(.secondary)
                            Text("• 传输安全：基于 CryptoKit Curve25519 ECDH 协商共享会话密钥与 ChaCha20-Poly1305 AEAD 对称加密，防止局域网窃听与篡改。\n• 证书说明：第一阶段未部署系统级 TLS CA 证书，请确保仅在家庭或受信任的工作局域网内开启。\n• 待机边界：第一阶段未接入公网 APNs 推送，iPhone 配套 App 需保持前台运行且 Mac 保持唤醒状态。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(16)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(12)

                // Section 3: Storage Monitoring
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("存储容量监测", icon: "internaldrive")

                    if controller.storageCapacities.isEmpty {
                        Text("未获取到存储容量信息，点击刷新硬件信息以同步。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(controller.storageCapacities) { cap in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(cap.areaDisplayName)
                                        .font(.subheadline.bold())
                                    Spacer()
                                    Text("\(cap.used) / \(cap.total) 条 (\(Int(cap.percent * 100))%)")
                                        .font(.caption.bold())
                                        .foregroundColor(cap.percent > 0.8 ? .red : .primary)
                                }
                                ProgressView(value: cap.percent)
                                    .tint(cap.percent > 0.8 ? .red : .accentColor)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .padding(16)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(12)

                // Section 3: Hardware & SIM Identity
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        sectionTitle("模块与 SIM 硬件状态", icon: "simcard")
                        Spacer()
                        Button(showSensitiveData ? "遮蔽敏感信息" : "显示完整号码") {
                            showSensitiveData.toggle()
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }

                    infoRow("模块型号", controller.simInfo.model ?? "Quectel EC20F")
                    infoRow("固件版本", controller.simInfo.revision ?? "EC20CEHDLGR08A02M1G")
                    infoRow("SIM 卡状态", controller.simInfo.cpinStatus.rawValue)
                    infoRow("ICCID (卡号)", showSensitiveData ? (controller.simInfo.iccid ?? "-") : controller.simInfo.maskedICCID)
                    infoRow("IMSI", showSensitiveData ? (controller.simInfo.imsi ?? "-") : controller.simInfo.maskedIMSI)
                    infoRow("IMEI (设备识别码)", showSensitiveData ? (controller.simInfo.imei ?? "-") : controller.simInfo.maskedIMEI)
                    infoRow("CS 电路域状态", controller.simInfo.cregStatus.description)
                    infoRow("EPS/LTE 分组域", controller.simInfo.ceregStatus.description)
                }
                .padding(16)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(12)

                // Section 4: Voice Audio Bridge Controls
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("USB 语音音频桥 (Interface 1 PCM)", icon: "waveform.and.mic")

                    Text("架构：Quectel EC20 无标准 UAC 设备，语音通过 USB 接口 1 (NMEA/Vendor) 传输 8kHz 16-bit 单声道原始 PCM。App 已实现 CoreAudio ↔ USB 实时双向桥接。")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack(spacing: 12) {
                        Button("本地环回自测 (麦克风 ➔ 扬声器)") {
                            audioBridge.start(deviceHandle: nil, loopbackOnly: true)
                            controller.setAudioBridgeStatus(audioBridge.state.rawValue)
                        }
                        .buttonStyle(.bordered)

                        Button("停止音频桥") {
                            Task {
                                audioBridge.stop()
                                _ = try? await controller.executeAT("AT+QPCMV=0")
                                controller.setAudioBridgeStatus(audioBridge.state.rawValue)
                            }
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        Text("状态: \(audioBridge.state.rawValue)")
                            .font(.caption.bold())
                            .foregroundColor(audioBridge.state == .stopped ? .secondary : .green)
                    }
                }
                .padding(16)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(12)

                // Section 5: Interactive AT Console
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("交互式 AT 控制台", icon: "terminal")

                    // Quick Buttons
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            quickButton("ATI")
                            quickButton("AT+CPIN?")
                            quickButton("AT+CSQ")
                            quickButton("AT+COPS?")
                            quickButton("AT+CPMS?")
                            quickButton("AT+QCFG=\"usbnet\"")
                            quickButton("AT+QCFG=\"usbnet\",1")
                            quickButton("AT+CFUN=1,1")
                        }
                    }

                    // Terminal Log Box
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(controller.atLogs.enumerated()), id: \.offset) { idx, log in
                                    Text(log)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(logColor(log))
                                        .textSelection(.enabled)
                                        .id(idx)
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 180)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(6)
                        .onChange(of: controller.atLogs.count) { _ in
                            if let last = controller.atLogs.indices.last {
                                proxy.scrollTo(last, anchor: .bottom)
                            }
                        }
                    }

                    // Input Bar
                    HStack {
                        Text("AT>")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(.secondary)
                        TextField("输入 AT 指令 (如 ATE0, AT+CSQ)...", text: $uiState.customCommand)
                            .font(.system(size: 12, design: .monospaced))
                            .textFieldStyle(.plain)
                            .onSubmit { sendCustomCommand() }
                        Button("发送") {
                            sendCustomCommand()
                        }
                        .disabled(uiState.customCommand.isEmpty || controller.isBusy)
                    }
                }
                .padding(16)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(12)
            }
            .padding(20)
        }
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
            Text(title)
                .font(.headline)
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(.subheadline, design: .monospaced))
                .fontWeight(.medium)
        }
        .padding(.vertical, 1)
    }

    private func quickButton(_ cmd: String) -> some View {
        Button(cmd) {
            uiState.customCommand = cmd
            sendCustomCommand()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func sendCustomCommand() {
        let cmd = uiState.customCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        Task {
            _ = try? await controller.executeAT(cmd)
        }
        uiState.customCommand = ""
    }

    private func logColor(_ log: String) -> Color {
        if log.contains(">>") { return .blue }
        if log.contains("ERROR") { return .red }
        if log.contains("OK") { return .green }
        if log.contains("[URC]") { return .orange }
        return .primary
    }
}
