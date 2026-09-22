import SwiftUI
import EC20Core

@MainActor
public struct CallControlView: View {
    @ObservedObject var controller: EC20Controller
    @ObservedObject var uiState: AppUIState
    
    public init(controller: EC20Controller, uiState: AppUIState) {
        self.controller = controller
        self.uiState = uiState
    }
    
    public var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Critical Architecture Banner: Distinction between Call Control & Audio Stream
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Call and Audio Status")
                            .font(.headline)
                            .foregroundColor(.primary)
                        Text("Call commands use USB Interface 2. The app includes a CoreAudio ↔ USB Interface 1 PCM bridge. A local loopback check is available under Voice Audio Bridge; two-way carrier audio still needs a live test call.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(14)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(10)
                
                // Incoming Call Banner (if any)
                if let alert = controller.incomingCallAlert {
                    HStack(spacing: 16) {
                        Image(systemName: "phone.badge.waveform.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.green)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Incoming Call Alert")
                                .font(.headline)
                            Text(alert)
                                .font(.title3.bold())
                        }
                        Spacer()
                        Button(action: {
                            Task {
                                do {
                                    try await controller.answerCall()
                                } catch {
                                    uiState.callErrorMessage = error.localizedDescription
                                }
                            }
                        }) {
                            Label("Answer (ATA)", systemImage: "phone.fill")
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        
                        Button(action: {
                            Task {
                                do {
                                    try await controller.hangupCall()
                                } catch {
                                    uiState.callErrorMessage = error.localizedDescription
                                }
                            }
                        }) {
                            Label("Decline (ATH)", systemImage: "phone.down.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }
                    .padding(16)
                    .background(Color.green.opacity(0.15))
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.green, lineWidth: 2)
                    )
                }
                
                // Active Calls Section
                if !controller.activeCalls.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Active Calls (AT+CLCC)")
                            .font(.headline)
                        ForEach(controller.activeCalls) { call in
                            HStack {
                                Image(systemName: call.direction == .incoming ? "arrow.down.left.circle.fill" : "arrow.up.right.circle.fill")
                                    .foregroundColor(call.direction == .incoming ? .blue : .green)
                                    .font(.title2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(call.maskedPhoneNumber)
                                        .font(.headline)
                                    Text("\(call.direction.rawValue) • \(call.status.rawValue)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button(action: {
                                    Task { try? await controller.hangupCall() }
                                }) {
                                    Label("Hang Up (ATH)", systemImage: "phone.down.fill")
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.red)
                            }
                            .padding(12)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(8)
                        }
                    }
                }
                
                // Dialer Keypad & Controls
                VStack(spacing: 16) {
                    Text("Dialpad & Call Control")
                        .font(.headline)
                    
                    // Display Field
                    HStack {
                        TextField("Enter phone number...", text: $uiState.dialNumber)
                            .font(.system(size: 24, weight: .bold, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .textFieldStyle(.plain)
                        if !uiState.dialNumber.isEmpty {
                            Button(action: {
                                if !uiState.dialNumber.isEmpty {
                                    uiState.dialNumber.removeLast()
                                }
                            }) {
                                Image(systemName: "delete.left")
                                    .font(.title3)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(12)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                    .frame(maxWidth: 320)
                    
                    // Keypad Grid (3x4)
                    let keypad: [[String]] = [
                        ["1", "2", "3"],
                        ["4", "5", "6"],
                        ["7", "8", "9"],
                        ["*", "0", "#"]
                    ]
                    
                    VStack(spacing: 10) {
                        ForEach(keypad, id: \.self) { row in
                            HStack(spacing: 14) {
                                ForEach(row, id: \.self) { digit in
                                    Button(action: {
                                        uiState.dialNumber.append(digit)
                                    }) {
                                        Text(digit)
                                            .font(.title2.bold())
                                            .frame(width: 70, height: 44)
                                            .background(Color(NSColor.controlBackgroundColor))
                                            .cornerRadius(8)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: 320)
                    
                    // Call & Hangup Action Buttons
                    HStack(spacing: 20) {
                        Button(action: {
                            guard !uiState.dialNumber.isEmpty else { return }
                            uiState.callErrorMessage = nil
                            Task {
                                do {
                                    try await controller.dial(number: uiState.dialNumber)
                                } catch {
                                    uiState.callErrorMessage = error.localizedDescription
                                }
                            }
                        }) {
                            HStack {
                                Image(systemName: "phone.fill")
                                Text("Call (ATD)")
                            }
                            .frame(width: 140, height: 40)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .disabled(uiState.dialNumber.isEmpty)
                        
                        Button(action: {
                            Task {
                                do {
                                    try await controller.hangupCall()
                                } catch {
                                    uiState.callErrorMessage = error.localizedDescription
                                }
                            }
                        }) {
                            HStack {
                                Image(systemName: "phone.down.fill")
                                Text("Hangup (ATH)")
                            }
                            .frame(width: 140, height: 40)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }
                    
                    if let err = uiState.callErrorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                .padding(20)
                .background(Color(NSColor.windowBackgroundColor))
                .cornerRadius(12)
            }
            .padding(20)
        }
    }
}
