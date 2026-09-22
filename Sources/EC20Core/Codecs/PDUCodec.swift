import Foundation

/// 3GPP TS 23.040 and TS 23.038 PDU encoder and decoder for SMS.
public enum PDUCodec {
    
    public struct MultipartInfo: Hashable, Equatable, Sendable {
        public let referenceNumber: UInt16
        public let totalParts: Int
        public let currentPart: Int
        
        public init(referenceNumber: UInt16, totalParts: Int, currentPart: Int) {
            self.referenceNumber = referenceNumber
            self.totalParts = totalParts
            self.currentPart = currentPart
        }
    }
    
    public struct DecodedSMS: Equatable, Sendable {
        public let sender: String
        public let timestamp: Date?
        public let text: String
        public let multipartInfo: MultipartInfo?
        public let rawPDU: String
        
        public init(sender: String, timestamp: Date?, text: String, multipartInfo: MultipartInfo?, rawPDU: String) {
            self.sender = sender
            self.timestamp = timestamp
            self.text = text
            self.multipartInfo = multipartInfo
            self.rawPDU = rawPDU
        }
    }
    
    public struct OutgoingPDU: Equatable, Sendable {
        /// PDU length in octets excluding SMSC bytes (value passed to AT+CMGS=<length>)
        public let tpduLength: Int
        /// Full hexadecimal PDU string ending with \x1A
        public let pduHex: String
        
        public init(tpduLength: Int, pduHex: String) {
            self.tpduLength = tpduLength
            self.pduHex = pduHex
        }
    }
    
    // MARK: - Address Encoding & Decoding
    
    /// Decodes semi-octet swapped address
    public static func decodeAddress(bytes: [UInt8], startIndex: Int, digitCount: Int, addressType: UInt8) -> (String, Int) {
        let isInternational = (addressType & 0x70) == 0x10 // 0x91 international
        var number = isInternational ? "+" : ""
        let octetCount = (digitCount + 1) / 2
        
        var digitsParsed = 0
        for i in 0..<octetCount {
            let byteIndex = startIndex + i
            guard byteIndex < bytes.count else { break }
            let b = bytes[byteIndex]
            let low = b & 0x0F
            let high = (b >> 4) & 0x0F
            
            if low <= 9 && digitsParsed < digitCount {
                number.append(String(low))
                digitsParsed += 1
            }
            if high <= 9 && digitsParsed < digitCount {
                number.append(String(high))
                digitsParsed += 1
            }
        }
        
        return (number, octetCount)
    }
    
    /// Encodes destination address into semi-octets
    public static func encodeAddress(_ number: String) -> [UInt8] {
        var cleanNumber = number.trimmingCharacters(in: .whitespacesAndNewlines)
        var addressType: UInt8 = 0x81 // National / unknown
        if cleanNumber.hasPrefix("+") {
            addressType = 0x91 // International
            cleanNumber.removeFirst()
        }
        
        let digits = cleanNumber.filter { $0.isNumber }
        let digitCount = UInt8(digits.count)
        
        var octets: [UInt8] = [digitCount, addressType]
        let chars = Array(digits)
        var i = 0
        while i < chars.count {
            let low = chars[i].wholeNumberValue ?? 0
            let high = (i + 1 < chars.count) ? (chars[i + 1].wholeNumberValue ?? 0) : 0x0F
            let byte = UInt8(low | (high << 4))
            octets.append(byte)
            i += 2
        }
        
        return octets
    }
    
    // MARK: - Timestamp Decoding
    
    public static func decodeTimestamp(bytes: [UInt8], startIndex: Int) -> Date? {
        guard startIndex + 7 <= bytes.count else { return nil }
        func swapNibbles(_ b: UInt8) -> Int {
            let low = Int(b & 0x0F)
            let high = Int((b >> 4) & 0x0F)
            return low * 10 + high
        }
        let year = swapNibbles(bytes[startIndex]) + 2000
        let month = swapNibbles(bytes[startIndex + 1])
        let day = swapNibbles(bytes[startIndex + 2])
        let hour = swapNibbles(bytes[startIndex + 3])
        let minute = swapNibbles(bytes[startIndex + 4])
        let second = swapNibbles(bytes[startIndex + 5])
        
        var dateComponents = DateComponents()
        dateComponents.year = year
        dateComponents.month = month
        dateComponents.day = day
        dateComponents.hour = hour
        dateComponents.minute = minute
        dateComponents.second = second
        dateComponents.timeZone = TimeZone(secondsFromGMT: 8 * 3600) // Default GMT+8
        
        return Calendar(identifier: .gregorian).date(from: dateComponents)
    }
    
    // MARK: - PDU Parser (SMS-DELIVER)
    
