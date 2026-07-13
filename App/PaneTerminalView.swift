// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftTerm

/// SwiftTerm delivers `bufferActivated` / `mouseModeChanged` (the alt-screen and
/// mouse-mode transition events) to the `TerminalView` INSTANCE via the emulator
/// `TerminalDelegate` — NOT to the app's `TerminalViewDelegate`. `TerminalView`
/// declares them `open` for exactly this: subclass and override. We `super`-call
/// first (preserve SwiftTerm's own scroller / mouse-pan-gesture side effects), then
/// hand the live `Terminal` to `onModeRelevantChange`, which each mount wires to its
/// `PaneModeTracker.recompute(...)`.
final class PaneTerminalView: TerminalView {
    /// Set by the mount right after construction. Called on every alt-screen or
    /// mouse-mode transition with this view's emulator terminal.
    var onModeRelevantChange: ((Terminal) -> Void)?

    override func bufferActivated(source: Terminal) {
        super.bufferActivated(source: source)
        onModeRelevantChange?(source)
    }
    override func mouseModeChanged(source: Terminal) {
        super.mouseModeChanged(source: source)
        onModeRelevantChange?(source)
    }
}
