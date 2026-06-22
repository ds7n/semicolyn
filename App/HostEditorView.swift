// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import GlymrKit

/// Single-scrollable host editor — handles both create and edit.
///
/// Sections always expanded for v1: Basics (label, hostName, user, port) and
/// Auth (identities pill row + password toggle). Sections 3–9 are deferred to
/// later tasks. Validation spine is wired to `HostFormValidation` via
/// `HostEditorViewModel`; soft-block issues render as non-blocking inline banners.
struct HostEditorView: View {
    @StateObject private var vm: HostEditorViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    /// Whether to show the discard-confirmation action sheet.
    @State private var showingDiscardConfirm = false
    /// Resolved defaults (loaded once on appear for hint labels).
    @State private var defaults: Defaults = Defaults()
    /// Tracks whether the user has changed anything since the form opened.
    private let originalHost: Host

    // MARK: - Init

    init(creating: Bool) {
        _vm = StateObject(wrappedValue: HostEditorViewModel(creating: creating))
        originalHost = Host(id: UUID(), label: "", hostName: "")
    }

    init(editing host: Host) {
        _vm = StateObject(wrappedValue: HostEditorViewModel(editing: host))
        originalHost = host
    }

    // MARK: - Computed

    private var hasChanges: Bool {
        vm.host != originalHost
            || vm.usePassword != (originalHost.passwordRef.value != nil)
    }

    private var title: String {
        vm.isNew ? "New host" : vm.host.label.isEmpty ? "Edit host" : vm.host.label
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                basicsSection
                authSection
                // TODO(Task 4): Connection section (collapsed)
                // TODO(Task 5): Jump chain section (collapsed)
                // TODO(Task 5): Port forwarding section (collapsed)
                // TODO(Task 6): Mosh section (collapsed)
                // TODO(Task 7): Tailscale section (collapsed)
                // TODO(Task 7): Glymr behavior section (collapsed)
                if !vm.isNew {
                    // TODO(Task 9): Delete host section (edit mode)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .onAppear {
                defaults = (try? AppStores.shared.hosts.defaults()) ?? Defaults()
                vm.revalidate()
            }
        }
        .confirmationDialog(
            "You have unsaved changes.",
            isPresented: $showingDiscardConfirm,
            titleVisibility: .visible
        ) {
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button("Cancel") {
                if hasChanges {
                    showingDiscardConfirm = true
                } else {
                    dismiss()
                }
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button("Save") {
                performSave()
            }
            .disabled(!vm.canSave)
            .fontWeight(vm.canSave ? .semibold : .regular)
            .foregroundStyle(
                vm.canSave
                    ? Color(theme.accent.primary)
                    : Color(theme.text.muted)
            )
        }
    }

    // MARK: - Basics section

    private var basicsSection: some View {
        Section("Basics") {
            // Label (required)
            LabeledContent {
                TextField("e.g. prod-web", text: $vm.host.label)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: vm.host.label) { _, _ in vm.revalidate() }
            } label: {
                HStack(spacing: 2) {
                    Text("Label")
                    Text("•")
                        .foregroundStyle(
                            vm.host.label.isEmpty
                                ? Color(theme.state.broken)
                                : Color(theme.accent.primary)
                        )
                        .font(.caption)
                }
            }

            // Hostname (required)
            LabeledContent {
                TextField("e.g. 192.168.1.1", text: $vm.host.hostName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .onChange(of: vm.host.hostName) { _, _ in vm.revalidate() }
            } label: {
                HStack(spacing: 2) {
                    Text("Hostname")
                    Text("•")
                        .foregroundStyle(
                            vm.host.hostName.isEmpty
                                ? Color(theme.state.broken)
                                : Color(theme.accent.primary)
                        )
                        .font(.caption)
                }
            }

            // User (optional — inheritable)
            LabeledContent {
                TextField(
                    userPlaceholder,
                    text: Binding(
                        get: { inheritedStringToText(vm.host.user) },
                        set: { vm.host.user = textToInheritedString($0) }
                    )
                )
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onChange(of: vm.host.user) { _, _ in vm.revalidate() }
            } label: {
                Text("User")
                    .foregroundStyle(Color(theme.text.primary))
            }

            // Port (optional — inheritable)
            LabeledContent {
                TextField(
                    portPlaceholder,
                    text: Binding(
                        get: { inheritedIntToText(vm.host.port) },
                        set: { vm.host.port = textToInheritedInt($0) }
                    )
                )
                .keyboardType(.numberPad)
                .onChange(of: vm.host.port) { _, _ in vm.revalidate() }
            } label: {
                Text("Port")
                    .foregroundStyle(Color(theme.text.primary))
            }

            // Inline validation banners for Basics fields
            if hasIssue(.missingLabel) {
                IssueBanner(message: "Label is required to save.", severity: .hardBlock)
            }
            if let dupIssue = duplicateLabelIssue,
               case .duplicateLabel(let existing) = dupIssue.kind {
                let labels = existing.map(\.label).joined(separator: ", ")
                IssueBanner(
                    message: "A host named '\(vm.host.label)' already exists (\(labels)). You can still save.",
                    severity: .softBlock
                )
            }
            if hasIssue(.missingHostName) {
                IssueBanner(message: "Hostname is required to save.", severity: .hardBlock)
            }
            if hasNoUserIssue {
                IssueBanner(
                    message: "No user set here or in Defaults. Connecting will require setting a user.",
                    severity: .softBlock
                )
            }
        }
    }

