// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import NeotildeKit

/// The Settings tree surfaced from a long-press on the Esc pill. For 4d-1 its
/// only leaf is the Keybar editor; the spec's full unified picker (windows /
/// Live hosts / Recent / Connect) is a later slice.
struct KeybarSettingsSheet: View {
    @ObservedObject var store: KeybarSettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    KeybarEditorView(store: store)
                } label: {
                    Label("Keybar", systemImage: "keyboard")
                }
                NavigationLink {
                    MacroLibraryView(store: store)
                } label: {
                    Label("Launcher", systemImage: "command")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// The modal flows reachable from the Keybar editor's "+ Add" / row edit.
private enum KeybarEditorSheet: Identifiable {
    case launcher, createMacro, createSlot
    case editSlot(CustomSlot)
    var id: String {
        switch self {
        case .launcher:        return "launcher"
        case .createMacro:     return "createMacro"
        case .createSlot:      return "createSlot"
        case .editSlot(let s): return "edit-\(s.id.raw)"
        }
    }
}

/// Settings → Keybar: a single editable list of every slot in order, split into
/// the locked and scroll regions, plus the reverse-bar toggle. Reorder via the
/// drag handles, delete via swipe-to-delete (Esc/Pad excluded), and move a slot
/// across the divider via its per-row menu. "Reset to defaults" restores the v1
/// layout. (keybar-customization spec "Customization model".)
///
/// Note: the spec describes a single draggable divider; SwiftUI cross-section
/// drag is unreliable, so 4d-1 uses two sections + an explicit per-row "move
/// across divider" action. Flagged for the Simulator pass.
struct KeybarEditorView: View {
    @ObservedObject var store: KeybarSettingsStore
    /// One-time warning before removing the Modifier (don't nag on repeat).
    @AppStorage("neotilde.keybar.modifierRemoveWarned") private var modifierRemoveWarned = false
    @State private var confirmingModifierRemove = false
    @State private var editorSheet: KeybarEditorSheet?

    private var layout: KeybarLayout { store.settings.layout }

    var body: some View {
        List {
            Section("Layout direction") {
                Picker("Locked region", selection: directionBinding) {
                    Text("Left").tag(KeybarLayoutDirection.lockedLeft)
                    Text("Right").tag(KeybarLayoutDirection.lockedRight)
                }
                .pickerStyle(.segmented)
            }

            Section("Locked region") {
                ForEach(layout.locked, id: \.self) { slot in
                    row(slot, inScroll: false)
                        .deleteDisabled(!KeybarLayout.isRemovable(slot))
                }
                .onMove { store.settings.layout = layout.reorderingLocked(fromOffsets: $0, toOffset: $1) }
                .onDelete { delete($0, from: layout.locked) }
            }

            Section("Scroll region") {
                ForEach(layout.scroll, id: \.self) { slot in
                    row(slot, inScroll: true)
                        .deleteDisabled(!KeybarLayout.isRemovable(slot))
                }
                .onMove { store.settings.layout = layout.reorderingScroll(fromOffsets: $0, toOffset: $1) }
                .onDelete { delete($0, from: layout.scroll) }
            }

            Section { addMenu } footer: {
                Text("Pin a saved macro, record or template a new one, or build a custom slot.")
            }
        }
        .environment(\.editMode, .constant(.active))   // always show reorder handles
        .navigationTitle("Keybar")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Reset") { store.resetToDefaults() }
            }
        }
        .sheet(item: $editorSheet) { which in
            NavigationStack {
                switch which {
                case .launcher:        MacroLibraryView(store: store)
                case .createMacro:     MacroCreationView(store: store)
                case .createSlot:      CustomSlotEditorView(store: store, slot: nil)
                case .editSlot(let s): CustomSlotEditorView(store: store, slot: s)
                }
            }
        }
        .alert("Remove Modifier?", isPresented: $confirmingModifierRemove) {
            Button("Remove", role: .destructive) {
                modifierRemoveWarned = true
                apply(layout.removing(.modifier))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll lose Ctrl/Alt/Shift access. You can re-add it from “Add” below.")
        }
    }

    // MARK: - Row

    @ViewBuilder private func row(_ slot: KeybarSlot, inScroll: Bool) -> some View {
        HStack {
            Text(slotLabel(slot))
            Spacer()
            if case .custom(let id) = slot, let customSlot = store.settings.library.customSlot(id) {
                Button { editorSheet = .editSlot(customSlot) } label: {
                    Image(systemName: "pencil").font(.footnote)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Edit custom slot")
            }
            if KeybarLayout.canMoveAcrossDivider(slot) {
                Menu {
                    Button(inScroll ? "Move to Locked region" : "Move to Scroll region") {
                        apply(layout.moving(slot, toScroll: !inScroll))
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down").font(.footnote)
                }
            } else {
                // Esc pill / Pad: pinned to the locked region.
                Image(systemName: "lock.fill").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Add

    @ViewBuilder private var addMenu: some View {
        Menu {
            ForEach(addableDefaults, id: \.self) { slot in
                Button(slotLabel(slot)) {
                    store.settings.layout = KeybarLayout(locked: layout.locked, scroll: layout.scroll + [slot])
                }
            }
            Divider()
            Button("Pin a macro…") { editorSheet = .launcher }
            Button("Create new macro…") { editorSheet = .createMacro }
            Button("Create new slot…") { editorSheet = .createSlot }
        } label: {
            Label("Add", systemImage: "plus")
        }
    }

    /// Default built-ins / symbols the user has removed and can re-add.
    private var addableDefaults: [KeybarSlot] {
        let present = Set(layout.locked + layout.scroll)
        let candidates = KeybarLayout.default.scroll + [KeybarSlot.modifier, .tab]
        return candidates.filter { !present.contains($0) }
    }

    // MARK: - Actions

    private var directionBinding: Binding<KeybarLayoutDirection> {
        Binding(get: { store.settings.direction },
                set: { store.settings.direction = $0 })
    }

    /// Handles a swipe-to-delete on a region. Single-row deletes only; routes the
    /// Modifier through a one-time confirm.
    private func delete(_ offsets: IndexSet, from region: [KeybarSlot]) {
        for index in offsets {
            let slot = region[index]
            guard KeybarLayout.isRemovable(slot) else { continue }
            if slot == .modifier && !modifierRemoveWarned {
                confirmingModifierRemove = true
            } else {
                apply(layout.removing(slot))
            }
        }
    }

    /// Commits a mutation that may have been refused (nil) by a sticky rule.
    private func apply(_ newLayout: KeybarLayout?) {
        guard let newLayout else { return }
        store.settings.layout = newLayout
    }

    private func slotLabel(_ slot: KeybarSlot) -> String {
        switch slot {
        case .escPill:        return "Esc pill"
        case .pad:            return "Pad (arrows + pane)"
        case .modifier:       return "Modifier (Ctrl/Alt/Shift)"
        case .tab:            return "Tab"
        case .fn:             return "Fn (function keys)"
        case .symbol(let s):  return "Symbol “\(s)”"
        case .pinnedMacro(let id):
            return store.settings.library.macro(id).map { "Macro “\($0.name)”" } ?? "Pinned macro (missing)"
        case .custom(let id):
            let lib = store.settings.library
            let name = lib.customSlot(id)?.displayLabel(macroName: { lib.macro($0)?.name })
            return name.map { "Slot “\($0)”" } ?? "Custom slot"
        }
    }
}
