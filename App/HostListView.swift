// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// Root host-library screen. Shows an empty-state CTA when no hosts exist;
/// otherwise a list where each row can be tapped to connect or swiped for
/// Edit / Delete actions.
struct HostListView: View {
    @StateObject private var vm = HostListViewModel()
    @Environment(\.theme) private var theme
    /// `nil` means the editor is closed; `.creating` opens it for a new host;
    /// `.editing(host)` opens it for an existing host.
    @State private var editorMode: HostEditorMode?
    /// Whether the Defaults editor sheet is presented.
    @State private var showingDefaults = false
    /// Whether the top-level Settings sheet is presented.
    @State private var showingSettings = false
    /// Non-nil when the user has tapped a saved host to connect (Task 8).
    @State private var connectingHost: IdentifiableHost?

    var body: some View {
        NavigationStack {
            Group {
                if vm.hosts.isEmpty {
                    emptyState
                } else {
                    hostList
                }
            }
            .navigationTitle("Hosts")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    // Defaults is always reachable, even when the host list is empty.
                    Button {
                        showingDefaults = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Defaults")

                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        editorMode = .creating
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .onAppear {
                vm.reload()
            }
            // Defaults editor sheet — Task 7.
            .sheet(isPresented: $showingDefaults) {
                DefaultsEditorView()
            }
            // Settings sheet — Task 4.
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            // Session cover — Task 8: tap a saved host to connect.
            .fullScreenCover(item: $connectingHost) { wrapper in
                SessionView(host: wrapper.host)
            }
            // Host editor sheet — Task 3.
            .sheet(item: $editorMode, onDismiss: { vm.reload() }) { mode in
                switch mode {
                case .creating:
                    HostEditorView(creating: true)
                case .editing(let host):
                    HostEditorView(editing: host)
                }
            }
            // Delete-refusal alert.
            .alert(
                "Cannot Delete Host",
                isPresented: Binding(
                    get: { vm.deleteError != nil },
                    set: { if !$0 { vm.deleteError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { vm.deleteError = nil }
            } message: {
                Text(vm.deleteError ?? "")
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Button {
                editorMode = .creating
            } label: {
                Text("Add your first host")
                    .font(.headline)
                    .foregroundStyle(Color(theme.accent.primary))
            }
            .buttonStyle(.plain)

            Text("You'll need a hostname, username, and either a password or key.")
                .font(.subheadline)
                .foregroundStyle(Color(theme.text.secondary))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            // Defaults is always reachable from the empty state (spec: Defaults editor entry points).
            Button {
                showingDefaults = true
            } label: {
                Text("Edit defaults")
                    .font(.subheadline)
                    .foregroundStyle(Color(theme.text.secondary))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Host list

    private var hostList: some View {
        List {
            // Defaults row — top of the host list (spec: §Defaults editor entry points).
            Button {
                showingDefaults = true
            } label: {
                Label("Defaults", systemImage: "slider.horizontal.3")
                    .foregroundStyle(Color(theme.text.primary))
            }
            .buttonStyle(.plain)

            ForEach(vm.hosts, id: \.id) { host in
                Button {
                    connectingHost = IdentifiableHost(host)
                } label: {
                    HostRow(host: host)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    // Delete action
                    Button(role: .destructive) {
                        vm.delete(host)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }

                    // Edit action
                    Button {
                        editorMode = .editing(host)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(Color(theme.accent.primary))
                }
            }
        }
    }
}

// MARK: - Host row

/// A single row in the host list: label on top, hostname in muted text below.
private struct HostRow: View {
    let host: Host
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(host.label)
                .font(.body)
                .foregroundStyle(Color(theme.text.primary))
            Text(host.hostName)
                .font(.caption)
                .foregroundStyle(Color(theme.text.secondary))
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Editor mode

/// Discriminates between the two entry points for the host editor sheet.
private enum HostEditorMode: Identifiable {
    case creating
    case editing(Host)

    var id: String {
        switch self {
        case .creating: return "creating"
        case .editing(let host): return host.id.uuidString
        }
    }
}

// MARK: - Identifiable wrapper for Host (Task 8)

/// `Host` itself does not conform to `Identifiable`, so `.fullScreenCover(item:)`
/// (and any other `item:`-based modifier) requires a thin wrapper that provides a
/// stable, Identifiable id. Using the host's own `UUID` keeps identity trivially
/// stable and avoids any alloc overhead beyond the box itself.
private struct IdentifiableHost: Identifiable {
    let id: UUID
    let host: Host
    init(_ host: Host) { self.id = host.id; self.host = host }
}