    public static func decodeDeliverPDU(_ hexString: String) -> DecodedSMS? {
        guard let bytes = hexToBytes(hexString) else { return nil }
        guard !bytes.isEmpty else { return nil }
        
        var index = 0
        
        // 1. SCA (Service Center Address) length in octets
        let scaLength = Int(bytes[index])
        index += 1
        index += scaLength // skip SMSC info
        
        guard index < bytes.count else { return nil }
        
        // 2. First octet of SMS-DELIVER
        let firstOctet = bytes[index]
        index += 1
        
        let hasUDH = (firstOctet & 0x40) != 0 // TP-UDHI bit 6
        
        // 3. Originating Address (OA)
        guard index < bytes.count else { return nil }
        let oaDigitCount = Int(bytes[index])
        index += 1
        guard index < bytes.count else { return nil }
        let oaType = bytes[index]
        index += 1
        
        let (senderNumber, oaOctetLen) = decodeAddress(bytes: bytes, startIndex: index, digitCount: oaDigitCount, addressType: oaType)
        index += oaOctetLen
        
        // 4. TP-PID
        guard index < bytes.count else { return nil }
        _ = bytes[index]
        index += 1
        
        // 5. TP-DCS (Data Coding Scheme)
        guard index < bytes.count else { return nil }
        let dcs = bytes[index]
        index += 1
        
        // 6. TP-SCTS (Timestamp, 7 octets)
        let timestamp = decodeTimestamp(bytes: bytes, startIndex: index)
        index += 7
        
        // 7. TP-UDL (User Data Length)
        guard index < bytes.count else { return nil }
        let udl = Int(bytes[index])
        index += 1
        
        guard index <= bytes.count else { return nil }
        let userDataBytes = Array(bytes[index...])
        
        // Parse UDH if present
        var multipart: MultipartInfo? = nil
        var bodyBytes = userDataBytes
        var udhLength = 0
        
        if hasUDH && !userDataBytes.isEmpty {
            udhLength = Int(userDataBytes[0])
            guard userDataBytes.count >= udhLength + 1 else { return nil }
            if userDataBytes.count >= udhLength + 1 {
                // Parse UDH Information Elements
                var udhIdx = 1
                while udhIdx + 1 < 1 + udhLength {
                    let iei = userDataBytes[udhIdx]
                    let ieLen = Int(userDataBytes[udhIdx + 1])
                    guard udhIdx + 2 + ieLen <= 1 + udhLength else { break }
                    if iei == 0x00 && ieLen == 3 && udhIdx + 4 < userDataBytes.count {
                        // 8-bit reference concat SMS
                        let ref = UInt16(userDataBytes[udhIdx + 2])
                        let total = Int(userDataBytes[udhIdx + 3])
                        let part = Int(userDataBytes[udhIdx + 4])
                        multipart = MultipartInfo(referenceNumber: ref, totalParts: total, currentPart: part)
                    } else if iei == 0x08 && ieLen == 4 && udhIdx + 5 < userDataBytes.count {
                        // 16-bit reference concat SMS
                        let ref = (UInt16(userDataBytes[udhIdx + 2]) << 8) | UInt16(userDataBytes[udhIdx + 3])
                        let total = Int(userDataBytes[udhIdx + 4])
                        let part = Int(userDataBytes[udhIdx + 5])
                        multipart = MultipartInfo(referenceNumber: ref, totalParts: total, currentPart: part)
                    }
                    udhIdx += 2 + ieLen
                }
                bodyBytes = Array(userDataBytes[(udhLength + 1)...])
            }
        }
        
        // Decode message text according to DCS
        var text = ""
        let isUCS2 = (dcs & 0x0C) == 0x08 // DCS bits 3..2 == 10 => UCS2
        let is8Bit = (dcs & 0x0C) == 0x04
        
        if isUCS2 {
            // UCS2: bodyBytes is pairs of UTF-16BE bytes
            var utf16Units: [UInt16] = []
            var i = 0
            while i + 1 < bodyBytes.count {
                let u = (UInt16(bodyBytes[i]) << 8) | UInt16(bodyBytes[i + 1])
                utf16Units.append(u)
                i += 2
            }
            text = String(utf16CodeUnits: utf16Units, count: utf16Units.count)
        } else if is8Bit {
            text = String(bytes: bodyBytes, encoding: .utf8) ?? String(bytes: bodyBytes, encoding: .ascii) ?? ""
        } else {
            // GSM 7-bit unpacked
            text = unpack7BitGSM(bytes: userDataBytes, udl: udl, hasUDH: hasUDH, udhLength: udhLength)
        }
        
        return DecodedSMS(
            sender: senderNumber,
            timestamp: timestamp,
            text: text,
            multipartInfo: multipart,
            rawPDU: hexString
        )
    }
    
    // MARK: - 7-bit GSM Unpacking
    
