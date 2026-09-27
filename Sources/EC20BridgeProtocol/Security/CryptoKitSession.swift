import Foundation
import CryptoKit

public enum CryptoSessionError: Error, LocalizedError, Equatable {
    case invalidPublicKeyHex
    case keyAgreementFailed(String)
    case decryptionFailed(String)
    case sessionNotEstablished

    public var errorDescription: String? {
        switch self {
        case .invalidPublicKeyHex:
            return "对端公钥 Hex 格式无效"
        case .keyAgreementFailed(let msg):
            return "ECDH 密钥协商失败: \(msg)"
        case .decryptionFailed(let msg):
            return "ChaChaPoly 解密/鉴权失败 (可能数据被篡改): \(msg)"
        case .sessionNotEstablished:
            return "安全加密通道尚未建立"
        }
    }
}

public final class CryptoKitSession: @unchecked Sendable {
    public let localPrivateKey: Curve25519.KeyAgreement.PrivateKey
    public var localPublicKeyHex: String {
        localPrivateKey.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
    }
    public var localPrivateKeyRawRepresentation: Data {
        localPrivateKey.rawRepresentation
    }

    private var symmetricKey: SymmetricKey? = nil
    private let lock = NSLock()

    private static let hkdfSharedInfo = Data("EC20Companion_Bridge_v1".utf8)
    private static let hkdfSalt = Data("EC20_Curve25519_Salt_2026".utf8)

    public init() {
        self.localPrivateKey = Curve25519.KeyAgreement.PrivateKey()
    }

    public init(privateKey: Curve25519.KeyAgreement.PrivateKey) {
        self.localPrivateKey = privateKey
    }

    public convenience init(privateKeyRawRepresentation: Data) throws {
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: privateKeyRawRepresentation
        )
        self.init(privateKey: privateKey)
    }

    /// Establishes the shared ChaCha20-Poly1305 key.
    ///
    /// During first-time pairing, `pairingSecret` must contain the high-entropy
    /// secret shown by the Mac. Mixing it into HKDF prevents an active LAN peer
    /// from replacing both ephemeral public keys and proxying the pairing flow.
    public func establishSharedKey(peerPublicKeyHex: String, pairingSecret: String? = nil) throws {
        guard let peerPubData = Data(hexString: peerPublicKeyHex), peerPubData.count == 32 else {
            throw CryptoSessionError.invalidPublicKeyHex
        }

        let peerPublicKey: Curve25519.KeyAgreement.PublicKey
        do {
            peerPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPubData)
        } catch {
            throw CryptoSessionError.keyAgreementFailed(error.localizedDescription)
        }

        do {
            let sharedSecret = try localPrivateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
            let localPublicKey = localPrivateKey.publicKey.rawRepresentation
            var transcript = Self.hkdfSharedInfo
            if localPublicKey.lexicographicallyPrecedes(peerPubData) {
                transcript.append(localPublicKey)
                transcript.append(peerPubData)
            } else {
                transcript.append(peerPubData)
                transcript.append(localPublicKey)
            }

            var saltMaterial = Self.hkdfSalt
            if let pairingSecret {
                saltMaterial.append(Data(pairingSecret.uppercased().utf8))
            }
            let salt = Data(SHA256.hash(data: saltMaterial))

            let key = sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: salt,
                sharedInfo: transcript,
                outputByteCount: 32
            )
            lock.lock()
            self.symmetricKey = key
            lock.unlock()
        } catch {
            throw CryptoSessionError.keyAgreementFailed(error.localizedDescription)
        }
    }

    /// Encrypts plaintext bytes using ChaCha20-Poly1305 AEAD
    public func seal(_ plaintext: Data, authenticating authenticatedData: Data = Data()) throws -> Data {
        lock.lock()
        guard let key = self.symmetricKey else {
            lock.unlock()
            throw CryptoSessionError.sessionNotEstablished
        }
        lock.unlock()

        do {
            let sealedBox = try ChaChaPoly.seal(
                plaintext,
                using: key,
                authenticating: authenticatedData
            )
            // combined returns Nonce (12B) + Ciphertext + Tag (16B)
            return sealedBox.combined
        } catch {
            throw CryptoSessionError.decryptionFailed(error.localizedDescription)
        }
    }

    /// Decrypts and authenticates ciphertext bytes using ChaCha20-Poly1305 AEAD.
    /// Fails safely if tag mismatch or tampered payload.
    public func open(_ combinedCiphertext: Data, authenticating authenticatedData: Data = Data()) throws -> Data {
        lock.lock()
        guard let key = self.symmetricKey else {
            lock.unlock()
            throw CryptoSessionError.sessionNotEstablished
        }
        lock.unlock()

        do {
            let sealedBox = try ChaChaPoly.SealedBox(combined: combinedCiphertext)
            let decrypted = try ChaChaPoly.open(
                sealedBox,
                using: key,
                authenticating: authenticatedData
            )
            return decrypted
        } catch {
            throw CryptoSessionError.decryptionFailed("数据已被篡改或密钥不匹配")
        }
    }

    public var isEstablished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return symmetricKey != nil
    }
}

// MARK: - Data Hex Extension

extension Data {
    public init?(hexString: String) {
        let clean = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count % 2 == 0 else { return nil }
        var data = Data(capacity: clean.count / 2)
        var index = clean.startIndex
        while index < clean.endIndex {
            let nextIndex = clean.index(index, offsetBy: 2)
            let byteStr = clean[index..<nextIndex]
            guard let byte = UInt8(byteStr, radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }

    public var hexString: String {
        return map { String(format: "%02x", $0) }.joined()
    }
}
