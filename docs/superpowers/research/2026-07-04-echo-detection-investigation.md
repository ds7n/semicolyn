<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Research: can the client detect a non-echoing (password-entry) remote terminal?

**Date:** 2026-07-04
**Status:** Reference (informs the predictor-secret-exclusion design)
**Question:** the shipped `PasswordEntryDetector` uses heuristic echo *inference*. An
earlier quick look concluded "we can't detect echo" (SwiftTerm exposes no flag; SSH
doesn't signal remote termios). This investigation stress-tested that conclusion.

## Bottom line

The prior conclusion is **half right**: there is **no deterministic echo flag on the
SSH wire**. But "we can't detect it" does **not** follow — two strong reachable signals
were missed. Verified against SwiftTerm `main`, russh 0.61.2, RFC 4254, vendored
`extern/mosh`, iTerm2.

## What is genuinely unavailable

- **SSH reverse pty-mode message: does not exist.** RFC 4254 reflects only `xon-xoff`
  (§6.8) and `exit-status`/`exit-signal` (§6.10) server→client on a session channel —
  never ECHO. OpenSSH never even sends `xon-xoff`. russh surfaces only `Handler::xon_xoff`.
- **Initial pty-req modes** (russh `Pty::ECHO = 53`, we pass `&[]`) are a one-shot
  client→server hint at pty creation; the remote app rewrites termios freely afterward.
  Zero detection value.
- **SwiftTerm SRM (mode 12): dead letter** — commented out (`Terminal.swift` ~4331),
  DECRQM hardcodes a placeholder (3394). *And it wouldn't matter if implemented*:
  password prompts change **remote termios via `tcsetattr()`**, which emits **zero
  bytes on the wire**. There is no escape sequence to observe. This is a "signal never
  exists in the stream" problem, not a "SwiftTerm doesn't model it" problem.
- Remote→host line-discipline queries (DECRQM/DSR-style): none exist.

## What IS reachable (the two missed signals + corroborators)

| Rank | Signal | Path | Reliability | Cost |
|---|---|---|---|---|
| 1 | **SwiftTerm buffer-anchored echo check** — after a keystroke, did the typed scalar appear at the pre-keystroke cursor cell + did cursor-x advance? Line-aggregated, gated on `isCurrentBufferAlternate` + output liveness. Yields 3-way echoed / masked / hidden. | SSH (also works under mosh) | High (robust-statistical; residual FP: non-alt-screen TUIs, output stalls) | Low — all public APIs (`getCharData`, `getCursorLocation`, `isCurrentBufferAlternate`); app already holds `getTerminal()` |
| 2 | **Mosh `PredictionEngine` tentative-epoch state** — `prediction_epoch > confirmed_epoch` (+ `IncorrectOrExpired` culls) means predictions are contradicted by the server framebuffer = server not echoing 1:1. This is *why mosh never local-echoes passwords*. | mosh only | Very high (validated against the server's actual rendered state; immune to redraw/timing confounders) | Medium — small vendored-mosh patch (getter → `iosclient` → `moshiosbridge.cc` → `MoshSession` → Swift); macOS-CI-only; **off when prediction mode = `Never`** |
| 3 | **Active probe (iTerm2 `iTermEchoProbe`-style: send space + BS, watch for echo)** | both | High at the moment of use | Medium; **invasive** (injects bytes) — confirmation-only, only when a prompt is already suspected |
| 4 | **OSC 133 prompt marks** via `registerOscHandler(133,…)` — inverted use: "we ARE at a marked shell prompt ⇒ echo expected ⇒ suppress false positives" | both | Low coverage (instrumented hosts only; sudo/ssh/PAM emit no marks) | Low, corroborative |
| 5 | Remote `stty -a` poll over a second exec channel | SSH | Deterministic but fragile (find the pty, GNU/BSD flags, restricted shells) | High |

## Key corrections vs. intuition

- **Mosh does NOT know the server's termios either** — SSP syncs *framebuffer state*, not
  termios; `echo_ack` is a timing ack, not an echo flag. But its prediction engine's
  validation-against-ground-truth *is* a production-hardened echo-inference that the
  tentative-epoch state exposes. Masked prompts also land as `IncorrectOrExpired`.
- The current `PasswordEntryDetector` is a **byte-count approximation of signal #1**
  (counts any output byte as an echo). A **buffer-anchored** version upgrades it from
  "biased-safe heuristic" to a genuinely reliable detector, and adds the masked/hidden
  distinction the byte counter cannot make.
- **Irreducible residuals:** a prompt that genuinely echoes the secret (`read` without
  `-s`) is undetectable by ANY client (it IS echoing). Fast typing during an output
  stall / inside a non-alt-screen TUI is the dominant false-positive class — driven low
  (not zero) by the alt-screen + liveness gates + line-level aggregation.

## Design consequence

Echo detection is real but never perfect, and the SSH and mosh paths differ. The
correct posture is **defense-in-depth**: a good echo signal per transport, PLUS
echo-independent deterministic layers (paste-detection, frequency-graduation for
human-chosen passwords, non-recoverable storage, sync-boundary firewall) so no single
layer is load-bearing. See `docs/superpowers/specs/2026-07-04-predictor-secret-exclusion-design.md`.
