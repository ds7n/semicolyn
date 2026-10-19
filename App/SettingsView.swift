// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// The Session section of the in-session Settings sheet: what is connected and the
/// two session actions. Built by `ConnectionViewModel.sessionControls`.
struct SessionSettingsControls {
    /// "<host> · <transport>" (`sessionMenuTitle`).
    let title: String
    /// The host label, for the Disconnect confirmation title.
    let hostLabel: String
    let onReconnect: () -> Void
    let onDisconnect: () -> Void
}

/// The single unified Settings screen. Reached from the host-list gear
/// (`.preConnect`), and in a session from long-press-Esc, `⌘,` or the "≡" corner
/// button (`.inSession`, with a Session section on top). Sections that don't apply
/// to the current context (Keybar, Macros pre-connect) render dimmed + disabled.
struct SettingsView: View {
    let context: SettingsContext
    @ObservedObject var keybarSettings: KeybarSettingsStore
    /// The live session's controls; nil pre-connect (no Session section).
    var session: SessionSettingsControls? = nil
    @Environment(\.dismiss) private var dismiss

    /// A session action chosen in the sheet. It runs once the sheet has gone away
    /// (`onDisappear`), so the teardown never races the sheet's own dismissal.
    private enum PendingSessionAction { case reconnect, disconnect }
    @State private var pendingSessionAction: PendingSessionAction?
    @State private var confirmingDisconnect = false

    var body: some View {
        NavigationStack {
            List {
                if let session {
                    sessionSection(session)
                }
                row(.appearance, "Appearance", "paintpalette") { ThemePickerView() }
                row(.terminal, "Terminal", "terminal") { TerminalSettingsView() }
                row(.keybar, "Keybar", "keyboard") { KeybarEditorView(store: keybarSettings) }
                row(.launcher, "Macros", "command") { MacroLibraryView(store: keybarSettings) }
                row(.defaults, "Connection Defaults", "slider.horizontal.3") { DefaultsEditorView() }
                row(.privacy, "Privacy", "hand.raised") { PrivacySettingsView() }
                row(.tips, "Tips & Gestures", "questionmark.circle") { TipsView(showsDoneButton: false) }
                row(.diagnostics, "Diagnostics", "ladybug") { DiagnosticsSettingsView() }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { InputClickFeedback.play(); dismiss() }
                }
            }
        }
        .onDisappear {
            guard let action = pendingSessionAction, let session else { return }
            pendingSessionAction = nil
            switch action {
            case .reconnect:  session.onReconnect()
            case .disconnect: session.onDisconnect()
            }
        }
    }

    /// Top section in a session: "<host> · <transport>", Reconnect, Disconnect.
    @ViewBuilder
    private func sessionSection(_ session: SessionSettingsControls) -> some View {
        Section {
            Text(session.title)
                .foregroundStyle(.secondary)
            Button {
                InputClickFeedback.play()
                pendingSessionAction = .reconnect
                dismiss()
            } label: {
                Label("Reconnect", systemImage: "arrow.clockwise")
            }
            Button(role: .destructive) {
                InputClickFeedback.play()
                confirmingDisconnect = true
            } label: {
                Label("Disconnect", systemImage: "xmark.circle")
            }
            .confirmationDialog("Disconnect from \(session.hostLabel)?",
                                isPresented: $confirmingDisconnect, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) {
                    InputClickFeedback.play()
                    pendingSessionAction = .disconnect
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
        } header: {
            Text("Session")
        }
    }

    /// One Settings row. Disabled + dimmed when the gate says the section doesn't
    /// apply in the current context.
    @ViewBuilder
    private func row<Destination: View>(_ section: SettingsSection,
                                        _ title: String,
                                        _ symbol: String,
                                        @ViewBuilder destination: @escaping () -> Destination) -> some View {
        let enabled = SettingsGate.isEnabled(section, in: context)
        NavigationLink { destination() } label: {
            Label(title, systemImage: symbol)
                .opacity(enabled ? 1.0 : 0.4)   // dim when the section doesn't apply
        }
        .disabled(!enabled)
    }
}
