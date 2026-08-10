import CryptoKit
import Foundation
import Security

public protocol DeviceKeySigning: Sendable {
    func publicKeyBase64URL() throws -> String
    func sign(_ payload: Data) throws -> Data
}

public enum DeviceKeyStoreError: Error, LocalizedError, Sendable {
    case keyCreationFailed
    case keyLookupFailed
    case keyExportFailed
    case signingFailed
    case invalidKeyEncoding

    public var errorDescription: String? {
        switch self {
        case .keyCreationFailed: "Unable to create the device signing key."
        case .keyLookupFailed: "Unable to find the device signing key."
        case .keyExportFailed: "Unable to export the public device key."
        case .signingFailed: "Unable to sign the enrollment challenge."
        case .invalidKeyEncoding: "The device key has an invalid encoding."
        }
    }
}

/// Keychain-backed P-256 signer. It prefers Secure Enclave and only falls
/// back to a device-only Keychain key when the enclave is unavailable (such as
/// an automated test machine). Private key material never enters app storage.
public final class SecureDeviceKeyStore: DeviceKeySigning, @unchecked Sendable {
    private let applicationTag: Data
    private let accessGroup: String?

    public init(applicationTag: String, accessGroup: String? = nil) {
        self.applicationTag = Data(applicationTag.utf8)
        self.accessGroup = accessGroup
    }

    public func publicKeyBase64URL() throws -> String {
        let privateKey = try loadOrCreatePrivateKey()
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let raw = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            throw DeviceKeyStoreError.keyExportFailed
        }
        let key: P256.Signing.PublicKey
        do { key = try P256.Signing.PublicKey(x963Representation: raw) }
        catch { throw DeviceKeyStoreError.invalidKeyEncoding }
        return key.derRepresentation.base64URLEncodedString()
    }

    public func sign(_ payload: Data) throws -> Data {
        let privateKey = try loadOrCreatePrivateKey()
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            payload as CFData,
            &error
        ) as Data? else {
            throw DeviceKeyStoreError.signingFailed
        }
        do { return try P256.Signing.ECDSASignature(derRepresentation: signature).rawRepresentation }
        catch { throw DeviceKeyStoreError.invalidKeyEncoding }
    }

    private func loadOrCreatePrivateKey() throws -> SecKey {
        if let key = findPrivateKey() { return key }
        if let enclaveKey = createPrivateKey(tokenID: kSecAttrTokenIDSecureEnclave) { return enclaveKey }
        if let softwareKey = createPrivateKey(tokenID: nil) { return softwareKey }
        throw DeviceKeyStoreError.keyCreationFailed
    }

    private func findPrivateKey() -> SecKey? {
        var query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrApplicationTag: applicationTag,
            kSecReturnRef: true
        ]
        if let accessGroup { query[kSecAttrAccessGroup] = accessGroup }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        guard let result else { return nil }
        return (result as! SecKey)
    }

    private func createPrivateKey(tokenID: CFString?) -> SecKey? {
        var privateAttributes: [CFString: Any] = [
            kSecAttrIsPermanent: true,
            kSecAttrApplicationTag: applicationTag,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        if let accessGroup { privateAttributes[kSecAttrAccessGroup] = accessGroup }
        var attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecPrivateKeyAttrs: privateAttributes
        ]
        if let tokenID { attributes[kSecAttrTokenID] = tokenID }
        return SecKeyCreateRandomKey(attributes as CFDictionary, nil)
    }
}

/// Persists only the short-lived API session in the Keychain. A library file,
/// UserDefaults, and source control never contain bearer tokens.
public actor KeychainDeviceSessionStore: DeviceSessionStore {
    private let service: String
    private let account: String
    private let accessGroup: String?

    public init(service: String, account: String, accessGroup: String? = nil) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    public func load() throws -> DeviceSession? {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        if let accessGroup { query[kSecAttrAccessGroup] = accessGroup }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw DeviceKeyStoreError.keyLookupFailed }
        return try JSONDecoder().decode(DeviceSession.self, from: data)
    }

    public func save(_ session: DeviceSession) throws {
        let data = try JSONEncoder().encode(session)
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        if let accessGroup { query[kSecAttrAccessGroup] = accessGroup }
        let updates: [CFString: Any] = [kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let updateStatus = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if updateStatus == errSecItemNotFound {
            query[kSecValueData] = data
            query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw DeviceKeyStoreError.keyCreationFailed }
        } else if updateStatus != errSecSuccess {
            throw DeviceKeyStoreError.keyCreationFailed
        }
    }

    public func clear() throws {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        if let accessGroup { query[kSecAttrAccessGroup] = accessGroup }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DeviceKeyStoreError.keyCreationFailed }
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
