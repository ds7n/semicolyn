// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

// MARK: - Pure account mapping (Linux-safe, no Security import)

/// Returns the Keychain `kSecAttrAccount` string for `ref`.
///
/// The mapping is injective: distinct `SecretRef` values always produce distinct
/// account strings, so no two refs ever collide onto the same Keychain item.
/// Stable strings, do not change without a migration.
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
    case .resumeSecret(let sessionID):
        return "resumeSecret/\(sessionID.uuidString)"
    }
}

/// When a Keychain item can be read.
public enum SecretAccessibility: Equatable, Sendable {
    /// Only while the device is unlocked (`kSecAttrAccessibleWhenUnlocked`). Still syncs.
    case whenUnlocked
    /// Any time after the first unlock since boot (`kSecAttrAccessibleAfterFirstUnlock`).
    case afterFirstUnlock
}

/// The accessibility for the Keychain item stored under `account` (a `keychainAccount`
/// string).
///
/// Credentials (private keys, passwords, passphrases) are only readable while the device
/// is unlocked (security audit M4). The record key, known hosts and resume secrets stay
/// `afterFirstUnlock`: the record key is read at app launch, which iOS can do before the
/// user unlocks (prewarming), and none of the three signs anyone in. Unknown accounts get
/// the stricter class.
public func secretAccessibility(forAccount account: String) -> SecretAccessibility {
    if account == keychainAccount(for: .recordKey) { return .afterFirstUnlock }
    if account.hasPrefix("hostKeys/") || account.hasPrefix("resumeSecret/") { return .afterFirstUnlock }
    return .whenUnlocked
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
/// All items are stored as `kSecClassGenericPassword` under the given `service`, with the
/// accessibility `secretAccessibility(forAccount:)` picks per item. When `synchronizable`
/// is `true` (the default) items ride iCloud Keychain (E2EE).
public final class KeychainSecretStore: BulkErasableSecretStore {
    private let service: String
    private let synchronizable: Bool

    /// Creates a store.
    /// - Parameters:
    ///   - service: The `kSecAttrService` value shared by all items in this store.
    ///   - synchronizable: When `true`, items are synced via iCloud Keychain.
    public init(
        service: String = "com.truepositive.semicolyn.secrets",
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
            let update: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: accessibleValue(for: ref)]
            let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(updateStatus)
            }
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = accessibleValue(for: ref)
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

    /// Result of `migrateAccessibility`: items re-classed, and items that could not be
    /// (each with its status), which the next launch retries.
    public struct AccessibilityMigration: Equatable, Sendable {
        public var changed = 0
        public var failed: [OSStatus] = []
    }

    /// Moves every item in this store to the accessibility `secretAccessibility(forAccount:)`
    /// picks. Items written before security audit M4 were all `AfterFirstUnlock`.
    /// Idempotent; call at launch. A failing item is skipped (and reported) so it can't
    /// block the others. Only the listing query failing throws.
    public func migrateAccessibility() throws -> AccessibilityMigration {
        var query = serviceQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        var outcome = AccessibilityMigration()
        if status == errSecItemNotFound { return outcome }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw KeychainError.unexpectedStatus(status)
        }
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String else { continue }
            let want = Self.accessibleValue(secretAccessibility(forAccount: account))
            if let have = item[kSecAttrAccessible as String] as? String, have == want as String { continue }
            var match = serviceQuery()
            match[kSecAttrAccount as String] = account
            let update: [String: Any] = [kSecAttrAccessible as String: want]
            let updateStatus = SecItemUpdate(match as CFDictionary, update as CFDictionary)
            if updateStatus == errSecSuccess {
                outcome.changed += 1
            } else {
                outcome.failed.append(updateStatus)
            }
        }
        return outcome
    }

    /// Deletes every item in this store (this service and sync domain) except the
    /// accounts of `kept`. Deleting a synchronizable item also deletes it from the user's
    /// other devices through iCloud Keychain. Every item is attempted; the first failure
    /// is thrown afterwards.
    public func deleteAllSecrets(except kept: Set<SecretRef>) throws {
        var query = serviceQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw KeychainError.unexpectedStatus(status)
        }
        let keptAccounts = Set(kept.map(keychainAccount(for:)))
        var firstFailure: OSStatus?
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  !keptAccounts.contains(account) else { continue }
            var match = serviceQuery()
            match[kSecAttrAccount as String] = account
            let deleteStatus = SecItemDelete(match as CFDictionary)
            if deleteStatus != errSecSuccess, deleteStatus != errSecItemNotFound, firstFailure == nil {
                firstFailure = deleteStatus
            }
        }
        if let firstFailure { throw KeychainError.unexpectedStatus(firstFailure) }
    }

    // MARK: - Private helpers

    /// Matches every item of this store (any account, any accessibility).
    private func serviceQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!,
        ]
    }

    /// Builds the base query dictionary shared by all Keychain operations for `ref`.
    /// Accessibility is deliberately NOT part of the match, so an item written under an
    /// older class is still found (and re-classed on its next write).
    private func baseQuery(for ref: SecretRef) -> [String: Any] {
        var query = serviceQuery()
        query[kSecAttrAccount as String] = keychainAccount(for: ref)
        return query
    }

    private func accessibleValue(for ref: SecretRef) -> CFString {
        Self.accessibleValue(secretAccessibility(forAccount: keychainAccount(for: ref)))
    }

    private static func accessibleValue(_ accessibility: SecretAccessibility) -> CFString {
        switch accessibility {
        case .whenUnlocked: return kSecAttrAccessibleWhenUnlocked
        case .afterFirstUnlock: return kSecAttrAccessibleAfterFirstUnlock
        }
    }
}
#endif
