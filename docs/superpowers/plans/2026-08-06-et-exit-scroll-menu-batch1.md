<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# ET exit-fix + scroll diagnostic + menu cleanup (Batch 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the false "Eternal Terminal could not connect: closed" screen on an intentional exit/disconnect; add a decisive scroll diagnostic (no scroll fix this batch); and clean up the transport/tmux menu (Transport dropdown is the sole selector; tmux-control toggle shown for SSH+ET, hidden for Mosh).

**Architecture:** (A) an `etUserDisconnecting` guard on `ConnectionViewModel`, set in `disconnect()` and read first in ET's `onEnd`, reset at connect-start (so the async `onEnd` still sees it). (B) a pan-state-transition log on the native scroll pan. (C) a pure Kit predicate `showsTmuxControlToggle(transport:)` gating the tmux toggle, plus removing the redundant "Enable Mosh" toggle and gating the Mosh config section on transport==Mosh.

**Tech Stack:** Swift 6, SwiftUI + UIKit, XCTest. One new Kit predicate (Linux-tested); everything else App-tier (macOS-CI-compiled only).

## Global Constraints

- **Two tiers:** `Sources/SemicolynKit/` = pure logic, Linux-tested, NO UIKit/SwiftUI. `App/` = Apple-only, macOS-CI-verified, invisible to `swift test`.
- **SPDX header** on every source file (`GPL-3.0-only`, © True Positive LLC).
- **No em-dash (U+2014) / en-dash (U+2013)** anywhere. Arrow `→` (U+2192) is allowed.
- **Tests must be real:** EP + BVA, assert observable values, negative tests assert the specific value.
- **Async-ordering constraint (Item A):** `etUserDisconnecting` must be reset at CONNECT-START, never in `teardown()` (ET's `onEnd` is async and fires after `teardown()` returns; resetting in `teardown()` reintroduces the bug).
- **Do NOT change** `resolveTransport`, `tmuxLaunchDecision`, or the Mosh config model. Item C is a UI-layer cleanup only; back-compat is already handled by `resolveTransport`'s legacy migration (Resolution.swift:199).
- **Item B is diagnostic-only:** the scroll trace attaches a logging target and adds NO behavior. It must not disable/enable/reorder/require-to-fail any recognizer.
- **Branch:** `fix/et-onend-clean-exit` (batches with the prior work; do NOT push/CI/TF until ALL THREE items are in, per user).
- **Kit test command:** `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter <TestName>`.

---

### Task 1: Item A, suppress ET onEnd failure on user disconnect

**Files:**
- Modify: `App/ConnectionViewModel.swift` (add `etUserDisconnecting` property; set in `disconnect()`; read first in ET `onEnd`; reset in `connect(savedHost:)`).

**Interfaces:**
- Consumes: existing `disconnect()` (line ~496), `teardown()` (~504), the ET `onEnd` closure (~992), `connect(savedHost:password:)` (~1464), `etExitDecision`.
- Produces: nothing downstream.

**Note:** App-tier, Linux-invisible. Verification = macOS CI compile + device retest. Trace the async ordering carefully (that is the whole bug).

- [ ] **Step 1: Add the `etUserDisconnecting` property**

In `App/ConnectionViewModel.swift`, near the existing `etFirstFrameSeen` declaration (line ~171), add:

```swift
    /// True from the moment the user initiates a disconnect ("x" button -> `disconnect()`)
    /// until the next connect attempt. ET's `onEnd` is asynchronous and fires AFTER
    /// `teardown()` has closed the session; without this guard it reads the already-reset
    /// `etFirstFrameSeen == false` and misroutes a user disconnect to
    /// `.failed("could not connect: closed")`. `onEnd` checks this FIRST and, when set,
    /// cleans up silently (no `.failed`, no banner). Reset at connect-start (NOT in
    /// `teardown()`, which runs before the async `onEnd` and would clear it too early).
    private var etUserDisconnecting = false
```

- [ ] **Step 2: Set the guard in `disconnect()` before teardown**

`disconnect()` currently:

```swift
    func disconnect() {
        DebugLog.shared.log(.lifecycle, "disconnect: user-initiated teardown → .idle")
        teardown()
        state = .idle
    }
```

Change to set the flag BEFORE `teardown()`:

```swift
    func disconnect() {
        DebugLog.shared.log(.lifecycle, "disconnect: user-initiated teardown → .idle")
        etUserDisconnecting = true   // ET onEnd (async) must not misfire a .failed
        teardown()
        state = .idle
    }
```

- [ ] **Step 3: Check the guard FIRST in ET `onEnd`**

The ET `onEnd` closure (line ~992) currently starts:

```swift
        sess.onEnd = { [weak self] reason in
            guard let self else { return }
            self.etWatchdog?.cancel(); self.etWatchdog = nil
            switch etExitDecision(reason: reason, sawFirstFrame: self.etFirstFrameSeen) {
```

Insert the user-disconnect check between the watchdog-cancel and the switch:

```swift
        sess.onEnd = { [weak self] reason in
            guard let self else { return }
            self.etWatchdog?.cancel(); self.etWatchdog = nil
            // User-initiated disconnect (the "x" button): `disconnect()` already tore the
            // session down and drove state to .idle. This async onEnd must NOT run the
            // failure path (teardown() reset etFirstFrameSeen, so etExitDecision would
            // wrongly return .handshakeFailed). Clean up silently and return.
            if self.etUserDisconnecting {
                DebugLog.shared.log(.transport, "et: onEnd during user disconnect → silent, no banner")
                self.etSession?.close()
                self.etSession = nil
                return
            }
            switch etExitDecision(reason: reason, sawFirstFrame: self.etFirstFrameSeen) {
```

(The `.dismiss` / `.handshakeFailed` cases below stay unchanged.)

- [ ] **Step 4: Reset the guard at connect-start**

In `connect(savedHost:password:)` (line ~1464), find the `teardown()` + `state = .connecting` at the start (lines ~1471-1472):

```swift
        teardown()
        state = .connecting
```

Add the reset immediately after (AFTER teardown, so it is clean for the NEW connection; teardown never touches this flag):

```swift
        teardown()
        etUserDisconnecting = false   // fresh connection: clear any prior user-disconnect guard
        state = .connecting
```

- [ ] **Step 5: Grep sanity check**

Run:
```bash
grep -n "etUserDisconnecting" App/ConnectionViewModel.swift
```
Expected FOUR sites: declaration (~171), set true in `disconnect()`, read in ET `onEnd`, reset false in `connect(savedHost:)`. Confirm NO occurrence inside `teardown()` (grep the teardown body lines ~504-541 for it; must be absent).

- [ ] **Step 6: Commit**

```bash
git add App/ConnectionViewModel.swift
git commit -m "fix(et): user disconnect no longer shows a false 'could not connect'

The x-button disconnect() calls teardown() which resets etFirstFrameSeen
before ET's async onEnd fires; onEnd then read false and routed the user
disconnect to .failed('could not connect: closed'). Add an etUserDisconnecting
guard (set in disconnect() before teardown, checked first in onEnd -> silent
cleanup, reset at connect-start so the async onEnd still sees it). Clean
exit-in-shell path (first-frame seen -> dismiss) is unaffected.

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
```

---

### Task 2: Item B, native-pan state-transition scroll diagnostic

**Files:**
- Modify: `App/TerminalGestureController.swift` (add an all-states observer for the native scroll pan).

**Interfaces:**
- Consumes: the existing `observeRecognizerState(_:)` (@objc, gates on `.began || .changed`), `observeStrayRecognizers(on:)`, `view.panGestureRecognizer`, `callbacks.currentMode()`.
- Produces: a new `scroll-trace` log token (diagnostic).

**Note:** App-tier, Linux-invisible. DIAGNOSTIC ONLY, no behavior change (no enable/disable/require-to-fail). Verify via grep; the signal comes from the device swipe.

- [ ] **Step 1: Add an all-states observer method for the native pan**

In `App/TerminalGestureController.swift`, add this method next to `observeRecognizerState` (~line 416):

```swift
    /// Issue 3 scroll diagnosis (device 2026-08-06): the native scroll pan never begins on
    /// a swipe (zero gr-observe, nothing scrolls) despite scroll range + an enabled pan.
    /// `observeRecognizerState` only logs `.began`/`.changed`, so a pan that reaches
    /// `.failed`/`.cancelled` WITHOUT ever beginning is invisible. This logs EVERY state
    /// transition of the native scroll pan (incl. .possible/.failed/.cancelled) with the
    /// translation + touch count, so a device swipe shows whether the pan begins, fails, or
    /// stays possible. Diagnostic only: attached as an extra target, changes no behavior.
    @objc private func observeScrollPanAllStates(_ g: UIGestureRecognizer) {
        guard let view = terminalView else { return }
        let t = (g as? UIPanGestureRecognizer)?.translation(in: view) ?? .zero
        DebugLog.shared.log(.gesture,
            "scroll-trace pan=nativePan state=\(g.state.rawValue) mode=\(callbacks.currentMode()) "
            + "touches=\(g.numberOfTouches) tx=\(Int(t.x)) ty=\(Int(t.y))")
    }
```

- [ ] **Step 2: Attach it to the native pan at mount**

In `installOurRecognizers(on view:)`, right after the existing `observeStrayRecognizers(on: view)` call (which attaches the began/changed observer), add the all-states target on the native scroll pan specifically:

```swift
        // Issue 3 scroll diagnosis: also observe the native scroll pan's FULL state
        // machine (observeStrayRecognizers' observer only fires on began/changed). This
        // lets a device swipe reveal a pan that .failed/.cancelled without ever beginning.
        view.panGestureRecognizer.addTarget(self, action: #selector(observeScrollPanAllStates(_:)))
```

(Idempotent: UIKit ignores a duplicate identical target/action, and this action differs from `observeRecognizerState`, so both fire.)

- [ ] **Step 3: Grep sanity check**

Run:
```bash
grep -n "observeScrollPanAllStates\|scroll-trace" App/TerminalGestureController.swift
```
Expected: the method definition, the `addTarget` call in `installOurRecognizers`, and the `scroll-trace` log string. Confirm the `addTarget` line is inside `installOurRecognizers` (search up for `func installOurRecognizers`).

- [ ] **Step 4: Commit**

```bash
git add App/TerminalGestureController.swift
git commit -m "diag(term): trace native scroll pan full state machine (Issue 3)

The native scroll pan never begins on an ET/raw-SSH swipe (nothing scrolls)
despite scroll range + an enabled pan, and observeRecognizerState only logs
began/changed, so a pan that fails/cancels without beginning is invisible.
Add observeScrollPanAllStates logging every state (possible/failed/cancelled
too) + translation, attached to panGestureRecognizer at mount. Diagnostic
only; no behavior change. The scroll fix follows from this trace.

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
```

---

### Task 3: Item C part 1, the pure Kit predicate

**Files:**
- Create: `Sources/SemicolynKit/Model/TransportMenu.swift`
- Test: `Tests/SemicolynKitTests/TransportMenuTests.swift`

**Interfaces:**
- Consumes: `Transport` (enum in `Sources/SemicolynKit/Model/Transport.swift`, cases `.ssh`, `.mosh`, `.et`).
- Produces: `public func showsTmuxControlToggle(transport: Transport) -> Bool` (true for `.ssh`/`.et`, false for `.mosh`).

- [ ] **Step 1: Write the failing test**

Create `Tests/SemicolynKitTests/TransportMenuTests.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class TransportMenuTests: XCTestCase {
    func testTmuxToggleShownForSSH() {
        XCTAssertTrue(showsTmuxControlToggle(transport: .ssh))
    }
    func testTmuxToggleShownForET() {
        // tmux -CC is transport-agnostic in principle; ET can run it (wiring pending).
        XCTAssertTrue(showsTmuxControlToggle(transport: .et))
    }
    func testTmuxToggleHiddenForMosh() {
        // Mosh structurally cannot run tmux -CC.
        XCTAssertFalse(showsTmuxControlToggle(transport: .mosh))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TransportMenuTests`
Expected: FAIL to compile, "cannot find 'showsTmuxControlToggle' in scope".

- [ ] **Step 3: Write the implementation**

Create `Sources/SemicolynKit/Model/TransportMenu.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Whether the "Attempt tmux control mode" toggle should be shown for a given transport.
///
/// tmux `-CC` (control mode) runs over any interactive PTY stream, so it is transport
/// agnostic in principle: SSH and ET can both host it. Mosh structurally cannot run
/// tmux `-CC` (documented incompatibility), so the toggle is hidden for Mosh. Note: ET
/// does not yet WIRE tmux `-CC` (that is a later slice); the toggle is shown for ET with
/// a "wiring pending" subtitle so the menu is correct in principle and ready for it.
public func showsTmuxControlToggle(transport: Transport) -> Bool {
    switch transport {
    case .ssh, .et: return true
    case .mosh: return false
    }
}
```

(If `Transport` has additional cases, handle them explicitly, do NOT add a `default`, so a future transport forces a deliberate decision.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TransportMenuTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Model/TransportMenu.swift Tests/SemicolynKitTests/TransportMenuTests.swift
git commit -m "feat(menu): pure showsTmuxControlToggle(transport:) predicate

tmux -CC is transport-agnostic (SSH+ET yes, Mosh no). Extracted as a pure
Linux-tested predicate so the editor gating is covered off the Apple gate.

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
```

---

### Task 4: Item C part 2, apply the menu cleanup in the editors

**Files:**
- Modify: `App/HostEditorSections.swift` (remove the "Enable Mosh" toggle; gate the Mosh config section on transport==Mosh; gate + relabel the tmux-control toggle).
- Modify: `App/DefaultsEditorView.swift` (gate + relabel the tmux-control toggle; the Defaults editor has no per-host "Enable Mosh" toggle, confirm and leave its Mosh handling as-is).
- Modify: `App/HostEditorView.swift` (if the `moshSection` composition needs the transport-gate wrapper).

**Interfaces:**
- Consumes: `showsTmuxControlToggle(transport:)` (Task 3); `resolveTransport(host:defaults:)` OR the editor's current transport selection (`vm.host.transport` / `vm.defaults.transport`, an `Inherited<Transport>`); `Transport`.
- Produces: nothing downstream.

**Note:** App-tier, Linux-invisible. Verify via grep + reading; behavior confirmed on device. The implementer must first READ `App/HostEditorSections.swift` and `App/DefaultsEditorView.swift` to see the exact current structure (transport picker, moshSection, tmux toggle) before editing, since the gating needs the editor's transport value.

- [ ] **Step 1: Determine the editor's selected transport**

In each editor, compute the effective transport for gating. The editors hold an
`Inherited<Transport>` (`vm.host.transport` / `vm.defaults.transport`). Use the resolved
value: for the host editor, `resolveTransport(host: vm.host, defaults: <the defaults the
editor has access to>)`; if the editor has no defaults handle, fall back to the explicit
selection with `.ssh` as the built-in default:

```swift
    // Effective transport for menu gating. Prefer an explicit selection; fall back to the
    // built-in default (.ssh) so the tmux toggle shows by default.
    private var selectedTransport: Transport {
        vm.host.transport.value ?? .ssh   // host editor
    }
```

(For `DefaultsEditorView`, use `vm.defaults.transport.value ?? .ssh`.) Read the file first
to place this correctly and to match how the picker already reads the binding.

- [ ] **Step 2: Gate + relabel the tmux-control toggle (host editor)**

In `App/HostEditorSections.swift`, wrap the existing "Attempt tmux control mode" toggle
(the `Toggle` around line 625-644) so it only appears when
`showsTmuxControlToggle(transport: selectedTransport)`, and update its subtitle to name
tmux `-CC` and note ET wiring is pending:

```swift
            if showsTmuxControlToggle(transport: selectedTransport) {
                Toggle(isOn: Binding(
                    get: { vm.host.semicolyn.value?.tmux?.attemptControlMode ?? true },
                    set: { newAttempt in
                        var cfg = vm.host.semicolyn.value ?? SemicolynConfig()
                        var tmux = cfg.tmux ?? TmuxConfig()
                        tmux.attemptControlMode = newAttempt
                        cfg.tmux = tmux
                        vm.host.semicolyn = .explicit(cfg)
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("tmux control mode (native panes)")
                            .foregroundStyle(Color(theme.text.primary))
                        Text(selectedTransport == .et
                             ? "Runs tmux -CC for native panes. ET support is coming soon."
                             : "Automatically use tmux -CC if tmux is running (default on).")
                            .font(.caption)
                            .foregroundStyle(Color(theme.text.secondary))
                    }
                }
            }
```

(Preserve any surrounding code, e.g. the `controlModeOn` read at line ~646, keep it working; if it referenced the toggle's value for another row, ensure that row still behaves when the toggle is hidden for Mosh, read the file to confirm.)

- [ ] **Step 3: Gate + relabel the tmux-control toggle (Defaults editor)**

Apply the same gate + relabel to the `Toggle` in `App/DefaultsEditorView.swift` (~632),
using `vm.defaults.transport.value ?? .ssh` as the transport:

```swift
            if showsTmuxControlToggle(transport: vm.defaults.transport.value ?? .ssh) {
                Toggle(isOn: Binding(
                    get: { vm.defaults.semicolyn.value?.tmux?.attemptControlMode ?? true },
                    set: { newAttempt in
                        var cfg = vm.defaults.semicolyn.value ?? SemicolynConfig()
                        var tmux = cfg.tmux ?? TmuxConfig()
                        tmux.attemptControlMode = newAttempt
                        cfg.tmux = tmux
                        vm.defaults.semicolyn = .explicit(cfg)
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("tmux control mode (native panes)")
                            .foregroundStyle(Color(theme.text.primary))
                        Text(vm.defaults.transport.value == .et
                             ? "Runs tmux -CC for native panes. ET support is coming soon."
                             : "Automatically use tmux -CC if tmux is running (default on).")
                            .font(.caption)
                            .foregroundStyle(Color(theme.text.secondary))
                    }
                }
            }
```

- [ ] **Step 4: Remove the redundant "Enable Mosh" toggle + gate the Mosh section**

In `App/HostEditorSections.swift`, `moshSection` (line ~401): REMOVE the "Master enabled
toggle" (`Toggle(isOn: ... vm.host.mosh.value?.enabled ...)` with label "Enable Mosh",
lines ~404-421) and its `.onChange`. KEEP the Mosh config fields (server path, UDP ports,
prediction). Then gate the WHOLE `moshSection` so it only shows when the selected
transport is Mosh: in `App/HostEditorView.swift` where `moshSection` is composed
(line ~107), wrap it:

```swift
                if selectedTransport == .mosh {
                    moshSection
                }
```

(Define `selectedTransport` on the view as in Step 1 if not already present. Because the
config fields formerly gated behind `mosh.enabled == true` are now shown whenever
transport==Mosh, read the file and ensure the fields render unconditionally inside the
section, dropping the inner `if vm.host.mosh.value?.enabled == true` wrapper if it exists,
since selecting Mosh in the dropdown is now the enable signal.)

Back-compat: an existing host with `mosh.enabled=true` but no `transport` field resolves
to `.mosh` via `resolveTransport` (Resolution.swift:199), so its Mosh section still shows.
Do NOT change `resolveTransport` or the `mosh` model.

- [ ] **Step 5: Grep + read sanity check**

Run:
```bash
grep -n "Enable Mosh\|showsTmuxControlToggle\|selectedTransport\|tmux control mode (native panes)" App/HostEditorSections.swift App/DefaultsEditorView.swift App/HostEditorView.swift
```
Expected: NO "Enable Mosh" remains; `showsTmuxControlToggle` gates the toggle in both editors; `selectedTransport` defined where used; the new label present. Read the changed regions to confirm the Mosh config fields still render and the tmux toggle is well-formed.

- [ ] **Step 6: Commit**

```bash
git add App/HostEditorSections.swift App/DefaultsEditorView.swift App/HostEditorView.swift
git commit -m "feat(menu): Transport dropdown is the sole selector; scope the tmux toggle

Remove the redundant 'Enable Mosh' toggle (Transport=Mosh is how you pick
Mosh; resolveTransport's legacy migration keeps existing hosts working) and
show the Mosh config section only when transport is Mosh. Gate the tmux
control-mode toggle via showsTmuxControlToggle: shown for SSH+ET, hidden for
Mosh; relabel it 'tmux control mode (native panes)' with an ET 'coming soon'
subtitle (ET -CC wiring is Batch 2).

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
```

---

### Task 5: Push, CI, TestFlight, device retest gate

**Files:** none (CI + device gate only).

**Interfaces:** none.

**Note:** Only NOW (all three items in) push and cut a build, per the user's "address all before CI/TF."

- [ ] **Step 1: Push and watch CI**

```bash
git push github fix/et-onend-clean-exit
gh run watch --repo ds7n/semicolyn $(gh run list --repo ds7n/semicolyn --branch fix/et-onend-clean-exit --workflow CI --limit 1 --json databaseId --jq '.[0].databaseId') --exit-status
```
Expected: `macos` + `linux-swift` (runs the 3 new `TransportMenuTests`) + `linux-rust` + `lint` all green. `macos` is the only signal the App-tier edits compile. Rerun `linux-rust` if it flakes on the sshd-fixtures race.

- [ ] **Step 2: Trigger TestFlight (gated on macos passing) and confirm UPLOAD SUCCEEDED**

```bash
gh workflow run "Release to TestFlight" --repo ds7n/semicolyn --ref fix/et-onend-clean-exit
RID=$(gh run list --repo ds7n/semicolyn --workflow "Release to TestFlight" --branch fix/et-onend-clean-exit --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch --repo ds7n/semicolyn "$RID" --exit-status
gh run view --repo ds7n/semicolyn "$RID" --log | grep -iE "UPLOAD SUCCEEDED|No errors uploading|UPLOAD FAILED"
```

- [ ] **Step 3: Hand off the device retest (all diagnostic categories ON)**

Report the build is ready and to run:
1. **Item A:** connect ET, use it, then exit via BOTH `exit` and the "x" button. Each must return to the connection list with NO "could not connect" screen and NO flash. (Log: no `pre-first-frame -> .failed` on a used session; `et: onEnd during user disconnect -> silent` on the x-button path.)
2. **Item B:** swipe on ET and on raw SSH; capture the `scroll-trace pan=nativePan state=...` lines. Report whether the native pan reaches `.began`(1), `.failed`(5), `.cancelled`(4), or stays `.possible`(0). This names the scroll fix for the next build.
3. **Item C:** host + Defaults editors show Transport as the only transport selector (no "Enable Mosh"); the tmux toggle shows for SSH+ET, is hidden for Mosh, and reads "tmux control mode (native panes)" with the ET "coming soon" subtitle. An existing Mosh host still connects via Mosh.

---

## Self-review checklist (run after writing, fix inline)

- Spec coverage: Item A -> Task 1; Item B -> Task 2; Item C -> Tasks 3 (predicate) + 4 (editors); build/gate -> Task 5.
- No placeholders: all code blocks literal.
- Type consistency: `etUserDisconnecting` (Bool), `observeScrollPanAllStates`/`scroll-trace`, `showsTmuxControlToggle(transport:) -> Bool`, `selectedTransport` used consistently.
- Async-ordering: Task 1 resets the guard at connect-start, never in teardown (called out in Step 4 + Global Constraints).
