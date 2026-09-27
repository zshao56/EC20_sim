import SwiftUI
import EC20BridgeProtocol

@MainActor
public struct MobilePairingView: View {
    @ObservedObject var client = MobileGatewayClient.shared
    @ObservedObject var appState = MobileAppState.shared

    @State private var otpInput: String = ""
    @State private var isSubmitting: Bool = false

    public init() {}

    public var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Top Icon & Title
                VStack(spacing: 8) {
                    Image(systemName: "macmini.and.iphone")
                        .font(.system(size: 56))
                        .foregroundColor(.accentColor)
                    Text("连接 Mac EC20 网关")
                        .font(.title2.bold())
                    Text(appState.statusMessage)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding(.top, 30)

                // High-entropy pairing secret input
                VStack(spacing: 12) {
                    Text("请输入 Mac 端设置中生成的 16 位安全配对密钥")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    TextField("16 位配对密钥", text: $otpInput)
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                        .frame(maxWidth: 240)
                        .onChange(of: otpInput) { newValue in
                            let normalized = GatewayPairingManager.normalizeSecret(newValue)
                            otpInput = String(normalized.prefix(16))
                        }

                    Button(action: {
                        let trimmed = otpInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard trimmed.count == 16 else { return }
                        isSubmitting = true
                        client.submitPairingOTP(trimmed)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            isSubmitting = false
                        }
                    }) {
                        if isSubmitting {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("立即验证配对")
                                .font(.headline)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(otpInput.count != 16 || isSubmitting)
                }

                Divider()
                    .padding(.horizontal)

                // Discovered Gateways
                VStack(alignment: .leading, spacing: 8) {
                    Text("局域网发现的网关")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)

                    if appState.discoveredGateways.isEmpty {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("正在通过 Bonjour 搜索局域网服务...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 8)
                    } else {
                        ForEach(appState.discoveredGateways, id: \.self) { gw in
                            HStack {
                                Image(systemName: "desktopcomputer")
                                    .foregroundColor(.accentColor)
                                Text(gw)
                                    .font(.subheadline)
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            }
                            .padding(10)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(8)
                        }
                    }

                    Button(action: {
                        client.startDiscovery()
                    }) {
                        Label("重新搜索局域网网关", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)

                Spacer()

                // Security Note
                VStack(spacing: 4) {
                    Text("安全与架构说明")
                        .font(.caption2.bold())
                        .foregroundColor(.secondary)
                    Text("• 会话通过 Curve25519 ECDH + ChaCha20-Poly1305 端到端加密\n• 第一阶段未部署系统 TLS 证书，仅限可信局域网使用\n• iPhone App 需保持前台运行，Mac 需保持开机唤醒状态")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }
                .padding(.bottom, 20)
            }
            .navigationTitle("网关配对")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                client.startDiscovery()
            }
        }
    }
}
