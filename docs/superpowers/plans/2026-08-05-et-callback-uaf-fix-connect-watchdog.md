<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Eternal Terminal Callback UAF Fix + Connect Watchdog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the on-device crash (`EXC_BAD_ACCESS` in the ET callback at `ETSession.mm:62`, an unretained `self`), stop the infinite spinner on a blocked Eternal Terminal connect with a 15s watchdog, and spell out "Eternal Terminal" in the picker.

**Architecture:** The crash fix retains the callback context for the connection's lifetime via `CFBridgingRetain`/`CFBridgingRelease` in `ETSession.mm`, mirroring the proven `MoshSession.mm` pattern. The watchdog + `onFirstFrame`/`onState` wiring live in `ConnectionViewModel.attachET`, mirroring `moshWatchdog` with a resolve-once guard. The label is a one-line pure Kit change with a test. Crash fix + watchdog are Apple-tier (macOS-CI + device verified); the label is Linux-tested.

**Tech Stack:** Obj-C++ (`ETSession.mm`, ARC, gnu++17), Swift 6 (ConnectionViewModel), the ET C ABI, `Transport` (SemicolynKit), XCTest.

## Global Constraints

- **Every source file: two-line SPDX header** (`// ...` for Swift/Obj-C, `<!-- -->` for Markdown). REUSE-compliant.
- **No em-dash (U+2014) / en-dash (U+2013)** anywhere (code, comments, docs, commits).
- **`ETSession.mm` is ARC** (confirmed: `__bridge` used, no manual retain/release). The fix uses `CFBridgingRetain`/`CFBridgingRelease`, which are the correct ARC bridging calls, exactly as `App/Mosh/MoshSession.mm` already does.
- **The retain must be balanced on ALL paths** (sync `et_connect`-NULL failure releases immediately; normal teardown releases AFTER `et_close` joins the transport thread) and released **exactly once** (idempotent `-close` must guard against a double release). A leaked `ETSession` (never released) or a double-release (crash) both fail the task.
- **`Sources/SemicolynKit/` is Linux-tested, Swift 6, `Sendable`**, no UIKit/SwiftUI/CryptoKit (the `Transport.displayName` change lives here).
- **`App/` (ETSession.mm, ConnectionViewModel) is Apple-only, macOS-CI + device verified.** No Linux compile.
- **No SSH fallback on ET timeout** (locked user decision): the watchdog sets `.failed(<message>)`.
- **Timeout = 15 seconds** (locked). Timeout message (locked, exact): `"Eternal Terminal timed out: no response on port 2022. Check that etserver is running and TCP 2022 is reachable (firewall)."`
- **Resolve-once**: whichever of {onFirstFrame success, onEnd, watchdog timeout} happens first wins; the others must no-op (mirror `moshResolved`).
- **Tests real** (`docs/superpowers/specs/2026-06-18-testing-standards-design.md`).
- **Conventional commits**; commit after each green step; end every commit message with `Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt`.
- **Build/test:** Kit tests via `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter <Class>` (`.build` perm error -> `docker compose run --rm --user root dev bash -c "chown -R $(id -u):$(id -g) /work/.build"`). ETSession.mm / ConnectionViewModel are macOS-CI-only.
- **Spec:** `docs/superpowers/specs/2026-08-05-et-callback-uaf-fix-connect-watchdog-design.md`. Read it first.
- **Precedent (authoritative):** `App/Mosh/MoshSession.mm` (the `CFBridgingRetain`/`CFBridgingRelease` context-retain pattern + its comments), `App/ConnectionViewModel.swift` `moshWatchdog` (the watchdog Task + `moshResolved` guard, ~lines 154-160, and the arming block).

---

## File Structure
- `Sources/SemicolynKit/Model/Transport.swift`, `.et` displayName "Eternal Terminal".
- `Tests/SemicolynKitTests/TransportCodableTests.swift`, update the displayName assertion.
- `App/ET/ETSession.mm`, `_ctx` ivar + `CFBridgingRetain`/`Release` retain, trampolines stay `__bridge` (now safe).
- `App/ConnectionViewModel.swift`, `etWatchdog`/`etResolved`, wire `onFirstFrame`/`onState`, resolve-once handlers, teardown cleanup.
- `Tests/AppTests/ETSessionTests.mm` (bridge test), a regression test that `on_end` after the owner drops its ref does not crash.

---

### Task 1: Fix the callback use-after-free in `ETSession.mm` (THE CRASH)

**Files:**
- Modify: `App/ET/ETSession.mm`

