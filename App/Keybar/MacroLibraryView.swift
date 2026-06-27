// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import NeotildeKit

/// The macro library, a.k.a. the Launcher: a searchable list of every macro.
/// Two modes via `onPick`:
///   - nil → **Launcher**: pin a macro to the bar, delete (swipe), create new.
///   - non-nil → **picker** (from a custom-slot binding row): tapping a macro
///     returns it to the caller.
/// "+ New macro" opens the creation flow in both modes (keybar-customization spec
/// "Macro library" / "Macro creation → entry points").
struct MacroLibraryView: View {
    @ObservedObject var store: KeybarSettingsStore
    @Environment(\.dismiss) private var dismiss
    var onPick: ((Macro) -> Void)?

    @State private var search = ""
    @State private var creating = false

    private var isPicker: Bool { onPick != nil }

    private var filtered: [Macro] {
        let all = store.settings.library.macros
        guard !search.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            if store.settings.library.macros.isEmpty {
                Text("No macros yet. Create one with “New macro”.")
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
        .navigationTitle(isPicker ? "Pick a macro" : "Launcher")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { creating = true } label: { Label("New macro", systemImage: "plus") }
            }
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
                    store.appendToScroll(.pinnedMacro(macro.id))
                } label: {
                    Image(systemName: "pin")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Pin \(macro.name) to keybar")
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

    private func deleteRows(_ offsets: IndexSet) {
        offsets.map { filtered[$0] }.forEach { store.deleteMacro($0.id) }
    }
}
