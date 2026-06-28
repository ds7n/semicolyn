// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// Single-scrollable host editor — handles both create and edit.
///
/// Sections always expanded for v1: Basics (label, hostName, user, port) and
/// Auth (identities pill row + password toggle). Sections 3–9 are deferred to
/// later tasks. Validation spine is wired to `HostFormValidation` via
/// `HostEditorViewModel`; soft-block issues render as non-blocking inline banners.
struct HostEditorView: View {
    // `vm`/`theme` are accessed from the section extensions in
    // HostEditorView+Sections (a separate file), so they must be at least
    // `internal` — Swift `private` is file-scoped and would not compile there.
    @StateObject var vm: HostEditorViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) var theme

    /// Whether to show the discard-confirmation action sheet.
    @State private var showingDiscardConfirm = false
    /// Resolved defaults (loaded once on appear for hint labels).
    /// `internal` (not `private`): read by the section extensions in a separate file.
    @State var defaults: Defaults = Defaults()
    /// Tracks whether the user has changed anything since the form opened.
    private let originalHost: Host

    // Fix 2 — subtitle tracking state
    /// True after the first successful save in this editing session.
    @State private var savedOnce = false

    // Fix 4 — touched tracking (gate required-field banners)
    /// True once the user has interacted with the Label field.
    @State private var labelTouched = false
    /// True once the user has interacted with the Hostname field.
    @State private var hostNameTouched = false

    // Task 4 — collapsible section expansion state
    /// Whether the Connection section is expanded.
    @State var connectionExpanded = false
    /// Whether the Jump chain section is expanded.
    @State var jumpChainExpanded = false
    /// Whether the Port forwarding section is expanded.
    @State var portForwardingExpanded = false

    // Task 5 — collapsible section expansion state
    /// Whether the Mosh section is expanded.
    @State var moshExpanded = false
    /// Whether the Tailscale section is expanded.
    @State var tailscaleExpanded = false
    /// Whether the Semicolyn behavior section is expanded.
    @State var semicolynExpanded = false

    // Task 6 — identity picker state
    /// Whether the inline identity picker half-sheet is presented.
    @State private var showingIdentityPicker = false

    // Task 5 — delete flow state
    /// Whether the delete confirmation sheet is presented.
    @State var showingDeleteConfirm = false
    /// Non-nil when a delete was refused because the host is a referenced jumphost.
    /// Cleared by the delete refusal banner's dismiss action.
    @State var deleteRefusalReferrers: [HostRef]? = nil
    /// Non-nil when an unexpected save or delete error occurs; drives the generic error alert.
    @State private var genericError: String? = nil

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

    // Fix 2 — subtitle derived from savedOnce + hasChanges
    private var subtitle: String {
        if !savedOnce { return "unsaved" }
        if hasChanges { return "unsaved changes" }
        return "up to date"
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                basicsSection
                authSection
                connectionSection
                jumpChainSection
                portForwardingSection
                moshSection
                tailscaleSection
                semicolynSection
                if !vm.isNew {
                    deleteSection
                }
            }
            // Fix 2 — principal toolbar item replaces .navigationTitle for
            // reliable iOS subtitle rendering (NavigationStack on iOS 16+).
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .onAppear {
                defaults = (try? AppStores.shared.hosts.defaults()) ?? Defaults()
                vm.revalidate()
                applyInitialExpansion()
            }
            .onChange(of: vm.issues) { _, _ in
                syncSectionAutoExpand()
            }
        }
        // Task 6 — inline identity picker half-sheet
        .sheet(isPresented: $showingIdentityPicker) {
            IdentityPickerSheet { identity in
                var ids = vm.host.identities.value ?? []
                if !ids.contains(identity.id) {
                    ids.append(identity.id)
                }
                vm.host.identities = .explicit(ids)
                vm.revalidate()
            }
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog(
            "You have unsaved changes.",
            isPresented: $showingDiscardConfirm,
            titleVisibility: .visible
        ) {
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
        // Task 5 — delete confirmation sheet
        .confirmationDialog(
            "Delete '\(vm.host.label)'?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { performDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the host config from your library. The action cannot be undone.")
        }
        // Task 5 — delete refusal alert (host is referenced as jumphost)
        .alert(
            "Cannot delete '\(vm.host.label)'.",
            isPresented: Binding(
                get: { deleteRefusalReferrers != nil },
                set: { if !$0 { deleteRefusalReferrers = nil } }
            )
        ) {
            Button("OK", role: .cancel) { deleteRefusalReferrers = nil }
        } message: {
            if let referrers = deleteRefusalReferrers {
                let names = referrers.map { $0.label.isEmpty ? $0.id.uuidString : $0.label }
                    .joined(separator: ", ")
                Text("Used as jumphost by: \(names). Remove these references first.")
            }
        }
        // Fix 1 — duplicate-label soft warning alert (save already succeeded)
        .alert(
            "Saved",
            isPresented: Binding(
                get: { vm.saveWarning != nil },
                set: { if !$0 { vm.saveWarning = nil; dismiss() } }
            )
        ) {
            Button("OK") {
                vm.saveWarning = nil
                dismiss()
            }
        } message: {
            if let warning = vm.saveWarning {
                Text(warning)
            }
        }
        // Generic error alert — unexpected save or delete failures
        .alert("Error", isPresented: Binding(
            get: { genericError != nil },
            set: { if !$0 { genericError = nil } }
        )) {
            Button("OK", role: .cancel) { genericError = nil }
        } message: {
            Text(genericError ?? "")
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
        // Fix 2 — principal VStack title + subtitle (iOS-reliable approach)
        ToolbarItem(placement: .principal) {
            VStack(spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color(theme.text.primary))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Color(theme.text.secondary))
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
                    : Color(theme.text.secondary)  // Fix 5 — was theme.text.muted
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
                    .onChange(of: vm.host.label) { _, _ in
                        labelTouched = true  // Fix 4 — mark touched on first edit
                        vm.revalidate()
                    }
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
                    .onChange(of: vm.host.hostName) { _, _ in
                        hostNameTouched = true  // Fix 4 — mark touched on first edit
                        vm.revalidate()
                    }
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
            // Fix 4 — gate required-field banners on touched state
            if labelTouched && hasIssue(.missingLabel) {
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
            // Fix 4 — gate required-field banners on touched state
            if hostNameTouched && hasIssue(.missingHostName) {
                IssueBanner(message: "Hostname is required to save.", severity: .hardBlock)
            }
            // Fix 2 — gate no-user banner: suppress on a fresh untouched new-host form
            if hasNoUserIssue && ((!vm.isNew) || labelTouched || hostNameTouched) {
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
                showingIdentityPicker = true
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

    // `internal` (not `private`): called from the section extensions in a separate file.
    func hasIssue(_ kind: ValidationIssue.Kind) -> Bool {
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
        // Fix 3 — only claim Defaults value when one is actually set
        if let defaultPort = defaults.port.value {
            return "Defaults · \(defaultPort)"
        }
        return "e.g. 22"
    }

    // MARK: - Expansion logic

    /// Sets initial expansion for sections 3–8 per the spec's rules:
    /// new host → all collapsed; edit → expand iff the section has a non-default value.
    /// Also applies auto-expand for any hard issue whose section should be visible.
    private func applyInitialExpansion() {
        if !vm.isNew {
            // Connection: expand if any Tier-2 field is explicit
            connectionExpanded =
                vm.host.serverAliveInterval != .inherit ||
                vm.host.serverAliveCountMax != .inherit ||
                vm.host.compression != .inherit ||
                vm.host.forwardAgent != .inherit ||
                vm.host.strictHostKeyChecking != .inherit ||
                vm.host.preferredAuthentications != .inherit

            // Jump chain: expand if proxyJump has any hops
            jumpChainExpanded = vm.host.proxyJump.value?.isEmpty == false

            // Port forwarding: expand if any forward list is non-empty
            portForwardingExpanded =
                vm.host.localForwards.value?.isEmpty == false ||
                vm.host.remoteForwards.value?.isEmpty == false ||
                vm.host.dynamicForwards.value?.isEmpty == false

            // Mosh: expand if mosh is explicitly configured
            moshExpanded = vm.host.mosh != .inherit

            // Tailscale: expand if tailscale is explicitly configured
            tailscaleExpanded = vm.host.tailscale != .inherit

            // Semicolyn: expand if semicolyn is explicitly configured
            semicolynExpanded = vm.host.semicolyn != .inherit
        }
        // Auto-expand on hard issues (also triggered live via onChange → revalidate)
        syncSectionAutoExpand()
    }

    /// Expands a section if it contains a hard-block issue. Call after revalidate().
    /// Only expands; never collapses a user-opened section.
    func syncSectionAutoExpand() {
        let hasJumpIssue = vm.issues.contains { issue in
            if issue.kind == .jumpChainCycle { return true }
            if case .inlineJumpHostMissingHostName = issue.kind { return true }
            return false
        }
        if hasJumpIssue { jumpChainExpanded = true }

        let hasPortIssue = vm.issues.contains { issue in
            if case .localForwardMissingField = issue.kind { return true }
            if case .remoteForwardMissingField = issue.kind { return true }
            if case .dynamicForwardMissingField = issue.kind { return true }
            return false
        }
        if hasPortIssue { portForwardingExpanded = true }

        // Connection has no hard-block validation issues in v1, so it is never force-expanded here.
        // Add a block here if a Connection-scoped hard issue is introduced.
    }

    // MARK: - Delete action

    /// Routes the confirmed delete through `HostStore`. On success, dismisses the
    /// editor (the list reloads via its sheet `onDismiss`). On
    /// `StoreError.jumpHostInUse`, sets `deleteRefusalReferrers` — the refusal
    /// alert is presented by the `.alert` modifier above.
    func performDelete() {
        do {
            try AppStores.shared.hosts.deleteHost(id: vm.host.id)
            dismiss()
        } catch StoreError.jumpHostInUse(let referrers) {
            deleteRefusalReferrers = referrers
        } catch {
            // Unexpected store error — surface via the generic error alert.
            genericError = "Couldn't delete this host. \(error.localizedDescription)"
        }
    }

    // MARK: - Save action

    private func performSave() {
        do {
            let outcome = try vm.save()
            // Fix 1 — if duplicateLabels is non-empty, saveWarning is set on vm;
            // the .alert modifier above will present it before dismissing.
            // If no warning, dismiss immediately.
            if outcome.duplicateLabels.isEmpty {
                savedOnce = true  // Fix 2 — mark as saved before dismissing
                dismiss()
            } else {
                savedOnce = true  // Fix 2 — save succeeded even with dup warning
                // vm.saveWarning is now set; the alert will dismiss after OK.
            }
        } catch EditorSaveError.hardBlocksPresent {
            // Issues are already reflected in vm.issues; the view renders them.
            // The Save button is disabled when hard blocks exist, so this branch
            // should not be reached in practice; it guards against race conditions.
        } catch {
            // Unexpected storage error — surface via the generic error alert.
            genericError = "Couldn't save this host. \(error.localizedDescription)"
        }
    }
}

// MARK: - Identity pill

/// A small rounded pill showing the identity's display name. Resolves the
/// `IdentityRef` (UUID) against `allIdentities()` at render time; falls back
/// to a truncated UUID if the identity is not found.
private struct IdentityPill: View {
    let identityRef: IdentityRef
    @Environment(\.theme) private var theme

    private var label: String {
        let all = (try? AppStores.shared.hosts.allIdentities()) ?? []
        if let identity = all.first(where: { $0.id == identityRef }) {
            return identity.displayName
        }
        return String(identityRef.uuidString.prefix(8).lowercased())
    }

    var body: some View {
        Text(label)
            .font(.caption)
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
struct IssueBanner: View {
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
