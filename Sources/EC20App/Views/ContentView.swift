import SwiftUI
import AppKit
import EC20Core
import EC20Transport

fileprivate final class WindowObservingView: NSView {
    var callback: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = self.window {
            callback?(window)
        }
    }
}

fileprivate struct WindowAccessor: NSViewRepresentable {
    let callback: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowObservingView {
        let view = WindowObservingView()
        view.callback = callback
        if let window = view.window {
            callback(window)
        }
        return view
    }

    func updateNSView(_ nsView: WindowObservingView, context: Context) {
        nsView.callback = callback
        if let window = nsView.window {
            callback(window)
        }
    }
}

@MainActor
public struct ContentView: View {
    @ObservedObject private var coordinator = AppCoordinator.shared
    @ObservedObject private var realController = AppCoordinator.shared.realController
    @ObservedObject private var mockController = AppCoordinator.shared.mockController
    @ObservedObject private var uiState = AppCoordinator.shared.uiState

    public init() {}

    private var activeController: EC20Controller {
        coordinator.activeController
    }

    private var activeAudioBridge: EC20AudioBridge {
        coordinator.activeAudioBridge
    }

    public var body: some View {
        NavigationSplitView {
            List(AppTab.allCases, selection: $uiState.selectedTab) { tab in
                NavigationLink(value: tab) {
                    HStack {
                        Label(tab.rawValue, systemImage: tab.icon)
                        Spacer()
                        if tab == .messages && activeController.totalUnreadCount > 0 {
                            Text("\(activeController.totalUnreadCount)")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.red)
                                .foregroundColor(.white)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)

            // Simulation indicator at bottom of sidebar
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                HStack(spacing: 6) {
                    Circle()
                        .fill(uiState.useSimulation ? Color.purple : Color.green)
                        .frame(width: 8, height: 8)
                    Text(uiState.useSimulation ? "仿真模拟模式" : "真实 EC20 硬件")
                        .font(.caption2.bold())
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        } detail: {
            VStack(spacing: 0) {
                // Top Global Status Bar
                topStatusBar
                Divider()

                // Active Section View
                Group {
                    switch uiState.selectedTab {
                    case .phone:
                        PhoneView(controller: activeController, uiState: uiState)
                    case .messages:
                        MessagesView(controller: activeController, uiState: uiState)
                    case .contacts:
                        ContactsView(controller: activeController, uiState: uiState)
                    case .cellular:
                        CellularDataView(controller: activeController)
                    case .settings:
                        SettingsAdvancedView(controller: activeController, uiState: uiState, audioBridge: activeAudioBridge)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(WindowAccessor { window in
            coordinator.registerMainWindow(window)
            window.delegate = MainWindowDelegate.shared
        })
    }

    // MARK: - Top Status Bar

    private var topStatusBar: some View {
        HStack(spacing: 12) {
            // Connection Indicator
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
                Text(statusText)
                    .font(.caption.bold())
            }

            Divider().frame(height: 14)

            // Operator & Signal
            HStack(spacing: 6) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundColor(.accentColor)
                Text(activeController.simInfo.operatorName ?? "搜索网络中...")
                    .font(.caption.bold())
                Text("(\(activeController.simInfo.signal.summary))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // SIM Pill
            Text("SIM: \(activeController.simInfo.cpinStatus.rawValue)")
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(activeController.simInfo.cpinStatus == .ready ? Color.green.opacity(0.15) : Color.red.opacity(0.15))
                .foregroundColor(activeController.simInfo.cpinStatus == .ready ? .green : .red)
                .cornerRadius(4)

            // Cellular Data Pill
            if activeController.cellularStatus.isConnected {
                HStack(spacing: 4) {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    Text("蜂窝: 已连接")
                        .font(.caption2.bold())
                        .foregroundColor(.green)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.15))
                .cornerRadius(4)
            }

            // Audio Bridge Pill
            if activeAudioBridge.state != .stopped {
                HStack(spacing: 4) {
                    Image(systemName: "waveform")
                        .foregroundColor(.green)
                    Text("语音桥: \(activeAudioBridge.state.rawValue)")
                        .font(.caption2.bold())
                        .foregroundColor(.green)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.15))
                .cornerRadius(4)
            }

            Spacer()

            // Connect / Disconnect Button
            Button(action: {
                Task {
                    if case .connected = activeController.connectionStatus {
                        await activeController.disconnect()
                    } else {
                        await activeController.connect()
                    }
                }
            }) {
                if case .connected = activeController.connectionStatus {
                    Label("断开", systemImage: "bolt.slash")
                } else {
                    Label("连接", systemImage: "bolt.fill")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var statusColor: Color {
        switch activeController.connectionStatus {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .gray
        case .error: return .red
        }
    }

    private var statusText: String {
        switch activeController.connectionStatus {
        case .connected: return "已连接"
        case .connecting: return "连接中..."
        case .disconnected: return "已断开"
        case .error: return "错误"
        }
    }
}
