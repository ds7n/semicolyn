// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import NeotildeKit

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
        .frame(minWidth: 34, minHeight: 34).padding(.horizontal, 6)
        .background(Color(theme.keybar.slotBgPromoted))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture { if let c = slot.tap.first { vm.keybar.tapSymbol(c) } }
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
    @Environment(\.theme) private var theme
    var body: some View {
        Text("F\(n)").font(.caption).foregroundStyle(Color(theme.text.primary))
            .frame(minWidth: 34, minHeight: 34).padding(.horizontal, 6)
            .background(Color(theme.keybar.slotBg))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onTapGesture { vm.fnTapFKey(n) }   // sends F-key + consumes one-shot Fn (Task 5)
    }
}

/// The Fn toggle slot. Background reflects Fn mode (armed/locked). Gestures land
/// in Task 5 via `vm.fnTap()` / `vm.fnDoubleTap()`.
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
            .frame(minWidth: 34, minHeight: 34).padding(.horizontal, 6)
            .background(bg).clipShape(RoundedRectangle(cornerRadius: 6))
            .onTapGesture(count: 2) { vm.fnDoubleTap() }
            .onTapGesture(count: 1) { vm.fnTap() }
    }
}
