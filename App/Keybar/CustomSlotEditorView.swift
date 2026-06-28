// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// Editor for a custom slot: a label/glyph override plus up to four gesture
/// bindings (tap / swipe-up / swipe-down / long-press), each pointing at a macro.
/// Save is gated on at least one binding. Assigning a binding opens the macro
/// library picker, whose "New macro" entry doubles as the spec's "Record new"
/// (keybar-customization spec "Editing custom slots").
struct CustomSlotEditorView: View {
    @ObservedObject var store: KeybarSettingsStore
    @Environment(\.dismiss) private var dismiss

    /// Existing slot id, or nil when creating a new slot.
    private let editingID: CustomSlotID?

    @State private var label: String
    @State private var bindings: [CustomSlotGesture: GestureBinding]
    @State private var pickingGesture: CustomSlotGesture?

    init(store: KeybarSettingsStore, slot: CustomSlot?) {
        _store = ObservedObject(wrappedValue: store)
        editingID = slot?.id
        _label = State(initialValue: slot?.label ?? "")
        var dict: [CustomSlotGesture: GestureBinding] = [:]
        if let slot {
            for gesture in CustomSlotGesture.allCases { dict[gesture] = slot.binding(for: gesture) }
        }
        _bindings = State(initialValue: dict)
    }

    private var working: CustomSlot {
        CustomSlot(id: editingID ?? CustomSlotID("draft"),
                   label: label.isEmpty ? nil : label,
                   tap: bindings[.tap], swipeUp: bindings[.swipeUp],
                   swipeDown: bindings[.swipeDown], longPress: bindings[.longPress])
    }

    var body: some View {
        Form {
            Section {
                TextField("Label / glyph (optional)", text: $label)
            } footer: {
                Text("Shown on the slot. If blank, the slot uses the tapped macro's name.")
            }

            Section("Gestures") {
                ForEach(CustomSlotGesture.allCases, id: \.self) { gesture in
                    bindingRow(gesture)
                }
            }

            if let id = editingID {
                Section {
                    Button("Delete slot", role: .destructive) {
                        store.deleteCustomSlot(id)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(editingID == nil ? "New slot" : "Edit slot")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.disabled(!working.isValid)
            }
        }
        .sheet(item: $pickingGesture) { gesture in
            NavigationStack {
                MacroLibraryView(store: store) { macro in
                    bindings[gesture] = GestureBinding(macro: macro.id)
                }
            }
        }
    }

    @ViewBuilder private func bindingRow(_ gesture: CustomSlotGesture) -> some View {
        HStack {
            Text(gestureLabel(gesture))
            Spacer()
            Text(boundName(gesture)).foregroundStyle(.secondary)
            if bindings[gesture] != nil {
                Button {
                    bindings[gesture] = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Clear \(gestureLabel(gesture)) binding")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { pickingGesture = gesture }
    }

    private func boundName(_ gesture: CustomSlotGesture) -> String {
        guard let binding = bindings[gesture] else { return "Unbound" }
        return store.settings.library.macro(binding.macro)?.name ?? "Missing macro"
    }

    private func gestureLabel(_ gesture: CustomSlotGesture) -> String {
        switch gesture {
        case .tap:       return "Tap"
        case .swipeUp:   return "Swipe up"
        case .swipeDown: return "Swipe down"
        case .longPress: return "Long-press"
        }
    }

    private func save() {
        guard working.isValid else { return }
        let id = editingID ?? store.mintCustomSlotID()
        let slot = CustomSlot(id: id, label: label.isEmpty ? nil : label,
                              tap: bindings[.tap], swipeUp: bindings[.swipeUp],
                              swipeDown: bindings[.swipeDown], longPress: bindings[.longPress])
        store.saveCustomSlot(slot)
        if editingID == nil { store.appendToScroll(.custom(id)) }
        dismiss()
    }
}

/// Lets `CustomSlotGesture` drive a `.sheet(item:)` for the macro picker.
extension CustomSlotGesture: Identifiable {
    public var id: String { rawValue }
}
