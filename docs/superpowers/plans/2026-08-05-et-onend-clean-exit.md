<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# ET `onEnd` clean-exit fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a clean Eternal Terminal `exit` gracefully dismiss to the connection list instead of leaving the terminal up, silently swallowing input.

**Architecture:** Add a pure, Linux-tested `etExitDecision(reason:sawFirstFrame:)` decider in `Sources/SemicolynKit/ET/` (mirroring `MoshExitDecision`), then rewrite `attachET`'s `onEnd` in `App/ConnectionViewModel.swift` to route on it: first-frame-seen end → `teardown()` + `state = .idle` (dismiss); never-saw-first-frame end → the existing `.failed` handshake banner.

**Tech Stack:** Swift 6 (strict concurrency, `Sendable`), XCTest. Kit tier is Linux-tested via the `semicolyn-dev` Docker image; the App-tier `onEnd` edit is macOS-CI-validated only.

## Global Constraints

- **Two tiers:** `Sources/SemicolynKit/` = pure logic, Linux-tested, NO `import UIKit`/`SwiftUI`/`CryptoKit`. `App/` = Apple-only, macOS-CI-verified, invisible to `swift test`.
- **SPDX header on every source file:** `// SPDX-FileCopyrightText: 2026 True Positive LLC` + `// SPDX-License-Identifier: GPL-3.0-only`.
- **No em-dash (U+2014) or en-dash (U+2013)** anywhere (prose, code, comments, commits). Use a colon, comma, parentheses, semicolon, or two sentences.
- **Tests must be real:** equivalence-partitioning + boundary values, assert observable values (no tautologies); a negative test asserts the *specific* failure/output.
- **Conventional commits** (`feat:`/`fix:`/`docs:`/…).
- **SECURITY:** the ET end `reason` is UNTRUSTED (possibly server-supplied). It must be sanitized (`sanitizeEndReason`) before reaching any log or banner. Never log the sanitized reason at a level that implies it is trusted; never bypass sanitization.
- **Kit test command:** `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter <TestName>`.

---

### Task 1: `etExitDecision` pure Kit decider

**Files:**
- Create: `Sources/SemicolynKit/ET/ETExitDecision.swift`
- Test: `Tests/SemicolynKitTests/ET/ETExitDecisionTests.swift`

**Interfaces:**
- Consumes: `sanitizeEndReason(_ reason: String?) -> String` (already in `Sources/SemicolynKit/ET/ETEndReason.swift`); returns `"connection ended"` for nil/empty and strips ANSI/control/`<...>` markup, truncating to 80 scalars.
- Produces:
  - `public enum ETExitDecision: Equatable, Sendable { case dismiss; case handshakeFailed(String) }`
  - `public func etExitDecision(reason: String?, sawFirstFrame: Bool) -> ETExitDecision`
    - `sawFirstFrame == true` → `.dismiss` (reason ignored)
    - `sawFirstFrame == false` → `.handshakeFailed(sanitizeEndReason(reason))`

- [ ] **Step 1: Write the failing test**

Create `Tests/SemicolynKitTests/ET/ETExitDecisionTests.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ETExitDecisionTests: XCTestCase {
    // ── first-frame seen → always .dismiss (graceful), reason ignored ──────────

    func testFirstFrameSeen_nilReason_dismisses() {
        XCTAssertEqual(etExitDecision(reason: nil, sawFirstFrame: true), .dismiss)
    }

    func testFirstFrameSeen_benignReason_dismisses() {
        XCTAssertEqual(etExitDecision(reason: "session ended", sawFirstFrame: true), .dismiss)
    }

    func testFirstFrameSeen_dropReason_dismisses() {
        // A mid-session network drop after a real session still dismisses gracefully.
        XCTAssertEqual(etExitDecision(reason: "connection lost", sawFirstFrame: true), .dismiss)
    }

    func testFirstFrameSeen_adversarialReasonIgnored_dismisses() {
        // The untrusted reason is NOT consulted on the dismiss path.
        XCTAssertEqual(etExitDecision(reason: "\u{1B}[31mboom\u{1B}[0m", sawFirstFrame: true), .dismiss)
    }

    // ── first-frame never seen → .handshakeFailed(sanitized reason) ────────────

    func testNoFirstFrame_nilReason_failsWithSanitizeDefault() {
        // sanitizeEndReason(nil) == "connection ended"
        XCTAssertEqual(etExitDecision(reason: nil, sawFirstFrame: false),
                       .handshakeFailed("connection ended"))
    }

    func testNoFirstFrame_plainReason_failsWithReason() {
        XCTAssertEqual(etExitDecision(reason: "handshake rejected", sawFirstFrame: false),
                       .handshakeFailed("handshake rejected"))
    }

    func testNoFirstFrame_ansiControlReason_failsWithSanitizedValue() {
        // Proves sanitization is wired through the decider: ANSI SGR + trailing
        // CRLF are stripped, leaving exactly "fail". If the decider forgot to call
        // sanitizeEndReason, this asserts the wrong (raw) string and fails.
        XCTAssertEqual(etExitDecision(reason: "\u{1B}[1mfail\u{1B}[0m\r\n", sawFirstFrame: false),
                       .handshakeFailed("fail"))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ETExitDecisionTests`
