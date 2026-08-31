// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SwiftTerm
import SemicolynKit

/// Phase-1 gate: gesture-driven plain tmux (no `-CC`) vs the existing `-CC` stack.
/// Debug/compile-time only, never persisted per-host. Default OFF so `-CC`/raw
/// stays the byte-for-byte default. Removed in Phase 2 with the `-CC` stack, once
/// the plain-tmux path is device-proven and `-CC` is deleted (see the
/// gesture-driven-plain-tmux design spec's Rollout section).
enum PlainTmuxDebugGate {
    private static let defaultsKey = "semicolyn.debug.plainTmuxGesture"

    #if DEBUG
    /// True only when explicitly flipped via `setEnabledForDebug`; false in every
    /// build that never calls it (including Release), so shipping behavior is
    /// unchanged unless a developer opts in locally.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    /// Debug-only: flip the gate to exercise the plain-tmux route end-to-end.
    /// Removed in Phase 2 alongside the rest of this temporary gate.
    static func setEnabledForDebug(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: defaultsKey)
    }
    #else
    /// Always off outside DEBUG builds: the flag has no setter to flip it on, so
    /// Release/TestFlight always takes the unchanged `-CC`/raw path.
    static var isEnabled: Bool { false }
    #endif
}

/// Launches plain tmux (`tmux new -A -s <name>`, NO `-CC`, NO `set`/mouse
/// mutation) over an already-connected transport and feeds its byte stream
/// straight into the raw `TerminalScreen`/`TerminalView`. Owns the incremental
/// `PaneModel` (Kit, pure) that tracks pane geometry from commands WE issue, the
/// on-tap border-drift validation, and (rare) recovery when the model goes stale
/// (the user changed layout outside our gestures, e.g. a raw `C-b %`/`C-b z`
/// binding, or a second attached client). See the "Pane targeting without -CC"
/// section of the design spec for the full rationale; this type is intentionally
/// thin, all geometry/drift/tap-resolution logic lives in `SemicolynKit.Tmux`.
///
/// Phase 1 limitation (documented, see `onSwitchWindow`): window switching is
/// BLIND (`next-window`/`previous-window`, no window-id tracking), so the model
/// is marked needing-rebuild on every window switch and the first tap after a
/// switch always goes through recovery.
@MainActor
final class PlainTmuxController {
    /// Sends raw bytes to the remote (the transport write, already newline-free;
    /// callers append `\n` themselves via `sendCommand`).
    private let sendInput: ([UInt8]) -> Void
    /// The raw single-pane terminal view feeding this session's rendered grid,
    /// used only to read cells for the on-tap border-drift check (`cellAt`).
    private weak var screen: TerminalView?
    /// Recovers the real layout via a side exec channel (SSH/ET) and returns the
    /// active window's id + parsed layout, or nil if no side channel exists (Mosh)
    /// or the recovery query failed. Owned by `ConnectionViewModel` (it holds the
    /// `Connection`/`openExec` capability, this controller only holds `sendInput`
    /// per the brief's threading note), so plain-tmux recovery composes with
    /// whichever transport connected this session without `PlainTmuxController`
    /// needing to know about `Connection` at all.
    private let recoverLayout: (@Sendable () async -> (window: WindowID, layout: PaneLayout)?)?

    private(set) var model: PaneModel
    /// True after a blind window switch (`onSwitchWindow`) until the next tap
    /// resolves: the tracked model's rects belong to the PREVIOUS window, so the
    /// very next tap must recover rather than trust a stale valid-looking model.
    private var needsRebuildAfterWindowSwitch = false
    private let sessionName: String

