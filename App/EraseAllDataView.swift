// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// Settings → Suggestions & Privacy → Erase All Data (privacy audit P-M2). Explains
/// what goes, offers "Also delete from my other devices" (off by default), then asks
/// for a destructive confirmation and Face ID / passcode before
/// `AppStores.eraseAllData`. Afterwards the app is in its first-launch state.
/// Only reachable with no session open (`AppStores.openSessions`).
struct EraseAllDataView: View {
    @State private var alsoFromOtherDevices = false
    @State private var confirming = false
    @State private var result: EraseResult?

    private enum EraseResult: Identifiable {
        case done
        case incomplete([EraseStep])
        var id: String {
            switch self {
            case .done: return "done"
            case let .incomplete(steps): return steps.map(\.rawValue).joined()
            }
        }
    }

    var body: some View {
        List {
            Section {
                Text("Erases your hosts, connection defaults, saved sessions, learned suggestions, imported fonts and every setting on this device. The app goes back to how it was when first installed.")
            }

            Section {
                Toggle("Also delete from my other devices", isOn: $alsoFromOtherDevices)
            } footer: {
                Text(alsoFromOtherDevices
                     ? "Passwords, SSH keys and trusted host keys are also deleted from iCloud Keychain, which removes them from your other devices."
                     : "Passwords, SSH keys and trusted host keys saved in iCloud Keychain are left there, because deleting them here would delete them on your other devices too.")
            }

            Section {
                Button(role: .destructive) {
                    InputClickFeedback.play()
                    confirming = true
                } label: {
                    Label("Erase All Data…", systemImage: "trash")
                }
            }
        }
        .navigationTitle("Erase All Data")
        .confirmationDialog("Erase all data?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Erase", role: .destructive) {
                InputClickFeedback.play()
                Task { await erase() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(alsoFromOtherDevices
                 ? "This can't be undone. Your passwords and keys will also be deleted from your other devices."
                 : "This can't be undone.")
        }
        .alert(item: $result) { result in
            switch result {
            case .done:
                return Alert(title: Text("All data erased"), dismissButton: .default(Text("OK")))
            case let .incomplete(steps):
                return Alert(title: Text("Some data couldn't be erased"),
                             message: Text("Not removed: \(steps.map(Self.describe).joined(separator: ", ")). Try again, or delete and reinstall the app."),
                             dismissButton: .default(Text("OK")))
            }
        }
    }

    /// Face ID / passcode, then erase. No passcode on the device means nothing to verify
    /// against, as for the other owner checks; a cancel or failure erases nothing.
    private func erase() async {
        do {
            try await KeyAccessAuthorizer.shared.verifyOwner(identityName: "all app data",
                                                             reason: "Erase all Semicolyn data")
        } catch KeyAccessError.unavailable {
            // No passcode set: proceed.
        } catch {
            DebugLog.shared.log(.lifecycle, "erase-all: owner check refused (\(error))")
            return
        }
        do {
            try AppStores.shared.eraseAllData(alsoFromOtherDevices: alsoFromOtherDevices)
            DebugLog.shared.log(.lifecycle, "erase-all: done otherDevices=\(alsoFromOtherDevices)")
            result = .done
        } catch let incomplete as EraseIncomplete {
            DebugLog.shared.log(.lifecycle, "erase-all: incomplete steps=\(incomplete.failedSteps.map(\.rawValue))")
            result = .incomplete(incomplete.failedSteps)
        } catch {
            result = .incomplete([.files])
        }
        alsoFromOtherDevices = false
    }

    private static func describe(_ step: EraseStep) -> String {
        switch step {
        case .files: return "some files"
        case .deviceSecrets: return "saved session keys"
        case .syncedSecrets: return "iCloud Keychain items"
        case .settings: return "settings"
        }
    }
}
