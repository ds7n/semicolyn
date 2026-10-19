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

/// The single unified Settings screen. Reached from the host-list gear, and in a
/// session from long-press-Esc, `⌘,` or the "≡" corner button (with a Session
/// section on top). Rows follow `SettingsLayout`; all of them work before connecting
/// too (Keybar and Macros edit the same global store either way).
struct SettingsView: View {
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
                ForEach(SettingsLayout.groups, id: \.sections) { group in
                    Section {
                        ForEach(group.sections, id: \.self) { section in
                            NavigationLink { destination(section) } label: {
                                Label(section.title, systemImage: section.symbol)
                            }
                        }
                    } header: {
                        if let header = group.header { Text(header) }
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
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

    /// The screen each Settings row pushes.
    @ViewBuilder
    private func destination(_ section: SettingsSection) -> some View {
        switch section {
        case .appearance:  AppearanceSettingsView()
        case .terminal:    TerminalSettingsView()
        case .keybar:      KeybarEditorView(store: keybarSettings)
        case .macros:      MacroLibraryView(store: keybarSettings)
        case .keyboard:    KeyboardSettingsView(store: keybarSettings)
        case .defaults:    DefaultsEditorView()
        case .sshKeys:     SSHKeysView()
        case .knownHosts:  KnownHostsView()
        case .privacy:     PrivacySettingsView()
        case .tips:        TipsView(showsDoneButton: false)
        case .diagnostics: DiagnosticsSettingsView()
        case .about:       AboutView()
        }
    }
}
