import Foundation
import Security

public protocol KeychainStorageProtocol: Sendable {
    func save(key: String, data: Data) throws
    func read(key: String) throws -> Data?
    func delete(key: String) throws
    func clearAll() throws
}

/// In-memory Keychain abstraction for testing and offline environments
public final class MockKeychainStorage: KeychainStorageProtocol, @unchecked Sendable {
    private var store: [String: Data] = [:]
    private let lock = NSLock()

    public init() {}

    public func save(key: String, data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        store[key] = data
    }

    public func read(key: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return store[key]
    }

    public func delete(key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        store.removeValue(forKey: key)
    }

    public func clearAll() throws {
        lock.lock()
        defer { lock.unlock() }
        store.removeAll()
    }
}

/// Production system Keychain implementation
public final class SystemKeychainStorage: KeychainStorageProtocol, @unchecked Sendable {
    private let serviceName: String

    public init(serviceName: String = "com.quectel.ec20companion.bridge") {
        self.serviceName = serviceName
    }

    public func save(key: String, data: Data) throws {
        _ = try? delete(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: "SystemKeychainStorage", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Keychain 存储失败: \(status)"
            ])
        }
    }

    public func read(key: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw NSError(domain: "SystemKeychainStorage", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Keychain 读取失败: \(status)"
            ])
        }
        return data
    }

    public func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw NSError(domain: "SystemKeychainStorage", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Keychain 删除失败: \(status)"
            ])
        }
    }

    public func clearAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw NSError(domain: "SystemKeychainStorage", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Keychain 清空失败: \(status)"
            ])
        }
    }
}