    public static func unpack7BitGSM(bytes: [UInt8], udl: Int, hasUDH: Bool, udhLength: Int) -> String {
        var septets: [UInt8] = []
        
        if hasUDH {
            // UDH takes (udhLength + 1) * 8 bits. We need to skip this and any fill bits to reach septet boundary.
            let udhBits = (udhLength + 1) * 8
            let fillBits = (7 - (udhBits % 7)) % 7
            let totalSkipBits = udhBits + fillBits
            let septetsInUDH = totalSkipBits / 7
            
            // Unpack all septets from bytes
            let allSeptets = unpackAllSeptets(from: bytes, count: udl)
            if allSeptets.count > septetsInUDH {
                septets = Array(allSeptets[septetsInUDH..<min(allSeptets.count, udl)])
            }
        } else {
            septets = unpackAllSeptets(from: bytes, count: udl)
        }
        
        // Map 7-bit GSM to Swift String
        var result = ""
        for s in septets {
            let charCode = Int(s & 0x7F)
            if let scalar = UnicodeScalar(charCode) {
                result.append(Character(scalar))
            }
        }
        return result
    }
    
    private static func unpackAllSeptets(from bytes: [UInt8], count: Int) -> [UInt8] {
        var septets: [UInt8] = []
        var shift = 0
        var carry: UInt8 = 0
        
        for byte in bytes {
            let septet = ((byte << shift) | carry) & 0x7F
            septets.append(septet)
            if septets.count >= count { break }
            
            carry = byte >> (7 - shift)
            shift += 1
            if shift == 7 {
                septets.append(carry & 0x7F)
                shift = 0
                carry = 0
                if septets.count >= count { break }
            }
        }
        return septets
    }
    
    // MARK: - PDU Encoder (SMS-SUBMIT)
    
    /// Encodes an SMS message into one or more SMS-SUBMIT PDUs (supporting long/multipart SMS)
    public static func encodeSubmitPDUs(destination: String, text: String, referenceNumber: UInt16 = 0x42) -> [OutgoingPDU] {
        let isUCS2 = UCS2Codec.requiresUCS2(text)
        let maxSingleChars = isUCS2 ? 70 : 160
        let maxMultipartChars = isUCS2 ? 67 : 153
        
        let destAddressBytes = encodeAddress(destination)
        
        if text.count <= maxSingleChars {
            // Single PDU
            let pdu = buildSingleSubmitPDU(destAddressBytes: destAddressBytes, text: text, isUCS2: isUCS2)
            return [pdu]
        } else {
            // Multipart PDU
            return buildMultipartSubmitPDUs(
                destAddressBytes: destAddressBytes,
                text: text,
                isUCS2: isUCS2,
                maxCharsPerPart: maxMultipartChars,
                referenceNumber: referenceNumber
            )
        }
    }
    
    private static func buildSingleSubmitPDU(destAddressBytes: [UInt8], text: String, isUCS2: Bool) -> OutgoingPDU {
        var tpdu: [UInt8] = []
        
        // 1. First octet: TP-MTI = 01 (SMS-SUBMIT), TP-VPF = 10 (Validity Period present, relative)
        tpdu.append(0x11)
        
        // 2. TP-MR (Message Reference) = 00
        tpdu.append(0x00)
        
        // 3. TP-DA (Destination Address)
        tpdu.append(contentsOf: destAddressBytes)
        
        // 4. TP-PID (Protocol Identifier) = 00
        tpdu.append(0x00)
        
        // 5. TP-DCS (Data Coding Scheme): 0x08 for UCS2, 0x00 for GSM 7-bit
        let dcs: UInt8 = isUCS2 ? 0x08 : 0x00
        tpdu.append(dcs)
        
        // 6. TP-VP (Validity Period): 0xAA (approx 4 days)
        tpdu.append(0xAA)
        
        // 7. TP-UDL & TP-UD
        if isUCS2 {
            var ucs2Bytes: [UInt8] = []
            for unit in text.utf16 {
                ucs2Bytes.append(UInt8(unit >> 8))
                ucs2Bytes.append(UInt8(unit & 0xFF))
            }
            tpdu.append(UInt8(ucs2Bytes.count)) // UDL in octets for UCS2
            tpdu.append(contentsOf: ucs2Bytes)
        } else {
            let (packedBytes, septetCount) = pack7Bit(text)
            tpdu.append(UInt8(septetCount)) // UDL in septets for GSM 7-bit
            tpdu.append(contentsOf: packedBytes)
        }
        
        let tpduLength = tpdu.count
        let fullPDUHex = "00" + bytesToHex(tpdu) // 00 = SMSC length 0 (use default from SIM)
        return OutgoingPDU(tpduLength: tpduLength, pduHex: fullPDUHex)
    }
    
