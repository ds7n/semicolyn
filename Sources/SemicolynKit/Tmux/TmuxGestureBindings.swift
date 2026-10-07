// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Private tmux key bindings that drive plain-tmux gestures without knowing the user's
/// own keybindings. The launch command (`plainTmuxLaunchCommand`) teaches the tmux server
/// a made-up escape sequence per action (`user-keys[N]`) and binds the matching `UserN`
/// key in the root table to the action's command; a gesture then writes the sequence and
/// tmux runs the command. Nothing is written to disk; the bindings live in the running
/// server until it exits. See spec 2026-09-25-tmux-private-gesture-bindings-design.
public extension TmuxAction {
    /// The PREFERRED `user-keys[N]` slot and `UserN` key for this action. Contiguous
    /// 900...907 in `allCases` order: the launch script derives each slot from the
    /// action's position in its `for` list, which is built from `allCases`. If the user
    /// already holds this slot, the launch binds `fallbackBindingSlot` instead.
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

    /// The slot the launch claims when `bindingSlot` holds a user value: 100 below the
    /// preferred slot, so contiguous 800...807 in `allCases` order. It is registered with
    /// the SAME `gestureSequence`, so the app sends one sequence whichever slot holds it.
    var fallbackBindingSlot: Int { bindingSlot - 100 }

    /// The private escape sequence for this action: `ESC [ <9000 + bindingSlot> ~`, e.g.
    /// `ESC [ 9900 ~`. It depends only on the PREFERRED slot number, even when the
    /// launch registered it in `fallbackBindingSlot`. Real keys only use small numbers in
    /// this form (<= 34, plus 200/201 for bracketed paste), so no keypress produces these.
    /// Must reach tmux in ONE transport write: tmux does not match the sequence if its
    /// bytes are split.
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
/// and kept on one short line (545 + name length) because Mosh/ET type it into an
/// interactive shell. It:
/// 1. prints `plainTmuxLaunchSentinel`;
/// 2. if tmux is not on `PATH`, `exec tmux` so the shell prints ONE `tmux: not found`
///    line (what `TmuxLaunchProbe` classifies as missing) and exits;
/// 3. creates the session detached if it does not exist (`has-session || new-session -d`),
///    so bindings go onto an already-running server too (e.g. one started from a laptop);
/// 4. for each action, tries the preferred slot `user-keys[900+i]`, then the fallback
///    `user-keys[800+i]`, and claims the first one that is empty or already ours (value
///    ends in `[<9900+i>~`): it registers the sequence there and binds `User<slot>` to
///    the action's command. A slot the user already uses is left untouched. Only if BOTH
///    slots are user-occupied is the action unbound, and then its raw sequence reaches
///    the foreground program in the pane. Re-running is idempotent;
/// 5. `exec`s `attach-session`.
///
/// - Precondition: `sessionName` passed `isValidTmuxSessionName` (letters, digits, `-`,
///   `_` only), so it is safe to interpolate unquoted. Enforced here; every caller also
///   validates first.
public func plainTmuxLaunchCommand(sessionName: String) -> String {
    precondition(isValidTmuxSessionName(sessionName),
                 "plainTmuxLaunchCommand: session name must pass isValidTmuxSessionName")
    let commands = TmuxAction.allCases
        .map { $0.command.contains(" ") ? "\"\($0.command)\"" : $0.command }
        .joined(separator: " ")
    return #"sh -c 'S=\#(sessionName);printf "SEMICOLYN_%s\r" LAUNCH;command -v tmux >/dev/null||exec tmux;tmux has-session -t "=$S" 2>/dev/null||tmux new-session -d -s "$S";i=0;for c in \#(commands);do k=$((9900+i));for n in $((900+i)) $((800+i));do v=$(tmux show -sv "user-keys[$n]" 2>/dev/null);case "$v" in ""|*"[$k~")tmux set -s "user-keys[$n]" "$(printf "\033[$k~")";tmux bind -n "User$n" $c;break;;esac;done;i=$((i+1));done;exec tmux attach-session -t "=$S"'"#
}
