import Foundation
import EC20Core
import EC20Transport

var passedCount = 0
var failedCount = 0

func assertTest(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition {
        passedCount += 1
        print("  ✅ [PASS] \(message)")
    } else {
        failedCount += 1
        print("  ❌ [FAIL] \(message) (\(file):\(line))")
    }
}

@main
@MainActor
struct TestSuiteRunner {
    static func main() async {
        print("=======================================================")
        print("   Running EC20 Offline Test Suite (Swift 6 Native)   ")
        print("=======================================================")
        
        // 1. UCS2 Codec Tests
        print("\n[Suite 1] UCS2 Codec Tests")
        let chinese = "你好，EC20！"
        let hex = UCS2Codec.encode(chinese)
        assertTest(hex == "4F60597DFF0C0045004300320030FF01", "UCS2 Hex Encoding")
        let decoded = UCS2Codec.decode(hex)
        assertTest(decoded == chinese, "UCS2 Hex Decoding")
        assertTest(UCS2Codec.requiresUCS2("Hello 123") == false, "ASCII does not require UCS2")
        assertTest(UCS2Codec.requiresUCS2("移远通信") == true, "Chinese characters require UCS2")
        
        // 2. PDU Codec Tests
        print("\n[Suite 2] PDU 7-Bit GSM & Multipart Codec Tests")
        let asciiText = "Hello EC20 GSM Alphabet"
        let (packed, septetCount) = PDUCodec.pack7Bit(asciiText)
        assertTest(septetCount == asciiText.count, "7-bit septet count matches character count")
        let unpacked = PDUCodec.unpack7BitGSM(bytes: packed, udl: septetCount, hasUDH: false, udhLength: 0)
        assertTest(unpacked == asciiText, "7-bit pack and unpack preserves exact text")
        
        let singlePDUs = PDUCodec.encodeSubmitPDUs(destination: "+8613800138000", text: "Simple Test")
        assertTest(singlePDUs.count == 1, "Short SMS creates exactly 1 PDU")
        assertTest(singlePDUs[0].tpduLength > 0, "Single PDU has positive TPDU length")
        
        let longChinese = String(repeating: "测试长短信拼接内容", count: 10) // 90 chars, exceeds 70
        let multiPDUs = PDUCodec.encodeSubmitPDUs(destination: "+8613800138000", text: longChinese, referenceNumber: 0x42)
        assertTest(multiPDUs.count == 2, "Long SMS splits into 2 concatenated PDUs")
        assertTest(multiPDUs[0].pduHex.contains("050003420201"), "Part 1 contains UDH 0x00 header (1/2)")
        assertTest(multiPDUs[1].pduHex.contains("050003420202"), "Part 2 contains UDH 0x00 header (2/2)")
        
        let testDeliverPDU = "0891683108200005F0040D91683108000000F000006290220202022304D4F29C0E"
        let decodedDeliver = PDUCodec.decodeDeliverPDU(testDeliverPDU)
        assertTest(decodedDeliver != nil, "Decode Deliver PDU succeeds")
        assertTest(decodedDeliver?.sender == "+8613800000000", "Decoded sender number is +8613800000000")
        assertTest(decodedDeliver?.text == "Test", "Decoded message body is 'Test'")
        
        // 3. URC Parser Tests
        print("\n[Suite 3] URC Parser Tests")
        let cmti = "+CMTI: \"ME\",15"
        assertTest(URCParser.isURC(cmti), "+CMTI identified as URC")
        assertTest(URCParser.parse(cmti) == .incomingSMS(storage: "ME", index: 15), "Parsed +CMTI event")
        
        let clip = "+CLIP: \"13812345678\",129,,,,0"
        assertTest(URCParser.isURC(clip), "+CLIP identified as URC")
        assertTest(URCParser.parse(clip) == .incomingCall(callerNumber: "13812345678"), "Parsed +CLIP caller ID")
        
        assertTest(URCParser.parse("RING") == .ring, "Parsed RING event")
        assertTest(URCParser.parse("NO CARRIER") == .callEnded(reason: "NO CARRIER"), "Parsed NO CARRIER event")
        assertTest(URCParser.parse("+CREG: 0,1") == .cregChanged(status: .registeredHome), "Parsed +CREG home registered")
        assertTest(URCParser.parse("+CEREG: 0,5") == .ceregChanged(status: .roaming), "Parsed +CEREG roaming registered")
        assertTest(URCParser.parse("+CSQ: 22,99") == .signalChanged(csq: 22), "Parsed +CSQ signal")
        
        // 4. Sensitive Masker Tests
        print("\n[Suite 4] Sensitive Information Masking Tests")
        let iccid = "89860401123456789012"
        let maskedICCID = SensitiveMasker.mask(identifier: iccid)
        assertTest(!maskedICCID.contains("0112345678"), "ICCID middle numbers masked")
        assertTest(maskedICCID.hasPrefix("8986") && maskedICCID.hasSuffix("9012"), "ICCID prefix and suffix preserved")
        
        let phone = "+8613812345678"
        let maskedPhone = SensitiveMasker.mask(phoneNumber: phone)
        assertTest(maskedPhone == "+86138****5678", "Chinese phone number masked format (+86138****5678)")
        
        let rawLog = "Response from modem: +QCCID: 89860401123456789012 and +CLIP: \"13812345678\",129"
        let sanitized = SensitiveMasker.sanitizeLog(rawLog)
        assertTest(!sanitized.contains("89860401123456789012"), "Sanitized log hides raw ICCID")
        assertTest(!sanitized.contains("13812345678"), "Sanitized log hides raw phone number")
        
        // 5. Audio Bridge Assessment Tests
        print("\n[Suite 5] Audio Bridge Assessment & Hardware Logic Tests")
        let pcmTransport = VoicePCMTransport()
        let assessment = pcmTransport.probeAudioCapabilities(currentQPCMV: "0,0", qdai: "3,0,0,4,0,0,1,1", querySupported: true)
        assertTest(assessment.uacDeviceDetected == false, "UAC Audio Class is absent in standard 2c7c:0125 descriptor")
        assertTest(assessment.qpcmvSupported == true, "Voice over USB (AT+QPCMV) is supported")
        assertTest(assessment.pcmInterfaceIndex == 1, "Voice over USB routes to Interface 1 (GNSS/NMEA)")
        assertTest(assessment.callSignalingStatus.contains("unverified"), "Live call remains unverified")
        assertTest(assessment.systemAudioBridgeStatus.contains("unverified"), "Live carrier audio remains unverified")
        
        // 6. Mock Controller Integration & Call State Flow Tests
        print("\n[Suite 6] Mock Controller Integration & Call Flow Tests")
        let mock = MockATTransport()
        let controller = EC20Controller(transport: mock)
        await controller.connect()
        var waited = 0
        while (controller.isBusy || controller.simInfo.operatorName == nil) && waited < 30 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }
        
