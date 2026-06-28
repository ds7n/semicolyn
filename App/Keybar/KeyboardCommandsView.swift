// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// Bridges a pure `KeyboardChord` to SwiftUI's key-equivalent types so the
/// catalog can drive `.keyboardShortcut`.
extension KeyboardChord {
    var keyEquivalent: KeyEquivalent? {
        guard input.count == 1, let ch = input.first else { return nil }
        return KeyEquivalent(ch)
    }
    var eventModifiers: EventModifiers {
        var mods: EventModifiers = []
        if command { mods.insert(.command) }
        if shift { mods.insert(.shift) }
        if control { mods.insert(.control) }
        if option { mods.insert(.option) }
        return mods
    }
}

/// An invisible overlay that registers every hardware-keyboard Cmd-shortcut as a
/// SwiftUI `.keyboardShortcut`, routing each to `vm.perform`. iOS surfaces these
/// in the ⌘-hold discoverability HUD using each button's title (external-keyboard
/// spec "Cmd-shortcut map"). `⌘C` is left to SwiftTerm's native copy and `⌘F`
/// (find-in-scrollback) is deferred to its own slice, so neither is registered.
struct KeyboardCommandsView: View {
    @ObservedObject var vm: ConnectionViewModel

    private var registered: [KeyboardCommandSpec] {
        KeyboardCommandCatalog.all.filter { $0.command != .copy && $0.command != .find }
    }

    var body: some View {
        ZStack {
            ForEach(Array(registered.enumerated()), id: \.offset) { _, spec in
                if let key = spec.chord.keyEquivalent {
                    Button(spec.title) { vm.perform(spec.command) }
                        .keyboardShortcut(key, modifiers: spec.chord.eventModifiers)
                }
            }
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
