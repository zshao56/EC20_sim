import SwiftUI
import EC20Core
import EC20Transport

public enum NavigationSection: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case sms = "Messages"
    case calls = "Phone & Calls"
    case voiceBridge = "Voice Audio Bridge"
    case console = "AT Console"
    
    public var id: String { rawValue }
    
    public var icon: String {
        switch self {
        case .dashboard: return "gauge.medium"
        case .sms: return "message.fill"
        case .calls: return "phone.fill"
        case .voiceBridge: return "waveform.and.mic"
        case .console: return "terminal.fill"
        }
    }
}

@MainActor
public struct ContentView: View {
    @StateObject private var realController: EC20Controller
    @StateObject private var mockController: EC20Controller
    @StateObject private var uiState = AppUIState()
    
    public init() {
        let realTransport = LibusbATTransport()
        let mockTransport = MockATTransport()
        _realController = StateObject(wrappedValue: EC20Controller(transport: realTransport))
        _mockController = StateObject(wrappedValue: EC20Controller(transport: mockTransport))
    }
    
    private var activeController: EC20Controller {
        uiState.useSimulation ? mockController : realController
    }
    
    public var body: some View {
        NavigationSplitView {
            List(NavigationSection.allCases, selection: $uiState.selectedSection) { section in
                NavigationLink(value: section) {
                    Label(section.rawValue, systemImage: section.icon)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            
            // Transport switch at bottom of sidebar
            VStack(alignment: .leading, spacing: 10) {
                Divider()
                Toggle(isOn: $uiState.useSimulation) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Simulation Mode")
                            .font(.subheadline.bold())
                        Text(uiState.useSimulation ? "Using Mock Modem" : "Using Real EC20 USB")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        } detail: {
            VStack(spacing: 0) {
                // Top status and connection bar
                topStatusBar
                Divider()
                
                // Active Section View
                Group {
                    switch uiState.selectedSection {
                    case .dashboard:
                        StatusDashboardView(controller: activeController)
                    case .sms:
                        SMSInboxView(controller: activeController, uiState: uiState)
                    case .calls:
                        CallControlView(controller: activeController, uiState: uiState)
                    case .voiceBridge:
                        VoiceBridgeView(controller: activeController)
                    case .console:
                        ATConsoleView(controller: activeController, uiState: uiState)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            await activeController.connect()
        }
        .onChange(of: uiState.useSimulation) { _ in
            Task {
                await activeController.connect()
            }
        }
    }
    
    // MARK: - Top Status Bar
    
    private var topStatusBar: some View {
        HStack(spacing: 14) {
            // Connection Indicator
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(statusText)
                    .font(.caption.bold())
            }
            
            Divider()
                .frame(height: 16)
            
            // Operator & Signal
            HStack(spacing: 6) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundColor(.accentColor)
                Text(activeController.simInfo.operatorName ?? "No Operator")
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
            
            Spacer()
            
            // Connect / Disconnect button
            Button(action: {
                Task {
                    if case .connected = activeController.connectionStatus {
                        activeController.disconnect()
                    } else {
                        await activeController.connect()
                    }
                }
            }) {
                if case .connected = activeController.connectionStatus {
                    Label("Disconnect", systemImage: "bolt.slash")
                } else {
                    Label("Connect", systemImage: "bolt.fill")
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
        case .connected: return "Connected"
        case .connecting: return "Connecting..."
        case .disconnected: return "Disconnected"
        case .error(let msg): return "Error: \(msg)"
        }
    }
}
