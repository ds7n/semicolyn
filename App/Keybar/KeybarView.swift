// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// The keyboard accessory bar. Locked region renders fixed at the leading edge;
/// the scroll region pans horizontally. 4d drives the composition from the
/// user's persisted `KeybarSettings`; reverse-bar flips the whole layout via
/// `layoutDirection` (a pure mirror — gestures are unaffected, per spec).
struct KeybarView: View {
    @ObservedObject var keybarSettings: KeybarSettingsStore
    @ObservedObject var vm: ConnectionViewModel
    /// True when a hardware keyboard is connected — the bar shrinks to its compact
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
        // Reverse-bar: a layout-mirror only. RTL flips HStack order + the
        // ScrollView's leading edge so the locked region anchors right and the
        // Esc pill lands far-right; DragGesture translations are unaffected, so
        // gesture semantics stay physical (keybar-customization spec).
        .environment(\.layoutDirection,
                     keybarSettings.settings.direction == .lockedRight ? .rightToLeft : .leftToRight)
        .sheet(isPresented: $showingSettings) {
            SettingsView(context: .inSession, keybarSettings: keybarSettings)
        }
    }

    /// Shared bar chrome: themed panel background + insets.
    @ViewBuilder private func barChrome<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(Color(theme.surface.panel))
    }

    /// Full bar: locked region + horizontally-scrollable region.
    private var fullContent: some View {
        HStack(spacing: 6) {
            ForEach(Array(layout.locked.enumerated()), id: \.offset) { _, slot in
                slotView(slot)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(scrollItems.enumerated()), id: \.offset) { _, item in
                        scrollItemView(item)
                    }
                }
            }
        }
    }

    /// Compact bar (hardware keyboard): the built-in widgets from the user's
    /// locked region only — no scroll region (4e "Keybar behavior").
    private var compactContent: some View {
        HStack(spacing: 6) {
            ForEach(Array(compactKeybarSlots(locked: layout.locked).enumerated()), id: \.offset) { _, slot in
                slotView(slot)
            }
        }
    }

    private var scrollItems: [KeybarScrollItem] {
        keybarScrollItems(promotions: vm.activePromotions,
                          scrollSlots: layout.scroll,
                          fnEngaged: vm.fnState.engaged)
    }

    @ViewBuilder private func scrollItemView(_ item: KeybarScrollItem) -> some View {
        switch item {
        case .promotion(let s): PromotionSlotView(slot: s, vm: vm)
        case .fkey(let n):      FkeySlotView(n: n, vm: vm)
        case .slot(let slot):   slotView(slot)
        }
    }

    @ViewBuilder private func slotView(_ slot: KeybarSlot) -> some View {
        switch slot {
        case .escPill:        EscPillView(vm: vm, onOpenSettings: { showingSettings = true })
        case .pad:            PadView(vm: vm)
        case .modifier:       ModifierSlotView(ctrl: vm.keybar.modifiers.ctrl, vm: vm)
        case .tab:            TabSlotView(vm: vm)
        case .fn:             FnSlotView(mode: vm.fnState.mode, vm: vm)
        case .symbol(let s):  SymbolSlotView(symbol: s, vm: vm)
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
