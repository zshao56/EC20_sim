import SwiftUI
import EC20Core

@MainActor
public struct ATConsoleView: View {
    @ObservedObject var controller: EC20Controller
    @ObservedObject var uiState: AppUIState
    
    public init(controller: EC20Controller, uiState: AppUIState) {
        self.controller = controller
        self.uiState = uiState
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header Controls & Quick Buttons
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Interactive AT Console")
                        .font(.headline)
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: "lock.shield.fill")
                            .foregroundColor(.blue)
                        Text("Auto-Masking Active")
                            .font(.caption2.bold())
                            .foregroundColor(.blue)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(6)
                }
                
                // Quick preset buttons
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        quickCmdButton("ATI")
                        quickCmdButton("AT+CPIN?")
                        quickCmdButton("AT+CSQ")
                        quickCmdButton("AT+COPS?")
                        quickCmdButton("AT+CREG?")
                        quickCmdButton("AT+CEREG?")
                        quickCmdButton("AT+QPCMV?")
                        quickCmdButton("AT+CLCC")
                        quickCmdButton("AT+CPMS?")
                    }
                }
            }
            .padding(12)
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Console Terminal Output
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(controller.atLogs.enumerated()), id: \.offset) { index, log in
                            Text(log)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(colorForLog(log))
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(NSColor.textBackgroundColor))
                .onChange(of: controller.atLogs.count) { _ in
                    if let last = controller.atLogs.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
            
            Divider()
            
            // Command Input Bar
            HStack(spacing: 10) {
                Text("AT>")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondary)
                TextField("Type AT command (e.g. ATE0, AT+CSQ)...", text: $uiState.customCommand)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .onSubmit {
                        sendCustomCommand()
                    }
                
                Button(action: {
                    sendCustomCommand()
                }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .disabled(uiState.customCommand.trimmingCharacters(in: .whitespaces).isEmpty || controller.isBusy)
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor))
        }
    }
    
    private func quickCmdButton(_ cmd: String) -> some View {
        Button(cmd) {
            Task {
                _ = try? await controller.executeAT(cmd)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .font(.system(size: 10, design: .monospaced))
    }
    
    private func sendCustomCommand() {
        let cmd = uiState.customCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        uiState.customCommand = ""
        Task {
            _ = try? await controller.executeAT(cmd)
        }
    }
    
    private func colorForLog(_ text: String) -> Color {
        if text.contains(">>") {
            return .accentColor
        } else if text.contains("[Error]") || text.contains("ERROR") {
            return .red
        } else if text.contains("OK") {
            return .green
        } else if text.contains("[URC]") {
            return .orange
        } else {
            return .primary
        }
    }
}
