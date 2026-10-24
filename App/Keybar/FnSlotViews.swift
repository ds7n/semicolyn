// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// A function-key slot (F1-F12) shown while Fn mode is engaged.
struct FkeySlotView: View {
    let n: Int
    let vm: ConnectionViewModel
    let keybarSettings: KeybarSettingsStore
    @Environment(\.theme) private var theme
    var body: some View {
        let secondaries = resolveSecondaries(for: .fkey(n),
                                             overrides: keybarSettings.settings.fixedKeySecondaries)
        let g = hintGlyphs(for: secondaries)
        SlotChrome(bg: Color(theme.keybar.slotBg), up: g.up, down: g.down) {
            Text("F\(n)").font(.caption).foregroundStyle(Color(theme.text.primary))
        }
        .onInputClickTap { vm.fnTapFKey(n) }   // sends F-key + consumes one-shot Fn (Task 5)
        .fixedKeySwipes(secondaries) { v in vm.keybar.emitSecondary(v) }
    }
}

/// The Fn toggle slot. Background reflects Fn mode (armed/locked), and a locked Fn
/// also shows a small lock glyph so the two on states read differently. A single tap
/// recognizer cycles off->armed->locked->off (`vm.fnTap()`); the former `count:2`
/// double-tap-to-lock was removed because the sibling recognizer forced SwiftUI
/// to wait out the double-tap window before firing the tap, which felt laggy.
/// Lock is now the second tap of the cycle.
struct FnSlotView: View {
    let mode: FnMode
    let vm: ConnectionViewModel
    @Environment(\.theme) private var theme
    private var bg: Color {
        switch mode {
        case .locked: return Color(theme.keybar.slotBgLocked)
        case .armed:  return Color(theme.keybar.slotBgArmed)
        case .off:    return Color(theme.keybar.slotBg)
        }
    }
    private var fnAccessibilityLabel: String {
        switch mode {
        case .locked: return "Fn, locked"
        case .armed:  return "Fn, on for one key"
        case .off:    return "Fn"
        }
    }
    var body: some View {
        SlotChrome(bg: bg) {
            HStack(spacing: 1) {
                Text("Fn").font(.caption)
                if mode == .locked {
                    Image(systemName: "lock.fill").font(.system(size: 7, weight: .semibold))
                }
            }
            .foregroundStyle(Color(theme.text.primary))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(fnAccessibilityLabel)
        .onInputClickTap { vm.fnTap() }
    }
}
