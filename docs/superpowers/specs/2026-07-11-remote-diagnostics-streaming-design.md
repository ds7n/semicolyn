<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Remote diagnostics streaming + gesture/input instrumentation

**Date:** 2026-07-11
**Status:** Approved (brainstorming), pending implementation plan
**Motivation:** Two on-device rounds (TF33, TF34) failed to fix the terminal gesture
system, and TF34 regressed further (scroll/swipe dead, stuck selection, backspace-repeat
broken, keybar still double-high). We are guessing without evidence. This feature ships
verbose on-device instrumentation of the gesture / selection / key-input / scroll / tmux
paths, streamed off-device to a syslog server, so the next fix is evidence-driven.

**Related:** extends `App/DebugLog.swift` + `App/DiagnosticsSettingsView.swift` (existing
gated diagnostics); reuses `Sources/SemicolynKit/Predictor/PasswordEntryDetector.swift`
(`shouldLearnCommittedLine()`) for keystroke redaction. Feeds the debugging of
`App/TerminalGestureController.swift`, `App/TerminalScreen.swift`,
`App/TmuxPaneContainer.swift`.

## Problem

The terminal gesture layer is broken on device in ways not visible from source:
vertical scroll and horizontal window-switch don't fire, selection gets "stuck" (single
tap re-anchors a block, can't exit), double-tap word-select fails, long-press zoom may not
fire, backspace key-repeat regressed, and window-tab taps switch but the pane doesn't
redraw correctly. These symptoms interact, suggesting our custom gesture layer is fighting
SwiftTerm's built-in text/selection/scroll machinery — but we cannot confirm which
recognizer wins, when selection state changes, or whether `deleteBackward` repeats, without
a real trace from the device. The existing `DebugLog` records to an on-screen panel only,
which is impractical to read while reproducing multi-touch gestures.

## Goal

Capture a verbose, timestamped trace of the gesture / selection / key / scroll / tmux
paths on device and stream it to a syslog server the developer controls, so the failing
interactions can be diagnosed from evidence. Verbose and inclusive by default (we don't yet
know what we're looking for), with keystroke *content* gated behind an explicit,
nagged, redaction-protected opt-in.

Non-goals: fixing the gestures themselves (that is the follow-up, informed by the trace);
changing the local on-screen debug panel's behavior; production telemetry (this is
developer diagnostics, off by default).

## Architecture

Three separated units plus instrumentation call sites.

```
DebugLog (existing, extended)            — the single sink; verbose; gated by master switch
  ├─ appends to local rolling buffer (unchanged)
  ├─ mirrors to os.Logger (unchanged)
  └─ NEW: forwards each line to `remote?.send(line)` when remote streaming is on

RemoteLogSink (new, App-tier)            — owns the network connection
  ├─ NWConnection (Network.framework), one of UDP / TCP / TLS
  ├─ frames each line via `syslogFrame(...)` (pure, SemicolynKit)
  ├─ fire-and-forget send on its own queue (never blocks `log()`)
  ├─ lazy connect + backoff reconnect; teardown when disabled
  └─ `test()` → sends one probe line, reports success/failure (Diagnostics "Test" button)

RemoteLogConfig + Diagnostics UI (extended) — @AppStorage config + controls
  ├─ remoteLogEnabled / Host / Port / Transport (udp|tcp|tls)
  ├─ logKeystrokeContent (default off; nag on enable)
  └─ links to tools/syslog-sink/ docker-compose receiver

Instrumentation call sites (verbose)     — all via DebugLog.shared.log(...)
  ├─ Gesture lifecycle: recognizer began/changed/ended/failed + which view/recognizer
  ├─ Selection: setSelectionRange / clearSelection / hasActiveSelection transitions
  ├─ Key input: insertText / deleteBackward / first-responder changes (structural),
  │             content only when logKeystrokeContent on (with redaction)
  ├─ Scroll: contentOffset / isTracking transitions + scroll-view pan target firing
  └─ Window-switch: onSwitchWindow / selectWindow + tmux layout/active-window/redraw
```

**Two-tier split:** the only pure, Linux-tested logic is (1) `syslogFrame(...)` (RFC 5424
framing) and (2) the keystroke-redaction decision. Everything network (`NWConnection`) and
every instrumentation call site is App-tier, validated on macOS CI + device. The trace
itself IS the App-tier deliverable.

## Transport & framing

Configurable transport, all emitting **RFC 5424** syslog messages
(`<PRI>1 TIMESTAMP HOSTNAME APP-NAME PROCID MSGID SD MSG`):

