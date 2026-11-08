// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// One part of Erase All Data, named when it fails.
public enum EraseStep: String, Sendable, Equatable {
    /// The app's files: records, learned words, imported fonts.
    case files
    /// Keychain items kept only on this device (resume secrets).
    case deviceSecrets
    /// iCloud Keychain items (passwords, keys, trusted host keys).
    case syncedSecrets
    /// Every app setting in `UserDefaults`.
    case settings
}

/// Erase All Data ran every step but some failed; the app should say what's left.
public struct EraseIncomplete: Error, Equatable {
    public let failedSteps: [EraseStep]
}

/// Erases the app's data on this device (privacy audit P-M2), returning it to the state
/// of a first launch:
///
/// - deletes each of `directories` (records, learned words, imported fonts),
/// - deletes every device-only Keychain item,
/// - when `alsoFromOtherDevices`, deletes the iCloud Keychain items too, which removes
///   them from the user's other devices as well. Otherwise they are left alone, since
///   deleting one here would delete it everywhere. The record key is always kept: other
///   devices' records are sealed with the same synced key, and deleting it would make
///   them unreadable rather than erased,
/// - removes every setting in `defaultsDomain`.
///
/// Every step is attempted even when an earlier one fails, so one stubborn item can't
/// leave the rest in place. Throws `EraseIncomplete` naming the steps that failed.
public func eraseAllAppData(directories: [URL],
                            deviceSecrets: BulkErasableSecretStore,
                            syncedSecrets: BulkErasableSecretStore,
                            alsoFromOtherDevices: Bool,
                            defaults: UserDefaults,
                            defaultsDomain: String) throws {
    var failed: [EraseStep] = []
    let fm = FileManager.default
    for dir in directories where fm.fileExists(atPath: dir.path) {
        do {
            try fm.removeItem(at: dir)
        } catch {
            if !failed.contains(.files) { failed.append(.files) }
        }
    }
    do {
        try deviceSecrets.deleteAllSecrets(except: [])
    } catch {
        failed.append(.deviceSecrets)
    }
    if alsoFromOtherDevices {
        do {
            try syncedSecrets.deleteAllSecrets(except: [.recordKey])
        } catch {
            failed.append(.syncedSecrets)
        }
    }
    defaults.removePersistentDomain(forName: defaultsDomain)
    if defaults.persistentDomain(forName: defaultsDomain).map({ !$0.isEmpty }) ?? false {
        failed.append(.settings)
    }
    if !failed.isEmpty { throw EraseIncomplete(failedSteps: failed) }
}
