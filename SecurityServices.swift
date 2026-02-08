import Foundation
import CryptoKit
import Security

final class KeychainStore {
    static let shared = KeychainStore()

    private let service = "com.offgrid.chatline"

    func data(for key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return data
    }

    func set(_ data: Data, for key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        } else {
            var addQuery = query
            addQuery.merge(attributes) { $1 }
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }
}

/// Wraps Core Data / file writes with a symmetric key so recovered data remains unreadable off-device.
struct SecureDiskStore {
    private let keyIdentifier: String
    private let fileURL: URL
    private let keychain: KeychainStore
    private let symmetricKey: SymmetricKey

    init(filename: String, keyIdentifier: String, keychain: KeychainStore = .shared) {
        self.keyIdentifier = keyIdentifier
        self.keychain = keychain
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = directory.appendingPathComponent("SecureData", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        self.fileURL = folder.appendingPathComponent(filename)
        self.symmetricKey = SecureDiskStore.loadOrCreateKey(identifier: keyIdentifier, keychain: keychain)
    }

    func load() -> Data? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            let sealedBox = try ChaChaPoly.SealedBox(combined: data)
            return try ChaChaPoly.open(sealedBox, using: symmetricKey)
        } catch {
            print("Secure load error: \(error)")
            return nil
        }
    }

    func save(_ data: Data) {
        do {
            let sealed = try ChaChaPoly.seal(data, using: symmetricKey)
            let options: Data.WritingOptions = [.atomic, .completeFileProtection]
            try sealed.combined.write(to: fileURL, options: options)
        } catch {
            print("Secure save error: \(error)")
        }
    }

    private static func loadOrCreateKey(identifier: String, keychain: KeychainStore) -> SymmetricKey {
        if let stored = keychain.data(for: identifier) {
            return SymmetricKey(data: stored)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        keychain.set(data, for: identifier)
        return key
    }
}

final class SecureSessionManager {
    private let localIdentity: LocalIdentity
    private var cached: [UUID: SymmetricKey] = [:]

    init(localIdentity: LocalIdentity) {
        self.localIdentity = localIdentity
    }

    func key(for remote: PeerIdentity) throws -> SymmetricKey {
        if let cached = cached[remote.uuid] {
            return cached
        }
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: localIdentity.privateKey)
        let remotePublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remote.publicKey)
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: remotePublicKey)

        var salt = Data(localIdentity.uuid.uuidString.utf8)
        salt.append(contentsOf: remote.uuid.uuidString.utf8)
        let symmetric = sharedSecret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data("session".utf8), outputByteCount: 32)
        cached[remote.uuid] = symmetric
        return symmetric
    }
}