| Transport | Port default | Framing | RFC | Notes |
|---|---|---|---|---|
| **UDP** | 514 | bare message, no length prefix | 5426 | ubiquitous; lossy (packets can drop) |
| **TCP** | 514 | octet-counted: `<len> <MSG>` | 6587 | reliable, no drops |
| **TLS** | 6514 | octet-counted over TLS | 5425 | reliable + encrypted; default |

- `PRI = facility·8 + severity`; facility `local0`(16), severity `debug`(7) → `<135>`.
- `VERSION` = `1`. `TIMESTAMP` = RFC 3339 with fractional seconds. `HOSTNAME` = device name
  (or `-`). `APP-NAME` = `semicolyn`. `PROCID`/`MSGID`/`SD` = `-`.
- **TLS**: `NWConnection` with `.tls`; **certificate verification disabled** (the developer's
  own diagnostics host; documented as intentional). No client cert.
- **Octet-counting** (TCP/TLS) uses the **UTF-8 byte length** of the syslog message, not the
  character count — must be correct for multibyte content.

`syslogFrame(message:hostname:timestamp:transport:) -> String` is a **pure function in
SemicolynKit** (`Sources/SemicolynKit/Diagnostics/`), Linux-tested with exact strings.

## Configuration & UI

`@AppStorage` keys (under Diagnostics), all developer-facing, off by default:

- `remoteLogEnabled: Bool = false`
- `remoteLogHost: String = ""`
- `remoteLogPort: Int = 6514`
- `remoteLogTransport: {udp, tcp, tls} = .tls`
- `logKeystrokeContent: Bool = false`

`DiagnosticsSettingsView` gains, below the existing debug-panel toggle:

- **"Stream logs to a server"** toggle → reveals Host field, Port field, Transport picker.
- **"Test connection"** button → `RemoteLogSink.test()`, shows ✓/✗ inline.
- **"Log keystroke content"** toggle (default off). Enabling (off→on) presents a **nag
  confirmation**: *"Diagnostic traces will include the actual keys you type, including
  anything sensitive, and stream to your configured host if remote logging is on.
  Password/prompt lines are still redacted. Turn on keystroke content?"* → Cancel / Turn On.
- Footer: *"Traces are verbose and may include typed input when keystroke content is on.
  Receiver setup: see `tools/syslog-sink/` (docker compose up). Leave all off for normal
  use."*

## Keystroke content gating (defense in depth)

Three-part model — **no raw/un-redacted mode**:

1. **`logKeystrokeContent` off (default):** key instrumentation logs **structure only** —
   `insertText(len=3)`, `deleteBackward`, first-responder changes. No characters. This alone
   diagnoses the backspace-repeat regression (we need *whether* `deleteBackward` fires and
   repeats, not what was typed).
2. **`logKeystrokeContent` on (nag-confirmed):** characters are logged, **except** on lines
   the existing `PasswordEntryDetector` flags (reuse `shouldLearnCommittedLine()` /
   equivalent per-line password state). On a flagged line we emit an explicit
   **redaction marker** — `insertText(REDACTED len=8 reason=password-line)` — **never a
   silent drop**. The trace always shows that a password line occurred.
3. **No un-redacted mode.** If redaction ever hides something genuinely needed, that is a
   signal to fix the heuristic, not to add a bypass.

The redaction *decision* (given a per-line "is-password" flag + the input → emit content or
a marker) is a **pure function in SemicolynKit**, Linux-tested.

## Instrumentation scope (verbose, inclusive)

Per the "we don't know what we're looking for" principle, log broadly. All via
`DebugLog.shared.log(...)` (zero cost when diagnostics off):

- **Gesture recognizer lifecycle** — for our recognizers AND, where observable, SwiftTerm's:
  state transitions (`.began/.changed/.ended/.failed/.cancelled`), recognizer identity, the
  view, `translation`/`location`, and which recognizer ultimately fired the action. THE key
  signal for "pan doesn't fire", "stuck selection", "long-press".
- **Selection** — `setSelectionRange(start,end)`, `clearSelection`, `hasActiveSelection`
  before/after each gesture; enough to see selection getting "stuck" / re-anchoring.
- **Key input** — `insertText` (len; content gated per above), `deleteBackward`,
  `becomeFirstResponder`/`resignFirstResponder`, first-responder identity. Diagnoses the
  backspace-repeat regression.
- **Scroll** — `contentOffset` changes, `isTracking` transitions, our scroll-view pan
  target firing (`handleScrollViewPan` state). Diagnoses dead vertical scroll.
