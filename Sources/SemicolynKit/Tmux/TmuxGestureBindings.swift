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

/// Printed by the DIRECT launch (`plainTmuxDirectLaunchCommand`) when `tmux` is not on
/// the non-interactive `PATH`, right before it `exec`s the user's login shell. Tells the
/// app to retry with the in-band launch in that shell, whose rc files may add tmux to
/// `PATH`. Printed via `printf "SEMICOLYN_%s\n" NOTMUX`, so the script text itself never
/// contains this exact string.
public let plainTmuxNoTmuxMarker = "SEMICOLYN_NOTMUX"

/// Whether accumulated direct-launch output contains the tmux-not-on-PATH marker.
public func containsPlainTmuxNoTmuxMarker(_ output: String) -> Bool {
    output.contains(plainTmuxNoTmuxMarker)
}

/// The one-line command that launches plain tmux with the private gesture bindings.
///
/// Wrapped in `sh -c '...'` so it behaves the same under any login shell (bash/zsh/fish),
/// and kept on one short line (739 + name length, under the 1024-byte MAX_CANON) because
/// Mosh/ET type it into an interactive shell. Every tmux client spawn delays the first
/// paint, so it starts at most FIVE: `has-session`, `new-session` (only if absent), one
/// `show -s user-keys` that reads every slot, one call carrying all the `set`/`bind`
/// commands (chained with `\;`), and the final `exec tmux attach-session`. It:
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
///    the foreground program in the pane. Re-running is idempotent (re-setting a slot
///    that is already ours is harmless and costs no extra spawn). Each slot is decided
///    in pure sh from ITS OWN `user-keys[N]` line of the single `show` output (matched
///    as newline + key + space, then cut at the next newline; tmux escapes newlines in
///    values), never by a glob over the whole multi-line output, where another slot's
///    line could make a user-occupied slot look like ours. An explicitly empty slot
///    (shown as `''`) counts as empty, and our value counts as ours whether `show`
///    prints it bare (tmux 3.4) or wrapped in double quotes (`[<9900+i>~"` suffix). If the `show` fails, no bindings are attempted;
/// 5. runs the collected `set`/`bind` commands in ONE tmux call (only if there are any),
///    ignoring its failure, then ALWAYS `exec`s a standalone `attach-session`. tmux stops
///    a `\;` chain at the first failing command, so attach must never ride in that chain:
///    a failed bind costs gestures, never the session.
///
/// Steps 3 to 5 (up to the attach) are `plainTmuxBindingsScript`, shared verbatim with
/// `plainTmuxDirectLaunchCommand`.
///
/// - Precondition: `sessionName` passed `isValidTmuxSessionName` (letters, digits, `-`,
///   `_` only), so it is safe to interpolate unquoted. Enforced here; every caller also
///   validates first.
public func plainTmuxLaunchCommand(sessionName: String) -> String {
    precondition(isValidTmuxSessionName(sessionName),
                 "plainTmuxLaunchCommand: session name must pass isValidTmuxSessionName")
    return #"sh -c 'S=\#(sessionName);printf "SEMICOLYN_%s\r" LAUNCH;command -v tmux >/dev/null||exec tmux;\#(plainTmuxBindingsScript());exec tmux attach-session -t "=$S"'"#
}

/// The DIRECT launch: the same tmux launch, run by mosh-server as its session command
/// (`mosh-server new ... -- <this>`) instead of being typed into the user's login shell,
/// so the interactive shell's startup and the echoed launch line never appear. Same
/// sentinel, session create and binding body (`plainTmuxBindingsScript`) as
/// `plainTmuxLaunchCommand`. Differences, because there is no interactive shell behind it:
/// - tmux not on `PATH` (a non-interactive `PATH` can lack the user's rc additions):
///   prints `plainTmuxNoTmuxMarker` and `exec`s the login shell (`"${SHELL:-sh}" -l`), so
///   the user gets their normal shell and the app can retry the in-band launch there;
/// - attach is NOT `exec`'d and is followed by the login shell, so detaching or exiting
///   tmux leaves the user at their shell (as the typed launch does) instead of ending the
///   Mosh session.
///
/// Contains no single quote of its own, so it survives the login shell's parse of the
/// joined mosh-server command exactly as the typed launch does.
///
/// - Precondition: `sessionName` passed `isValidTmuxSessionName` (see
///   `plainTmuxLaunchCommand`).
public func plainTmuxDirectLaunchCommand(sessionName: String) -> String {
    precondition(isValidTmuxSessionName(sessionName),
                 "plainTmuxDirectLaunchCommand: session name must pass isValidTmuxSessionName")
    let loginShell = #"exec "${SHELL:-sh}" -l"#
    return #"sh -c 'S=\#(sessionName);printf "SEMICOLYN_%s\r" LAUNCH;command -v tmux >/dev/null||{ printf "SEMICOLYN_%s\n" NOTMUX;\#(loginShell);};\#(plainTmuxBindingsScript());tmux attach-session -t "=$S";\#(loginShell)'"#
}

/// The launch body shared by both launch variants: create the session `$S` if absent,
/// then claim a slot and bind each action in ONE ignored-failure tmux call (steps 3 to 5
/// of `plainTmuxLaunchCommand`, up to but excluding the attach). Expects `S` set and
/// tmux on `PATH`; contains no single quote.
private func plainTmuxBindingsScript() -> String {
    let commands = TmuxAction.allCases
        .map { $0.command.contains(" ") ? "\"\($0.command)\"" : $0.command }
        .joined(separator: " ")
    return #"tmux has-session -t "=$S" 2>/dev/null||tmux new-session -d -s "$S";E=$(printf "\033");Q=$(printf "\047");N=$(printf "\nx");N=${N%x};set --;i=0;U=$N$(tmux show -s user-keys 2>/dev/null)&&for c in \#(commands);do k=$((9900+i));for n in $((900+i)) $((800+i));do K="${N}user-keys[$n] ";v=;case "$U" in *"$K"*)v=${U#*"$K"};v=${v%%"$N"*};;esac;case "$v" in ""|"$Q$Q"|*"[$k~"|*"[$k~\"")set -- "$@" set -s "user-keys[$n]" "$E[$k~" \; bind -n "User$n" $c \;;break;;esac;done;i=$((i+1));done;[ $# -gt 0 ]&&tmux "$@" 2>/dev/null"#
}
