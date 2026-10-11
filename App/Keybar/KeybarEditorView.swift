// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// The modal flows reachable from the Keybar editor's "+ Add" / row edit.
private enum KeybarEditorSheet: Identifiable {
    case launcher, createMacro, createSlot
    case editSlot(CustomSlot)
    case editFixed(FixedKeyID)
    var id: String {
        switch self {
        case .launcher:          return "launcher"
        case .createMacro:       return "createMacro"
        case .createSlot:        return "createSlot"
        case .editSlot(let s):   return "edit-\(s.id.raw)"
        case .editFixed(let k):  return "editfixed-\(k)"
        }
    }
}

/// Settings → Keybar: every slot in order across the Left (fixed), Middle
/// (scrolls) and Right (fixed) regions. Reorder via drag handles, delete via
/// swipe (Esc/Pad excluded), move between regions via each row's menu. Reset
/// restores the default layout.
///
/// Note: SwiftUI cross-section drag is unreliable, so moving between regions
/// uses an explicit per-row "Move to" menu instead of dragging across sections.
struct KeybarEditorView: View {
    @ObservedObject var store: KeybarSettingsStore
    /// One-time warning before removing the Modifier (don't nag on repeat).
    @AppStorage("semicolyn.keybar.modifierRemoveWarned") private var modifierRemoveWarned = false
    @State private var confirmingModifierRemove = false
    @State private var editorSheet: KeybarEditorSheet?

    private var layout: KeybarLayout { store.settings.layout }

    var body: some View {
        List {
            Section {
                Toggle("Hide when hardware keyboard connected", isOn: hideWithHardwareKeyboardBinding)
            } footer: {
                Text("Hides the keybar while a hardware keyboard is attached. The predictor strip stays.")
            }

            ForEach(KeybarRegion.allCases, id: \.self) { region in
                regionSection(region)
            }

            Section { addMenu } footer: {
                Text("A macro key runs one macro when tapped. A gesture key can run a different macro for tap, swipe up, swipe down and long-press.")
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
                case .createMacro:
                    // From the Add menu a new macro lands on the bar as a macro key.
                    MacroCreationView(store: store) { store.appendToMiddle(.pinnedMacro($0.id)) }
                case .createSlot:      CustomSlotEditorView(store: store, slot: nil)
                case .editSlot(let s):  CustomSlotEditorView(store: store, slot: s)
                case .editFixed(let k): FixedKeySecondaryEditorView(store: store, id: k)
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

    @ViewBuilder private func regionSection(_ region: KeybarRegion) -> some View {
        let slots = layout.slots(in: region)
        Section(regionTitle(region)) {
            ForEach(slots, id: \.self) { slot in
                row(slot, in: region)
                    .deleteDisabled(!KeybarLayout.isRemovable(slot))
            }
            .onMove { store.settings.layout = layout.reordering(region, fromOffsets: $0, toOffset: $1) }
            .onDelete { delete($0, from: slots) }
        }
    }

    private func regionTitle(_ region: KeybarRegion) -> String {
        switch region {
        case .left:   return "Left (fixed)"
        case .middle: return "Middle (scrolls)"
        case .right:  return "Right (fixed)"
        }
    }

    @ViewBuilder private func row(_ slot: KeybarSlot, in region: KeybarRegion) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(slotLabel(slot))
                if let detail = keybarEditorDetail(for: slot, settings: store.settings) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if case .custom(let id) = slot, let customSlot = store.settings.library.customSlot(id) {
                Button { editorSheet = .editSlot(customSlot) } label: {
                    Image(systemName: "pencil").font(.footnote)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Edit gesture key")
            }
            if let fixedID = fixedKeyID(for: slot) {
                Button { editorSheet = .editFixed(fixedID) } label: {
                    Image(systemName: "pencil").font(.footnote)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Edit swipe secondaries")
            }
            Menu {
                ForEach(KeybarLayout.allowedRegions(for: slot).filter { $0 != region }, id: \.self) { target in
                    Button("Move to \(regionTitle(target))") {
                        apply(layout.moving(slot, to: target))
                    }
                }
            } label: {
                Image(systemName: "arrow.left.arrow.right").font(.footnote)
            }
        }
    }

    // MARK: - Add

    @ViewBuilder private var addMenu: some View {
        Menu {
            ForEach(addableDefaults, id: \.self) { slot in
                Button(slotLabel(slot)) {
                    store.settings.layout = layout.appending(slot, to: .middle)
                }
            }
            Divider()
            Button("Add macro key…") { editorSheet = .launcher }
            Button("Add gesture key…") { editorSheet = .createSlot }
            Button("Record new macro key…") { editorSheet = .createMacro }
        } label: {
            Label("Add", systemImage: "plus")
        }
    }

    /// Default built-ins / symbols the user has removed and can re-add.
    private var addableDefaults: [KeybarSlot] {
        let present = Set(layout.allSlots)
        let candidates = KeybarLayout.default.middle + [KeybarSlot.modifier, .tab]
        return candidates.filter { !present.contains($0) }
    }

    // MARK: - Actions

    private var hideWithHardwareKeyboardBinding: Binding<Bool> {
        Binding(get: { store.settings.hideKeybarWithHardwareKeyboard },
                set: { store.settings.hideKeybarWithHardwareKeyboard = $0 })
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
        guard let newLayout else {
            DebugLog.shared.log(.keybar, "keybar:layoutApply refused")
            return
        }
        DebugLog.shared.log(.keybar, "keybar:layoutApply left=\(newLayout.left.count) middle=\(newLayout.middle.count) right=\(newLayout.right.count)")
        store.settings.layout = newLayout
    }

    /// Map a fixed KeybarSlot to its FixedKeyID for the swipe-secondary editor.
    /// Only symbol + Tab rows are editable here; F-keys come from the Fn slot
    /// (not a KeybarSlot row) and keep their built-in defaults.
    private func fixedKeyID(for slot: KeybarSlot) -> FixedKeyID? {
        switch slot {
        case .symbol(let s): return .symbol(s)
        case .tab:           return .tab
        default:             return nil
        }
    }

    private func slotLabel(_ slot: KeybarSlot) -> String {
        keybarEditorTitle(for: slot, library: store.settings.library)
    }
}
