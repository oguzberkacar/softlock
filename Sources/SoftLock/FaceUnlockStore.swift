//
//  FaceUnlockStore.swift
//
//  Encrypted persistence for the enrolled face embeddings.
//
//  Only 512-float embeddings are stored, never images. They are sealed with AES-GCM under a
//  random 256-bit key that lives in the login Keychain (this-device-only), so the file in
//  Application Support is useless on its own. Embeddings are not reversible into a photo, but
//  they are still biometric data, hence the encryption.
//

import CryptoKit
import Foundation
import Security
import SoftLockCore

struct FaceSampleRecord: Codable, Equatable, Sendable {
    let embedding: [Float]
    /// Which guided-capture step produced this sample.
    let pose: String
}

struct FaceProfile: Codable, Equatable, Sendable {
    var modelIdentifier: String
    var createdAt: Date
    var samples: [FaceSampleRecord]

    var template: FaceTemplate? {
        FaceTemplate(samples: samples.map(\.embedding))
    }
}

enum FaceUnlockStoreError: LocalizedError {
    case keychain(OSStatus)
    case corrupt
    case randomFailed

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "Keychain error: \(text)"
        case .corrupt:
            return "The stored face data could not be read."
        case .randomFailed:
            return "Could not generate an encryption key."
        }
    }
}

nonisolated enum FaceUnlockStore {
    private static let service = "\(FaceUnlockPaths.appIdentifier).face-unlock"
    private static let account = "embedding-key-v1"
    private static let aad = Data("softlock.face-unlock.v1".utf8)

    private static var fileURL: URL {
        FaceUnlockPaths.applicationSupportDirectory.appendingPathComponent("face-profile.enc")
    }

    static var hasProfile: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// nil when nothing is enrolled. Throws when data exists but cannot be decrypted (for
    /// example the Keychain key was removed), which callers treat as "not enrolled".
    static func load() throws -> FaceProfile? {
        guard let sealed = try? Data(contentsOf: fileURL) else { return nil }
        guard let key = try existingKey() else { throw FaceUnlockStoreError.corrupt }
        do {
            let box = try AES.GCM.SealedBox(combined: sealed)
            let plain = try AES.GCM.open(box, using: key, authenticating: aad)
            return try JSONDecoder().decode(FaceProfile.self, from: plain)
        } catch {
            throw FaceUnlockStoreError.corrupt
        }
    }

    static func save(_ profile: FaceProfile) throws {
        let key = try existingKey() ?? createKey()
        let plain = try JSONEncoder().encode(profile)
        let box = try AES.GCM.seal(plain, using: key, authenticating: aad)
        guard let combined = box.combined else { throw FaceUnlockStoreError.corrupt }
        try FileManager.default.createDirectory(at: FaceUnlockPaths.applicationSupportDirectory, withIntermediateDirectories: true)
        try combined.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /// Removes the encrypted file and the Keychain key.
    static func eraseAll() {
        try? FileManager.default.removeItem(at: fileURL)
        SecItemDelete(baseQuery() as CFDictionary)
    }

    // MARK: - Keychain

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func existingKey() throws -> SymmetricKey? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count == 32 else {
            throw FaceUnlockStoreError.keychain(status)
        }
        return SymmetricKey(data: data)
    }

    private static func createKey() throws -> SymmetricKey {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw FaceUnlockStoreError.randomFailed
        }
        var attributes = baseQuery()
        attributes[kSecValueData as String] = Data(bytes)
        // Readable without a prompt while the Mac is up (the lock screen needs it), never synced or migrated.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw FaceUnlockStoreError.keychain(status) }
        return SymmetricKey(data: Data(bytes))
    }
}