Expected: FAIL to compile with "cannot find 'etExitDecision' in scope" / "cannot find type 'ETExitDecision'".

- [ ] **Step 3: Write the minimal implementation**

Create `Sources/SemicolynKit/ET/ETExitDecision.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// How an ET session end should be handled by `ConnectionViewModel`. Pure +
/// Linux-tested so the decision is covered off the Apple-only bridge gate,
/// mirroring `MoshExitDecision`.
///
/// Unlike Mosh (which cannot trust its pre-handshake init frame and classifies on
/// reason + elapsed), ET's `onFirstFrame` fires only when the stream is genuinely
/// up, so first-frame IS a reliable success signal: once seen, any later end is a
/// normal session end that should dismiss gracefully.
public enum ETExitDecision: Equatable, Sendable {
    /// A real session ran (first-frame seen) and then ended. The App tears the
    /// session down and returns to the connection list. No error banner.
    case dismiss
    /// First-frame never fired: the handshake never came up. The App shows the
    /// `.failed` banner carrying this sanitized reason string.
    case handshakeFailed(String)
}

/// Classify an ET session end.
/// - Parameters:
///   - reason: the raw `onEnd` reason. UNTRUSTED (possibly server-supplied); only
///     consulted on the failure path, and sanitized here before it can reach the
///     UI or a log.
///   - sawFirstFrame: whether `onFirstFrame` fired for this session.
public func etExitDecision(reason: String?, sawFirstFrame: Bool) -> ETExitDecision {
    sawFirstFrame ? .dismiss : .handshakeFailed(sanitizeEndReason(reason))
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ETExitDecisionTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/ET/ETExitDecision.swift Tests/SemicolynKitTests/ET/ETExitDecisionTests.swift
git commit -m "feat(et): pure etExitDecision (first-frame-seen -> dismiss | handshakeFailed)

Mirrors MoshExitDecision. Keys on sawFirstFrame: a session that reached
first-frame and then ended dismisses gracefully; one that never did is a
pre-connect handshake failure. Sanitizes the untrusted reason internally.

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
```

---

### Task 2: Route `attachET`'s `onEnd` on `etExitDecision`

**Files:**
- Modify: `App/ConnectionViewModel.swift` (the `attachET` `onEnd` closure ~lines 985-999; the `onFirstFrame` closure ~lines 975-981; add an `etFirstFrameSeen` property near the existing `etResolved`; reset it in `teardown()` ~line 507).

**Interfaces:**
- Consumes: `etExitDecision(reason:sawFirstFrame:) -> ETExitDecision` (Task 1); the existing `teardown()`, `etFailureMessage(_:)`, `ETBootstrapError.handshakeFailed(reason:)`, `state`, `etResolved`, `etWatchdog`, `etSession`.
- Produces: nothing new consumed downstream; this is the terminal wiring task.

**Note on verification:** `App/ConnectionViewModel.swift` does NOT compile on Linux (`swift test` cannot see it); it is validated by the macOS CI job only. There is no local Step to "run the test" for this task; verification is the macOS CI compile + the device retest in the spec. Keep the edit mechanical and exact.

