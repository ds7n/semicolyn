// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// Shared slot chrome: themed background + label, fixed min size.
private struct SlotChrome<Label: View>: View {
    let bg: Color
    @ViewBuilder var label: () -> Label
    var body: some View {
        label()
            .frame(minWidth: 34, minHeight: 34)
            .padding(.horizontal, 6)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// A plain symbol slot (tap = send the literal character).
struct SymbolSlotView: View {
    let symbol: String
    let vm: ConnectionViewModel
    @Environment(\.theme) private var theme
    var body: some View {
        SlotChrome(bg: Color(theme.keybar.slotBg)) {
            Text(symbol).font(.system(.body, design: .monospaced)).foregroundStyle(Color(theme.text.primary))
        }
        .onTapGesture { if let c = symbol.first { vm.keybar.tapSymbol(c) } }
    }
}

/// Tab slot.
struct TabSlotView: View {
    let vm: ConnectionViewModel
    @Environment(\.theme) private var theme
    var body: some View {
        SlotChrome(bg: Color(theme.keybar.slotBg)) {
            Text("⇥").foregroundStyle(Color(theme.text.primary))
        }
        .onTapGesture { vm.keybar.tapTab() }
    }
}

/// Modifier slot: tap=arm Ctrl (one-shot), swipe-up=Alt, swipe-down=Shift.
/// A single tap recognizer — no double-tap sibling — so the arm fires the instant
/// the finger lifts (a `count:2` sibling forced SwiftUI to wait out the
/// double-tap window first, which felt laggy).
struct ModifierSlotView: View {
    let ctrl: CtrlState
    let vm: ConnectionViewModel
    @Environment(\.theme) private var theme
    private var bg: Color {
        switch ctrl {
        case .armed: return Color(theme.keybar.slotBgArmed)
        case .off:   return Color(theme.keybar.slotBg)
        }
    }
    var body: some View {
        SlotChrome(bg: bg) {
            Text("⌃").foregroundStyle(Color(theme.text.primary))
        }
        .onTapGesture { vm.keybar.tapCtrl() }
        .gesture(DragGesture(minimumDistance: 12).onEnded { g in
            if g.translation.height < -12 { vm.keybar.armAlt() }
            else if g.translation.height > 12 { vm.keybar.armShift() }
        })
    }
}

/// Esc pill: tap=Esc; swipe-left/right = prev/next window; long-press opens the
/// Settings tree (4d wires the Settings→Keybar leaf; the full unified picker —
/// windows/hosts/recent — is a later slice). The dim `≡` glyph hints at the
/// extra gestures (keybar-customization spec "Esc pill → Visual").
struct EscPillView: View {
    let vm: ConnectionViewModel
    /// Invoked on long-press to surface the Settings tree.
    var onOpenSettings: () -> Void = {}
    @Environment(\.theme) private var theme
    var body: some View {
        SlotChrome(bg: Color(theme.keybar.slotBg)) {
            ZStack(alignment: .topTrailing) {
                Text("Esc").font(.caption).foregroundStyle(Color(theme.text.primary))
                Text("≡").font(.system(size: 8))
                    .foregroundStyle(Color(theme.text.secondary))
                    .offset(x: 4, y: -3)
            }
        }
        .onTapGesture { vm.keybar.tapEscape() }
        .onLongPressGesture { onOpenSettings() }
        .gesture(DragGesture(minimumDistance: 18).onEnded { g in
            if g.translation.width > 18 { vm.selectNextWindow() }
            else if g.translation.width < -18 { vm.selectPrevWindow() }
        })
    }
}

/// A macro pinned directly to the bar (a `.pinnedMacro` slot): tap fires the
/// recorded body via the input router. (keybar-customization spec "Macro library
/// → pinning".)
struct PinnedMacroSlotView: View {
    let macro: Macro
    let vm: ConnectionViewModel
    @Environment(\.theme) private var theme
    var body: some View {
        SlotChrome(bg: Color(theme.keybar.slotBg)) {
            Text(macro.name).font(.caption).lineLimit(1)
                .foregroundStyle(Color(theme.text.primary))
        }
        .onTapGesture { vm.keybar.fireMacro(macro.body) }
    }
}

/// A user-created custom slot (a `.custom` slot): up to four gesture bindings,
/// each firing a macro from the library. The primary label resolves per spec; dim
/// edge glyphs hint at bound swipe-up/down, and a corner `≡` hints at long-press
/// (keybar-customization spec "Slot display content").
struct CustomSlotView: View {
    let slot: CustomSlot
    let library: KeybarLibrary
    let vm: ConnectionViewModel
    @Environment(\.theme) private var theme

    private var label: String {
        slot.displayLabel(macroName: { library.macro($0)?.name }) ?? "·"
    }

    /// Fires the macro bound to `gesture`, if any (orphaned refs are no-ops).
    private func fire(_ gesture: CustomSlotGesture) {
        guard let binding = slot.binding(for: gesture),
              let body = library.macro(binding.macro)?.body else { return }
        vm.keybar.fireMacro(body)
    }

    var body: some View {
        SlotChrome(bg: Color(theme.keybar.slotBg)) {
            Text(label).font(.system(.body, design: .monospaced)).lineLimit(1)
                .foregroundStyle(Color(theme.text.primary))
        }
        .overlay(alignment: .top) {
            if slot.swipeUp != nil { hintGlyph("˄") }
        }
        .overlay(alignment: .bottom) {
            if slot.swipeDown != nil { hintGlyph("˅") }
        }
        .overlay(alignment: .topTrailing) {
            if slot.longPress != nil { hintGlyph("≡").offset(x: -2, y: 2) }
        }
        .onTapGesture { fire(.tap) }
        .onLongPressGesture { fire(.longPress) }
        .gesture(DragGesture(minimumDistance: 12).onEnded { g in
            if g.translation.height < -12 { fire(.swipeUp) }
            else if g.translation.height > 12 { fire(.swipeDown) }
        })
    }

    private func hintGlyph(_ s: String) -> some View {
        Text(s).font(.system(size: 7)).foregroundStyle(Color(theme.text.secondary))
    }
}

/// A dim placeholder for a slot whose library entry is missing (orphaned id) —
/// defensive only; the store prunes references on delete.
struct MissingSlotView: View {
    @Environment(\.theme) private var theme
    var body: some View {
        SlotChrome(bg: Color(theme.keybar.slotBg)) {
            Text("?").foregroundStyle(Color(theme.text.secondary))
        }
    }
}

/// Pad: drag = arrow key (dominant axis), tap = zoom active pane.
/// (Long-press pane-mode + splits = a later slice.)
struct PadView: View {
    let vm: ConnectionViewModel
    @Environment(\.theme) private var theme
    var body: some View {
        SlotChrome(bg: Color(theme.keybar.slotBg)) {
            Image(systemName: "dpad").foregroundStyle(Color(theme.text.primary))
        }
        .onTapGesture { vm.zoomActivePane() }
        .gesture(DragGesture(minimumDistance: 16).onEnded { g in
            let dx = g.translation.width, dy = g.translation.height
            if abs(dx) > abs(dy) { vm.keybar.arrow(dx > 0 ? .right : .left) }
            else { vm.keybar.arrow(dy > 0 ? .down : .up) }
        })
    }
}