    /// - Parameters:
    ///   - sessionName: validated by the caller (`isValidTmuxSessionName`) before
    ///     `launchCommand()` is ever sent; stored as-is.
    ///   - sendInput: raw-byte write to the connected transport (mirrors
    ///     `ConnectionViewModel.rawWriter`/`sendTerminalInput`'s raw branch).
    ///   - screen: the raw `TerminalView` this session renders into, read-only,
    ///     used solely for the on-tap border-drift cell check.
    ///   - recoverLayout: SSH/ET side-channel query, nil on Mosh (see class doc).
    init(sessionName: String,
        sendInput: @escaping ([UInt8]) -> Void,
        screen: TerminalView,
        recoverLayout: (@Sendable () async -> (window: WindowID, layout: PaneLayout)?)? = nil) {
        self.sessionName = sessionName
        self.sendInput = sendInput
        self.screen = screen
        self.recoverLayout = recoverLayout
        let term = screen.getTerminal()
        let cols = max(term.cols, 1)
        let rows = max(term.rows, 1)
        // Placeholder ids: real ones are unknown until the first recovery query
        // (list-windows). Safe for a single-pane model, `applySelectPane`/
        // `resolveTappedPane` only need containment, and no `select-pane` is ever
        // sent for a single-pane window (there's nothing else to select).
        self.model = PaneModel(window: WindowID(raw: 0), pane: PaneID(raw: 0),
                               gridCols: cols, gridRows: rows)
    }

    /// The launch command to run on the transport: plain `tmux new -A -s <name>`.
    /// Deliberately NO `-CC` and NO `set -g mouse on`/other option mutation (the
    /// design's ruled-out list): this must never fight the user's own tmux config.
    func launchCommand() -> String { Self.launchCommand(sessionName: sessionName) }

    /// Static form of `launchCommand()`, usable BEFORE a `PlainTmuxController`
    /// exists: `ConnectionViewModel.attachPlainTmux` opens the launch exec before
    /// the raw `TerminalView` exists (the controller needs that view's live grid,
    /// see `init`, so it is built lazily once the view mounts), so it calls this
    /// directly rather than constructing a controller just to read the string.
    /// Single source of truth for the command format either way.
    static func launchCommand(sessionName: String) -> String {
        "tmux new -A -s \(sessionName)"
    }

    /// Send one command line to the attached tmux (appends the single `\n` the
    /// transport framing expects; `TmuxCommand` encoders never include one).
    private func sendCommand(_ command: String) {
        var bytes = Array(command.utf8)
        bytes.append(0x0a)
        sendInput(bytes)
    }

    // MARK: - Gesture entry points

    /// Long-press: toggle zoom on the active pane. Deterministic, no recovery
    /// needed (we know our own active pane id from the tracked model).
    func onLongPressZoom() {
        sendCommand(TmuxCommand.zoomPane(target: model.activePane))
        model.applyZoomToggle()
        DebugLog.shared.log(.tmux, "plainTmux:zoom pane=%\(model.activePane.raw)")
    }

    /// Finger-drag / edge-swipe window switch. PHASE 1 LIMITATION: blind
    /// (`next-window`/`previous-window`), we do not track window ids/order, so we
    /// cannot target a specific window or know the new one's layout. Marks the
    /// model needing-rebuild so the FIRST tap in the new window always recovers
    /// rather than resolving against the old (now-wrong) window's rects.
    func onSwitchWindow(delta: Int) {
        let command = delta >= 0 ? "next-window" : "previous-window"
        sendCommand(command)
        needsRebuildAfterWindowSwitch = true
        DebugLog.shared.log(.tmux, "plainTmux:switchWindow delta=\(delta) cmd=\(command) (blind, next tap recovers)")
    }

