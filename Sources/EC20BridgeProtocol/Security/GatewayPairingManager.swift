import Foundation

public enum PairingError: Error, LocalizedError, Equatable {
    case codeExpired
    case codeIncorrect(remainingAttempts: Int)
    case rateLimitLocked(secondsRemaining: Int)
    case deviceRevoked
    case internalStorageError(String)

    public var errorDescription: String? {
        switch self {
        case .codeExpired:
            return "配对码已过期，请在 Mac 端重新生成"
        case .codeIncorrect(let remaining):
            return "配对码错误，还剩 \(remaining) 次尝试机会"
        case .rateLimitLocked(let seconds):
            return "尝试次数过多，已临时锁定配对，请在 \(seconds) 秒后重试"
        case .deviceRevoked:
            return "该设备配对已被撤销"
        case .internalStorageError(let msg):
            return "配对凭证存储失败: \(msg)"
        }
    }
}

public struct PairedDevice: Codable, Sendable, Identifiable, Equatable {
    public var id: String { deviceId }
    public let deviceId: String
    public let deviceName: String
    public let publicKeyHex: String
    public let pairedAt: Double

    public init(deviceId: String, deviceName: String, publicKeyHex: String, pairedAt: Double = Date().timeIntervalSince1970) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.publicKeyHex = publicKeyHex
        self.pairedAt = pairedAt
    }
}

public final class GatewayPairingManager: @unchecked Sendable {
    private let keychain: KeychainStorageProtocol
    private let lock = NSLock()

    private var activeOTP: String? = nil
    private var otpExpiresAt: Date? = nil
    private var failedAttempts: Int = 0
    private var lockedUntil: Date? = nil

    private static let maxAttempts = 5
    private static let lockDurationSeconds: TimeInterval = 60
    private static let otpValidityDuration: TimeInterval = 300 // 5 minutes

    public init(keychain: KeychainStorageProtocol = SystemKeychainStorage()) {
        self.keychain = keychain
    }

    /// Generates an 80-bit, human-readable one-time pairing secret.
    /// Ambiguous characters (0/O and 1/I) are intentionally omitted.
    @discardableResult
    public func generateNewOTP() -> String {
        lock.lock()
        defer { lock.unlock() }

        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let code = String((0..<16).map { _ in alphabet.randomElement()! })
        self.activeOTP = code
        self.otpExpiresAt = Date().addingTimeInterval(Self.otpValidityDuration)
        self.failedAttempts = 0
        self.lockedUntil = nil
        return code
    }

    /// Gets currently active OTP if still valid
    public var currentOTP: String? {
        lock.lock()
        defer { lock.unlock() }

        guard let code = activeOTP, let exp = otpExpiresAt, Date() < exp else {
            return nil
        }
        return code
    }

    /// Gets seconds remaining until current OTP expires
    public var otpSecondsRemaining: Int {
        lock.lock()
        defer { lock.unlock() }

        guard let exp = otpExpiresAt else { return 0 }
        let remaining = Int(exp.timeIntervalSince(Date()))
        return max(0, remaining)
    }

    /// Verifies client pairing attempt
    public func verifyOTP(
        code: String,
        clientDeviceId: String,
        clientName: String,
        clientPublicKeyHex: String
    ) -> Result<Void, PairingError> {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()

        // Check rate limit lock
        if let lockExp = lockedUntil, now < lockExp {
            let seconds = Int(lockExp.timeIntervalSince(now))
            return .failure(.rateLimitLocked(secondsRemaining: max(1, seconds)))
        }

        // Check expiration
        guard let current = activeOTP, let exp = otpExpiresAt, now < exp else {
            return .failure(.codeExpired)
        }

        let cleanInput = Self.normalizeSecret(code)
        if cleanInput == current {
            // Success: clear OTP, register device
            self.activeOTP = nil
            self.otpExpiresAt = nil
            self.failedAttempts = 0
            self.lockedUntil = nil

            let device = PairedDevice(
                deviceId: clientDeviceId,
                deviceName: clientName,
                publicKeyHex: clientPublicKeyHex,
                pairedAt: now.timeIntervalSince1970
            )

            do {
                try savePairedDeviceUnsafe(device)
                return .success(())
            } catch {
                return .failure(.internalStorageError(error.localizedDescription))
            }
        } else {
            return .failure(registerFailedAttemptUnsafe(now: now))
        }
    }

    /// Records an authentication failure that happened before a pairing
    /// payload could be decrypted (normally a wrong pairing secret).
    public func registerFailedAttempt() -> PairingError {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        if let lockExp = lockedUntil, now < lockExp {
            return .rateLimitLocked(secondsRemaining: max(1, Int(lockExp.timeIntervalSince(now))))
        }
        return registerFailedAttemptUnsafe(now: now)
    }

    private func registerFailedAttemptUnsafe(now: Date) -> PairingError {
        failedAttempts += 1
        if failedAttempts >= Self.maxAttempts {
            self.lockedUntil = now.addingTimeInterval(Self.lockDurationSeconds)
            self.activeOTP = nil
            self.otpExpiresAt = nil
            return .rateLimitLocked(secondsRemaining: Int(Self.lockDurationSeconds))
        }
        return .codeIncorrect(remainingAttempts: Self.maxAttempts - failedAttempts)
    }

    public static func normalizeSecret(_ value: String) -> String {
        value.uppercased().filter { !$0.isWhitespace && $0 != "-" }
    }

    public func isDevicePaired(deviceId: String) -> Bool {
        return getDevice(deviceId: deviceId) != nil
    }

    /// Returns a session object backed by the Mac gateway's persistent
    /// Curve25519 identity key. A new wrapper is returned for each connection,
    /// while the private identity remains protected by Keychain storage.
    public func makeServerCryptoSession() -> CryptoKitSession {
        lock.lock()
        defer { lock.unlock() }

        let keyName = "gateway_server_identity_private_key"
        if let stored = try? keychain.read(key: keyName),
           let session = try? CryptoKitSession(privateKeyRawRepresentation: stored) {
            return session
        }

        let session = CryptoKitSession()
        try? keychain.save(key: keyName, data: session.localPrivateKeyRawRepresentation)
        return session
    }

    public func getDevice(deviceId: String) -> PairedDevice? {
        let devices = listPairedDevices()
        return devices.first(where: { $0.deviceId == deviceId })
    }

    public func listPairedDevices() -> [PairedDevice] {
        lock.lock()
        defer { lock.unlock() }

        guard let data = try? keychain.read(key: "paired_devices_list"),
              let list = try? JSONDecoder().decode([PairedDevice].self, from: data) else {
            return []
        }
        return list
    }

    public func revokeDevice(deviceId: String) {
        lock.lock()
        defer { lock.unlock() }

        var list = (try? keychain.read(key: "paired_devices_list")).flatMap {
            try? JSONDecoder().decode([PairedDevice].self, from: $0)
        } ?? []

        list.removeAll(where: { $0.deviceId == deviceId })
        if let encoded = try? JSONEncoder().encode(list) {
            try? keychain.save(key: "paired_devices_list", data: encoded)
        }
    }

    private func savePairedDeviceUnsafe(_ device: PairedDevice) throws {
        var list = (try? keychain.read(key: "paired_devices_list")).flatMap {
            try? JSONDecoder().decode([PairedDevice].self, from: $0)
        } ?? []

        list.removeAll(where: { $0.deviceId == device.deviceId })
        list.append(device)

        let encoded = try JSONEncoder().encode(list)
        try keychain.save(key: "paired_devices_list", data: encoded)
    }
}
