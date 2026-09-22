import SwiftUI
import EC20Core

@MainActor
public struct StatusDashboardView: View {
    @ObservedObject var controller: EC20Controller
    
    public init(controller: EC20Controller) {
        self.controller = controller
    }
    
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Header Banner
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("EC20 Status & Telephony Dashboard")
                            .font(.title2.bold())
                        Text("Hardware: Quectel EC20-CE-HDLG | USB VID: 0x2c7c PID: 0x0125")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: {
                        Task { await controller.initializeModem() }
                    }) {
                        Label("Refresh All", systemImage: "arrow.clockwise")
                    }
                    .disabled(controller.isBusy)
                }
                .padding(.bottom, 6)
                
                // Top Metrics Grid
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    metricCard(
                        title: "Operator",
                        value: controller.simInfo.operatorName ?? "Searching...",
                        subtitle: controller.simInfo.isRegistered ? "Registered" : "Not Registered",
                        icon: "antenna.radiowaves.left.and.right",
                        color: controller.simInfo.isRegistered ? .green : .orange
                    )
                    
                    metricCard(
                        title: "Signal Quality",
                        value: controller.simInfo.signal.summary,
                        subtitle: "\(controller.simInfo.signal.signalBars)/4 Bars",
                        icon: "cellularbars",
                        color: controller.simInfo.signal.signalBars >= 2 ? .blue : .red
                    )
                    
                    metricCard(
                        title: "SIM Card State",
                        value: controller.simInfo.cpinStatus.rawValue,
                        subtitle: controller.simInfo.cpinStatus == .ready ? "Ready for Telephony" : "Attention Required",
                        icon: "simcard",
                        color: controller.simInfo.cpinStatus == .ready ? .purple : .red
                    )
                }
                
                // Detailed Information Sections
                HStack(alignment: .top, spacing: 14) {
                    // Left Column: Identity & SIM
                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader(title: "SIM & Hardware Identity", icon: "person.text.rectangle")
                        
                        infoRow(label: "ICCID (SIM)", value: controller.simInfo.maskedICCID, note: "Masked for security")
                        infoRow(label: "IMSI", value: controller.simInfo.maskedIMSI, note: "Masked")
                        infoRow(label: "IMEI", value: controller.simInfo.maskedIMEI, note: "Masked")
                        infoRow(label: "Module Model", value: controller.simInfo.model ?? "Quectel EC20F")
                        infoRow(label: "Firmware Revision", value: controller.simInfo.revision ?? "EC20CEHDLGR08A02M1G")
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(10)
                    
                    // Right Column: Network & Registration
                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader(title: "Network Registration", icon: "network")
                        
                        infoRow(label: "CS Domain (CREG)", value: controller.simInfo.cregStatus.description)
                        infoRow(label: "EPS/LTE (CEREG)", value: controller.simInfo.ceregStatus.description)
                        infoRow(label: "Active Calls", value: "\(controller.activeCalls.count) Active")
                        infoRow(label: "Stored SMS Count", value: "\(controller.smsMessages.count) Messages")
                        infoRow(label: "Voice Audio Path", value: "PCM over USB (NMEA)", note: "AT+QPCMV")
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(10)
                }
                
                // Hardware Connection Notice
                HStack {
                    Image(systemName: "shield.lefthalf.filled")
                        .foregroundColor(.blue)
                    Text("SIM identifiers are masked on this dashboard. SMS sender numbers are shown in the inbox; diagnostic logs mask phone numbers.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 4)
            }
            .padding(20)
        }
    }
    
    private func sectionHeader(title: String, icon: String) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
            Text(title)
                .font(.headline)
        }
    }
    
    private func infoRow(label: String, value: String, note: String? = nil) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(value)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.medium)
                if let note = note {
                    Text(note)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
    
    private func metricCard(title: String, value: String, subtitle: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Image(systemName: icon)
                    .foregroundColor(color)
            }
            Text(value)
                .font(.title3.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
    }
}
