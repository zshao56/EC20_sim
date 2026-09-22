import Foundation
import EC20Core
import EC20Transport

@main
@MainActor
struct EC20CLIMain {
    static func main() async {
        let args = ProcessInfo.processInfo.arguments
        let useMock = args.contains("--mock") || args.contains("--sim")
        
        print("=======================================================")
        print(" Quectel EC20 macOS Diagnostic & Telephony CLI Tool")
        print(" Hardware: VID:0x2c7c PID:0x0125 (EC20-CE-HDLG)")
        print(" Mode: \(useMock ? "Simulation (Mock)" : "Live Hardware (libusb-1.0)")")
        print("=======================================================")
        
        let transport: any ATTransport = useMock ? MockATTransport() : LibusbATTransport()
        let controller = EC20Controller(transport: transport)
        
        print("[1/5] Opening transport...")
        await controller.connect()
        
        // Wait a moment for modem initialization
        var waitCount = 0
        while (controller.isBusy || controller.simInfo.operatorName == nil) && waitCount < 30 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waitCount += 1
        }
        
        let simInfo = controller.simInfo
        let audioAssessment = controller.audioAssessment
        
        print("\n[2/5] Hardware & SIM Identity:")
        print("  - Model:             \(simInfo.model ?? "Quectel EC20")")
        print("  - Firmware Revision: \(simInfo.revision ?? "Unknown")")
        print("  - SIM Status:        \(simInfo.cpinStatus.rawValue)")
        print("  - Operator:          \(simInfo.operatorName ?? "Unknown / Not Registered")")
        print("  - Signal:            \(simInfo.signal.summary) (\(simInfo.signal.signalBars)/4 bars)")
        print("  - Masked ICCID:      \(simInfo.maskedICCID)")
        print("  - Masked IMSI:       \(simInfo.maskedIMSI)")
        print("  - Masked IMEI:       \(simInfo.maskedIMEI)")
        print("  - CS Domain (CREG):  \(simInfo.cregStatus.description)")
        print("  - EPS/LTE (CEREG):   \(simInfo.ceregStatus.description)")
        
        print("\n[3/5] Audio & Voice Hardware Assessment:")
        print("  - USB Audio Class (UAC):      \(audioAssessment.uacDeviceDetected ? "Exposed" : "NOT Exposed in USB descriptors")")
        print("  - Voice over USB (AT+QPCMV):   \(audioAssessment.qpcmvSupported ? "Supported" : "Unsupported")")
        print("  - Current AT+QPCMV Setting:   \(audioAssessment.qpcmvCurrentSetting)")
        print("  - Digital Audio (AT+QDAI):    \(audioAssessment.qdaiSetting ?? "Unknown")")
        print("  - Voice PCM Port:             Interface \(audioAssessment.pcmInterfaceIndex) (Endpoints: OUT 0x0\(audioAssessment.pcmOutEndpoint), IN 0x8\(audioAssessment.pcmInEndpoint & 0x0F))")
        print("  - PCM Format:                 \(audioAssessment.pcmFormatDescription)")
        print("  - Call Signaling Status:      \(audioAssessment.callSignalingStatus)")
        print("  - macOS CoreAudio Status:     \(audioAssessment.systemAudioBridgeStatus)")
        
        print("\n[4/5] Testing PDU & UCS2 Codecs:")
        let testString = "Quectel EC20 移远通信测试短信 123"
        let pdus = PDUCodec.encodeSubmitPDUs(destination: "+8613800000000", text: testString)
        print("  - Text: \"\(testString)\"")
        print("  - Requires UCS2: \(UCS2Codec.requiresUCS2(testString))")
        print("  - Generated PDUs: \(pdus.count) part(s)")
        for (i, p) in pdus.enumerated() {
            print("    Part \(i + 1): TPDU length = \(p.tpduLength), PDU = \(p.pduHex)")
        }
        
        print("\n[5/5] Technical Assessment Conclusion:")
        print(audioAssessment.technicalConclusion)
        
        await controller.disconnect()
        print("\n[Done] Diagnostic run completed successfully.")
    }
}