**Interfaces:**
- Consumes: the ET C ABI (`et_connect`, `et_close`).
- Produces: no signature change; `ETSession` now retains its callback context for the connection lifetime.

This is Apple-tier (no Linux compile). Verified by the macOS bridge test (Task 2) + device. Follow the `MoshSession.mm` pattern exactly.

- [ ] **Step 1: Add the `_ctx` ivar**

In the `@implementation ETSession { ... }` ivar block, add:
```objc
    void *_ctx;   // CFBridgingRetain'd self handed to et_connect; released on teardown
```

- [ ] **Step 2: Retain on connect, balance on sync failure**

In `-start`, replace the `et_connect` call (currently `self->_handle = et_connect(&cfg, &cbs, (__bridge void *)self);`) with a retained context:
```objc
        et_callbacks cbs = { et_on_bytes, et_on_state, et_on_end };
        void *ctx = (void *)CFBridgingRetain(self);   // +1: keep self alive for the connection
        self->_handle = et_connect(&cfg, &cbs, ctx);
        free(ck); free(cv);

        if (self->_handle == NULL) {
            // Synchronous arg failure: no transport thread, release the +1 now.
            CFBridgingRelease(ctx);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.onEnd) self.onEnd(@"et_connect failed");
            });
        } else {
            self->_ctx = ctx;   // released in -close / -dealloc after et_close joins the thread
        }
```

- [ ] **Step 3: Release on teardown (after the thread is joined), exactly once**

In `-close`, after `et_close` nils the handle, release the context:
```objc
- (void)close {
    dispatch_async(_api, ^{
        if (self->_closed) return;
        self->_closed = YES;
        if (self->_handle) { et_close(self->_handle); self->_handle = NULL; }
        if (self->_ctx) { CFBridgingRelease(self->_ctx); self->_ctx = NULL; }
    });
}
```
And in `-dealloc` (the safety net), do the same after the `et_close`:
```objc
- (void)dealloc {
    if (_handle != NULL) {
        et_close(_handle);
        _handle = NULL;
    }
    if (_ctx) { CFBridgingRelease(_ctx); _ctx = NULL; }
}
```
(Guarding on `_ctx != NULL` + niling makes the release exactly-once even if both `-close` and `-dealloc` run.)

- [ ] **Step 4: Confirm the trampolines are now safe (no change needed, verify)**

The three trampolines (`et_on_bytes`, `et_on_state`, `et_on_end`) keep `ETSession *self = (__bridge ETSession *)ctx;` (unretained cast). This is now SAFE because `ctx` holds the +1 for the whole connection: `self` cannot be freed while `_ctx` is non-NULL, and `_ctx` is only released AFTER `et_close` joins the transport thread (so no callback runs after the release). Add a one-line comment on each trampoline noting the ctx holds a +1. Do NOT otherwise change them (the `NSData` copy in `et_on_bytes` stays before the hop).

- [ ] **Step 5: Manual re-read (no Linux compile; macOS CI + Task 2 verify)**

Verify by reading: `_ctx` ivar added; `CFBridgingRetain` at connect; `CFBridgingRelease` on the NULL-handle path AND in `-close` AND in `-dealloc`, each guarded so it releases exactly once; the trampolines unchanged except the comment. Confirm there is no path where `et_connect` succeeds but `_ctx` is never released (that would leak): success -> `_ctx` set -> released in close/dealloc.

- [ ] **Step 6: Commit**

```bash
git add App/ET/ETSession.mm
git commit -m "fix(et): retain callback context for the connection lifetime (fixes ETSession.mm UAF crash)

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
```

---

### Task 2: Bridge-test regression for the UAF (macOS-CI)

**Files:**
- Modify: `Tests/AppTests/ETSessionTests.mm`

**Interfaces:**
- Consumes: `ETSession` + the fake `et_client` (existing bridge test).
- Produces: a test that reproduces the crash scenario and asserts no crash.

This runs on macOS CI only. The goal: fire `on_end` while/after the Swift owner has dropped its strong reference to the `ETSession`, and assert the process does not crash (the retained ctx keeps it alive through the callback).

- [ ] **Step 1: Add the regression test**