        let simInfo = controller.simInfo
        assertTest(simInfo.cpinStatus == .ready, "Mock initialization retrieved CPIN READY")
        assertTest(simInfo.operatorName == "CHN-UNICOM", "Mock initialization retrieved CHN-UNICOM operator (got '\(simInfo.operatorName ?? "nil")')")
        assertTest(simInfo.signal.csq == 25, "Mock initialization retrieved CSQ 25")

        await controller.loadSMSMessages()
        assertTest(controller.smsMessages.first?.text == "Test", "PDU inbox decodes message body")
        assertTest(controller.smsMessages.first?.senderOrRecipient == "+8613800000000", "PDU inbox decodes sender")
        try? await controller.sendSMS(to: "+8613800138000", text: "Offline test")
        assertTest(!mock.lastSMSPayloadHadCRLF, "SMS PDU ends at Ctrl-Z without extra CRLF")
        assertTest(!controller.atLogs.joined().contains("Offline test"), "SMS body is absent from AT logs")
        
        // Test simulated incoming call
        mock.simulateIncomingCall(number: "13912345678")
        try? await Task.sleep(nanoseconds: 100_000_000)
        let incomingAlert = controller.incomingCallAlert
        assertTest(incomingAlert != nil && incomingAlert!.contains("139****5678"), "Incoming call URC triggered masked alert")
        
        // Answer call
        try? await controller.answerCall()
        let activeCalls = controller.activeCalls
        assertTest(activeCalls.count == 1 && activeCalls[0].status == .active, "Call answered and active")
        
        // Hangup call
        try? await controller.hangupCall()
        let callsAfterHangup = controller.activeCalls
        assertTest(callsAfterHangup.isEmpty, "Call terminated after hangup")
        
        await controller.disconnect()
        
        // Summary
        print("\n=======================================================")
        print("  Test Results: \(passedCount) Passed, \(failedCount) Failed")
        print("=======================================================")
        if failedCount > 0 {
            exit(1)
        }
    }
}
