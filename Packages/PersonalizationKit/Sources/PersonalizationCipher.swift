import CryptoKit
import Foundation
import Security

enum PersonalizationEncryptionError: Error {
    case invalidCiphertext
    case keychain(OSStatus)
}

struct PersonalizationCipher: Sendable {
    private let key: SymmetricKey

    init(keyData: Data) {
        key = SymmetricKey(data: keyData)
    }

    func seal(_ plaintext: String) throws -> String {
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key)
        guard let combined = sealed.combined else {
            throw PersonalizationEncryptionError.invalidCiphertext
        }
        return "v1:" + combined.base64EncodedString()
    }

    func open(_ ciphertext: String) throws -> String {
        guard ciphertext.hasPrefix("v1:"),
            let combined = Data(base64Encoded: String(ciphertext.dropFirst(3)))
        else {
            throw PersonalizationEncryptionError.invalidCiphertext
        }
        let box = try AES.GCM.SealedBox(combined: combined)
        return String(decoding: try AES.GCM.open(box, using: key), as: UTF8.self)
    }
}

enum PersonalizationKeychain {
    private static let service = "com.voxol.VoxoL.personalization"
    private static let account = "database-key-v1"

    static func loadOrCreateKey() throws -> Data {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            return data
        }
        guard status == errSecItemNotFound else {
            throw PersonalizationEncryptionError.keychain(status)
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw PersonalizationEncryptionError.keychain(errSecAllocate)
        }
        let key = Data(bytes)
        var add = baseQuery
        add[kSecValueData as String] = key
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return key
        }
        if addStatus == errSecDuplicateItem {
            return try loadOrCreateKey()
        }
        throw PersonalizationEncryptionError.keychain(addStatus)
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
