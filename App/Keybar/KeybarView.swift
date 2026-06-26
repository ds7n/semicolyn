// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import NeotildeKit

/// The keyboard accessory bar. Locked region renders fixed at the leading edge;
/// the scroll region pans horizontally. 4a renders `KeybarLayout.default`;
/// customization (4d) will supply a user layout.
struct KeybarView: View {
    let layout: KeybarLayout
    @ObservedObject var vm: ConnectionViewModel
    @Environment(\.theme) private var theme

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
    }

    private var scrollItems: [KeybarScrollItem] {
        let symbols = layout.scroll.compactMap { slot -> String? in
            if case .symbol(let s) = slot { return s } else { return nil }
        }
        return keybarScrollItems(promotions: vm.activePromotions,
                                 defaultSymbols: symbols,
                                 fnEngaged: vm.fnState.engaged)
    }

    @ViewBuilder private func scrollItemView(_ item: KeybarScrollItem) -> some View {
        switch item {
        case .promotion(let s): PromotionSlotView(slot: s, vm: vm)
        case .symbol(let s):    SymbolSlotView(symbol: s, vm: vm)
        case .fn:               FnSlotView(mode: vm.fnState.mode, vm: vm)
        case .fkey(let n):      FkeySlotView(n: n, vm: vm)
        }
    }

    @ViewBuilder private func slotView(_ slot: KeybarSlot) -> some View {
        switch slot {
        case .escPill:        EscPillView(vm: vm)
        case .pad:            PadView(vm: vm)
        case .modifier:       ModifierSlotView(ctrl: vm.keybar.modifiers.ctrl, vm: vm)
        case .tab:            TabSlotView(vm: vm)
        case .symbol(let s):  SymbolSlotView(symbol: s, vm: vm)
        }
    }
}
