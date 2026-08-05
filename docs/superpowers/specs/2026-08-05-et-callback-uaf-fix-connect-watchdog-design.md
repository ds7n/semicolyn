<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Eternal Terminal callback use-after-free fix + connect watchdog, design

**Date:** 2026-08-05
**Status:** approved (brainstorm), pending implementation plan
**Fixes:** on-device CRASH (`EXC_BAD_ACCESS` at `ETSession.mm:62`) + an infinite spinner on a failed/blocked Eternal Terminal connect.
**Depends on:** slices 1a (`8cfd630`), 1b (`0f1b422`), Transport picker (`87edea3`), parse fix (PR #119).

## Root cause (from the device crash report + the syslog sink)

Two symptoms, one root-cause chain, confirmed by the TestFlight crash report (`0.1.0 (112)`):

```
Thread 0 Crashed:
0  libobjc.A.dylib   objc_msgSend + 32
1  Semicolyn         invocation function for block in et_on_end(void*, char const*) + 28 (ETSession.mm:62)
```
`EXC_BAD_ACCESS (SIGSEGV)` inside the `et_on_end` callback block, calling `objc_msgSend` on a freed pointer.

### Bug 1 (CRITICAL, the crash): the callback trampolines capture `self` UNRETAINED
All three C trampolines in `App/ET/ETSession.mm` (`et_on_bytes`, `et_on_state`, `et_on_end`) do:
```objc
static void et_on_end(void *ctx, const char *reason) {
    ETSession *self = (__bridge ETSession *)ctx;   // unretained bridge cast
    ...
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.onEnd) self.onEnd(r);   // self may be DEALLOCATED by now -> crash
    });
}
```
`self` is a `__bridge` (unretained) cast of the C `ctx` pointer. The dispatched block captures that raw pointer, NOT a retained reference. When ET's transport thread fires `on_end` (on a failed / blocked / torn-down connect) and the block hops to the main queue, the `ETSession` can already be deallocated (the connect failed and nothing held a strong reference across the hop). The block then messages freed memory. This is the device crash.

The `-dealloc` safety net (slice 1a) and the `close()` thread-join do NOT prevent this: they guarantee the transport thread is joined before dealloc, but a callback that has ALREADY hopped to the main queue (an in-flight `dispatch_async` block) still holds the stale `self` pointer and runs after dealloc.

Also latent: `et_on_bytes` touches `self->_firstFrameSent` inside the main-queue block; correct queue, but same dangling-`self` exposure.

### Bug 2 (HIGH, the spin): no connect watchdog
`attachET` calls `sess.start()` and wires only `onOutput`/`onEnd`. It does NOT wire `onFirstFrame`/`onState` and has NO timeout. If the ET stream hangs at the port-2022 handshake (a firewalled port, or the protocol-6-client vs 7.0.0-server mismatch), nothing observes the silence, so the UI spins on `.connecting` forever. (The crash is what actually ended the spin on-device: the hang eventually produced an `on_end` that crashed.)

### Bug 3 (LOW, cosmetic): the picker still says "ET"
`Transport.displayName` for `.et` returns `"ET"`; the user asked for the full "Eternal Terminal".

## Scope

### In
1. **Fix the use-after-free in `ETSession.mm`** (the crash): the three trampolines must hold a STRONG reference to `self` for the duration of the async block, so the object cannot dealloc while a callback is in flight.
2. **Connect watchdog + 15s timeout** in `attachET`: wire `onFirstFrame` + `onState`; arm a 15s `Task` on `start()`; if neither `onFirstFrame` nor `onEnd` resolves first, fail to a specific `.failed` message (no SSH fallback), mirroring `moshWatchdog`. Log the ET session lifecycle under `.transport`.
3. **`Transport.displayName` for `.et`** = "Eternal Terminal".

### Out
- The actual protocol-6-vs-7.0.0 handshake fix (re-pin the vendored ET client, or run a matching server). Separate; the watchdog makes it a clean timeout instead of a hang, and the `.transport` log will show where it dies. Watch-item.
- Firewall configuration (user-side).
- Mosh adopting anything here.

## The fix

### 1. `ETSession.mm`, retain `self` for the callback-context lifetime (mirror the PROVEN `MoshSession` pattern)
This is not a novel technique: the sibling `App/Mosh/MoshSession.mm` (reviewed, shipping, crash-free) already does exactly this. Its comment: *"The block retains self, so teardown safely outlives the app dropping its ref."* It hands each callback context a RETAINED (+1) reference via `CFBridgingRetain` when the transport thread is created, and balances it with `CFBridgingRelease` when the thread exits. The ET bridge simply failed to copy that pattern, it passes `(__bridge void *)self` (unretained) to `et_connect`, which is the bug.

**Fix (preferred, matches Mosh): retain `self` for the whole connection, not just per-callback.** ET's `ctx` is passed once to `et_connect` (line 91) and held by the library for the connection's life, so retain there and release on teardown:
```objc
// -start, replacing:  self->_handle = et_connect(&cfg, &cbs, (__bridge void *)self);
void *ctx = (void *)CFBridgingRetain(self);   // +1: self stays alive for the connection
self->_handle = et_connect(&cfg, &cbs, ctx);
if (self->_handle == NULL) { CFBridgingRelease(ctx); /* balance the +1 on sync failure */ }
else { self->_ctx = ctx; }   // store to release on teardown
```
Then in `-close` (and the `-dealloc` net), AFTER `et_close` returns (the transport thread is joined, so no more callbacks will fire), release the +1:
```objc
if (self->_handle) { et_close(self->_handle); self->_handle = NULL; }
if (self->_ctx) { CFBridgingRelease(self->_ctx); self->_ctx = NULL; }
```
The three trampolines keep casting with `__bridge` (unretained cast is now SAFE because the +1 held via `_ctx` keeps `self` alive for the whole connection, including any in-flight main-queue callback):
```objc
static void et_on_end(void *ctx, const char *reason) {
    ETSession *self = (__bridge ETSession *)ctx;   // safe: ctx holds a +1 for the connection's life
    NSString *r = reason ? [NSString stringWithUTF8String:reason] : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.onEnd) self.onEnd(r);
    });
}
```
Key points:
- Add a `void *_ctx;` ivar to hold the retained context so `-close`/`-dealloc` can release exactly once.
- The `CFBridgingRetain`/`CFBridgingRelease` are balanced on ALL paths: sync `et_connect`-NULL failure (release immediately), and normal teardown (release after `et_close` joins the thread). Idempotent `-close` must not double-release (guard on `_ctx != NULL`, nil after release).
- This is strictly stronger than a per-callback strong local: `self` is alive from `et_connect` until the thread is joined, so even a callback that hopped to main just before teardown finds a live object; and because release happens only AFTER `et_close` joins the transport thread, no callback can fire after the release.
- The `NSData` copy in `et_on_bytes` stays BEFORE the hop (unchanged). The `_firstFrameSent` touch is now safe (self is retained).
- Coexists with the existing `-dealloc` safety net + `close()` join (unchanged); this adds the missing retain that makes the `ctx` pointer valid for the callbacks' lifetime.

**Acceptable simpler alternative** if the reviewer prefers minimal change: assign the `__bridge` cast to a strong local `ETSession *self = ...` in each trampoline and let the block capture that (a transient +1 for the block's duration). This fixes the crash too, but retains only across the main-queue hop, not the whole thread lifetime. The `CFBridgingRetain`-at-connect approach above is preferred because it matches the reviewed Mosh pattern and is robust for the full connection lifetime.

### 2. `attachET` connect watchdog (mirror `moshWatchdog`)
Add to `ConnectionViewModel`:
- `private var etWatchdog: Task<Void, Never>?`
- `private var etResolved = false` (terminal-resolution guard, like `moshResolved`)
- Wire `onFirstFrame` (success signal), `onState` (log transitions), keep `onOutput`/`onEnd`.

Flow in `attachET`, after `sess.start()`:
```
etResolved = false
sess.onFirstFrame = { [weak self] in self?.resolveETSuccess() }   // disarms the watchdog
sess.onState = { [weak self] raw in log(.transport, "et: state=\(mapETState(Int32(raw)))") }
sess.onEnd = { [weak self] reason in self?.resolveETEnd(sanitizeEndReason(reason)) }  // disarms
etWatchdog = Task { [weak self] in
    try? await Task.sleep(nanoseconds: 15_000_000_000)   // 15s
    guard !Task.isCancelled, let self, !self.etResolved else { return }
    self.etResolved = true
    self.etSession?.close(); self.etSession = nil
    self.state = .failed("Eternal Terminal timed out: no response on port 2022. Check that etserver is running and TCP 2022 is reachable (firewall).")
    DebugLog.shared.log(.transport, "et: watchdog fired (no first-frame/end in 15s) -> .failed(timeout)")
}
```
- `resolveETSuccess()` / `resolveETEnd(_:)` set `etResolved = true` (guarded, return if already resolved), cancel `etWatchdog`, and drive `.shell` (success) or `.failed(etFailureMessage(.handshakeFailed(reason:)))` (end). This is the terminal-resolution guard: whichever of {first-frame, end, watchdog} happens first wins; the others no-op.
- On success, `onFirstFrame` cancels the watchdog and the session proceeds (output already flows via `onOutput`).
- `teardown()` cancels `etWatchdog` + nils it + resets `etResolved` (alongside the existing `etSession?.close()`).
- Decision (locked): timeout = **15s**; on timeout, **no SSH fallback** (the user chose explicit failure), a `.failed` with the specific message.

### 3. `Transport.displayName`
`case .et: return "Eternal Terminal"` (was `"ET"`). `rawValue` stays `"et"` (persistence + resolver unaffected).

## Testing strategy

### Linux fast loop (`swift test`), real coverage
The crash fix + the watchdog live in Apple-tier `.mm`/`ConnectionViewModel` (macOS-CI-only, not Linux-testable directly), so the Linux-testable surface is thin but real:
| Unit | Tier | Cases |
|---|---|---|
| `Transport.displayName` | Trivial+ | `.et` -> "Eternal Terminal" (exact); `.ssh` -> "SSH"; `.mosh` -> "Mosh". A test asserting the exact string catches a regression of the label. |
| (existing) `Transport` Codable, `resolveTransport`, `mapETState` | unchanged | rawValue stays "et" (persistence unaffected) -> the existing tests must stay green (assert no behavior change from the displayName edit). |

The watchdog decision logic is minimal glue (a Task + a guard); the meaningful correctness is the memory-safety fix + the resolve-once guard, both Apple-tier.

### macOS CI (compile + the bridge test)
- `ETSession.mm` compiles with the strong-capture change; the existing `SemicolynBridgeTests` (fake `et_client`) still passes, AND is the place to add a regression test: drive the fake to fire `on_end` AFTER the session's Swift owner has dropped its reference, and assert no crash (the strong capture keeps the object alive through the callback). If a deterministic "owner dropped mid-callback" is hard to force in the harness, at minimum assert `on_end` after `close()` does not crash and no callback fires post-resolution.
- The `ConnectionViewModel` watchdog + `onFirstFrame`/`onState` wiring compiles.

### Device (the payoff)
Retry the Eternal Terminal connect (build with this fix):
- If port 2022 is blocked / protocol mismatches: the app **does NOT crash** and, after 15s, shows "Eternal Terminal timed out: no response on port 2022 ...". The `.transport` log shows the state sequence + the watchdog firing.
- If it connects: a shell, typing works (the earlier interactive wiring).
- The picker shows "Eternal Terminal".

## Non-goals / YAGNI
- No protocol-version fix (separate watch-item; the watchdog + `.transport` log make it diagnosable).
- No SSH fallback on ET timeout (explicit failure, per the locked decision).
- No change to the `-dealloc` / `close()` join (they stay; the strong-capture fix is complementary).