Add to `Tests/AppTests/ETSessionTests.mm` a test that:
1. Creates an `ETSession`, sets `onEnd` to a block that fulfills an expectation.
2. Calls `start`.
3. Drops the local strong reference (`s = nil`) WITHOUT calling `close` first, OR calls `close` and then lets the fake fire `on_end` (use whichever the fake supports; the fake's `et_close` already fires `on_end`).
4. Waits for the expectation; asserts it fulfills and the process is alive (reaching the assertion after the callback == no crash).

Concretely, adapt to the existing fake's behavior (the fake's `et_close` calls `on_end` via `dispatch_sync` on its work queue):
```objc
- (void)testOnEndAfterOwnerReleaseDoesNotCrash {
    XCTestExpectation *ended = [self expectationWithDescription:@"end"];
    @autoreleasepool {
        ETSession *s = [self makeSession];   // the helper used by the other tests
        s.onEnd = ^(NSString *reason) { [ended fulfill]; };
        [s start];
        // Drop our only strong ref. Before the fix, the retained-by-nothing ctx
        // meant a subsequent on_end messaged freed memory. With the ctx +1, the
        // session stays alive until teardown releases it, so on_end is safe.
        [s close];   // fake's et_close fires on_end; ctx released after
        s = nil;
    }
    [self waitForExpectations:@[ended] timeout:2.0];
    // Reaching here without a crash is the assertion.
    XCTAssertTrue(YES);
}
```
Adjust `makeSession` to the actual helper name in the file, and if the fake needs a way to emit `on_end` on demand, reuse the existing `fake_et_set_end_reason` / `et_close` path. If the fake fires `on_end` only from `et_close`, the `[s close]` above is the trigger. The essential property: after `s = nil`, a callback that runs must not touch freed memory.

- [ ] **Step 2: Manual re-read + commit**

Confirm the test uses the real `ETSession` + fake (no new fake behavior needed beyond what exists), the `@autoreleasepool` + `s = nil` genuinely drops the ref, and the assertion is "reached without crashing". macOS CI runs it.
```bash
git add Tests/AppTests/ETSessionTests.mm
git commit -m "test(et): regression for the callback UAF (on_end after owner release must not crash)

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
```

---

### Task 3: `Transport.displayName` for `.et` = "Eternal Terminal"

**Files:**
- Modify: `Sources/SemicolynKit/Model/Transport.swift`
- Test: `Tests/SemicolynKitTests/TransportCodableTests.swift`

**Interfaces:**
- Produces: `Transport.et.displayName == "Eternal Terminal"` (was "ET"). `rawValue` unchanged ("et").

- [ ] **Step 1: Update the failing test**

In `Tests/SemicolynKitTests/TransportCodableTests.swift`, the existing `testDisplayNames` asserts `Transport.et.displayName == "ET"`. Change that assertion to:
```swift
XCTAssertEqual(Transport.et.displayName, "Eternal Terminal")
```
(Keep `.ssh` -> "SSH", `.mosh` -> "Mosh".)

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TransportCodableTests`
Expected: FAIL (`"ET"` != `"Eternal Terminal"`).

- [ ] **Step 3: Update the implementation**

In `Sources/SemicolynKit/Model/Transport.swift`, in `displayName`:
```swift
case .et: return "Eternal Terminal"
```
(rawValue stays "et"; do NOT touch `rawValue`, `summary`, or `allCases`.)

- [ ] **Step 4: Run tests to verify pass (+ no regression)**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TransportCodableTests`
Expected: PASS. Then confirm the resolver/Codable are unaffected:
`HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TransportResolutionTests`
Expected: PASS (rawValue unchanged, so no behavior change).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Model/Transport.swift Tests/SemicolynKitTests/TransportCodableTests.swift
git commit -m "fix(transport): spell out Eternal Terminal in the picker (displayName)

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
```

---

### Task 4: ET connect watchdog + onFirstFrame/onState wiring (App, macOS-CI-only)

**Files:**
- Modify: `App/ConnectionViewModel.swift`

**Interfaces:**
- Consumes: `ETSession` (`onFirstFrame`/`onState`/`onEnd`/`close`), `mapETState`/`etFailureMessage`/`sanitizeEndReason` (Kit), the `moshWatchdog` precedent.
- Produces: `etWatchdog`/`etResolved` state + resolve-once handlers, so a blocked ET connect fails to a `.failed(timeout)` in 15s instead of spinning.

Apple-tier (macOS-CI-verified). Mirror `moshWatchdog` (read it first). Keep it wiring.

- [ ] **Step 1: Add the watchdog + resolve-once state**

Near the existing `moshWatchdog`/`moshResolved` declarations (~line 154-160), add:
```swift
    /// ET connect watchdog: fails the connect if the session shows no life (no
    /// onFirstFrame, no onEnd) within the window. Cancelled by either callback.
    private var etWatchdog: Task<Void, Never>?
    /// True once a terminal ET handler (watchdog timeout OR onFirstFrame OR onEnd)
    /// has resolved this session. Guards against double-resolution.
    private var etResolved = false
