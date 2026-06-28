// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SemicolynKit

/// Errors thrown by `HostEditorViewModel.save()` that the view surfaces inline.
enum EditorSaveError: Error {
    /// One or more hard-block issues prevent saving. The `issues` array contains
    /// every blocking issue and is already reflected in `HostEditorViewModel.issues`.
    case hardBlocksPresent([ValidationIssue])
}

/// Drives `HostEditorView`: owns the working draft `Host`, runs validation, and
/// persists on save.
///
/// Must be created and used on the main actor because it mutates `@Published`
/// properties that drive SwiftUI updates.
@MainActor
final class HostEditorViewModel: ObservableObject {
    /// The working draft. The view binds directly to fields on this host.
    @Published var host: Host
    /// Current validation issues. Recomputed by `revalidate()` each time a
    /// field changes and on every Save attempt.
    @Published var issues: [ValidationIssue] = []

    /// `true` when the editor is creating a new host; `false` when editing an
    /// existing one (controls the sheet title and Delete-row visibility).
    let isNew: Bool

    /// Working-copy password entered via the "Use password" toggle. Not stored
    /// on `host` until Save so the Keychain is only written on explicit commit.
    @Published var passwordText: String = ""
    /// Whether the "Use password instead" toggle is on. Toggling off clears
    /// `passwordText` and `host.passwordRef`.
    @Published var usePassword: Bool = false

    /// Non-nil after a successful save when the store detected duplicate labels.
    /// The view renders this as a soft warning before dismissing.
    @Published var saveWarning: String? = nil

    // MARK: - Init

    /// Opens the editor for a brand-new host.
    init(creating: Bool) {
        self.isNew = creating
        self.host = Host(id: UUID(), label: "", hostName: "")
    }

    /// Opens the editor for an existing host.
    init(editing host: Host) {
        self.isNew = false
        self.host = host
        // Restore toggle state from stored passwordRef.
        if host.passwordRef.value != nil {
            self.usePassword = true
        }
    }

    // MARK: - Validation

    /// Whether the Save button should be enabled. Requires no hard-block issues
    /// AND both required text fields non-empty.
    var canSave: Bool {
        SemicolynKit.canSave(issues)
            && !host.label.isEmpty
            && !host.hostName.isEmpty
    }

    /// Recomputes `issues` against the live store state. Call on every field
    /// change; the view uses `onChange` to drive this.
    func revalidate() {
        let others = (try? AppStores.shared.hosts.allHosts())?.filter { $0.id != host.id } ?? []
        let defaults = (try? AppStores.shared.hosts.defaults()) ?? Defaults()
        let pwRefResolves = passwordRefResolves()
        issues = validateHostForm(
            host,
            others: others,
            defaults: defaults,
            passwordRefResolves: pwRefResolves
        )
    }

    // MARK: - Save

    /// Persists the host. Throws `EditorSaveError.hardBlocksPresent` if any
    /// hard-block issues remain after a final revalidation pass.
    ///
    /// On success:
    /// - If a password was entered, writes it to the secret store and assigns
    ///   `host.passwordRef`.
    /// - Calls `HostStore.saveHost(_:)` and returns the `SaveOutcome`
    ///   (caller surfaces `duplicateLabels` as a soft warning if needed).
    ///
    /// - Returns: `SaveOutcome` from `HostStore.saveHost`.
    @discardableResult
    func save() throws -> SaveOutcome {
        // Persist a password if one was entered via the toggle.
        if usePassword && !passwordText.isEmpty {
            let ref: UUID = host.id  // use the host id as the stable password ref key
            try AppStores.shared.secrets.setSecret(
                Data(passwordText.utf8),
                for: .password(id: ref)
            )
            host.passwordRef = .explicit(ref)
        } else if !usePassword {
            // Toggle is off: clear any existing password ref.
            host.passwordRef = .inherit
        }

        // Final validation pass with the committed password state.
        revalidate()

        let hardBlocks = issues.filter { $0.severity == .hardBlock }
        guard hardBlocks.isEmpty else {
            throw EditorSaveError.hardBlocksPresent(hardBlocks)
        }

        let outcome = try AppStores.shared.hosts.saveHost(host)

        // Surface duplicate-label warning to the view if present.
        if !outcome.duplicateLabels.isEmpty {
            let dupeLabels = outcome.duplicateLabels.map(\.label).joined(separator: ", ")
            saveWarning = "Saved. Another host already uses the label '\(host.label)': \(dupeLabels)."
        }

        return outcome
    }

    // MARK: - Helpers

    /// Returns `true` iff the host's `passwordRef` can be resolved.
    ///
    /// Resolves to `true` when:
    /// - There is no password ref (nothing to check).
    /// - The user has entered a new password in-editor (will be written on save).
    /// - The existing Keychain secret is still present.
    private func passwordRefResolves() -> Bool {
        guard let ref = host.passwordRef.value else { return true }
        // If the user has the toggle on with new text, they're about to set it.
        if usePassword && !passwordText.isEmpty { return true }
        return (try? AppStores.shared.secrets.getSecret(.password(id: ref))) != nil
    }
}
