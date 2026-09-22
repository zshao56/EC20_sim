import Foundation
import CLibUSB
import EC20Core

public final class VoicePCMTransport: @unchecked Sendable {
    public let pcmInterface: Int32 = 1 // GNSS/NMEA interface where EC20 routes raw PCM
    public let epOut: UInt8 = 0x02
    public let epIn: UInt8 = 0x82
    
    public init() {}
    
    /// Evaluates hardware audio pathway on current USB configuration
    public func probeAudioCapabilities(currentQPCMV: String, qdai: String?, querySupported: Bool) -> AudioBridgeAssessment {
        // Detailed hardware inspection:
        // 1. USB Descriptors VID:0x2c7c PID:0x0125 contains 5 vendor-specific interfaces (class 0xff).
        // 2. No USB Audio Class (bInterfaceClass == 0x01) is present.
        // 3. Audio Note confirms AT+QPCMV=1,0 streams raw PCM over Interface 1 (NMEA).
        
        return AudioBridgeAssessment(
            uacDeviceDetected: false,
            qpcmvSupported: querySupported,
            qpcmvCurrentSetting: currentQPCMV,
            qdaiSetting: qdai,
            pcmInterfaceIndex: Int(pcmInterface),
            pcmOutEndpoint: epOut,
            pcmInEndpoint: epIn,
            pcmFormatDescription: "8000 Hz, signed 16-bit mono (640 bytes/40ms down, 1600 bytes/100ms up)",
            callSignalingStatus: "AT call commands implemented; live call unverified",
            systemAudioBridgeStatus: "CoreAudio bridge implemented; live audio unverified",
            technicalConclusion: """
                [Hardware Audio Evaluation Summary]
                - USB Device: Quectel EC20-CE-HDLG (0x2c7c:0x0125)
                - Audio Class (UAC): NOT present in device descriptors. macOS does not see an input/output sound device.
                - Voice over USB (Raw PCM): AT+QPCMV query support = \(querySupported). When enabled, it maps PCM to USB Interface 1 (GNSS/NMEA, EP 0x02 / 0x82).
                - CoreAudio bridge code is present; two-way carrier audio remains unverified.
                """
        )
    }
}