```

- [ ] **Step 2: Replace the `attachET` onEnd wiring + add onFirstFrame/onState + arm the watchdog**

The current `attachET` tail (App/ConnectionViewModel.swift ~952-975) is:
```swift
        let sess = ETSession(host: config.host, ...)
        sess.onOutput = { [weak self] data in self?.output.onOutput(data: data) }
        sess.onEnd = { [weak self] reason in
            let safe = sanitizeEndReason(reason)
            DebugLog.shared.log(.connect, "et: session ended (\(safe))")
            self?.etSession = nil
        }
        DebugLog.shared.log(.connect, "et: sess.start()")
        sess.start()
        etSession = sess
        connection = conn
        return .success(())
```
Replace the onEnd wiring and add onFirstFrame/onState + the watchdog. Keep onOutput as-is:
```swift
        etResolved = false
        sess.onOutput = { [weak self] data in self?.output.onOutput(data: data) }
        sess.onFirstFrame = { [weak self] in
            guard let self, !self.etResolved else { return }
            self.etResolved = true
            self.etWatchdog?.cancel(); self.etWatchdog = nil
            DebugLog.shared.log(.transport, "et: onFirstFrame, stream up; watchdog cancelled")
            self.state = .shell
        }
        sess.onState = { raw in
            DebugLog.shared.log(.transport, "et: state=\(mapETState(Int32(raw)))")
        }
        sess.onEnd = { [weak self] reason in
            guard let self, !self.etResolved else { return }
            self.etResolved = true
            self.etWatchdog?.cancel(); self.etWatchdog = nil
            let safe = sanitizeEndReason(reason)
            DebugLog.shared.log(.transport, "et: session ended (\(safe))")
            self.etSession?.close(); self.etSession = nil
            self.state = .failed(etFailureMessage(.handshakeFailed(reason: safe)))
        }
        DebugLog.shared.log(.connect, "et: sess.start()")
        sess.start()
        etSession = sess
        connection = conn
        etWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)   // 15s
            guard !Task.isCancelled, let self, !self.etResolved else { return }
            self.etResolved = true
            DebugLog.shared.log(.transport, "et: watchdog fired (no first-frame/end in 15s) → .failed(timeout)")
            self.etSession?.close(); self.etSession = nil
            self.state = .failed("Eternal Terminal timed out: no response on port 2022. Check that etserver is running and TCP 2022 is reachable (firewall).")
        }
        return .success(())
```
Notes for the implementer:
- The `.success(())` return is unchanged (the connect is async; the watchdog/handlers resolve `state` later, exactly as Mosh does).
- `onFirstFrame` sets `.shell` (the session is live). If setting `.shell` here conflicts with any existing state-set in the ET path, reconcile so the terminal shows once frames flow (match how the Mosh success path reaches `.shell`).
- All handlers are `@MainActor`-safe: they touch `self.state`/`self.etSession` which are main-actor; the ETSession callbacks already hop to the main queue (per ETSession.mm), so these run on main. If Swift 6 complains about actor isolation in the closures, wrap the body in `MainActor.assumeIsolated { }` following the existing pattern in this file (see the `@MainActor delegate-callback trap` convention).
- `onState` uses `mapETState(Int32(raw))` for a readable log; `raw` is the `NSInteger` from ETSession.

- [ ] **Step 3: Cancel the watchdog in teardown**

In `teardown()` (where `etSession?.close()` already runs, and next to the `moshWatchdog?.cancel()` line ~494), add:
```swift
        etWatchdog?.cancel(); etWatchdog = nil
        etResolved = false
```

- [ ] **Step 4: Manual re-read + commit**

Confirm: the watchdog arms after `start()`, all three of {onFirstFrame, onEnd, watchdog} are guarded by `etResolved` (resolve-once), each cancels the watchdog, teardown cancels it, and the timeout message is the exact locked string. macOS CI compiles it.
```bash
git add App/ConnectionViewModel.swift
git commit -m "feat(et): 15s connect watchdog + onFirstFrame/onState wiring (no more infinite spin)

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
```

---

### Task 5: Push, verify CI, TestFlight, update TODO

**Files:**
- Modify: `TODO.md`

- [ ] **Step 1: Branch + push**

```bash
git checkout -b fix/et-callback-uaf-watchdog 2>/dev/null || git checkout fix/et-callback-uaf-watchdog
git push -u github fix/et-callback-uaf-watchdog
```

- [ ] **Step 2: Open the PR**

```bash
gh pr create --repo ds7n/semicolyn --base main --head fix/et-callback-uaf-watchdog \
  --title "fix(et): callback use-after-free crash + connect watchdog" \
  --body "$(cat <<'BODY'