    // MARK: - Auth section

    private var authSection: some View {
        Section("Auth") {
            // Identities pill row
            if let identityRefs = vm.host.identities.value, !identityRefs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(identityRefs, id: \.self) { ref in
                            IdentityPill(identityRef: ref)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            // Identity add button
            Button {
                // TODO(Task 6): IdentityPickerSheet — open the inline identity picker
            } label: {
                Label(
                    vm.host.identities.value?.isEmpty ?? true
                        ? "Add identity"
                        : "Add another identity",
                    systemImage: "plus.circle"
                )
                .foregroundStyle(Color(theme.accent.primary))
            }

            // Use password toggle
            Toggle(isOn: $vm.usePassword) {
                Text("Use password instead")
                    .foregroundStyle(Color(theme.text.primary))
            }
            .onChange(of: vm.usePassword) { _, newValue in
                if !newValue {
                    vm.passwordText = ""
                    vm.host.passwordRef = .inherit
                }
                vm.revalidate()
            }

            // Password row — only visible when toggle is on
            if vm.usePassword {
                LabeledContent {
                    SecureField("Password", text: $vm.passwordText)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: vm.passwordText) { _, _ in vm.revalidate() }
                } label: {
                    Text("Password")
                        .foregroundStyle(Color(theme.text.primary))
                }

                if hasIssue(.stalePasswordRef) {
                    IssueBanner(
                        message: "Linked password missing. Re-enter the password or remove it.",
                        severity: .hardBlock
                    )
                }
            }

        }
    }

    // MARK: - Validation helpers

    private func hasIssue(_ kind: ValidationIssue.Kind) -> Bool {
        vm.issues.contains { $0.kind == kind }
    }

    private var hasNoUserIssue: Bool {
        vm.issues.contains { $0.kind == .noUserSet }
    }

    private var duplicateLabelIssue: ValidationIssue? {
        vm.issues.first {
            if case .duplicateLabel = $0.kind { return true }
            return false
        }
    }

    // MARK: - Placeholder hints

    private var userPlaceholder: String {
        if let defaultUser = defaults.user.value {
            return "Defaults · \(defaultUser)"
        }
        return "e.g. ubuntu"
    }

    private var portPlaceholder: String {
        let defaultPort = defaults.port.value ?? 22
        return "Defaults · \(defaultPort)"
    }

    // MARK: - Save action

    private func performSave() {
        do {
            _ = try vm.save()
            dismiss()
        } catch EditorSaveError.hardBlocksPresent {
            // Issues are already reflected in vm.issues; the view renders them.
            // The Save button is disabled when hard blocks exist, so this branch
            // should not be reached in practice; it guards against race conditions.
        } catch {
            // Unexpected storage error — surface via an issue banner is
            // outside scope for v1; the error is intentionally swallowed here.
            // TODO(Task N): surface unexpected save errors in a top-level banner.
        }
    }
}

// MARK: - Identity pill

/// A small rounded pill showing the identity's UUID (truncated). The display
/// name lookup is deferred to Task 6 when the identity store is wired.
private struct IdentityPill: View {
    let identityRef: IdentityRef
    @Environment(\.theme) private var theme

    var body: some View {
        Text(identityRef.uuidString.prefix(8).lowercased())
            .font(.caption.monospaced())
            .foregroundStyle(Color(theme.text.primary))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color(theme.surface.panelHigh))
            .clipShape(Capsule())
    }
}

// MARK: - Issue banner

/// A single-line inline banner for a validation issue. Hard blocks render in
/// error red; soft blocks render in warning amber.
private struct IssueBanner: View {
    let message: String
    let severity: ValidationSeverity
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: severity == .hardBlock ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(
                    severity == .hardBlock
                        ? Color(theme.state.broken)
                        : Color(theme.state.warning)
                )
            Text(message)
                .font(.caption)
                .foregroundStyle(Color(theme.text.secondary))
        }
        .padding(.vertical, 2)
    }
}
