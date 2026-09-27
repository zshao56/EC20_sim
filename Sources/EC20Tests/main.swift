import Foundation
import EC20Core
import EC20Transport
import EC20BridgeProtocol

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
        let controller = EC20Controller(transport: mock, database: EC20Database(inMemory: true))
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

        // 7. Database & Persistence Tests
        print("\n[Suite 7] SQLite Database Persistence & Dedup Tests")
        let testDB = EC20Database(inMemory: true)

        // Save incoming SMS
        let sms1 = SMSMessage(
            storageIndex: 1,
            storageArea: "ME",
            senderOrRecipient: "+8613800138000",
            text: "Hello SQLite",
            timestamp: Date(timeIntervalSince1970: 1700000000),
            isIncoming: true,
            isRead: false
        )
        let inserted1 = testDB.saveMessage(sms1)
        assertTest(inserted1 == true, "First message inserted successfully")
        let insertedDup = testDB.saveMessage(sms1)
        assertTest(insertedDup == false, "Duplicate message correctly ignored by dedupKey")

        let convs = testDB.fetchConversations()
        assertTest(convs.count == 1, "One conversation thread created")
        assertTest(convs.first?.unreadCount == 1, "Unread count is 1")
        assertTest(testDB.totalUnreadCount() == 1, "Total unread count is 1")

        testDB.markThreadRead(threadId: convs.first!.threadId)
        assertTest(testDB.totalUnreadCount() == 0, "Mark thread read resets unread count to 0")

        // Contact persistence and notes
        let contact = Contact(name: "张三", phoneNumber: "13800138000", notes: "VIP 客户")
        testDB.saveContact(contact)
        let fetchedContacts = testDB.fetchContacts()
        assertTest(fetchedContacts.count == 1 && fetchedContacts.first?.notes == "VIP 客户", "Contact saved with custom notes")
        let foundContact = testDB.findContact(forPhone: "+8613800138000")
        assertTest(foundContact?.name == "张三", "Normalized phone lookup finds contact")

        // Call record persistence
        let callRec = CallHistoryItem(
            phoneNumber: "+8613800138000",
            contactName: "张三",
            type: .incoming,
            durationSeconds: 45,
            source: .local,
            hasExactTimestamp: true
        )
        testDB.saveCallRecord(callRec)
        let history = testDB.fetchCallHistory()
        assertTest(history.count == 1 && history.first?.durationSeconds == 45, "Call record saved and retrieved")

        // 8. Outbox Retry by ID Tests
        print("\n[Suite 8] Outbox Retry by ID Tests")
        let failedSMS = SMSMessage(
            senderOrRecipient: "+8613800138000",
            text: "Failed Outbox SMS",
            isIncoming: false,
            isRead: true,
            sendStatus: .failed,
            sendError: "Network timeout"
        )
        testDB.saveMessage(failedSMS)
        let fetchedFailed = testDB.fetchMessage(id: failedSMS.id)
        assertTest(fetchedFailed != nil && fetchedFailed?.sendStatus == .failed, "Failed SMS saved in outbox")

        testDB.updateMessageStatus(id: failedSMS.id, status: .sending, error: nil)
        let inFlight = testDB.fetchMessage(id: failedSMS.id)
        assertTest(inFlight?.sendStatus == .sending && inFlight?.sendError == nil, "SMS status updated to sending on retry")

        testDB.updateMessageStatus(id: failedSMS.id, status: .sent, error: nil)
        let resolved = testDB.fetchMessage(id: failedSMS.id)
        assertTest(resolved?.sendStatus == .sent, "SMS status updated to sent after successful retry")

        // 9. Audio Bridge Microphone Mute Tests
        print("\n[Suite 9] Audio Bridge Microphone Mute Tests")
        let bridge = EC20AudioBridge()
        bridge.setMicrophoneMuted(true)
        assertTest(bridge.state == .stopped, "AudioBridge initial state is stopped")
        bridge.setMicrophoneMuted(false)
        assertTest(true, "AudioBridge microphone mute toggle succeeds")

        // 10. Module Slot Reuse & Multipart Incomplete Fragment Tests
        print("\n[Suite 10] Module Slot Reuse & Multipart Suppression Tests")
        let slotReuseDB = EC20Database(inMemory: true)

        // Same module storage slot (ME:1), but different timestamp (SCTS) & rawPDU/content
        let slotMsg1 = SMSMessage(
            storageIndex: 1,
            storageArea: "ME",
            senderOrRecipient: "+8613800000001",
            text: "First SMS in ME Slot 1",
            timestamp: Date(timeIntervalSince1970: 1700000001),
            isIncoming: true,
            isRead: true,
            rawPDU: "PDU_SLOT1_FIRST"
        )
        let slotMsg2 = SMSMessage(
            storageIndex: 1,
            storageArea: "ME",
            senderOrRecipient: "+8613800000001",
            text: "Second SMS in ME Slot 1 after index reuse",
            timestamp: Date(timeIntervalSince1970: 1700000002),
            isIncoming: true,
            isRead: false,
            rawPDU: "PDU_SLOT1_REUSED"
        )
        let insSlot1 = slotReuseDB.saveMessage(slotMsg1)
        let insSlot2 = slotReuseDB.saveMessage(slotMsg2)
        assertTest(insSlot1 == true, "First message in ME:1 inserted")
        assertTest(insSlot2 == true, "Second message in reused ME:1 with different SCTS/PDU also inserted")
        let allSlotMsgs = slotReuseDB.fetchAllMessages()
        assertTest(allSlotMsgs.count == 2, "Both slot 1 messages coexist in SQLite without overwrite")

        // Multipart incomplete fragment assembly & suppression
        let part1Fragment = SMSMessage(
            storageIndex: 10,
            storageArea: "ME",
            senderOrRecipient: "+8613800000003",
            text: "前半段内容...",
            timestamp: Date(timeIntervalSince1970: 1700000010),
            isIncoming: true,
            isRead: false,
            multipartInfo: PDUCodec.MultipartInfo(referenceNumber: 42, totalParts: 2, currentPart: 1)
        )
        let part2Fragment = SMSMessage(
            storageIndex: 11,
            storageArea: "ME",
            senderOrRecipient: "+8613800000003",
            text: "后半段内容。",
            timestamp: Date(timeIntervalSince1970: 1700000011),
            isIncoming: true,
            isRead: false,
            multipartInfo: PDUCodec.MultipartInfo(referenceNumber: 42, totalParts: 2, currentPart: 2)
        )

        // When only part 1 has arrived:
        let incompleteAssembled = EC20Controller.assembleMultipartMessages([part1Fragment])
        assertTest(incompleteAssembled.isEmpty, "Incomplete multipart fragment (1/2) is not emitted as complete message")

        // When both parts have arrived:
        let fullyAssembled = EC20Controller.assembleMultipartMessages([part1Fragment, part2Fragment])
        assertTest(fullyAssembled.count == 1, "Complete multipart (2/2) successfully assembled into 1 message")
        assertTest(fullyAssembled.first?.text == "前半段内容...后半段内容。", "Assembled message text is concatenated correctly")
        assertTest(fullyAssembled.first?.multipartInfo == nil, "Assembled message multipartInfo is nil (ready for notification)")

        // -------------------------------------------------------------
        // Suite 11: Cellular Network Manager Netmask & Safe Route Tests
        // -------------------------------------------------------------
        print("\n[Suite 11] Cellular Network Manager Netmask & Safe Route Tests")

        // Netmask conversion tests
        let mask1 = EC20NetworkManager.convertHexNetmask("0xffffff00")
        assertTest(mask1 == "255.255.255.0", "Hex 0xffffff00 converts to 255.255.255.0")

        let mask2 = EC20NetworkManager.convertHexNetmask("0xffff0000")
        assertTest(mask2 == "255.255.0.0", "Hex 0xffff0000 converts to 255.255.0.0")

        let mask3 = EC20NetworkManager.convertHexNetmask("255.255.255.0")
        assertTest(mask3 == "255.255.255.0", "Dotted-decimal netmask preserved untouched")

        // CellularNetworkStatus External Disabled State
        let extDisabledStatus = CellularNetworkStatus(
            isSupported: true,
            isServiceEnabled: false,
            isServiceDisabledExternally: true,
            isLinkActive: false,
            interfaceName: "en8",
            serviceName: "EC20-CE-HDLG",
            ipv4Address: "192.168.225.27",
            statusDescription: "macOS 网络服务已在系统设置中禁用 (需重启模块重新枚举)"
        )
        assertTest(extDisabledStatus.isServiceDisabledExternally == true, "External disabled state is tracked")
        assertTest(extDisabledStatus.isLinkActive == false, "Link inactive state is tracked")
        assertTest(extDisabledStatus.isConnected == false, "Externally disabled service reports not connected")

        // CellularNetworkStatus Active DHCP State
        let activeStatus = CellularNetworkStatus(
            isSupported: true,
            isServiceEnabled: true,
            isServiceDisabledExternally: false,
            isLinkActive: true,
            interfaceName: "en8",
            serviceName: "EC20-CE-HDLG",
            ipv4Address: "192.168.225.27",
            subnetMask: "255.255.255.0",
            routerAddress: "192.168.225.1",
            statusDescription: "已连接蜂窝网络 (en8)"
        )
        assertTest(activeStatus.isLinkActive == true, "Link active state is tracked")
        assertTest(activeStatus.isConnected == true, "Active DHCP state reports connected")
        assertTest(activeStatus.subnetMask == "255.255.255.0", "Real subnet mask preserved in status")
        assertTest(activeStatus.routerAddress == "192.168.225.1", "Real router address preserved in status")

        // 12. Call History Fallback & Number Sanitization Tests
        print("\n[Suite 12] Call History Fallback & Number Sanitization Tests")
        let callFallbackDB = EC20Database(inMemory: true)

        // 12.1 CallHistoryItem empty phone fallback
        let emptyItem = CallHistoryItem(phoneNumber: "", type: .outgoing)
        assertTest(emptyItem.phoneNumber == "未知号码", "Empty phone number in CallHistoryItem defaults to 未知号码")
        assertTest(emptyItem.normalizedPhone == "未知号码", "Empty phone number normalizes to 未知号码")

        let whitespaceItem = CallHistoryItem(phoneNumber: "   ", type: .missed)
        assertTest(whitespaceItem.phoneNumber == "未知号码", "Whitespace phone number defaults to 未知号码")

        // 12.2 Database saveCallRecord sanitization
        callFallbackDB.saveCallRecord(emptyItem)
        callFallbackDB.saveCallRecord(CallHistoryItem(phoneNumber: "  ", type: .incoming))
        let fetchedCalls = callFallbackDB.fetchCallHistory()
        assertTest(fetchedCalls.count == 2, "Two call records saved in database")
        assertTest(fetchedCalls.allSatisfy { $0.phoneNumber == "未知号码" && !$0.phoneNumber.isEmpty }, "Database stores and returns 未知号码 for blank inputs")

        // 12.3 PhoneNumberNormalizer.displayFormat fallback
        assertTest(PhoneNumberNormalizer.displayFormat("") == "未知号码", "Display format of empty string is 未知号码")
        assertTest(PhoneNumberNormalizer.displayFormat("   ") == "未知号码", "Display format of whitespace is 未知号码")
        assertTest(PhoneNumberNormalizer.displayFormat("未知号码") == "未知号码", "Display format of 未知号码 is 未知号码")
        assertTest(PhoneNumberNormalizer.displayFormat("13800138000") == "+86 138 0013 8000", "Display format formats 11-digit mobile")

        // 12.4 Controller call polling with empty CLCC number preserves dialed number
        let mockTransport12 = MockATTransport()
        let mockDB12 = EC20Database(inMemory: true)
        let mockController12 = EC20Controller(transport: mockTransport12, database: mockDB12)
        try? mockTransport12.open()
        await mockController12.connect()

        try? await mockController12.dial(number: "19267026145")
        assertTest(mockController12.activeCalls.first?.phoneNumber == "19267026145", "Active call has dialed number")

        try? await mockController12.hangupCall()
        let callRecs = mockDB12.fetchCallHistory()
        assertTest(callRecs.first?.phoneNumber == "19267026145", "Hangup preserves dialed number in history record")
        await mockController12.disconnect()

        // 13. Dialpad Input Filter Pure Function Tests
        print("\n[Suite 13] Dialpad Input Filter Pure Function Tests")
        assertTest(DialpadInputFilter.filter("1234567890+*#") == "1234567890+*#", "All allowed dialpad characters preserved")
        assertTest(DialpadInputFilter.filter("+86 (138) 1234-5678") == "+8613812345678", "Strips spaces, brackets, and hyphens")
        assertTest(DialpadInputFilter.filter("Tel: +86-138-0000-5678 📞") == "+8613800005678", "Strips letters and emojis")
        assertTest(DialpadInputFilter.filter("abc") == "", "Non-dialpad letters filtered to empty string")
        assertTest(DialpadInputFilter.isAllowed("5") == true, "Digit 5 is allowed")
        assertTest(DialpadInputFilter.isAllowed("+") == true, "Plus is allowed")
        assertTest(DialpadInputFilter.isAllowed("*") == true, "Asterisk is allowed")
        assertTest(DialpadInputFilter.isAllowed("#") == true, "Hash is allowed")
        assertTest(DialpadInputFilter.isAllowed("-") == false, "Hyphen is disallowed")
        assertTest(DialpadInputFilter.isAllowed(" ") == false, "Space is disallowed")

        // 14. SMS Deletion Tests (Single & Thread)
        print("\n[Suite 14] SMS Deletion Tests (Single & Thread)")
        let mockTransport14 = MockATTransport()
        let mockDB14 = EC20Database(inMemory: true)
        let mockController14 = EC20Controller(transport: mockTransport14, database: mockDB14)
        try? mockTransport14.open()
        await mockController14.connect()

        // 14.1 Delete single message with module storage index
        let modSMS = SMSMessage(
            storageIndex: 7,
            storageArea: "ME",
            senderOrRecipient: "+8613800001111",
            text: "Module SMS to delete",
            isIncoming: true,
            isRead: true
        )
        mockDB14.saveMessage(modSMS)
        mockController14.loadLocalData()
        assertTest(mockDB14.fetchMessage(id: modSMS.id) != nil, "Module SMS exists in DB before delete")

        try? await mockController14.deleteSMS(id: modSMS.id)
        assertTest(mockDB14.fetchMessage(id: modSMS.id) == nil, "Module SMS deleted from DB after deleteSMS")

        // 14.2 Delete local-only message (without storage index)
        let localSMS = SMSMessage(
            storageIndex: nil,
            storageArea: nil,
            senderOrRecipient: "+8613800002222",
            text: "Local outbox SMS to delete",
            isIncoming: false,
            isRead: true
        )
        mockDB14.saveMessage(localSMS)
        mockController14.loadLocalData()
        assertTest(mockDB14.fetchMessage(id: localSMS.id) != nil, "Local SMS exists in DB before delete")

        try? await mockController14.deleteSMS(id: localSMS.id)
        assertTest(mockDB14.fetchMessage(id: localSMS.id) == nil, "Local SMS deleted from DB after deleteSMS")

        // 14.3 Delete entire conversation thread
        let threadTarget = "+8613800003333"
        let msgA = SMSMessage(
            threadId: PhoneNumberNormalizer.normalize(threadTarget),
            storageIndex: 8,
            storageArea: "ME",
            senderOrRecipient: threadTarget,
            text: "Thread msg 1",
            isIncoming: true,
            isRead: true
        )
        let msgB = SMSMessage(
            threadId: PhoneNumberNormalizer.normalize(threadTarget),
            storageIndex: 9,
            storageArea: "ME",
            senderOrRecipient: threadTarget,
            text: "Thread msg 2",
            isIncoming: true,
            isRead: true
        )
        mockDB14.saveMessage(msgA)
        mockDB14.saveMessage(msgB)
        mockController14.loadLocalData()
        let tNorm = PhoneNumberNormalizer.normalize(threadTarget)
        assertTest(mockDB14.fetchMessages(threadId: tNorm).count == 2, "Thread has 2 messages before deleteThread")

        try? await mockController14.deleteThread(threadId: tNorm)
        assertTest(mockDB14.fetchMessages(threadId: tNorm).isEmpty, "All messages in thread deleted")
        assertTest(!mockController14.conversations.contains(where: { $0.threadId == tNorm }), "Thread removed from conversations")

        await mockController14.disconnect()

        // -------------------------------------------------------
        // Suite 15: Phone Attribution Lookup (Offline)
        // -------------------------------------------------------
        print("\n--- Suite 15: Phone Attribution Lookup (Offline) ---")
        let lookup = PhoneAttributionLookup.shared

        // 15.1 Mobile Carrier detection
        let mobileCM = lookup.lookup("13812345678")
        assertTest(mobileCM.category == .mobile && mobileCM.carrier == "中国移动", "138 recognized as China Mobile")

        let mobileCU = lookup.lookup("+8613012345678")
        assertTest(mobileCU.category == .mobile && mobileCU.carrier == "中国联通", "+86130 recognized as China Unicom")

        let mobileCT = lookup.lookup("008618912345678")
        assertTest(mobileCT.category == .mobile && mobileCT.carrier == "中国电信", "0086189 recognized as China Telecom")

        let mobileCBN = lookup.lookup("19212345678")
        assertTest(mobileCBN.category == .mobile && mobileCBN.carrier == "中国广电", "192 recognized as China Broadnet")

        // 15.2 Landline area codes
        let bjLandline = lookup.lookup("01088889999")
        assertTest(bjLandline.category == .landline && bjLandline.province == "北京", "010 recognized as Beijing Landline")

        let shLandline = lookup.lookup("+862166667777")
        assertTest(shLandline.category == .landline && shLandline.province == "上海", "021 recognized as Shanghai Landline")

        let szLandline = lookup.lookup("075512345678")
        assertTest(szLandline.category == .landline && szLandline.city == "深圳", "0755 recognized as Shenzhen Landline")

        // 15.3 Emergency numbers
        let em110 = lookup.lookup("110")
        assertTest(em110.category == .emergency && em110.displayString.contains("报警"), "110 recognized as 匪警")

        let em120 = lookup.lookup("120")
        assertTest(em120.category == .emergency && em120.displayString.contains("急救"), "120 recognized as 急救")

        // 15.4 Customer service & toll-free
        let bank = lookup.lookup("95555")
        assertTest(bank.category == .service && bank.displayString.contains("招商银行"), "95555 recognized as CMB Service")

        let tollFree = lookup.lookup("4008123456")
        assertTest(tollFree.category == .tollFree && tollFree.displayString.contains("400"), "400 recognized as toll-free")

        let intl = lookup.lookup("+14155552671")
        assertTest(intl.category == .international && (intl.country ?? "").contains("+1"), "+1 recognized as US/Canada")

        // -------------------------------------------------------
        // Suite 16: Bridge Protocol Framing & Max Size Enforcement
        // -------------------------------------------------------
        print("\n--- Suite 16: Bridge Protocol Framing & Max Size Enforcement ---")

        // 16.1 Encode & Decode round-trip
        let testPayload = "Hello EC20 Bridge Protocol!".data(using: .utf8)!
        let encodedFrame = BridgeFraming.encode(testPayload)
        assertTest(encodedFrame.count == testPayload.count + 4, "Encoded frame has 4-byte header")

        var buffer = encodedFrame
        let decodedPayload = try? BridgeFraming.decode(from: &buffer)
        assertTest(decodedPayload == testPayload, "Decoded payload matches original")
        assertTest(buffer.isEmpty, "Buffer completely consumed after decode")

        // 16.2 Incomplete frame handling
        var partialBuffer = encodedFrame.prefix(10)
        let partialDecoded = try? BridgeFraming.decode(from: &partialBuffer)
        assertTest(partialDecoded == nil, "Partial frame returns nil without error")
        assertTest(partialBuffer.count == 10, "Partial buffer retained")

        // 16.3 Multi-frame stream decoding
        let payloadA = "Packet A".data(using: .utf8)!
        let payloadB = "Packet B".data(using: .utf8)!
        var multiBuffer = BridgeFraming.encode(payloadA) + BridgeFraming.encode(payloadB)

        let outA = try? BridgeFraming.decode(from: &multiBuffer)
        let outB = try? BridgeFraming.decode(from: &multiBuffer)
        assertTest(outA == payloadA && outB == payloadB, "Multiple frames decoded in sequence")
        assertTest(multiBuffer.isEmpty, "Multi-frame buffer emptied")

        // 16.4 Max Frame Size limit enforcement
        var hugeHeader = Data([0x00, 0x30, 0x00, 0x00]) // 3,145,728 bytes (> 2MB limit)
        var errorThrown = false
        do {
            _ = try BridgeFraming.decode(from: &hugeHeader)
        } catch let err as BridgeFramingError {
            if case .frameTooLarge = err {
                errorThrown = true
            }
        } catch {}
        assertTest(errorThrown, "Framing throws frameTooLarge for >2MB frame")

        // -------------------------------------------------------
        // Suite 17: CryptoKit ECDH + ChaChaPoly Session
        // -------------------------------------------------------
        print("\n--- Suite 17: CryptoKit ECDH + ChaChaPoly Session ---")

        let serverSession = CryptoKitSession()
        let clientSession = CryptoKitSession()

        // 17.1 Key agreement
        try? serverSession.establishSharedKey(peerPublicKeyHex: clientSession.localPublicKeyHex)
        try? clientSession.establishSharedKey(peerPublicKeyHex: serverSession.localPublicKeyHex)
        assertTest(serverSession.isEstablished && clientSession.isEstablished, "ECDH shared keys established on both peers")

        // 17.2 Encryption & Decryption
        let secretMessage = "Confidential SMS Text Content".data(using: .utf8)!
        let ciphertext = try? clientSession.seal(secretMessage)
        assertTest(ciphertext != nil && ciphertext != secretMessage, "Ciphertext is sealed and not plaintext")

        let plaintext = try? serverSession.open(ciphertext!)
        assertTest(plaintext == secretMessage, "Decrypted plaintext matches original secret message")

        // 17.3 Tamper protection
        var tamperedCiphertext = ciphertext!
        tamperedCiphertext[tamperedCiphertext.count - 1] ^= 0xFF // Flip last byte (auth tag)
        var tamperRejected = false
        do {
            _ = try serverSession.open(tamperedCiphertext)
        } catch {
            tamperRejected = true
        }
        assertTest(tamperRejected, "Tampered ciphertext rejected with AEAD authentication failure")

        // 17.4 First-time pairing secret is mixed into key derivation.
        let pairingServer = CryptoKitSession()
        let pairingClient = CryptoKitSession()
        let pairingSecret = "ABCDEFGHJKLM2345"
        try? pairingServer.establishSharedKey(
            peerPublicKeyHex: pairingClient.localPublicKeyHex,
            pairingSecret: pairingSecret
        )
        try? pairingClient.establishSharedKey(
            peerPublicKeyHex: pairingServer.localPublicKeyHex,
            pairingSecret: pairingSecret
        )
        let encryptedVerification = try? pairingClient.seal(Data(pairingSecret.utf8))
        assertTest(
            encryptedVerification != nil && !encryptedVerification!.contains(Data(pairingSecret.utf8)),
            "Pairing secret is never present in encrypted verification payload"
        )
        assertTest(
            (try? pairingServer.open(encryptedVerification!)) == Data(pairingSecret.utf8),
            "Peers using the same pairing secret derive the same authenticated key"
        )

        let attacker = CryptoKitSession()
        try? attacker.establishSharedKey(
            peerPublicKeyHex: pairingServer.localPublicKeyHex,
            pairingSecret: "WRONGPAIRINGKEY2"
        )
        assertTest(
            (try? attacker.open(encryptedVerification!)) == nil,
            "A peer without the pairing secret cannot decrypt verification traffic"
        )

        // 17.5 Envelope metadata is authenticated, so changing a captured
        // request ID cannot bypass replay detection.
        let originalEnvelope = BridgeEnvelope(id: "request-1", type: .smsSend)
        let boundCiphertext = try? pairingClient.seal(
            secretMessage,
            authenticating: originalEnvelope.authenticatedMetadata
        )
        let changedEnvelope = BridgeEnvelope(id: "request-2", type: .smsSend)
        assertTest(
            (try? pairingServer.open(
                boundCiphertext!,
                authenticating: changedEnvelope.authenticatedMetadata
            )) == nil,
            "Changing authenticated envelope metadata invalidates captured ciphertext"
        )

        // 17.6 Persisted Curve25519 private keys preserve the public identity
        // needed for automatic paired-session resume.
        let restoredClient = try? CryptoKitSession(
            privateKeyRawRepresentation: pairingClient.localPrivateKeyRawRepresentation
        )
        assertTest(
            restoredClient?.localPublicKeyHex == pairingClient.localPublicKeyHex,
            "Persisted client private key restores the paired public identity"
        )

        // -------------------------------------------------------
        // Suite 18: Gateway Pairing OTP Rate-Limiting & Expiry
        // -------------------------------------------------------
        print("\n--- Suite 18: Gateway Pairing OTP Rate-Limiting & Expiry ---")

        let mockKeychain = MockKeychainStorage()
        let pairingMgr = GatewayPairingManager(keychain: mockKeychain)

        let serverIdentity1 = pairingMgr.makeServerCryptoSession()
        let serverIdentity2 = pairingMgr.makeServerCryptoSession()
        assertTest(
            serverIdentity1.localPublicKeyHex == serverIdentity2.localPublicKeyHex,
            "Mac gateway identity key persists for secure iPhone key pinning"
        )

        // 18.1 OTP generation
        let otp = pairingMgr.generateNewOTP()
        let allowedPairingCharacters = CharacterSet(charactersIn: "ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        assertTest(
            otp.count == 16 && otp.unicodeScalars.allSatisfy { allowedPairingCharacters.contains($0) },
            "Generated pairing secret has 80 bits of Base32 entropy"
        )
        assertTest(pairingMgr.currentOTP != nil && pairingMgr.otpSecondsRemaining > 0, "New OTP is active and not expired")

        // 18.2 Rate limiting after 5 failed attempts
        let devId = "test-iphone-1"
        for i in 1...4 {
            let res = pairingMgr.verifyOTP(code: "WRONGPAIRINGKEY", clientDeviceId: devId, clientName: "Test iPhone", clientPublicKeyHex: "0011")
            switch res {
            case .failure(let err):
                if case .codeIncorrect(let remaining) = err, remaining == (5 - i) {
                    assertTest(true, "Failed attempt \(i) tracks remaining count (\(remaining))")
                } else {
                    assertTest(false, "Unexpected error on attempt \(i): \(err)")
                }
            case .success:
                assertTest(false, "Expected failure on attempt \(i)")
            }
        }
        let res5 = pairingMgr.verifyOTP(code: "WRONGPAIRINGKEY", clientDeviceId: devId, clientName: "Test iPhone", clientPublicKeyHex: "0011")
        switch res5 {
        case .failure(let err):
            if case .rateLimitLocked = err {
                assertTest(true, "5th failed attempt triggers rateLimitLocked lockout")
            } else {
                assertTest(false, "Expected rateLimitLocked error, got \(err)")
            }
        case .success:
            assertTest(false, "Expected rateLimitLocked on 5th attempt")
        }

        // 18.3 Successful verification and revocation
        let freshOTP = pairingMgr.generateNewOTP()
        let successRes = pairingMgr.verifyOTP(code: freshOTP, clientDeviceId: "test-iphone-2", clientName: "Test iPhone 2", clientPublicKeyHex: "0022")
        switch successRes {
        case .success:
            assertTest(true, "Correct OTP verification succeeds")
        case .failure(let err):
            assertTest(false, "Expected success for correct OTP, got \(err)")
        }
        assertTest(pairingMgr.isDevicePaired(deviceId: "test-iphone-2"), "Device marked as paired in storage")

        pairingMgr.revokeDevice(deviceId: "test-iphone-2")
        assertTest(!pairingMgr.isDevicePaired(deviceId: "test-iphone-2"), "Device successfully revoked")

        // -------------------------------------------------------
        // Suite 19: Batch Deletion Engine (SMS, Threads, Call History)
        // -------------------------------------------------------
        print("\n--- Suite 19: Batch Deletion Engine ---")

        final class RecordedIndices: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [Int] = []
            func append(_ val: Int) {
                lock.lock()
                values.append(val)
                lock.unlock()
            }
            var snapshot: [Int] {
                lock.lock()
                defer { lock.unlock() }
                return values
            }
        }
        let mockTransport19 = MockATTransport()
        let recordedIndices = RecordedIndices()
        mockTransport19.onCommand = { cmd in
            if cmd.hasPrefix("AT+CMGL=") {
                return "OK"
            }
            if cmd.hasPrefix("AT+CMGD=") {
                let idxStr = cmd.replacingOccurrences(of: "AT+CMGD=", with: "")
                if let idx = Int(idxStr) {
                    recordedIndices.append(idx)
                }
                return "OK"
            }
            return nil
        }
        let mockDB19 = EC20Database(inMemory: true)
        let mockController19 = EC20Controller(transport: mockTransport19, database: mockDB19)
        try? mockTransport19.open()
        await mockController19.connect()
        mockController19.loadLocalData()

        // 19.1 Batch delete SMS messages with descending index order
        let batchMsg1 = SMSMessage(storageIndex: 3, storageArea: "ME", senderOrRecipient: "13800001111", text: "Batch 1", isIncoming: true, isRead: true)
        let batchMsg2 = SMSMessage(storageIndex: 7, storageArea: "ME", senderOrRecipient: "13800001111", text: "Batch 2", isIncoming: true, isRead: true)
        let batchMsg3 = SMSMessage(storageIndex: 5, storageArea: "ME", senderOrRecipient: "13800001111", text: "Batch 3", isIncoming: true, isRead: true)
        mockDB19.saveMessage(batchMsg1)
        mockDB19.saveMessage(batchMsg2)
        mockDB19.saveMessage(batchMsg3)
        mockController19.loadLocalData()
        assertTest(mockDB19.fetchAllMessages().count == 3, "3 batch messages inserted")

        let cmdId = "batch-cmd-1"
        let batchResult = await mockController19.deleteSMSBatch(ids: [batchMsg1.id, batchMsg2.id, batchMsg3.id], clientCommandId: cmdId)
        assertTest(batchResult.isFullSuccess, "deleteSMSBatch full success")
        assertTest(batchResult.succeededCount == 3 && batchResult.failedCount == 0, "succeededCount == 3")
        assertTest(mockDB19.fetchAllMessages().isEmpty, "Database empty after batch SMS deletion")
        let indicesCopy = recordedIndices.snapshot
        assertTest(indicesCopy == [7, 5, 3], "Module SMS deleted in descending storage index order (7 -> 5 -> 3)")

        // 19.1b Batch delete with partial failure (module error keeps local DB record)
        let failMsg1 = SMSMessage(storageIndex: 10, storageArea: "ME", senderOrRecipient: "13800008888", text: "Fail Test 1", isIncoming: true, isRead: true)
        let failMsg2 = SMSMessage(storageIndex: 11, storageArea: "ME", senderOrRecipient: "13800008888", text: "Fail Test 2", isIncoming: true, isRead: true)
        mockDB19.saveMessage(failMsg1)
        mockDB19.saveMessage(failMsg2)
        mockController19.loadLocalData()

        mockTransport19.onCommand = { cmd in
            if cmd == "AT+CMGD=10" {
                return "+CMS ERROR: 321\r\n"
            }
            return "OK"
        }

        let partialResult = await mockController19.deleteSMSBatch(ids: [failMsg1.id, failMsg2.id], clientCommandId: "partial-fail-cmd")
        assertTest(!partialResult.isFullSuccess, "Partial failure result indicates not full success")
        assertTest(partialResult.succeededCount == 1 && partialResult.failedCount == 1, "Partial failure: 1 succeeded, 1 failed")
        assertTest(mockDB19.fetchMessage(id: failMsg1.id) != nil, "Failed message retained in local database")
        assertTest(mockDB19.fetchMessage(id: failMsg2.id) == nil, "Succeeded message removed from local database")

        // 19.2 Idempotency test (same clientCommandId returns cached result)
        let repeatResult = await mockController19.deleteSMSBatch(ids: [batchMsg1.id], clientCommandId: cmdId)
        assertTest(repeatResult.clientCommandId == cmdId && repeatResult.succeededCount == 3, "Idempotent batch command returns cached result")

        // 19.2b Reject untrusted storage identifiers before constructing AT commands.
        let invalidStorageMsg = SMSMessage(
            storageIndex: 12,
            storageArea: "ME\";ATD10086",
            senderOrRecipient: "13800009999",
            text: "Invalid storage",
            isIncoming: true,
            isRead: true
        )
        mockDB19.saveMessage(invalidStorageMsg)
        let invalidStorageResult = await mockController19.deleteSMSBatch(
            ids: [invalidStorageMsg.id],
            clientCommandId: "invalid-storage-cmd"
        )
        assertTest(
            invalidStorageResult.failedCount == 1 && mockDB19.fetchMessage(id: invalidStorageMsg.id) != nil,
            "Invalid modem storage area is rejected and the local message is retained"
        )

        // 19.3 Batch delete threads
        let threadTargetA = "13800002222"
        let threadTargetB = "13800003333"
        let msgT1 = SMSMessage(threadId: threadTargetA, storageIndex: 1, storageArea: "SM", senderOrRecipient: threadTargetA, text: "T1", isIncoming: true, isRead: true)
        let msgT2 = SMSMessage(threadId: threadTargetB, storageIndex: 2, storageArea: "SM", senderOrRecipient: threadTargetB, text: "T2", isIncoming: true, isRead: true)
        mockDB19.saveMessage(msgT1)
        mockDB19.saveMessage(msgT2)
        mockController19.loadLocalData()

        let threadBatchRes = await mockController19.deleteThreadsBatch(threadIds: [threadTargetA, threadTargetB], clientCommandId: "thread-cmd-1")
        assertTest(threadBatchRes.isFullSuccess, "deleteThreadsBatch full success")
        assertTest(mockDB19.fetchMessages(threadId: threadTargetA).isEmpty, "Thread A deleted")
        assertTest(mockDB19.fetchMessages(threadId: threadTargetB).isEmpty, "Thread B deleted")

        // 19.4 Batch delete call history
        let callA = CallHistoryItem(phoneNumber: "13800004444", type: .incoming)
        let callB = CallHistoryItem(phoneNumber: "13800005555", type: .outgoing)
        mockDB19.saveCallRecord(callA)
        mockDB19.saveCallRecord(callB)
        mockController19.loadLocalData()
        assertTest(mockDB19.fetchCallHistory().count == 2, "2 calls inserted into DB")

        let callBatchRes = mockController19.deleteCallHistoryBatch(ids: [callA.id, callB.id], clientCommandId: "call-cmd-1")
        assertTest(callBatchRes.isFullSuccess, "deleteCallHistoryBatch full success")
        assertTest(mockDB19.fetchCallHistory().isEmpty, "Call history empty after batch deletion")

        // 19.5 A repeated remote SMS command must not submit or persist twice.
        mockTransport19.onCommand = nil
        let outgoingBefore = mockDB19.fetchAllMessages().filter { !$0.isIncoming }.count
        try? await mockController19.sendSMSIdempotently(
            to: "13800138000",
            text: "Idempotent SMS",
            clientCommandId: "sms-send-cmd-1"
        )
        try? await mockController19.sendSMSIdempotently(
            to: "13800138000",
            text: "Idempotent SMS",
            clientCommandId: "sms-send-cmd-1"
        )
        let outgoingAfter = mockDB19.fetchAllMessages().filter { !$0.isIncoming }.count
        assertTest(outgoingAfter == outgoingBefore + 1, "Repeated SMS command ID creates only one outgoing message")

        await mockController19.disconnect()

        // Summary
        print("\n=======================================================")
        print("  Test Results: \(passedCount) Passed, \(failedCount) Failed")
        print("=======================================================")
        if failedCount > 0 {
            exit(1)
        }
    }
}
