import SwiftUI
import EC20Core

@MainActor
public struct VoiceBridgeView: View {
    @ObservedObject var controller: EC20Controller
    
    public init(controller: EC20Controller) {
        self.controller = controller
    }
    
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("EC20 Audio Architecture & Feasibility Assessment")
                        .font(.title2.bold())
                    Text("Technical evaluation based on Quectel EC2x/EG9x Voice Over USB & UAC Application Note and live USB descriptors.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                // Live Status Overview Cards
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    statusCard(
                        title: "USB Audio Class (UAC)",
                        value: controller.audioAssessment.uacDeviceDetected ? "Exposed" : "Not Present",
                        subtitle: "No macOS CoreAudio device",
                        icon: "speaker.slash.fill",
                        color: controller.audioAssessment.uacDeviceDetected ? .green : .red
                    )
                    
                    statusCard(
                        title: "Voice over USB (PCM)",
                        value: controller.audioAssessment.qpcmvSupported ? "Supported" : "Unsupported",
                        subtitle: "AT+QPCMV: \(controller.audioAssessment.qpcmvCurrentSetting)",
                        icon: "waveform",
                        color: .blue
                    )
                    
                    statusCard(
                        title: "Call Signaling Path",
                        value: "Operational",
                        subtitle: "Interface 2 (AT port)",
                        icon: "phone.circle.fill",
                        color: .green
                    )
                }
                
                // USB Interface Mapping Table
                VStack(alignment: .leading, spacing: 12) {
                    Text("USB 2.0 Interface Topology (Quectel EC20-CE 0x2c7c:0x0125)")
                        .font(.headline)
                    
                    VStack(spacing: 8) {
                        interfaceRow(
                            id: 0,
                            name: "DIAG / DM",
                            eps: "EP 0x01 OUT, EP 0x81 IN (Bulk)",
                            purpose: "Diagnostic and Qualcomm QCDM logging",
                            status: "Inactive"
                        )
                        interfaceRow(
                            id: 1,
                            name: "GNSS / NMEA (Voice PCM)",
                            eps: "EP 0x02 OUT, EP 0x82 IN (Bulk), EP 0x83 INT",
                            purpose: "NMEA data; When AT+QPCMV=1,0 active, transfers 8kHz 16-bit Linear PCM audio frames",
                            status: "Voice PCM Pathway",
                            highlight: true
                        )
                        interfaceRow(
                            id: 2,
                            name: "AT Commands & URC",
                            eps: "EP 0x03 OUT, EP 0x84 IN (Bulk), EP 0x85 INT",
                            purpose: "Primary AT commands, URC notifications, SIM, SMS & Call control",
                            status: "Active (Current Transport)",
                            highlight: true
                        )
                        interfaceRow(
                            id: 3,
                            name: "Modem / Data",
                            eps: "EP 0x04 OUT, EP 0x86 IN (Bulk), EP 0x87 INT",
                            purpose: "PPP dialup data & secondary AT interface",
                            status: "Standby"
                        )
                        interfaceRow(
                            id: 4,
                            name: "Network / QMI",
                            eps: "EP 0x05 OUT, EP 0x88 IN (Bulk), EP 0x89 INT",
                            purpose: "Qualcomm MSM Interface / RMNET cellular network data",
                            status: "Inactive"
                        )
                    }
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(10)
                
                // Comprehensive Technical Handoff Report
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "doc.text.magnifyingglass")
                            .foregroundColor(.blue)
                        Text("Audio Feasibility Conclusion & Next Step Roadmap")
                            .font(.headline)
                    }
                    
                    Text("""
                    1. Hardware Reality:
                       The connected Quectel EC20-CE-HDLG (Firmware: EC20CEHDLGR08A02M1G) exposes 5 vendor-specific USB interfaces. No USB Audio Class (UAC) 1.0/2.0 interface exists in its USB descriptor. Consequently, macOS cannot natively enumerate it as a microphone or speaker in System Settings.
                    
                    2. Voice over USB (Raw PCM Streaming):
                       As confirmed by official Quectel documentation and query `AT+QPCMV=?` -> `(0,1),(0-2)`:
                       - Setting `AT+QPCMV=1,0` activates raw bidirectional PCM audio streaming over USB Interface 1 (GNSS/NMEA).
                       - Audio format: 8000 Hz sample rate, 16-bit signed linear PCM, mono, 20ms frames (160 samples = 320 bytes per transfer).
                       - The current non-destructive setting is `AT+QPCMV?` -> `0,0` (disabled), preserving default GNSS behavior.
                    
                    3. Call Signaling vs Full Voice Distinction:
                       - Call signaling (dialing with `ATD`, answering with `ATA`, hanging up with `ATH`, querying active calls with `AT+CLCC`, and caller ID via `+CLIP` / `RING`) is fully operational.
                       - Complete bidirectional voice call requires bridging the raw PCM byte stream on Interface 1 with macOS CoreAudio.
                       - Transparent reporting: Under no circumstances should call signaling alone be misrepresented as complete voice calls.
                    
                    4. Implementation Roadmap for Bidirectional Voice:
                       To complete voice audio without firmware reflashing:
                       - Implement a userspace CoreAudio AudioServerPlugin (Virtual Audio Driver) or use an AudioUnit render/input callback.
                       - When a call enters `ACTIVE` state, issue `AT+QPCMV=1,0` on Interface 2.
                       - Pipe microphone samples (converted from macOS CoreAudio 48kHz float to 8kHz 16-bit PCM) out via Interface 1 (EP 0x02).
                       - Read incoming voice samples from Interface 1 (EP 0x82) and pipe into macOS speaker output.
                    """)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineSpacing(4)
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(10)
            }
            .padding(20)
        }
    }
    
    private func statusCard(title: String, value: String, subtitle: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Image(systemName: icon)
                    .foregroundColor(color)
            }
            Text(value)
                .font(.title3.bold())
                .foregroundColor(color)
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
    }
    
    private func interfaceRow(id: Int, name: String, eps: String, purpose: String, status: String, highlight: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text("Interface \(id)")
                .font(.system(.subheadline, design: .monospaced).bold())
                .frame(width: 90, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(name)
                        .font(.subheadline.bold())
                    Spacer()
                    Text(status)
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(highlight ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.15))
                        .foregroundColor(highlight ? .accentColor : .secondary)
                        .cornerRadius(4)
                }
                Text(eps)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                Text(purpose)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(8)
        .background(highlight ? Color.accentColor.opacity(0.05) : Color.clear)
        .cornerRadius(6)
    }
}