    /// Tap-to-select-pane: validate the tracked model against the rendered grid,
    /// resolve the tap, and select on success; recover on any drift signal.
    func onTapSelectPane(col: Int, row: Int) {
        guard let screen else { return }
        if needsRebuildAfterWindowSwitch {
            DebugLog.shared.log(.tmux, "plainTmux:tap col=\(col) row=\(row) → recovery (post-window-switch)")
            recover(thenResolveTapAt: col, row)
            return
        }
        let borders = model.predictedBorders
        let verdict = validateBorders(borders) { c, r in cellScalar(at: c, row: r, in: screen) }
        switch verdict {
        case .valid:
            guard let id = resolveTappedPane(col: col, row: row, in: model) else {
                DebugLog.shared.log(.tmux, "plainTmux:tap col=\(col) row=\(row) verdict=valid resolve=nil → recovery")
                recover(thenResolveTapAt: col, row)
                return
            }
            sendCommand(TmuxCommand.selectPane(target: id))
            model.applySelectPane(id)
            DebugLog.shared.log(.tmux, "plainTmux:tap col=\(col) row=\(row) verdict=valid pane=%\(id.raw) → selected")
        case .drift:
            DebugLog.shared.log(.tmux, "plainTmux:tap col=\(col) row=\(row) verdict=drift → recovery")
            recover(thenResolveTapAt: col, row)
        }
    }

    // MARK: - Recovery (Step 2)

    /// Recover the real layout for THIS tap and rebuild the tracked model.
    /// SSH/ET (a side channel exists, `recoverLayout` is non-nil): re-query
    /// `list-windows` and rebuild from the parsed layout, then resolve the tap
    /// against the fresh model. Mosh (no side channel, `recoverLayout` is nil):
    /// Phase 1 falls back to a blind relative cycle (`select-pane -t :.+`) for
    /// this one tap; the model rebuilds lazily on the next app-issued layout
    /// change (split/zoom/window-switch), per the design spec's Mosh fallback.
    private func recover(thenResolveTapAt col: Int, _ row: Int) {
        guard let recoverLayout else {
            sendCommand(TmuxCommand.selectPaneRelative(next: true))
            needsRebuildAfterWindowSwitch = false
            DebugLog.shared.log(.tmux, "plainTmux:recovery transport=mosh outcome=blind-cycle")
            return
        }
        // `PlainTmuxController` is @MainActor; a `Task` started from a @MainActor
        // method inherits that isolation, and `recoverLayout` is `@Sendable` (crosses
        // into the caller's off-actor query), so no further actor hop is needed after
        // the `await` resumes: we are back on the main actor automatically.
        Task { [weak self] in
            guard let self else { return }
            guard let recovered = await recoverLayout() else {
                DebugLog.shared.log(.tmux, "plainTmux:recovery transport=sideChannel outcome=queryFailed")
                return
            }
            let cols = self.model.gridCols
            let rows = self.model.gridRows
            let activePane = recovered.layout.panes.first?.pane ?? self.model.activePane
            self.model = PaneModel(window: recovered.window, activePane: activePane,
                                   layout: recovered.layout, gridCols: cols, gridRows: rows)
            self.needsRebuildAfterWindowSwitch = false
            if let id = resolveTappedPane(col: col, row: row, in: self.model) {
                self.sendCommand(TmuxCommand.selectPane(target: id))
                self.model.applySelectPane(id)
                DebugLog.shared.log(.tmux,
                    "plainTmux:recovery transport=sideChannel outcome=resolved pane=%\(id.raw)")
            } else {
                DebugLog.shared.log(.tmux,
                    "plainTmux:recovery transport=sideChannel outcome=rebuiltNoResolve col=\(col) row=\(row)")
            }
        }
    }
}

/// Read the rendered scalar at a viewport cell (0-based col/row), or nil for a
/// blank/out-of-range cell (drift check treats nil as drift, see
/// `validateBorders`). Mirrors `SwiftTermEchoOracle.cell`'s `getCharData` +
/// `getCharacter()` pattern (App-tier, macOS-CI-only, no Linux equivalent).
private func cellScalar(at col: Int, row: Int, in view: TerminalView) -> Unicode.Scalar? {
    guard let cd = view.getTerminal().getCharData(col: col, row: row) else { return nil }
    let ch = cd.getCharacter()
    if ch == "\u{0}" || ch == " " { return nil }
    return ch.unicodeScalars.first
}
