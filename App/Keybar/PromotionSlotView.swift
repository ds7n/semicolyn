// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// A context-promoted slot: bronze fill, primary char on tap, optional swipe
/// secondaries (context-detection spec "Promoted slot visual").
struct PromotionSlotView: View {
    let slot: PromotionSlot
    let vm: ConnectionViewModel
    @Environment(\.theme) private var theme
    var body: some View {
        VStack(spacing: 0) {
            if let up = slot.up { Text(up).font(.system(size: 9)).foregroundStyle(Color(theme.text.secondary)) }
            Text(slot.tap).font(.system(.body, design: .monospaced)).foregroundStyle(Color(theme.text.primary))
            if let down = slot.down { Text(down).font(.system(size: 9)).foregroundStyle(Color(theme.text.secondary)) }
        }
        .frame(minWidth: 40, minHeight: 34).padding(.horizontal, 6)
        .background(Color(theme.keybar.slotBgPromoted))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onInputClickTap { if let c = slot.tap.first { vm.keybar.tapSymbol(c) } }
        .gesture(DragGesture(minimumDistance: 12).onEnded { g in
            if g.translation.height < -12, let u = slot.up?.first { vm.keybar.tapSymbol(u) }
            else if g.translation.height > 12, let d = slot.down?.first { vm.keybar.tapSymbol(d) }
        })
    }
}

/// A function-key slot (F1–F12) shown while Fn mode is engaged.
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

/// The Fn toggle slot. Background reflects Fn mode (armed/locked). A single tap
/// recognizer cycles off→armed→locked→off (`vm.fnTap()`); the former `count:2`
/// double-tap-to-lock was removed because the sibling recognizer forced SwiftUI
/// to wait out the double-tap window before firing the tap, which felt laggy.
/// Manual lock is now the second tap of the cycle; auto-engage still locks
/// directly (context-detection spec).
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
    var body: some View {
        Text("Fn").font(.caption).foregroundStyle(Color(theme.text.primary))
            .frame(minWidth: 40, minHeight: 34).padding(.horizontal, 6)
            .background(bg).clipShape(RoundedRectangle(cornerRadius: 6))
            .onInputClickTap { vm.fnTap() }
    }
}
