import Foundation
import Security

public enum KeychainDeviceCredentialStoreError: Error, Equatable, Sendable {
    case unexpectedStatus(OSStatus)
    case corruptedItem
}

/// Keychain-backed `DeviceCredentialStore`. No credential storage existed
/// anywhere in the app before this — this is a new, single Keychain item
/// (`kSecClassGenericPassword`) holding the enrolled device id, bearer token,
/// and expiry as a JSON blob.
public final class KeychainDeviceCredentialStore: DeviceCredentialStore, Sendable {
    private let service: String
    private let account: String

    public init(
        service: String = "com.vincentlaroche.framebase.cloud-dev",
        account: String = "device-credential"
    ) {
        self.service = service
        self.account = account
    }

    public func currentCredential() async throws -> StoredDeviceCredential? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainDeviceCredentialStoreError.unexpectedStatus(status)
        }
        do {
            return try JSONDecoder().decode(StoredDeviceCredential.self, from: data)
        } catch {
            throw KeychainDeviceCredentialStoreError.corruptedItem
        }
    }

    public func store(_ credential: StoredDeviceCredential) async throws {
        let data = try JSONEncoder().encode(credential)
        try await clear()

        var attributes = baseQuery()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainDeviceCredentialStoreError.unexpectedStatus(status)
        }
    }

    public func clear() async throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainDeviceCredentialStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
