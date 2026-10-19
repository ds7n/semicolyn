// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// The macro library (Settings → Macros): a searchable list of every macro.
/// Two modes via `onPick`:
///   - nil → **library**: add a macro to the bar as a macro key, delete (swipe; a
///     macro that keybar keys use asks first), create new.
///   - non-nil → **picker** (from a gesture-key binding row): tapping a macro
///     returns it to the caller.
/// "+ New macro" opens the creation flow in both modes (keybar-customization spec
/// "Macro library" / "Macro creation → entry points").
struct MacroLibraryView: View {
    @ObservedObject var store: KeybarSettingsStore
    @Environment(\.dismiss) private var dismiss
    var onPick: ((Macro) -> Void)?

    @State private var search = ""
    @State private var creating = false
    /// A swipe-deleted macro that keybar keys still use, awaiting confirmation.
    @State private var pendingDelete: Macro?

    private var isPicker: Bool { onPick != nil }

    private var filtered: [Macro] {
        let all = store.settings.library.macros
        guard !search.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            if store.settings.library.macros.isEmpty {
                Text("No macros yet. A macro sends saved text or keys with one tap, like a command you run often. Tap + to create one.")
                    .foregroundStyle(.secondary)
            }
            ForEach(filtered) { macro in
                row(macro)
            }
            .onDelete { offsets in
                guard !isPicker else { return }
                deleteRows(offsets)
            }
        }
        .searchable(text: $search)
        .navigationTitle(isPicker ? "Pick a Macro" : "Macros")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { creating = true } label: { Label("New Macro", systemImage: "plus") }
            }
        }
        .confirmationDialog("Delete “\(pendingDelete?.name ?? "")”?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingDelete) { macro in
            Button("Delete", role: .destructive) { store.deleteMacro(macro.id); pendingDelete = nil }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { macro in
            Text(macroDeleteUsageMessage(keyCount: store.settings.keyCount(using: macro.id)))
        }
        .sheet(isPresented: $creating) {
            NavigationStack {
                MacroCreationView(store: store) { macro in
                    // In picker mode a freshly-created macro is returned straight away.
                    if let onPick { onPick(macro); dismiss() }
                }
            }
        }
    }

    @ViewBuilder private func row(_ macro: Macro) -> some View {
        if isPicker {
            Button { onPick?(macro); dismiss() } label: { label(macro) }
        } else {
            HStack {
                label(macro)
                Spacer()
                Button {
                    store.appendToMiddle(.pinnedMacro(macro.id))
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Add \(macro.name) as a macro key")
            }
        }
    }

    private func label(_ macro: Macro) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(macro.name)
            Text(macro.body.map(macroEventLabel).joined())
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary).lineLimit(1)
        }
    }

    /// Unused macros delete immediately; one that keybar keys use asks first
    /// (its keys would otherwise silently become "missing macro").
    private func deleteRows(_ offsets: IndexSet) {
        for macro in offsets.map({ filtered[$0] }) {
            if store.settings.keyCount(using: macro.id) > 0 {
                pendingDelete = macro
            } else {
                store.deleteMacro(macro.id)
            }
        }
    }
}
