// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// Identifies a launch-resume presentation: the resolved saved host plus the pure
/// `ResumeAction` to execute. `id` is the record's session id (stable, unique per
/// resumable session) so `.fullScreenCover(item:)` presents exactly once.
private struct ResumeTarget: Identifiable {
    let host: Host
    let action: ResumeAction
    var id: UUID {
        switch action {
        case .coldReattach(let r), .promptRaw(let r): return r.sessionID
        case .reforeground, .none: return host.id
        }
    }
}

/// Root host-library screen. Shows an empty-state CTA when no hosts exist;
/// otherwise a searchable list where each row can be tapped to connect, swiped for
/// Edit / Delete, or long-pressed for Connect / Edit / Duplicate / Delete. The
/// toolbar also offers "Connect to user@host…" (`QuickConnectEntrySheet`).
struct HostListView: View {
    @StateObject private var vm = HostListViewModel()
    @Environment(\.theme) private var theme
    /// `nil` means the editor is closed; `.creating` opens it for a new host;
    /// `.editing(host)` opens it for an existing host.
    @State private var editorMode: HostEditorMode?
    /// Whether the top-level Settings sheet is presented.
    @State private var showingSettings = false
    /// Non-nil when the user has tapped a saved host to connect (Task 8).
    @State private var connectingHost: IdentifiableHost?
    /// Non-nil when launch-resume resolved an actionable record: presents a session
    /// cover that executes the action (cold reattach or the raw-SSH prompt).
    @State private var resumeTarget: ResumeTarget?
    /// Guards the once-per-launch resume sweep so re-entering `onAppear` (e.g. after a
    /// sheet dismiss) never re-triggers it.
    @State private var didRunResume = false
    /// A host swiped for Delete, awaiting confirmation.
    @State private var pendingDelete: Host?
    /// The Hosts search text (`filterHosts`).
    @State private var search = ""
    /// Whether the "Connect to user@host…" sheet is up.
    @State private var showingQuickConnect = false
    /// The host chosen in that sheet, connected once the sheet has gone away.
    @State private var quickConnectHost: Host?

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
                    Button {
                        InputClickFeedback.play()
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        InputClickFeedback.play()
                        showingQuickConnect = true
                    } label: {
                        Image(systemName: "bolt.horizontal")
                    }
                    .accessibilityLabel("Connect to user@host…")
                    Button {
                        InputClickFeedback.play()
                        editorMode = .creating
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Host")
                }
            }
            .onAppear {
                vm.reload()
                runLaunchResumeIfNeeded()
            }
            // Settings sheet, Task 4.
            .sheet(isPresented: $showingSettings) {
                SettingsView(keybarSettings: AppStores.shared.keybarSettings)
            }
            // Connect to user@host…: find-or-create the host, then connect.
            // The session cover opens once the sheet is gone (two presentations at once
            // would drop the second).
            .sheet(isPresented: $showingQuickConnect, onDismiss: {
                vm.reload()
                if let host = quickConnectHost {
                    quickConnectHost = nil
                    connectingHost = IdentifiableHost(host)
                }
            }) {
                QuickConnectEntrySheet(
                    onConnect: { target in
                        quickConnectHost = try? ConnectionViewModel.savedOrNewHost(for: target)
                        showingQuickConnect = false
                    },
                    onCancel: { showingQuickConnect = false })
            }
            // Session cover, Task 8: tap a saved host to connect.
            .fullScreenCover(item: $connectingHost) { wrapper in
                SessionView(host: wrapper.host)
            }
            // Launch-resume cover: opens a session that executes the resolved
            // ResumeAction (cold Mosh/ET reattach, or the raw-SSH reconnect prompt).
            .fullScreenCover(item: $resumeTarget) { target in
                SessionView(host: target.host, resume: target.action)
            }
            // Host editor sheet, Task 3.
            .sheet(item: $editorMode, onDismiss: { vm.reload() }) { mode in
                switch mode {
                case .creating:
                    HostEditorView(creating: true)
                case .editing(let host):
                    HostEditorView(editing: host)
                }
            }
            // Swipe Delete asks first, with the same message as the editor's Delete.
            .confirmationDialog(
                "Delete “\(pendingDelete?.label ?? "")”?",
                isPresented: Binding(get: { pendingDelete != nil },
                                     set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { host in
                Button("Delete", role: .destructive) {
                    InputClickFeedback.play()
                    vm.delete(host)
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: { _ in
                Text(hostDeleteMessage)
            }
            // Delete-refusal alert.
            .alert(
                "Can't Delete “\(vm.deleteErrorHostLabel)”",
                isPresented: Binding(
                    get: { vm.deleteError != nil },
                    set: { if !$0 { vm.deleteError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { InputClickFeedback.play(); vm.deleteError = nil }
            } message: {
                Text(vm.deleteError ?? "")
            }
            .alert(
                "Couldn't Duplicate Host",
                isPresented: Binding(
                    get: { vm.duplicateError != nil },
                    set: { if !$0 { vm.duplicateError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { InputClickFeedback.play(); vm.duplicateError = nil }
            } message: {
                Text(vm.duplicateError ?? "")
            }
        }
    }

    // MARK: - Launch resume

    /// Run the once-per-launch resume sweep: reconcile orphans, decide (pure), and, for
    /// an actionable result (`.coldReattach` / `.promptRaw`), resolve the host and open
    /// the resume cover. `isWarm: false`: a cold app launch has no surviving live VM, so
    /// the App only ever handles the cold + prompt cases here. A `.none` result (or an
    /// unresolvable host) leaves the user on the host list. Idempotent via `didRunResume`.
    private func runLaunchResumeIfNeeded() {
        guard !didRunResume else { return }
        didRunResume = true
        let action = AppStores.shared.resume.resumeOnLaunch(isWarm: false)
        switch action {
        case .coldReattach(let record), .promptRaw(let record):
            guard let host = (try? AppStores.shared.hosts.host(id: record.hostID)) ?? nil else {
                DebugLog.shared.log(.connect, "resume:launch host \(record.hostID) unresolved → host list")
                return
            }
            DebugLog.shared.log(.connect, "resume:launch present host=\(host.label)")
            resumeTarget = ResumeTarget(host: host, action: action)
        case .reforeground, .none:
            // Nothing to reforeground on a cold launch; normal host-list landing.
            return
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Button {
                InputClickFeedback.play()
                editorMode = .creating
            } label: {
                Text("Add your first host")
                    .font(.headline)
                    .foregroundStyle(Color(theme.accent.primary))
            }
            .buttonStyle(.plain)

            Text("You'll need the server's address, your username, and a password or SSH key. You can create a key in the next step.")
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
            ForEach(filterHosts(vm.hosts, query: search), id: \.id) { host in
                Button {
                    InputClickFeedback.play()
                    connectingHost = IdentifiableHost(host)
                } label: {
                    HostRow(host: host)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button {
                        connectingHost = IdentifiableHost(host)
                    } label: {
                        Label("Connect", systemImage: "play")
                    }
                    Button {
                        editorMode = .editing(host)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    Button {
                        if let copy = vm.duplicate(host) { editorMode = .editing(copy) }
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }
                    // Confirmed first, same dialog as the swipe.
                    Button(role: .destructive) {
                        pendingDelete = host
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    // Delete action: confirmed first. Not `role: .destructive`, which
                    // animates the row away before the user has confirmed.
                    Button {
                        InputClickFeedback.play()
                        pendingDelete = host
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(.red)

                    // Edit action
                    Button {
                        InputClickFeedback.play()
                        editorMode = .editing(host)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(Color(theme.accent.primary))
                }
            }
        }
        .searchable(text: $search, prompt: "Search hosts")
        .overlay {
            if filterHosts(vm.hosts, query: search).isEmpty {
                ContentUnavailableView.search(text: search)
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
        // Fill the row width and make the whole area (not just the text glyphs)
        // the button's hit target, so a tap anywhere in the row connects.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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
