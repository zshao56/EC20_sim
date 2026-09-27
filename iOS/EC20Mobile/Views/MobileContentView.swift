import SwiftUI
import UserNotifications
import EC20BridgeProtocol

@MainActor
public struct MobileContentView: View {
    @ObservedObject var appState = MobileAppState.shared
    @ObservedObject var client = MobileGatewayClient.shared

    public init() {}

    public var body: some View {
        ZStack {
            if !appState.isPaired {
                MobilePairingView()
            } else {
                TabView {
                    MobileMessagesView()
                        .tabItem {
                            Label("信息", systemImage: "message")
                        }
                        .badge(appState.totalUnreadCount)

                    MobileContactsView()
                        .tabItem {
                            Label("通讯录", systemImage: "person.crop.circle")
                        }

                    MobilePhoneView()
                        .tabItem {
                            Label("电话", systemImage: "phone")
                        }

                    MobileSettingsView()
                        .tabItem {
                            Label("网关设置", systemImage: "gearshape")
                        }
                }
            }

            // Fullscreen Incoming Call Banner/Overlay
            if let call = appState.activeCall, call.status == "ringing" {
                MobileIncomingCallView(activeCall: call)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(100)
            }
        }
        .animation(.easeInOut, value: appState.activeCall)
        .onAppear {
            updateApplicationBadge(appState.totalUnreadCount)
        }
        .onChange(of: appState.totalUnreadCount) { count in
            updateApplicationBadge(count)
        }
    }

    private func updateApplicationBadge(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(max(0, count)) { _ in }
    }
}

@MainActor
public struct MobileSettingsView: View {
    @ObservedObject var appState = MobileAppState.shared
    @ObservedObject var client = MobileGatewayClient.shared

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                Section(header: Text("连接状态")) {
                    HStack {
                        Text("网关状态")
                        Spacer()
                        Text(appState.statusMessage)
                            .font(.caption)
                            .foregroundColor(appState.isConnected ? .green : .secondary)
                    }

                    HStack {
                        Text("未读短信总数")
                        Spacer()
                        Text("\(appState.totalUnreadCount)")
                            .font(.subheadline.bold())
                    }

                    Button("立即全量同步") {
                        client.requestSync()
                    }
                }

                Section(header: Text("配对管理")) {
                    Button(role: .destructive, action: {
                        client.disconnect()
                    }) {
                        Text("断开与此 Mac 的连接")
                    }
                }

                Section(header: Text("安全与局域网说明")) {
                    Text("• 采用 Curve25519 ECDH + ChaCha20-Poly1305 端到端对称加密信道。\n• 本阶段不包含公网 APNs 推送与系统级 TLS 根证书，请在受信任的局域网内使用。\n• iPhone App 需保持前台，Mac 需保持开机唤醒状态。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("网关设置")
        }
    }
}
