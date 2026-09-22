import SwiftUI
import EC20Core

@MainActor
public struct SMSInboxView: View {
    @ObservedObject var controller: EC20Controller
    @ObservedObject var uiState: AppUIState
    
    public init(controller: EC20Controller, uiState: AppUIState) {
        self.controller = controller
        self.uiState = uiState
    }
    
    public var body: some View {
        HSplitView {
            // Left: Message List
            VStack(spacing: 0) {
                // Toolbar
                HStack {
                    Text("Messages (\(controller.smsMessages.count))")
                        .font(.headline)
                    Spacer()
                    Button(action: {
                        Task { await controller.loadSMSMessages() }
                    }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh SMS from module & SIM")
                    
                    Button(action: {
                        uiState.isShowingComposeSheet = true
                    }) {
                        Label("Compose", systemImage: "square.and.pencil")
                    }
                }
                .padding(12)
                .background(Color(NSColor.windowBackgroundColor))
                
                Divider()
                
                if controller.smsMessages.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "tray")
                            .font(.system(size: 36))
                            .foregroundColor(.secondary)
                        Text("No SMS Messages")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("Messages stored on module (ME) or SIM (SM) will appear here.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Spacer()
                    }
                    .frame(minWidth: 260)
                } else {
                    List(selection: $uiState.selectedMessage) {
                        ForEach(controller.smsMessages) { msg in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(msg.senderOrRecipient)
                                        .font(.subheadline.bold())
                                    Spacer()
                                    if let area = msg.storageArea, let idx = msg.storageIndex {
                                        Text("\(area)[\(idx)]")
                                            .font(.system(size: 9, weight: .bold))
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 2)
                                            .background(Color.secondary.opacity(0.15))
                                            .cornerRadius(4)
                                    }
                                }
                                Text(msg.text)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                                HStack {
                                    Text(msg.isIncoming ? "Received" : "Sent")
                                        .font(.system(size: 9))
                                        .foregroundColor(msg.isIncoming ? .blue : .green)
                                    Spacer()
                                    Text(msg.timestamp, style: .time)
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                            .tag(msg)
                        }
                    }
                    .listStyle(.inset)
                    .frame(minWidth: 260)
                }
            }
            .frame(minWidth: 240, maxWidth: 360)
            
            // Right: Detail View
            if let msg = uiState.selectedMessage {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(msg.isIncoming ? "From: \(msg.senderOrRecipient)" : "To: \(msg.senderOrRecipient)")
                                .font(.title3.bold())
                                .textSelection(.enabled)
                            Text(msg.timestamp.formatted(date: .complete, time: .standard))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    
                    Divider()
                    
                    ScrollView {
                        Text(msg.text)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }
                    
                    Spacer()
                    
                    // Technical PDU & Codec inspector box
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SMS Technical Details")
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                        HStack {
                            Text("Encoding:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(UCS2Codec.requiresUCS2(msg.text) ? "UCS2 (UTF-16BE)" : "GSM 7-bit / ASCII")
                                .font(.caption.bold())
                            Spacer()
                            Text("Character Length: \(msg.text.count)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(10)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                }
                .padding(20)
                .frame(minWidth: 320)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "message")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("Select a message to view details")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $uiState.isShowingComposeSheet) {
            composeSheet
        }
    }
    
    // MARK: - Compose Sheet
    
    private var composeSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Compose SMS (UCS2 / PDU Supported)")
                    .font(.headline)
                Spacer()
                Button("Close") {
                    uiState.isShowingComposeSheet = false
                    uiState.sendSMSError = nil
                    uiState.sendSMSSuccess = false
                }
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 6) {
                Text("Destination Phone Number:")
                    .font(.subheadline.bold())
                TextField("e.g. +8613800000000 or 10010", text: $uiState.composeRecipient)
                    .textFieldStyle(.roundedBorder)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Message Content:")
                        .font(.subheadline.bold())
                    Spacer()
                    let isUCS2 = UCS2Codec.requiresUCS2(uiState.composeText)
                    let limitPerPart = isUCS2 ? 67 : 153
                    let maxSingle = isUCS2 ? 70 : 160
                    let count = uiState.composeText.count
                    let parts = count <= maxSingle ? 1 : ((count + limitPerPart - 1) / limitPerPart)
                    Text("\(count) chars | \(isUCS2 ? "UCS2 (Chinese)" : "GSM 7-bit") | \(parts) part(s)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                TextEditor(text: $uiState.composeText)
                    .font(.body)
                    .frame(height: 120)
                    .border(Color.secondary.opacity(0.2), width: 1)
                    .cornerRadius(4)
            }
            
            if let err = uiState.sendSMSError {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
            }
            if uiState.sendSMSSuccess {
                Text("Message sent successfully!")
                    .font(.caption)
                    .foregroundColor(.green)
            }
            
            HStack {
                Text("⚠️ Safety: Real SMS transmission requires user authorization and a valid test number.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: {
                    Task {
                        await sendSMSAction()
                    }
                }) {
                    if uiState.isSendingSMS {
                        ProgressView()
                            .scaleEffect(0.6)
                    } else {
                        Text("Send SMS")
                    }
                }
                .disabled(uiState.composeRecipient.isEmpty || uiState.composeText.isEmpty || uiState.isSendingSMS)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
    
    private func sendSMSAction() async {
        uiState.isSendingSMS = true
        uiState.sendSMSError = nil
        uiState.sendSMSSuccess = false
        
        do {
            try await controller.sendSMS(to: uiState.composeRecipient, text: uiState.composeText)
            uiState.sendSMSSuccess = true
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            uiState.isShowingComposeSheet = false
            uiState.composeText = ""
            uiState.composeRecipient = ""
        } catch {
            uiState.sendSMSError = error.localizedDescription
        }
        uiState.isSendingSMS = false
    }
}