Design: docs/superpowers/specs/2026-08-05-et-callback-uaf-fix-connect-watchdog-design.md.

Fixes the on-device Eternal Terminal crash + infinite spinner (device crash report + syslog sink).

- CRASH (EXC_BAD_ACCESS at ETSession.mm:62): the 3 callback trampolines passed (__bridge void *)self UNRETAINED to et_connect, so a callback hopping to main during a failed/blocked connect messaged freed memory. Fix retains the ctx for the connection lifetime via CFBridgingRetain/CFBridgingRelease, mirroring the proven MoshSession.mm pattern (balanced on the sync-failure path + after et_close joins the thread; released exactly once). macOS bridge-test regression added.
- SPIN: attachET had no timeout. Added a 15s connect watchdog (mirror moshWatchdog) + onFirstFrame/onState wiring with a resolve-once guard, so a blocked port-2022 handshake fails to a specific .failed message instead of spinning. Lifecycle logged under the transport category.
- The picker now says "Eternal Terminal" (was "ET").

Enables the on-device retest (should not crash; a blocked/mismatched handshake shows a clear timeout).

https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt
BODY
)"
```

- [ ] **Step 3: Verify all CI jobs green**

Run: `gh run watch --repo ds7n/semicolyn $(gh run list --repo ds7n/semicolyn --branch fix/et-callback-uaf-watchdog --limit 1 --json databaseId --jq '.[0].databaseId')`
Expected: `linux-swift`, `linux-rust`, `lint`, `macos` all pass. The `macos` job is the only signal that ETSession.mm + the bridge test + the watchdog compile and the bridge test passes. Rerun `linux-rust` only if it flakes ("sshd fixtures not reachable").

- [ ] **Step 4: Trigger a TestFlight build (gate on macos green)**

```bash
gh workflow run "Release to TestFlight" --repo ds7n/semicolyn --ref fix/et-callback-uaf-watchdog
```
Confirm the run STARTS, watch it, and confirm the Upload step logs `UPLOAD SUCCEEDED` (the lane reports green even on a failed upload, check the log, per the `testflight-lane-live` memory).

- [ ] **Step 5: Update TODO + commit**

Edit `TODO.md`: record the crash fix + watchdog + label slice (PR #<n>, CI green, TestFlight build N), and that the NEXT step is the on-device Eternal Terminal retest: it must NOT crash; a blocked/mismatched connect shows the 15s timeout message; if it connects, a shell. Keep the protocol-6-vs-7.0.0 watch-item (a handshake mismatch now surfaces as a clean `.failed` via the watchdog / onEnd rather than a hang).

```bash
git add TODO.md
git commit -m "docs: record ET crash fix + connect watchdog; next = device retest

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
git push
```

---

## Self-Review

**Spec coverage:**
- §In 1 (fix the UAF, retain ctx for connection lifetime, CFBridgingRetain/Release mirroring Mosh) -> Task 1 (+ Task 2 regression test).
- §In 2 (15s watchdog, wire onFirstFrame/onState, resolve-once, no SSH fallback, transport logging) -> Task 4.
- §In 3 (displayName "Eternal Terminal") -> Task 3.
- §The fix detail (retain on connect, balance on NULL, release after et_close joins, exactly-once) -> Task 1 Steps 2-3 + the Global Constraint on balanced/exactly-once.
- §Testing Linux (displayName) -> Task 3. §macOS bridge test (on_end after release no crash) -> Task 2. §Device retest -> Task 5.
- §Non-goals (no protocol fix, no SSH fallback, no dealloc/close-join change beyond adding the release) -> respected.

**Placeholder scan:** No "TBD"/"add error handling"/"similar to Task N". Task 2 says "adapt to the fake's actual behavior / helper name", which is a precise instruction to read the existing bridge test (the fake's `et_close`-fires-`on_end` behavior is real, confirmed in the file), not a blank. Task 4's actor-isolation note references the existing `MainActor.assumeIsolated` convention in the file.

**Type consistency:** `ETSession` init + `onFirstFrame`/`onState`/`onEnd`/`close` match slice 1a's header. `CFBridgingRetain`/`CFBridgingRelease` are the ARC-correct bridging calls (same as MoshSession.mm). `etWatchdog: Task<Void, Never>?` + `etResolved: Bool` mirror `moshWatchdog`/`moshResolved`. `mapETState(Int32)`, `etFailureMessage(.handshakeFailed(reason:))`, `sanitizeEndReason` match shipped Kit API. `Transport.et.displayName` change keeps `rawValue == "et"` (persistence/resolver unaffected). The exact timeout string matches the spec's locked message.