- [ ] **Step 1: Add the `etFirstFrameSeen` property**

Find the existing `etResolved` declaration (the ET analog of `moshResolved`, around line 164 per the field's doc comment "True once a terminal ET handler … has fired"). Immediately after it, add:

```swift
    /// True once ET's `onFirstFrame` fired for the current session. Drives
    /// `etExitDecision`: a session that reached first-frame and then ended is a
    /// graceful dismiss; one that never did is a pre-connect handshake failure.
    /// Reset in `teardown()`.
    private var etFirstFrameSeen = false
```

- [ ] **Step 2: Set `etFirstFrameSeen` in `onFirstFrame`**

In the `attachET` `onFirstFrame` closure, alongside the existing `self.etResolved = true`, add the flag set. The block currently reads:

```swift
        sess.onFirstFrame = { [weak self] in
            guard let self, !self.etResolved else { return }
            self.etResolved = true
            self.etWatchdog?.cancel(); self.etWatchdog = nil
            DebugLog.shared.log(.transport, "et: onFirstFrame, stream up; watchdog cancelled")
            self.state = .shell
        }
```

Change it to add `self.etFirstFrameSeen = true` right after `self.etResolved = true`:

```swift
        sess.onFirstFrame = { [weak self] in
            guard let self, !self.etResolved else { return }
            self.etResolved = true
            self.etFirstFrameSeen = true
            self.etWatchdog?.cancel(); self.etWatchdog = nil
            DebugLog.shared.log(.transport, "et: onFirstFrame, stream up; watchdog cancelled")
            self.state = .shell
        }
```

- [ ] **Step 3: Rewrite the `onEnd` closure to route on `etExitDecision`**

The `onEnd` closure currently reads:

```swift
        sess.onEnd = { [weak self] reason in
            guard let self else { return }
            let safe = sanitizeEndReason(reason)
            DebugLog.shared.log(.transport, "et: session ended (\(safe))")
            self.etWatchdog?.cancel(); self.etWatchdog = nil
            self.etSession?.close()      // ALWAYS release the retained ctx + tear down
            self.etSession = nil         // ALWAYS drop the ref
            // Only the outcome transition is resolve-once: if the connect already
            // resolved (success .shell, or the watchdog timeout), a natural/late end
            // must NOT clobber that state.
            if !self.etResolved {
                self.etResolved = true
                self.state = .failed(etFailureMessage(.handshakeFailed(reason: safe)))
            }
        }
```

Replace the WHOLE closure with:

```swift
        sess.onEnd = { [weak self] reason in
            guard let self else { return }
            self.etWatchdog?.cancel(); self.etWatchdog = nil
            switch etExitDecision(reason: reason, sawFirstFrame: self.etFirstFrameSeen) {
            case .dismiss:
                // A real session ran (first-frame seen) and then ended (clean exit
                // or mid-session drop). Return to the connection list gracefully:
                // teardown() closes+nils etSession, cancels the watchdog, and resets
                // every flag; .idle dismisses the view. No error banner.
                DebugLog.shared.log(.transport, "et: session ended (first-frame seen) → dismiss to list")
                self.teardown()
                self.state = .idle
            case .handshakeFailed(let safe):
                // First-frame never fired: a pre-connect failure. If the watchdog
                // already resolved this session to a timeout .failed, a late onEnd
                // (enqueued before the callback was niled) must NOT clobber it.
                if self.etResolved {
                    DebugLog.shared.log(.transport, "et: onEnd after watchdog already resolved → ignored")
                    return
                }
                self.etResolved = true
                DebugLog.shared.log(.transport, "et: session ended pre-first-frame (\(safe)) → .failed")
                self.etSession?.close()   // release the retained ctx + tear down
                self.etSession = nil
                self.state = .failed(etFailureMessage(.handshakeFailed(reason: safe)))
            }
        }
```

Key points of the rewrite:
- The `.transport` log line and the banner both use `safe` (already sanitized by `etExitDecision`); no separate `sanitizeEndReason` call remains in `onEnd`.
- The `.dismiss` path relies on `teardown()` to close+nil `etSession` (so the redundant inline `etSession?.close()` is dropped from that path).
- The `.handshakeFailed` path keeps the close+nil + resolve-once + `.failed` behavior unchanged (only the guard now branches on the decision, and the watchdog-already-resolved bail is preserved).

- [ ] **Step 4: Reset `etFirstFrameSeen` in `teardown()`**

In `teardown()`, find the existing ET reset lines:

```swift
        etWatchdog?.cancel(); etWatchdog = nil
        etResolved = false
        etSession?.close()
        etSession = nil
```

Add the flag reset immediately after `etResolved = false`:

```swift
        etWatchdog?.cancel(); etWatchdog = nil
        etResolved = false
        etFirstFrameSeen = false
        etSession?.close()
        etSession = nil
```

- [ ] **Step 5: Local sanity check (grep, since this file is Linux-invisible)**

Confirm the edits landed and no stale `sanitizeEndReason(reason)` remains in `onEnd`, and the new symbol is referenced:

Run:
```bash
grep -n "etFirstFrameSeen\|etExitDecision\|et: session ended" App/ConnectionViewModel.swift
```
Expected: `etFirstFrameSeen` appears 3× (declaration, `onFirstFrame` set, `teardown` reset); `etExitDecision` appears 1× (in `onEnd`); two `et: session ended` log strings (dismiss + failed paths). No `let safe = sanitizeEndReason(reason)` line left in the `onEnd` closure.

- [ ] **Step 6: Commit**

```bash
git add App/ConnectionViewModel.swift
git commit -m "fix(et): clean exit dismisses to connection list instead of hanging

A clean Eternal Terminal exit left state=.shell forever: onEnd took no
action once first-frame was seen, so the terminal stayed up and silently
swallowed input. Route onEnd on the new etExitDecision: first-frame-seen
end -> teardown() + .idle (graceful dismiss, no banner); pre-first-frame
end -> the existing .failed handshake banner (watchdog-resolved bail kept).

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
```

---

### Task 3: Push to CI and verify the macOS build

**Files:** none (CI + verification only).

**Interfaces:** none.

- [ ] **Step 1: Push the branch and open the PR**

```bash
git push -u github fix/et-onend-clean-exit
gh pr create --repo ds7n/semicolyn --base main --head fix/et-onend-clean-exit \
  --title "fix(et): clean exit dismisses to connection list" \
  --body "$(cat <<'BODY'
Clean Eternal Terminal `exit` left `state=.shell` forever (onEnd took no
action once first-frame was seen), so the terminal stayed up and silently
swallowed input. This routes `attachET`'s `onEnd` on a new pure,
Linux-tested `etExitDecision(reason:sawFirstFrame:)`:

- first-frame seen -> `teardown()` + `.idle` (graceful dismiss to the
  connection list, no banner)
- first-frame never seen -> the existing `.failed` handshake banner
  (watchdog-already-resolved bail preserved)

Mirrors `MoshExitDecision`. The 15s watchdog, ctx `CFBridgingRetain`
lifecycle, and close-once semantics are untouched.

Spec: docs/superpowers/specs/2026-08-05-et-onend-clean-exit-design.md
Plan: docs/superpowers/plans/2026-08-05-et-onend-clean-exit.md

https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt
BODY
)"
```

- [ ] **Step 2: Watch CI, especially the macOS job**

Run: `gh run watch --repo ds7n/semicolyn $(gh run list --repo ds7n/semicolyn --branch fix/et-onend-clean-exit --limit 1 --json databaseId --jq '.[0].databaseId')`
Expected: `linux-swift` (must include the 7 new `ETExitDecisionTests`), `linux-rust`, `lint`, and the `macos` job all green. `macos` is the ONLY signal that the `ConnectionViewModel` edit compiles.
Note: `linux-rust` occasionally flakes on the sshd-fixtures readiness race; if only that job fails, rerun it (`gh run rerun <id> --failed`).

- [ ] **Step 3: Report status and hand off to the device retest**

Once CI is green, report the run URL and remind the user this needs the on-device ET retest from the spec (§"Device retest"): connect ET to the dev box, type `exit`, confirm it returns to the connection list with no banner and stops accepting input; confirm a no-etserver host still shows the `.failed` banner and the 15s timeout still fires. Do NOT merge until the device test passes (per the ET slice pattern).
