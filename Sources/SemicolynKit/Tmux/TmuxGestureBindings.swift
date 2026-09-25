// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Private tmux key bindings that drive plain-tmux gestures without knowing the user's
/// own keybindings. The launch command (`plainTmuxLaunchCommand`) teaches the tmux server
/// a made-up escape sequence per action (`user-keys[N]`) and binds the matching `UserN`
/// key in the root table to the action's command; a gesture then writes the sequence and
/// tmux runs the command. Nothing is written to disk; the bindings live in the running
/// server until it exits. See spec 2026-09-25-tmux-private-gesture-bindings-design.
public extension TmuxAction {
    /// The `user-keys[N]` slot and `UserN` key this action is bound to. Contiguous
    /// 900...907 in `allCases` order: the launch script derives each slot from the
    /// action's position in its `for` list, which is built from `allCases`.
    var bindingSlot: Int {
        switch self {
        case .splitHorizontal: return 900
        case .splitVertical:   return 901
        case .closePane:       return 902
        case .newWindow:       return 903
        case .zoom:            return 904
        case .nextWindow:      return 905
        case .previousWindow:  return 906
        case .cyclePane:       return 907
        }
    }

    /// The private escape sequence for this action: `ESC [ <9000 + slot> ~`, e.g.
    /// `ESC [ 9900 ~`. Real keys only use small numbers in this form (<= 34, plus
    /// 200/201 for bracketed paste), so no keypress produces these. Must reach tmux in
    /// ONE transport write: tmux does not match the sequence if its bytes are split.
    var gestureSequence: [UInt8] { Array("\u{1b}[\(9000 + bindingSlot)~".utf8) }
}

/// Printed by the launch script before attaching. It proves the remote shell actually
/// EXECUTED the launch (the Mosh cold-reattach liveness signal). The script prints it via
/// `printf "SEMICOLYN_%s\r" LAUNCH`, so the shell's echo of the typed command never
/// contains this exact string.
public let plainTmuxLaunchSentinel = "SEMICOLYN_LAUNCH"

/// Whether accumulated launch output contains the executed launch sentinel.
public func containsPlainTmuxLaunchSentinel(_ output: String) -> Bool {
    output.contains(plainTmuxLaunchSentinel)
}

/// The one-line command that launches plain tmux with the private gesture bindings.
///
/// Wrapped in `sh -c '...'` so it behaves the same under any login shell (bash/zsh/fish),
/// and kept on one short line (475 + name length) because Mosh/ET type it into an
/// interactive shell. It:
/// 1. prints `plainTmuxLaunchSentinel`;
/// 2. creates the session detached if it does not exist (`has-session || new-session -d`),
///    so bindings go onto an already-running server too (e.g. one started from a laptop);
/// 3. for each action, claims `user-keys[900+i]` ONLY if it is empty or already ours
///    (value ends in `[<9900+i>~`), then binds `User<900+i>` to the action's command.
///    A slot the user already uses is left untouched and only that gesture is unavailable.
///    Re-running is idempotent;
/// 4. `exec`s `attach-session`.
///
/// - Precondition: `sessionName` passed `isValidTmuxSessionName` (letters, digits, `-`,
///   `_` only), so it is safe to interpolate unquoted. Every caller already guards this.
public func plainTmuxLaunchCommand(sessionName: String) -> String {
    let commands = TmuxAction.allCases
        .map { $0.command.contains(" ") ? "\"\($0.command)\"" : $0.command }
        .joined(separator: " ")
    return #"sh -c 'S=\#(sessionName);printf "SEMICOLYN_%s\r" LAUNCH;tmux has-session -t "=$S" 2>/dev/null||tmux new-session -d -s "$S";i=0;for c in \#(commands);do n=$((900+i));k=$((9900+i));v=$(tmux show -sv "user-keys[$n]" 2>/dev/null);case "$v" in ""|*"[$k~")tmux set -s "user-keys[$n]" "$(printf "\033[$k~")";tmux bind -n "User$n" $c;;esac;i=$((i+1));done;exec tmux attach-session -t "=$S"'"#
}