- **Window-switch + tmux redraw** — `onSwitchWindow`/`selectWindow` calls, tmux
  `%layout-change`/active-window events, pane container re-render. Diagnoses "tab tap
  switches but pane doesn't redraw / windows treated as same object".

## Data flow

```
gesture/key/scroll/tmux event
  → instrumentation call: DebugLog.shared.log("gr:pan .began view=… t=(dx,dy)")
      guard enabled (master switch) — else zero cost, returns
      → append local buffer (unchanged)
      → os.Logger (unchanged)
      → remote?.send(line):
           syslogFrame(line, hostname, now, transport)  [pure]
           → NWConnection.send (fire-and-forget, own queue; drop if disconnected)
                → (TLS) encrypted → developer's syslog:6514 → logfile → `tail -f`
key input with logKeystrokeContent on:
  redactionDecision(isPasswordLine, input) → chars OR "REDACTED len=N reason=password-line"  [pure]
```

## Error handling

- Remote send is **fire-and-forget**; a down/failed connection never affects the app,
  the keystroke path, or the local buffer. Lines simply drop while disconnected (local
  buffer retains them).
- Only the **Test connection** button surfaces a connection result. Invalid host/port →
  Test reports failure; streaming stays disconnected, no crash.
- TLS certificate verification is intentionally disabled (developer's own host) — documented
  in code and in the spec; NOT a general-purpose secure transport.
- The whole subsystem is inert unless the master diagnostics switch is on AND remote
  streaming is enabled AND a host is set.

## Receiver: `tools/syslog-sink/`

A `docker-compose.yml` + minimal syslog config (rsyslog or syslog-ng) that stands up a
**TLS syslog listener on 6514**, generating a self-signed cert on first run, writing
received messages to a mounted logfile (`./logs/semicolyn.log`) for `tail -f`. Also documents
the plaintext UDP/TCP 514 path for quick tests. One-command setup: `docker compose up`.
Referenced from the Diagnostics UI footer. (Cert is self-signed; the app skips verification,
matching.)

## Testing

Per `docs/superpowers/specs/2026-06-18-testing-standards-design.md`:

- **`syslogFrame(...)` (Linux `swift test`):** exact-string assertions — `<135>1 ` PRI+version
  prefix; RFC 3339 timestamp shape; `-` for empty PROCID/MSGID/SD; **octet count equals the
  UTF-8 byte length** for TCP/TLS incl. a multibyte (e.g. emoji/accented) message; **no**
  count prefix for UDP; `APP-NAME=semicolyn`. Boundary: empty message, message with a
  newline (must be escaped/handled), very long message.
- **Redaction decision (Linux):** password-line flag true → returns the
  `REDACTED len=N reason=password-line` marker with the correct length and NO content;
  flag false + content-logging on → returns the content; content-logging off → returns the
  structural form regardless of flag. Exact expected strings; a negative case per branch.
- **App-tier (macOS CI + device):** `RemoteLogSink` NWConnection wiring per transport, the
  Diagnostics UI + nag popup + Test button, and the instrumentation actually emitting a
  usable trace. Validated by capturing a real trace on device while reproducing the broken
  gestures — which is the entire point of the feature.

## Risks & mitigations

- **Verbose logging cost on the sacred path.** Mitigated by the existing `@autoclosure` +
  `guard enabled` gate — zero cost when diagnostics off (the default). When on, cost is
  accepted (it's a diagnostic session).
- **Keystroke leakage.** Mitigated by default-off content gating, the nag, password-line
  redaction with a visible marker, and no un-redacted mode.
- **NWConnection blocking the log call.** Mitigated by fire-and-forget send on the
  connection's own queue; lines drop rather than block.
- **TLS cert-verify off.** Accepted and documented; scope is a developer's own diagnostics
  host, not general transport.
- **The trace might still not pinpoint the gesture bug.** If so, the trace narrows the
  search and the fallback is the re-architecture option already on the table (keep
  SwiftTerm's native behavior, add only the genuinely-new tmux gestures) — a separate spec.

## Open items (deferred to plan / implementation)

- Exact `PasswordEntryDetector` reuse surface for the per-line password flag in the key path
  (which method/state gives "current line is password entry" at `insertText` time).
- Whether gesture instrumentation can observe SwiftTerm's *own* recognizers (they're
  unstored) or only ours + the native scroll pan — verify what's reachable; log what is.
- rsyslog vs syslog-ng for the docker-compose sink (pick the simpler TLS config).
