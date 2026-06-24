// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

// MARK: - Pure account mapping (Linux-safe, no Security import)

/// Returns the Keychain `kSecAttrAccount` string for `ref`.
///
/// The mapping is injective: distinct `SecretRef` values always produce distinct
/// account strings, so no two refs ever collide onto the same Keychain item.
/// Stable strings — do not change without a migration.
public func keychainAccount(for ref: SecretRef) -> String {
    switch ref {
    case .recordKey:
        return "recordKey"
    case .privateKey(let identityID):
        return "privateKey/\(identityID.uuidString)"
    case .password(let id):
        return "password/\(id.uuidString)"
    case .passphrase(let identityID):
        return "passphrase/\(identityID.uuidString)"
    case .hostKeys(let hostID):
        return "hostKeys/\(hostID.uuidString)"
    }
}

// MARK: - Keychain-backed store (Apple platforms only)

#if canImport(Security)
import Security

/// An error thrown by `KeychainSecretStore` when the Security framework returns
/// an unexpected status code.
public enum KeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
}

/// A `SecretStore` backed by the iOS/macOS Keychain with iCloud Keychain sync.
///
/// All items are stored as `kSecClassGenericPassword` under the given `service`
/// and are accessible after first device unlock (`kSecAttrAccessibleAfterFirstUnlock`).
/// When `synchronizable` is `true` (the default) items ride iCloud Keychain (E2EE).
public final class KeychainSecretStore: SecretStore {
    private let service: String
    private let synchronizable: Bool

    /// Creates a store.
    /// - Parameters:
    ///   - service: The `kSecAttrService` value shared by all items in this store.
    ///   - synchronizable: When `true`, items are synced via iCloud Keychain.
    public init(
        service: String = "com.truepositive.neotilde.secrets",
        synchronizable: Bool = true
    ) {
        self.service = service
        self.synchronizable = synchronizable
    }

    // MARK: - SecretStore

    public func setSecret(_ data: Data, for ref: SecretRef) throws {
        let query = baseQuery(for: ref)
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            let update: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(updateStatus)
            }
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func getSecret(_ ref: SecretRef) throws -> Data? {
        var query = baseQuery(for: ref)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainError.unexpectedStatus(errSecInternalError)
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func deleteSecret(_ ref: SecretRef) throws {
        let query = baseQuery(for: ref)
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return  // idempotent
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Private helpers

    /// Builds the base query dictionary shared by all Keychain operations for `ref`.
    private func baseQuery(for ref: SecretRef) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keychainAccount(for: ref),
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
    }
}
#endif
