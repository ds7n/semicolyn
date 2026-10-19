// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// The keyboard accessory bar. Left and right regions render fixed at their
/// edges; the middle region pans horizontally and absorbs the slack. The
/// composition comes from the user's persisted `KeybarSettings`.
struct KeybarView: View {
    @ObservedObject var keybarSettings: KeybarSettingsStore
    @ObservedObject var vm: ConnectionViewModel
    /// True when a hardware keyboard is connected, the bar shrinks to its compact
    /// built-in subset, or hides entirely per the user's setting (4e).
    var hardwareKeyboardConnected: Bool = false
    @Environment(\.theme) private var theme
    /// Opens Settings→Keybar (long-press the Esc pill). Seed of the spec's
    /// unified picker; the rest of that picker is a later slice.
    @State private var showingSettings = false

    private var layout: KeybarLayout { keybarSettings.settings.layout }

    /// Hardware keyboard connected + the user opted to hide the keybar (4e). The
    /// predictor strip is governed independently and stays put.
    private var hidden: Bool {
        hardwareKeyboardConnected && keybarSettings.settings.hideKeybarWithHardwareKeyboard
    }

    var body: some View {
        Group {
            if hidden {
                EmptyView()
            } else if hardwareKeyboardConnected {
                barChrome { compactContent }
            } else {
                barChrome { fullContent }
            }
        }
        // The UIInputViewAudioFeedback context for `UIDevice.playInputClick()` is now
        // provided by `KeybarInputAccessory` (this keybar is hosted as the terminal's
        // real inputAccessoryView), so no in-view audio-feedback host is needed here.
        .sheet(isPresented: $showingSettings, onDismiss: { vm.requestKeyboardFocus() }) {
            SettingsView(context: .inSession, keybarSettings: keybarSettings,
                         session: vm.sessionControls)
        }
    }

    /// Shared bar chrome: themed panel background + insets.
    ///
    /// Device #2 (Build 2): the full-width frame must align its content `.leading`, or SwiftUI
    /// centers/distributes the bar's HStack across the full width and the locked keys spread
    /// edge-to-edge with large gaps. `.leading` packs them at the leading edge (the Build-1
    /// probe on the inner ScrollView was the wrong element; this is the real fix).
    @ViewBuilder private func barChrome<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(.horizontal, 4).padding(.vertical, 2)   // tightened input area (2026-07-24): 3→2; sides 8→4 (2026-10-12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(theme.surface.panel))
    }

    /// Full bar: fixed left + horizontally scrolling middle + fixed right.
    /// The middle ScrollView takes `maxWidth: .infinity`, so it owns all slack and
    /// both fixed regions pack tight against their edges. A hairline divider is
    /// overlaid in the 3pt gap at each region boundary, so it takes no space.
    private var fullContent: some View {
        HStack(spacing: 3) {
            if !layout.left.isEmpty {
                HStack(spacing: 3) {
                    ForEach(Array(layout.left.enumerated()), id: \.offset) { _, slot in
                        slotView(slot)
                    }
                }
                .overlay(alignment: .trailing) { regionDivider.offset(x: 2) }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(Array(scrollItems.enumerated()), id: \.offset) { _, item in
                        scrollItemView(item)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !layout.right.isEmpty {
                HStack(spacing: 3) {
                    ForEach(Array(layout.right.enumerated()), id: \.offset) { _, slot in
                        slotView(slot)
                    }
                }
                .overlay(alignment: .leading) { regionDivider.offset(x: -2) }
            }
        }
    }

    /// A subtle 1pt line centered in the gap between two regions (offset ±2 from
    /// the region edge = half the 3pt spacing plus half the line).
    private var regionDivider: some View {
        Capsule()
            .fill(Color(theme.text.secondary).opacity(0.35))
            .frame(width: 1, height: 18)
            .allowsHitTesting(false)
    }

    /// Compact bar (hardware keyboard): built-in widgets from the fixed regions
    /// only, each kept on its own side; no middle (4e "Keybar behavior").
    private var compactContent: some View {
        let compact = compactKeybarSlots(left: layout.left, right: layout.right)
        return HStack(spacing: 3) {
            ForEach(Array(compact.left.enumerated()), id: \.offset) { _, slot in
                slotView(slot)
            }
            Spacer(minLength: 0)
            ForEach(Array(compact.right.enumerated()), id: \.offset) { _, slot in
                slotView(slot)
            }
        }
    }

    private var scrollItems: [KeybarScrollItem] {
        keybarScrollItems(scrollSlots: layout.middle,
                          fnEngaged: vm.fnState.engaged)
    }

    @ViewBuilder private func scrollItemView(_ item: KeybarScrollItem) -> some View {
        switch item {
        case .fkey(let n):    FkeySlotView(n: n, vm: vm, keybarSettings: keybarSettings)
        case .slot(let slot): slotView(slot)
        }
    }

    @ViewBuilder private func slotView(_ slot: KeybarSlot) -> some View {
        switch slot {
        case .escPill:        EscPillView(vm: vm, onOpenSettings: { showingSettings = true })
        case .pad:            PadView(vm: vm)
        case .modifier:       ModifierSlotView(ctrl: vm.keybar.modifiers.ctrl, vm: vm)
        case .tab:            TabSlotView(vm: vm, keybarSettings: keybarSettings)
        case .fn:             FnSlotView(mode: vm.fnState.mode, vm: vm)
        case .symbol(let s):  SymbolSlotView(symbol: s, vm: vm, keybarSettings: keybarSettings)
        case .pinnedMacro(let id):
            if let macro = keybarSettings.settings.library.macro(id) {
                PinnedMacroSlotView(macro: macro, vm: vm)
            } else {
                MissingSlotView()
            }
        case .custom(let id):
            if let slot = keybarSettings.settings.library.customSlot(id) {
                CustomSlotView(slot: slot, library: keybarSettings.settings.library, vm: vm)
            } else {
                MissingSlotView()
            }
        }
    }
}
