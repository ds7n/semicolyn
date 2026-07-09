// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// Per-key override editor for a fixed key's swipe-up/down secondaries. Each
/// direction is None / Literal / Special-key(+modifiers). Writes the whole
/// SwipeSecondaries pair to `store.settings.fixedKeySecondaries[id]`; "Clear
/// override" removes the entry (reverts to the built-in default).
struct FixedKeySecondaryEditorView: View {
    @ObservedObject var store: KeybarSettingsStore
    let id: FixedKeyID
    @Environment(\.dismiss) private var dismiss

    private var effective: SwipeSecondaries {
        resolveSecondaries(for: id, overrides: store.settings.fixedKeySecondaries)
    }

    var body: some View {
        Form {
            Section("Swipe up")  { directionEditor(\.up) }
            Section("Swipe down"){ directionEditor(\.down) }
            Section {
                Button("Clear override (use defaults)", role: .destructive) {
                    store.settings.fixedKeySecondaries[id] = nil
                }
            }
        }
        .navigationTitle(title)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { InputClickFeedback.play(); dismiss() } } }
    }

    private var title: String {
        switch id {
        case .symbol(let s): return "Swipe: \(s)"
        case .tab: return "Swipe: Tab"
        case .fkey(let n): return "Swipe: F\(n)"
        }
    }

    /// Editor for one direction (keyPath into SwipeSecondaries). Reads/writes the
    /// override map, seeding from the current effective value.
    @ViewBuilder
    private func directionEditor(_ dir: WritableKeyPath<SwipeSecondaries, SecondaryValue?>) -> some View {
        let current = effective[keyPath: dir]
        // Mode picker: None / Literal / Key
        Picker("Action", selection: Binding(
            get: { mode(of: current) },
            set: { setMode($0, dir: dir) })) {
                Text("None").tag(0); Text("Literal").tag(1); Text("Special key").tag(2)
        }.pickerStyle(.segmented)

        if case .literal(let s)? = binding(dir).wrappedValue {
            TextField("Character(s)", text: Binding(
                get: { s },
                set: { writeOverride(dir: dir, .literal($0)) }))
                .autocorrectionDisabled()
        } else if case .key(let input, let mods)? = binding(dir).wrappedValue {
            keyPicker(input: input, mods: mods, dir: dir)
        }
    }

    // Helpers: mode(of:), setMode, writeOverride, binding, keyPicker.
    private func mode(of v: SecondaryValue?) -> Int {
        switch v { case .none: return 0; case .literal: return 1; case .key: return 2 }
    }
    private func setMode(_ m: Int, dir: WritableKeyPath<SwipeSecondaries, SecondaryValue?>) {
        switch m {
        case 0: writeOverride(dir: dir, nil)
        case 1: writeOverride(dir: dir, .literal(""))
        default: writeOverride(dir: dir, .key(.tab, KeyModifiers()))
        }
    }
    /// The current override pair for this key (seeded from effective so editing
    /// starts from what the user sees), used to read the live per-direction value.
    private func binding(_ dir: WritableKeyPath<SwipeSecondaries, SecondaryValue?>) -> Binding<SecondaryValue?> {
        Binding(
            get: { (store.settings.fixedKeySecondaries[id] ?? effective)[keyPath: dir] },
            set: { writeOverride(dir: dir, $0) })
    }
    private func writeOverride(dir: WritableKeyPath<SwipeSecondaries, SecondaryValue?>, _ v: SecondaryValue?) {
        var pair = store.settings.fixedKeySecondaries[id] ?? effective
        pair[keyPath: dir] = v
        store.settings.fixedKeySecondaries[id] = pair
    }
    @ViewBuilder
    private func keyPicker(input: KeyInput, mods: KeyModifiers,
                           dir: WritableKeyPath<SwipeSecondaries, SecondaryValue?>) -> some View {
        // Minimal key set for v1: Tab, Esc, Enter, Backspace, F1–F12, arrows.
        Picker("Key", selection: Binding(
            get: { keyTag(input) },
            set: { writeOverride(dir: dir, .key(keyFromTag($0), mods)) })) {
                Text("Tab").tag(0); Text("Esc").tag(1); Text("Enter").tag(2); Text("Backspace").tag(3)
                Text("↑").tag(4); Text("↓").tag(5); Text("←").tag(6); Text("→").tag(7)
                ForEach(1...12, id: \.self) { Text("F\($0)").tag(100 + $0) }
        }
        Toggle("Control", isOn: modBinding(\.control, input: input, mods: mods, dir: dir))
        Toggle("Option",  isOn: modBinding(\.option,  input: input, mods: mods, dir: dir))
        Toggle("Shift",   isOn: modBinding(\.shift,   input: input, mods: mods, dir: dir))
    }
    private func modBinding(_ kp: WritableKeyPath<KeyModifiers, Bool>, input: KeyInput, mods: KeyModifiers,
                            dir: WritableKeyPath<SwipeSecondaries, SecondaryValue?>) -> Binding<Bool> {
        Binding(get: { mods[keyPath: kp] },
                set: { var m = mods; m[keyPath: kp] = $0; writeOverride(dir: dir, .key(input, m)) })
    }
    private func keyTag(_ k: KeyInput) -> Int {
        switch k {
        case .tab: return 0; case .escape: return 1; case .enter: return 2; case .backspace: return 3
        case .arrow(let d): return ["up":4,"down":5,"left":6,"right":7][d.rawValue] ?? 4
        case .function(let n): return 100 + n
        case .char: return 0
        }
    }
    private func keyFromTag(_ t: Int) -> KeyInput {
        switch t {
        case 0: return .tab; case 1: return .escape; case 2: return .enter; case 3: return .backspace
        case 4: return .arrow(.up); case 5: return .arrow(.down); case 6: return .arrow(.left); case 7: return .arrow(.right)
        default: return .function(max(1, min(12, t - 100)))
        }
    }
}
