// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import NeotildeKit

/// The keyboard accessory bar. Locked region renders fixed at the leading edge;
/// the scroll region pans horizontally. 4d drives the composition from the
/// user's persisted `KeybarSettings`; reverse-bar flips the whole layout via
/// `layoutDirection` (a pure mirror — gestures are unaffected, per spec).
struct KeybarView: View {
    @ObservedObject var keybarSettings: KeybarSettingsStore
    @ObservedObject var vm: ConnectionViewModel
    @Environment(\.theme) private var theme
    /// Opens Settings→Keybar (long-press the Esc pill). Seed of the spec's
    /// unified picker; the rest of that picker is a later slice.
    @State private var showingSettings = false

    private var layout: KeybarLayout { keybarSettings.settings.layout }

    var body: some View {
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
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(Color(theme.surface.panel))
        // Reverse-bar: a layout-mirror only. RTL flips HStack order + the
        // ScrollView's leading edge so the locked region anchors right and the
        // Esc pill lands far-right; DragGesture translations are unaffected, so
        // gesture semantics stay physical (keybar-customization spec).
        .environment(\.layoutDirection,
                     keybarSettings.settings.direction == .lockedRight ? .rightToLeft : .leftToRight)
        .sheet(isPresented: $showingSettings) {
            KeybarSettingsSheet(store: keybarSettings)
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
        }
    }
}
