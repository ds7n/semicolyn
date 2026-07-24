// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// Shared slot chrome: themed background + label, uniform min size. When a slot has
/// swipe secondaries, they render as a small accent-tinted column to the RIGHT of the
/// label: swipe-up glyph on top, swipe-down below. A single-direction key fills only its
/// slot; the other is an invisible spacer so the main label stays vertically centered
/// (device issue #2: replaces the old edge-pinned overlay glyphs).
struct SlotChrome<Label: View>: View {
    let bg: Color
    var up: String? = nil
    var down: String? = nil
    @Environment(\.theme) private var theme
    @ViewBuilder var label: () -> Label

    private var hasHints: Bool { up != nil || down != nil }

    var body: some View {
        HStack(spacing: 3) {
            label()
            if hasHints {
                VStack(spacing: 0) {
                    hintText(up)
                    hintText(down)
                }
            }
        }
        .frame(minWidth: 36, minHeight: 27)   // tightened input area (2026-07-24): 34→27 row, still tappable
        .padding(.horizontal, 6)
        .background(bg)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// One hint glyph, or an invisible spacer of the same metrics when the direction is
    /// unbound (keeps the main label centered and both single-swipe directions aligned).
    @ViewBuilder private func hintText(_ s: String?) -> some View {
        Text(s ?? " ")
            .font(.system(size: 8, design: .monospaced))
            .foregroundStyle(Color(theme.accent.primary))
            .opacity(s == nil ? 0 : 0.85)
    }
}

/// A plain symbol slot (tap = send the literal character).
struct SymbolSlotView: View {
    let symbol: String
    let vm: ConnectionViewModel
    let keybarSettings: KeybarSettingsStore
    @Environment(\.theme) private var theme
    var body: some View {
        let secondaries = resolveSecondaries(for: .symbol(symbol),
                                             overrides: keybarSettings.settings.fixedKeySecondaries)
        let g = hintGlyphs(for: secondaries)
        SlotChrome(bg: Color(theme.keybar.slotBg), up: g.up, down: g.down) {
            Text(symbol).font(.system(.body, design: .monospaced)).foregroundStyle(Color(theme.text.primary))
        }
        .onInputClickTap { if let c = symbol.first { vm.keybar.tapSymbol(c) } }
        .fixedKeySwipes(secondaries) { v in vm.keybar.emitSecondary(v) }
    }
}

/// Tab slot.
struct TabSlotView: View {
    let vm: ConnectionViewModel
    let keybarSettings: KeybarSettingsStore
    @Environment(\.theme) private var theme
    var body: some View {
        let secondaries = resolveSecondaries(for: .tab,
                                             overrides: keybarSettings.settings.fixedKeySecondaries)
        let g = hintGlyphs(for: secondaries)
        SlotChrome(bg: Color(theme.keybar.slotBg), up: g.up, down: g.down) {
            Text("⇥").foregroundStyle(Color(theme.text.primary))
        }
        .onInputClickTap { vm.keybar.tapTab() }
        .fixedKeySwipes(secondaries) { v in vm.keybar.emitSecondary(v) }
    }
}

// MARK: - Fixed-key swipe secondaries

extension View {
    /// The swipe-up / swipe-down gesture that emits a fixed key's secondaries. The hint
    /// GLYPHS are rendered by SlotChrome's column (fed hintGlyphs(for:)); this modifier is
    /// now gesture-only (device #2 removed the edge-pinned overlay glyphs).
    func fixedKeySwipes(_ secondaries: SwipeSecondaries,
                        emit: @escaping (SecondaryValue) -> Void) -> some View {
        self.gesture(DragGesture(minimumDistance: 12).onEnded { g in
            if g.translation.height < -12, let up = secondaries.up { emit(up) }
            else if g.translation.height > 12, let down = secondaries.down { emit(down) }
        })
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
        .onInputClickTap { vm.keybar.tapCtrl() }
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
        .onInputClickTap { vm.keybar.tapEscape() }
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
        .onInputClickTap {
            DebugLog.shared.log(.keybar, "keybar:macroResolved events=\(macro.body.count)")
            vm.keybar.fireMacro(macro.body)
        }
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
        DebugLog.shared.log(.keybar, "keybar:macroResolved events=\(body.count)")
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
        .onInputClickTap { fire(.tap) }
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

/// Pad: SWIPE = arrow key in the swiped (dominant-axis) direction, and HOLDING the swipe
/// auto-repeats it iOS-style (distance picks direction, held-time drives the rate; see
/// SemicolynKit `ArrowRepeat`). No tap action: the pad is purely a directional control
/// (device 2026-07-20: tap used to zoom the active pane, so a press meant to send an arrow
/// zoomed a pane instead). Zoom lives on the long-press-pane gesture elsewhere.
struct PadView: View {
    let vm: ConnectionViewModel
    @Environment(\.theme) private var theme

    @State private var heldSince: Date?                 // set on the first crossing; nil = not held
    @State private var lastTranslation: CGSize = .zero  // latest dx/dy, updated every onChanged
    @State private var repeatTimer: Timer?

    var body: some View {
        SlotChrome(bg: Color(theme.keybar.slotBg)) {
            Image(systemName: "dpad").foregroundStyle(Color(theme.text.primary))
        }
        .gesture(
            DragGesture(minimumDistance: 16)
                .onChanged { g in
                    lastTranslation = g.translation           // always track the latest thumb pos
                    guard heldSince == nil else { return }     // already holding; timer drives it
                    fireArrow()                                // first fire on crossing 16pt
                    heldSince = Date()
                    DebugLog.shared.log(.keybar,
                        "keybar:dpad swipe dx=\(Int(g.translation.width)) dy=\(Int(g.translation.height)) -> arrow=\(dominantArrow(dx: g.translation.width, dy: g.translation.height))")
                    DebugLog.shared.log(.keybar, "keybar:dpad repeat start")
                    scheduleNextRepeat()
                }
                .onEnded { _ in stopRepeat() }
        )
    }

    /// Fire the arrow for the current thumb direction.
    private func fireArrow() {
        vm.keybar.arrow(dominantArrow(dx: lastTranslation.width, dy: lastTranslation.height))
    }

    /// Re-arm the repeat timer: ask the Kit decider for the interval at the current held-time.
    /// While still in the initial-delay window it returns nil; poll again at the remaining delay.
    private func scheduleNextRepeat() {
        guard let since = heldSince else { return }
        let held = Date().timeIntervalSince(since)
        let delay: TimeInterval
        let shouldFire: Bool
        if let interval = ArrowRepeat.interval(heldFor: held) {
            delay = interval
            shouldFire = true
        } else {
            delay = max(0.01, ArrowRepeat.initialDelay - held)   // wait out the remaining delay
            shouldFire = false
        }
        repeatTimer?.invalidate()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard self.heldSince != nil else { return }      // released between arm and fire
                if shouldFire { self.fireArrow() }
                self.scheduleNextRepeat()
            }
        }
    }

    /// Stop repeating and reset held state (on release).
    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        heldSince = nil
    }
}
