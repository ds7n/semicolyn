// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import GlymrKit

/// Root host-library screen. Shows an empty-state CTA when no hosts exist;
/// otherwise a list where each row can be tapped to connect or swiped for
/// Edit / Delete actions.
struct HostListView: View {
    @StateObject private var vm = HostListViewModel()
    @Environment(\.theme) private var theme
    /// `nil` means the editor is closed; `.creating` opens it for a new host;
    /// `.editing(host)` opens it for an existing host.
    @State private var editorMode: HostEditorMode?

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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Host list

    private var hostList: some View {
        List {
            ForEach(vm.hosts, id: \.id) { host in
                Button {
                    // TODO(Task 8): connect-from-saved — wire ConnectionViewModel with saved Host credentials
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