    private static func buildMultipartSubmitPDUs(
        destAddressBytes: [UInt8],
        text: String,
        isUCS2: Bool,
        maxCharsPerPart: Int,
        referenceNumber: UInt16
    ) -> [OutgoingPDU] {
        let chars = Array(text)
        let totalParts = (chars.count + maxCharsPerPart - 1) / maxCharsPerPart
        var pdus: [OutgoingPDU] = []
        
        for partIndex in 0..<totalParts {
            let start = partIndex * maxCharsPerPart
            let end = min(start + maxCharsPerPart, chars.count)
            let partText = String(chars[start..<end])
            
            var tpdu: [UInt8] = []
            // First octet: TP-MTI = 01 (SMS-SUBMIT), TP-UDHI = 0x40 (has UDH), TP-VPF = 0x10
            tpdu.append(0x51)
            tpdu.append(0x00) // TP-MR
            tpdu.append(contentsOf: destAddressBytes)
            tpdu.append(0x00) // TP-PID
            tpdu.append(isUCS2 ? 0x08 : 0x00) // TP-DCS
            tpdu.append(0xAA) // TP-VP
            
            // UDH for concatenated SMS (IEI 0x00: 8-bit ref or 0x08: 16-bit ref)
            let udh: [UInt8] = [
                0x05, // UDH Length: 5 bytes
                0x00, // IEI: Concatenated short message, 8-bit reference
                0x03, // IEDL: 3 bytes
                UInt8(referenceNumber & 0xFF),
                UInt8(totalParts),
                UInt8(partIndex + 1)
            ]
            
            if isUCS2 {
                var ucs2Bytes: [UInt8] = []
                for unit in partText.utf16 {
                    ucs2Bytes.append(UInt8(unit >> 8))
                    ucs2Bytes.append(UInt8(unit & 0xFF))
                }
                let totalUserDataOctets = udh.count + ucs2Bytes.count
                tpdu.append(UInt8(totalUserDataOctets))
                tpdu.append(contentsOf: udh)
                tpdu.append(contentsOf: ucs2Bytes)
            } else {
                // GSM 7-bit packing with UDH
                let udhBits = udh.count * 8
                let fillBits = (7 - (udhBits % 7)) % 7
                let totalSeptetsInUDH = (udhBits + fillBits) / 7
                let (packedBody, septetCount) = pack7BitWithPrecedingBits(partText, fillBits: fillBits)
                
                let totalUDL = totalSeptetsInUDH + septetCount
                tpdu.append(UInt8(totalUDL))
                tpdu.append(contentsOf: udh)
                tpdu.append(contentsOf: packedBody)
            }
            
            let tpduLength = tpdu.count
            let fullPDUHex = "00" + bytesToHex(tpdu)
            pdus.append(OutgoingPDU(tpduLength: tpduLength, pduHex: fullPDUHex))
        }
        
        return pdus
    }
    
    // MARK: - 7-bit GSM Packing
    
    public static func pack7Bit(_ text: String) -> ([UInt8], Int) {
        let septets: [UInt8] = text.unicodeScalars.map { UInt8($0.value & 0x7F) }
        var octets: [UInt8] = []
        var shift = 0
        var current: UInt8 = 0
        
        for septet in septets {
            if shift == 0 {
                current = septet
                shift = 1
            } else {
                current |= (septet << (8 - shift))
                octets.append(current)
                current = septet >> shift
                shift += 1
                if shift == 8 {
                    shift = 0
                }
            }
        }
        if shift != 0 {
            octets.append(current)
        }
        return (octets, septets.count)
    }
    
    private static func pack7BitWithPrecedingBits(_ text: String, fillBits: Int) -> ([UInt8], Int) {
        let septets: [UInt8] = text.unicodeScalars.map { UInt8($0.value & 0x7F) }
        var octets: [UInt8] = []
        var shift = fillBits
        var current: UInt8 = 0
        
        for septet in septets {
            current |= (septet << shift)
            if shift + 7 >= 8 {
                octets.append(current)
                current = septet >> (8 - shift)
                shift = (shift + 7) - 8
            } else {
                shift += 7
            }
        }
        if shift > 0 {
            octets.append(current)
        }
        return (octets, septets.count)
    }
    
    // MARK: - Hex Helpers
    
    public static func hexToBytes(_ hex: String) -> [UInt8]? {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var i = cleaned.startIndex
        while i < cleaned.endIndex {
            let next = cleaned.index(i, offsetBy: 2)
            guard let b = UInt8(cleaned[i..<next], radix: 16) else { return nil }
            bytes.append(b)
            i = next
        }
        return bytes
    }
    
    public static func bytesToHex(_ bytes: [UInt8]) -> String {
        return bytes.map { String(format: "%02X", $0) }.joined()
    }
}
