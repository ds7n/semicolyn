// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SemicolynKit

/// Launches plain tmux (NO `-CC`) over an already-connected transport and turns gestures
/// into tmux commands. The launch command (`plainTmuxLaunchCommand`) installs private
/// root-table bindings on made-up escape sequences (`ESC [ 9900 ~` ...); each gesture
/// writes its action's `gestureSequence` in ONE write and tmux runs the bound command.
/// No prefix, no keybinding discovery, and nothing read back over the transport, so it
/// works the same on SSH, Mosh (frame-diffed output) and ET. See spec
/// 2026-09-25-tmux-private-gesture-bindings-design.
@MainActor
final class PlainTmuxController {
    /// Transport-aware raw write (`ConnectionViewModel.sendTerminalInput`). Each gesture is
    /// ONE call: tmux only matches a sequence whose bytes arrive together.
    private let sendInput: ([UInt8]) -> Void
    private let sessionName: String

    /// - Parameters:
    ///   - sessionName: validated by the caller (`isValidTmuxSessionName`) before
    ///     `launchCommand()` is ever sent; stored as-is.
    ///   - sendInput: raw-byte write to the connected transport.
    init(sessionName: String, sendInput: @escaping ([UInt8]) -> Void) {
        self.sessionName = sessionName
        self.sendInput = sendInput
    }

    /// The launch command for this session (see `launchCommand(sessionName:)`).
    func launchCommand() -> String { Self.launchCommand(sessionName: sessionName) }

    /// Static form, usable before a controller exists (`ConnectionViewModel` sends the
    /// launch before the `TerminalView` mounts). Single source of truth is the Kit builder.
    ///
    /// INVARIANT: the command prints `plainTmuxLaunchSentinel`; the Mosh cold-reattach
    /// liveness watchdog (`ConnectionViewModel.reattachMosh`) treats its arrival as proof
    /// the re-homed server EXECUTED the relaunch. Keep them in sync.
    static func launchCommand(sessionName: String) -> String {
        plainTmuxLaunchCommand(sessionName: sessionName)
    }

    // MARK: - Gesture entry points

    /// Single routing chokepoint: write `action`'s private sequence in one call.
    private func sendAction(_ action: TmuxAction) {
        sendInput(action.gestureSequence)
        DebugLog.shared.log(.tmux, "plainTmux:action \(action) -> User\(action.bindingSlot)")
    }

    /// Long-press: toggle zoom on the active pane.
    func onLongPressZoom() {
        sendAction(.zoom)
    }

    /// Route a single tap on a tmux pane. With the remote's mouse mode ON, forward an SGR
    /// mouse click at the tapped cell so tmux selects the EXACT pane. With mouse OFF, cycle
    /// focus to the next pane (best-effort; exact for a 2-pane split). `col`/`row` are
    /// 1-based cell coordinates (caller clamps to the grid).
    func onTapPane(col: Int, row: Int, mouseModeOn: Bool) {
        switch tapPaneRoute(mouseModeOn: mouseModeOn) {
        case .forwardClick:
            sendInput(sgrMouseClick(col: col, row: row))
            DebugLog.shared.log(.tmux, "plainTmux:tapPane col=\(col) row=\(row) -> forwardClick")
        case .cyclePrefix:
            sendAction(.cyclePane)
            DebugLog.shared.log(.tmux, "plainTmux:tapPane col=\(col) row=\(row) -> cycle")
        }
    }

    /// Drive a pane/window action from the dpad long-press menu on the ACTIVE pane.
    func onWindowAction(_ action: WindowMenuAction) {
        let tmuxAction: TmuxAction
        switch action {
        case .splitHorizontal: tmuxAction = .splitHorizontal
        case .splitVertical:   tmuxAction = .splitVertical
        case .closePane:       tmuxAction = .closePane
        case .newWindow:       tmuxAction = .newWindow
        case .zoom:            tmuxAction = .zoom
        }
        sendAction(tmuxAction)
        DebugLog.shared.log(.tmux, "plainTmux:windowAction \(action)")
    }

    /// Finger-drag / edge-swipe window switch (relative: next/previous window).
    func onSwitchWindow(delta: Int) {
        let action: TmuxAction = delta >= 0 ? .nextWindow : .previousWindow
        sendAction(action)
        DebugLog.shared.log(.tmux, "plainTmux:switchWindow delta=\(delta) action=\(action)")
    }
}
