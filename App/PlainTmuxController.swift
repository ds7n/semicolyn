// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SwiftTerm
import SemicolynKit

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
    /// Sends raw bytes to the remote (the transport write). Every gesture path
    /// builds its bytes via the Kit prefix encoders (`prefixKeySequence`/
    /// `prefixCommandSequence`) so tmux receives a real prefix keystroke, never
    /// text typed into the pane's running program.
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
    /// Per-host user override for the tmux prefix (e.g. "C-a"), parsed and
    /// preferred over the discovered value when it parses. Nil means "no
    /// override configured", not "use C-b" (that fallback is `discoveredPrefix`'s
    /// default).
    private let prefixOverride: String?
    /// The prefix byte discovered from the launch-time `tmux show -gv prefix`
    /// sentinel (see `launchCommand()`/`noteLaunchOutput(_:)`). Defaults to C-b
    /// (0x02, tmux's own default) until a sentinel is parsed, so gestures sent
    /// before discovery completes still hit the common case correctly.
    private var discoveredPrefix: UInt8 = 0x02
    /// Guards `noteLaunchOutput(_:)` so discovery only ever happens once: later
    /// launch-output chunks (e.g. the shell prompt after `tmux new -A` attaches)
    /// must never stomp the already-discovered byte.
    private var prefixDiscovered = false

    /// The prefix byte gestures should send: the per-host override if it parses,
    /// else whatever was discovered (or the C-b default pre-discovery).
    private var effectivePrefix: UInt8 {
        prefixOverride.flatMap(parseTmuxPrefix) ?? discoveredPrefix
    }

    /// - Parameters:
    ///   - sessionName: validated by the caller (`isValidTmuxSessionName`) before
    ///     `launchCommand()` is ever sent; stored as-is.
    ///   - prefixOverride: per-host user-configured tmux prefix (e.g. "C-a"), or
    ///     nil to rely entirely on launch-time discovery.
    ///   - sendInput: raw-byte write to the connected transport (mirrors
    ///     `ConnectionViewModel.rawWriter`/`sendTerminalInput`'s raw branch).
    ///   - screen: the raw `TerminalView` this session renders into, read-only,
    ///     used solely for the on-tap border-drift cell check.
    ///   - recoverLayout: SSH/ET side-channel query, nil on Mosh (see class doc).
    init(sessionName: String,
        prefixOverride: String? = nil,
        sendInput: @escaping ([UInt8]) -> Void,
        screen: TerminalView,
        recoverLayout: (@Sendable () async -> (window: WindowID, layout: PaneLayout)?)? = nil) {
        self.sessionName = sessionName
        self.prefixOverride = prefixOverride
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

    /// The launch command to run on the transport: prefix discovery then
    /// `tmux new -A -s <name>`. Deliberately NO `-CC` and NO `set -g mouse on`/
    /// other option mutation (the design's ruled-out list): this must never
    /// fight the user's own tmux config.
    func launchCommand() -> String { Self.launchCommand(sessionName: sessionName) }

    /// Static form of `launchCommand()`, usable BEFORE a `PlainTmuxController`
    /// exists: `ConnectionViewModel.attachPlainTmux` opens the launch exec before
    /// the raw `TerminalView` exists (the controller needs that view's live grid,
    /// see `init`, so it is built lazily once the view mounts), so it calls this
    /// directly rather than constructing a controller just to read the string.
    /// Single source of truth for the command format either way.
    ///
    /// Discovery+attach compound: `tmux show -gv prefix` is read-only (no
    /// `set`/`bind` mutation of the user's config), printed with a
    /// `SEMICOLYN_PREFIX=` sentinel and a bare `\r` (not `\n`) so it lands as its
    /// own overwritable line; `tmux new -A` then attaches, and tmux's alt-screen
    /// entry wipes that sentinel line from the visible terminal without us having
    /// to clear it ourselves. See `noteLaunchOutput(_:)` for the ingest side.
    static func launchCommand(sessionName: String) -> String {
        "printf 'SEMICOLYN_PREFIX=%s\\r' \"$(tmux show -gv prefix)\"; tmux new -A -s \(sessionName)"
    }

    /// Scan accumulated launch-time output for the `SEMICOLYN_PREFIX=` sentinel
    /// printed by `launchCommand()` and, on the first successful parse, cache the
    /// discovered prefix byte. Idempotent: a no-op after the first successful
    /// discovery, so later output (the tmux status line, shell prompts, etc.)
    /// can never overwrite an already-discovered byte with a spurious match.
    /// Called by `ConnectionViewModel.evaluatePlainTmuxProbe()` alongside its
    /// tmux-missing classification, since that is the call site that already
    /// owns the accumulated probe buffer.
    func noteLaunchOutput(_ buffer: String) {
        guard !prefixDiscovered else { return }
        guard let raw = parseSemicolynPrefixSentinel(buffer), let byte = parseTmuxPrefix(raw) else { return }
        discoveredPrefix = byte
        prefixDiscovered = true
        DebugLog.shared.log(.tmux, "plainTmux:prefix discovered raw=\(raw) byte=0x\(String(byte, radix: 16))")
    }

    // MARK: - Gesture entry points

    /// Long-press: toggle zoom on the active pane. Deterministic, no recovery
    /// needed (we know our own active pane id from the tracked model). Routed
    /// through the discovered/override prefix key (`<prefix> z`), never sent as
    /// raw command text, so the keystroke lands as a real tmux binding instead of
    /// being typed into whatever program is running in the pane.
    func onLongPressZoom() {
        sendInput(prefixKeySequence(prefix: effectivePrefix, key: "z"))
        model.applyZoomToggle()
        DebugLog.shared.log(.tmux,
            "plainTmux:zoom pane=%\(model.activePane.raw) prefix=0x\(String(effectivePrefix, radix: 16)) key=z")
    }

    /// Finger-drag / edge-swipe window switch. PHASE 1 LIMITATION: blind
    /// (`next-window`/`previous-window`), we do not track window ids/order, so we
    /// cannot target a specific window or know the new one's layout. Marks the
    /// model needing-rebuild so the FIRST tap in the new window always recovers
    /// rather than resolving against the old (now-wrong) window's rects. Sent as
    /// `<prefix> n`/`<prefix> p` (the default tmux bindings), never raw text.
    func onSwitchWindow(delta: Int) {
        let key: Character = delta >= 0 ? "n" : "p"
        sendInput(prefixKeySequence(prefix: effectivePrefix, key: key))
        needsRebuildAfterWindowSwitch = true
        DebugLog.shared.log(.tmux,
            "plainTmux:switchWindow delta=\(delta) prefix=0x\(String(effectivePrefix, radix: 16)) key=\(key) (blind, next tap recovers)")
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
            let addedPane = detectUnpredictedBorder(rects: model.rects,
                                                     gridCols: model.gridCols, gridRows: model.gridRows) { c, r in
                cellScalar(at: c, row: r, in: screen)
            }
            if addedPane == .drift {
                DebugLog.shared.log(.tmux,
                    "plainTmux:tap col=\(col) row=\(row) verdict=valid unpredicted-border → recovery")
                recover(thenResolveTapAt: col, row)
                return
            }
            guard let id = resolveTappedPane(col: col, row: row, in: model) else {
                DebugLog.shared.log(.tmux, "plainTmux:tap col=\(col) row=\(row) verdict=valid resolve=nil → recovery")
                recover(thenResolveTapAt: col, row)
                return
            }
            sendInput(prefixCommandSequence(prefix: effectivePrefix, command: TmuxCommand.selectPane(target: id)))
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
            sendInput(prefixKeySequence(prefix: effectivePrefix, key: "o"))
            needsRebuildAfterWindowSwitch = false
            DebugLog.shared.log(.tmux,
                "plainTmux:recovery transport=mosh outcome=blind-cycle prefix=0x\(String(effectivePrefix, radix: 16)) key=o")
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
                self.sendInput(prefixCommandSequence(prefix: self.effectivePrefix, command: TmuxCommand.selectPane(target: id)))
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
