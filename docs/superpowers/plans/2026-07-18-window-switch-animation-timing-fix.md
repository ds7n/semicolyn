<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Window-switch Animation Timing Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the window-switch animation actually play by giving the ANIMATION control of the transition timing (a both-ready gate) instead of racing tmux, plus a paired page-turn (old slides off, new snapshot slides in from the opposite edge).

**Architecture:** Pure App-tier (UIKit timing). No Kit changes. Two Coordinator readiness flags (`switchAnimDone`, `switchDelivered`) gate a shared `finishSwitchHandoffIfReady()` so the live-window swap happens only when the 180 ms slide has finished AND tmux has delivered (whichever is last). `commitSwitchDrag` runs a paired slide; `completePendingSwitchIfNeeded` records delivery instead of resetting transforms. Diagnostics log every ordering step so the next syslog proves the timing.

**Tech Stack:** Swift 6 (strict concurrency), UIKit + SwiftTerm (App tier, macOS-CI / device only), tmux `-CC`. No `swift test` surface (App tier is invisible to Linux).

**Spec:** `docs/superpowers/specs/2026-07-18-window-switch-animation-timing-fix-design.md`

**Root cause (from device syslog `data/syslog/semicolyn-bunknown-2026-07-18.log`):** the 180 ms commit slide is reset mid-animation by `completePendingSwitchIfNeeded` because tmux delivers in ~120 ms; the snapshot also covers the pane instantly; and fast flicks give ~100 ms of drag. The animation never plays.

## Global Constraints

- **App tier only:** does NOT compile on Linux / invisible to `swift test`. The macOS CI job is the ONLY compile signal (webhook may need a manual dispatch: `gh workflow run CI --ref feat/finger-drag-window-transition`).
- **RECURRING macOS-CI TRAP:** the pane-container `Coordinator` is a NONISOLATED NSObject; every method touching `@MainActor`/UIKit/`DebugLog` must be inside `MainActor.assumeIsolated {}`. All existing switch methods already do; new code MUST match. Private helpers called ONLY from within already-wrapped callers do NOT self-wrap (matches `clearPendingSwitch`/`updateGapDim`/`discardCommittedSnapshot`).
- **SPDX header** already present in the file (modifying, not creating). No em-dashes in added comments.
- **Kit stays green:** run `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test` after each task to confirm no Kit regression (App changes should not touch Kit).
- **Direction geometry (from `windowSlideDirection(delta:)`):** `delta<0` (rightward swipe, previous window) -> `out: .right, in: .left` (current slides off RIGHT, new enters from LEFT). `delta>0` -> `out: .left, in: .right`. A `.left` edge maps to x offset `-width`, `.right` to `+width`.
- **Preserve** the pivot's core property: the snapshot is laid out at its FINAL full-size frame (`WindowSnapshotStore.layout(...)`) - never scaled - so no zoom mismatch. It just STARTS off the incoming edge and animates to identity.
- **Preserve** the C1 fix (rapid double-switch), the I1/I2 fixes (no-op switch spring-back, gap-dim full at commit), and the 1.5 s timeout backstop.
- **Branch:** continues on `feat/finger-drag-window-transition` (PR #103); commits stack on top.

---

## File Structure

**App (modified, one file):**
- `App/TmuxPaneContainer.swift` - the `Coordinator`:
  - Add `switchAnimDone: Bool` + `switchDelivered: Bool` state.
  - Add `finishSwitchHandoffIfReady()` (the both-ready gate + teardown).
  - Rewrite `commitSwitchDrag(delta:)` (paired page-turn + reset flags + completion sets `switchAnimDone` + calls the gate).
  - Rewrite `completePendingSwitchIfNeeded(newActive:)` (record delivery + call the gate, not reset directly).
  - Update `failPendingSwitch()`, `discardCommittedSnapshot()`, `cancelSwitchDrag()` to reset the two flags.
  - Add ordering diagnostics (`.gesture` log lines).

**Unchanged (verify, don't touch):** `GapDim.swift`, `WindowDragModel.swift`, `DragAxisLock.swift`, `SwitchCommitDecision.swift`, `WindowSnapshotStore.swift`, `WindowSlide.swift`, `TerminalGestureController.swift`, `updateSwitchDrag`/`updateGapDim`/`clearGapDim` (the live-drag path already fires correctly).

---

## Task 1: Both-ready gate + flags + delivery recorder (the race fix)

**Why:** This is the core fix. Split the teardown out of `completePendingSwitchIfNeeded` into a shared `finishSwitchHandoffIfReady()` gated on BOTH the animation and delivery being done, so tmux delivering early no longer resets the transform mid-animation.

**Files:**
- Modify: `App/TmuxPaneContainer.swift` (Coordinator state + `finishSwitchHandoffIfReady` + `completePendingSwitchIfNeeded` + `failPendingSwitch` + `discardCommittedSnapshot`)
- Test: none (App tier); Kit stays green.

**Interfaces:**
- Consumes: existing `revealedSnapshot`, `pendingSwitchWindow`, `pendingSwitchTimeout`, `clearGapDim()`, `containerView`.
- Produces: `switchAnimDone: Bool`, `switchDelivered: Bool`, `finishSwitchHandoffIfReady()`.

- [ ] **Step 1: Add the two readiness flags to the Coordinator state**

Next to `private var pendingSwitchWindow: WindowID?` (~line 160), add:

```swift
        /// Both-ready gate for the commit handoff (2026-07-18 timing fix): the live window
        /// swaps in only when the commit slide animation has finished (`switchAnimDone`) AND
        /// tmux has delivered the target window (`switchDelivered`). Whichever async event
        /// finishes LAST triggers `finishSwitchHandoffIfReady`. Fixes the race where tmux
        /// delivery (~120ms) reset the transform mid-slide (180ms) so no animation was seen.
        private var switchAnimDone = false
        private var switchDelivered = false
```

- [ ] **Step 2: Add `finishSwitchHandoffIfReady()` (the gate + teardown)**

Add this method next to `completePendingSwitchIfNeeded` (it centralizes the teardown that method
used to do inline). Place it just BEFORE `completePendingSwitchIfNeeded`:

```swift
        /// The both-ready gate: complete the commit handoff only when the slide animation has
        /// finished AND tmux has delivered the target window. Called from BOTH the commit
        /// animation completion and the delivery path; the second caller (whichever is last)
        /// runs the teardown. No-op until both flags are set. Main-actor caller only (both
        /// call sites are inside `assumeIsolated` blocks).
        private func finishSwitchHandoffIfReady() {
            guard switchAnimDone, switchDelivered else {
                DebugLog.shared.log(.gesture,
                    "switch finish WAIT anim=\(switchAnimDone) delivered=\(switchDelivered)")
                return
            }
            pendingSwitchTimeout?.cancel(); pendingSwitchTimeout = nil
            pendingSwitchWindow = nil
            switchAnimDone = false
            switchDelivered = false
            // Live panes are already mounted UNDER the snapshot by `apply(state:)`; reveal them
            // by resetting the content transform and removing the covering snapshot + gap-dim.
            containerView?.paneContentView.transform = .identity
            revealedSnapshot?.view.removeFromSuperview(); revealedSnapshot = nil
            clearGapDim()
            DebugLog.shared.log(.gesture, "switch finish (both-ready) -> live shown")
        }
```

- [ ] **Step 3: Rewrite `completePendingSwitchIfNeeded` to record delivery + call the gate**

Replace the body of `completePendingSwitchIfNeeded(newActive:)` (the version that resets transforms
directly) with:

```swift
        /// Called from `apply(state:)` when the active window actually changed: RECORD that
        /// tmux delivered the target window, then let the both-ready gate decide whether to
        /// finish now (if the slide animation has also finished) or wait for it. No-op if no
        /// drag-switch is pending (e.g. an esc-pill switch, which sets no `pendingSwitchWindow`).
        /// Wrapped in `MainActor.assumeIsolated` (Swift 6 checks isolation per-method; nested
        /// wrap when called from `apply`'s own block is a runtime assertion, safe to nest).
        func completePendingSwitchIfNeeded(newActive: WindowID) {
            MainActor.assumeIsolated {
                guard pendingSwitchWindow != nil else {
                    // A switch that arrived without our drag (e.g. esc-pill): nothing to hand off.
                    return
                }
                switchDelivered = true
                DebugLog.shared.log(.gesture,
                    "switch delivered active=@\(newActive.raw) animDone=\(switchAnimDone)")
                finishSwitchHandoffIfReady()
            }
        }
```

- [ ] **Step 4: Reset both flags in `failPendingSwitch` (timeout) and `discardCommittedSnapshot` (C1)**

In `failPendingSwitch()`, after `pendingSwitchWindow = nil`, add the flag reset (the timeout path
must clear the gate so a later commit starts clean):

```swift
        private func failPendingSwitch() {
            MainActor.assumeIsolated {
                pendingSwitchTimeout = nil
                pendingSwitchWindow = nil
                switchAnimDone = false
                switchDelivered = false
                containerView?.paneContentView.transform = .identity
                revealedSnapshot?.view.removeFromSuperview(); revealedSnapshot = nil
                clearGapDim()
                DebugLog.shared.log(.gesture, "switch TIMEOUT -> restore current")
            }
        }
```

In `discardCommittedSnapshot()` (the C1 helper), also reset the flags so a new drag interrupting a
pending commit starts from a clean gate:

```swift
        private func discardCommittedSnapshot() {
            guard revealedSnapshot != nil else { return }
            revealedSnapshot?.view.removeFromSuperview()
            revealedSnapshot = nil
            switchAnimDone = false
            switchDelivered = false
            containerView?.paneContentView.transform = .identity
            clearGapDim()
        }
```

> **Verify:** confirm `discardCommittedSnapshot` is still called from `beginSwitchReveal` before
> `clearPendingSwitch` (grep both). The flag resets here matter because a rapid second drag must not
> inherit a half-set gate from switch A.

- [ ] **Step 5: Verify Kit still builds/tests**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS (App change invisible to Linux; confirms nothing Kit-side broke).

- [ ] **Step 6: Commit**

```bash
git add App/TmuxPaneContainer.swift
git commit -m "fix(terminal): both-ready gate for switch handoff (animation vs tmux-delivery race)"
```

---

## Task 2: Paired page-turn commit animation + `switchAnimDone` + diagnostics

**Why:** With the gate in place, make the commit a visible page-turn (old slides off one edge, new snapshot slides in from the opposite edge), and set `switchAnimDone` in the animation completion so the gate fires. Add the ordering diagnostics the syslog needed.

**Files:**
- Modify: `App/TmuxPaneContainer.swift` (`commitSwitchDrag`)
- Test: none (App tier); Kit stays green.

**Interfaces:**
- Consumes: `switchAnimDone`/`switchDelivered` (Task 1), `finishSwitchHandoffIfReady()` (Task 1), `windowSlideDirection(delta:)`, `WindowSnapshotStore.snapshotView(for:)` + `layout(...)`, `resolvedCellPublic()`, `GapDim.maxOpacity`.
- Produces: a `commitSwitchDrag` that runs the paired slide, sets `switchAnimDone` in completion, and gates the handoff.

- [ ] **Step 1: Rewrite `commitSwitchDrag` for the paired page-turn**

Replace the body of `commitSwitchDrag(delta:)` (currently the version that animates only `content`
off + adds the snapshot at identity instantly) with:

```swift
        func commitSwitchDrag(delta: Int) {
            MainActor.assumeIsolated {
                guard let content = containerView?.paneContentView,
                      let container = containerView,
                      let vm, let state = vm.tmuxState,
                      let active = state.activeWindow,
                      let dir = windowSlideDirection(delta: delta) else { cancelSwitchDrag(); return }
                // I1: a switch whose target is the CURRENT window never changes activeWindow, so
                // the delivery gate would never fire - spring back instead of committing.
                let target = vm.neighborWindow(of: active, delta: delta)
                guard let neighbor = target, neighbor != active else { cancelSwitchDrag(); return }

                let w = container.bounds.width
                let outX: CGFloat = (dir.out == .left) ? -w : w   // current window exits this edge
                let inStartX: CGFloat = (dir.in == .left) ? -w : w // new window enters from this edge

                // Fresh gate for this commit.
                switchAnimDone = false
                switchDelivered = false

                // I2: force the gap-dim to full so the exposed gap reads as solid grey (a fast
                // flick may have left the drag-ramped alpha near zero).
                container.gapDimOverlay().alpha = CGFloat(GapDim.maxOpacity)

                // Place the pre-warmed snapshot at its FINAL full-size frame (no zoom mismatch),
                // but START it one width off the INCOMING edge so it can slide in. If the capture
                // has not landed yet, there is no incoming view - the current window still slides
                // off over the dark gap, and the live window draws on delivery.
                let host = vm.snapshotStore?.snapshotView(for: neighbor)
                if let host {
                    container.addSubview(host)                          // above gapDim + content
                    let cell = container.resolvedCellPublic()
                    vm.snapshotStore?.layout(window: neighbor, in: state, bounds: container.bounds,
                                             cellWidth: cell.w, cellHeight: cell.h)
                    host.transform = CGAffineTransform(translationX: inStartX, y: 0) // start off-edge
                    revealedSnapshot = (host, neighbor)
                }
                pendingSwitchWindow = neighbor

                // Paired page-turn: current window slides OFF `outX`, new snapshot slides IN from
                // `inStartX` to identity, in one animation. The animation OWNS the timing - its
                // completion sets `switchAnimDone` and asks the both-ready gate to finish (which
                // waits if tmux has not delivered yet, and no longer resets mid-slide).
                DebugLog.shared.log(.gesture,
                    "switch anim-start delta=\(delta) snapshot=\(host != nil) out=\(dir.out) in=\(dir.in)")
                UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut], animations: {
                    content.transform = CGAffineTransform(translationX: outX, y: 0)
                    host?.transform = .identity
                }, completion: { [weak self] _ in
                    // Runs inside the outer `assumeIsolated` context (the enclosing
                    // `commitSwitchDrag` block), so main-actor state is reachable directly -
                    // NO inner `assumeIsolated` (matches the shipped `cancelSwitchDrag`
                    // completion, which touches `revealedSnapshot` unwrapped and compiles on CI).
                    self?.switchAnimDone = true
                    DebugLog.shared.log(.gesture, "switch anim-done")
                    self?.finishSwitchHandoffIfReady()
                })

                onSwitchWindow(delta)   // tmux select-window (delivery flips `switchDelivered`)

                // 1.5s timeout backstop (unchanged): a never-delivered switch restores the current.
                pendingSwitchTimeout?.cancel()
                let timeout = DispatchWorkItem { [weak self] in self?.failPendingSwitch() }
                pendingSwitchTimeout = timeout
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: timeout)
            }
        }
```

> **Grounded (verified against the shipped code):** the animation `completion` closure needs NO
> inner `MainActor.assumeIsolated` - it sits inside the enclosing `commitSwitchDrag` `assumeIsolated`
> block and inherits that isolation, exactly like the SHIPPED `cancelSwitchDrag` completion (which
> touches `revealedSnapshot` unwrapped and compiles CI-green). Do NOT add an inner wrap. The timeout
> `DispatchWorkItem` body DOES self-wrap (it fires later, off the async queue) - `failPendingSwitch`
> already wraps its own body, so the timeout closure just calls `self?.failPendingSwitch()`.
> Confirm `[weak self]` is present on both the completion and the timeout closures (no retain cycle).

- [ ] **Step 2: Verify the interaction with `cancelSwitchDrag` (spring-back) is still correct**

`cancelSwitchDrag` (spring-back on a short drag) does NOT set `switchAnimDone`/`switchDelivered`
(there is no commit). It calls `clearPendingSwitch()` + animates content back + `clearGapDim()`. No
change needed, but CONFIRM it does not leave `switchAnimDone`/`switchDelivered` set from a prior
committed switch: since `commitSwitchDrag` resets both to false at its start and the finisher resets
them on completion, a spring-back after a completed switch sees them already false. A spring-back
INTERRUPTING a pending commit goes through `beginSwitchReveal` -> `discardCommittedSnapshot` (Task 1,
which now resets the flags). No code change; note the reasoning in the report.

- [ ] **Step 3: Verify Kit still builds/tests**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS.

- [ ] **Step 4: Confirm no orphaned references + the diagnostics are present**

Run: `grep -n "switchAnimDone\|switchDelivered\|finishSwitchHandoffIfReady\|anim-start\|anim-done\|switch delivered\|switch finish" App/TmuxPaneContainer.swift`
Expected: flags set/reset in `commitSwitchDrag` (start), completion (`switchAnimDone=true`),
`completePendingSwitchIfNeeded` (`switchDelivered=true`), `failPendingSwitch` + `discardCommittedSnapshot`
(both reset); `finishSwitchHandoffIfReady` defined + called from the completion AND
`completePendingSwitchIfNeeded`; the 4 diagnostic strings present.

- [ ] **Step 5: Commit**

```bash
git add App/TmuxPaneContainer.swift
git commit -m "fix(terminal): paired page-turn commit animation (old off + new snapshot in) + ordering diagnostics"
```

---

## Task 3: macOS CI + device retest

**Files:** none (process task).

- [ ] **Step 1: Push + trigger CI**

```bash
git push github feat/finger-drag-window-transition
gh workflow run CI --repo ds7n/semicolyn --ref feat/finger-drag-window-transition   # in case the webhook is stuck
```

- [ ] **Step 2: Watch macOS job to green**

`gh run list --repo ds7n/semicolyn --branch feat/finger-drag-window-transition --limit 1`, then
`gh run view --job=<macos-job-id> --repo ds7n/semicolyn` until the `macos` job is green. Likely
failure classes (fix inline, re-push, re-dispatch):
- Missing `MainActor.assumeIsolated` on the animation-completion closure -> wrap it (Step 1's note).
- A member-name mismatch (`resolvedCellPublic`, `snapshotView(for:)`, `layout(...)`) -> match the real signature.

- [ ] **Step 3: TF build**

```bash
gh workflow run "Release to TestFlight" --repo ds7n/semicolyn --ref feat/finger-drag-window-transition
```

- [ ] **Step 4: Device retest (enable Settings > Diagnostics > Gesture first)**

1. **Slow drag:** current window slides off tracking the finger; the exposed gap DARKENS with distance; no new window shown mid-drag.
2. **Release (commit):** the current window slides fully off one edge AND the new window slides in from the opposite edge (page-turn); no zoom mismatch on the new window; no blank flash.
3. **Fast flick:** the page-turn STILL plays fully (the race fix - this was the broken case).
4. **Short drag:** springs back, gap-dim clears, no switch.
5. Vertical drag still scrolls / wheel-scrolls Claude; horizontal on Claude/alt-screen also switches; edge-wrap; single-window no switch.
6. **Rapid double-switch** (commit then immediately drag again): no frozen snapshot stuck over the pane (C1 still holds).
7. **Pull the new syslog** (`data/syslog/`) and confirm the ordering: `switch anim-start` -> (`switch delivered ... animDone=false` if tmux fast) -> `switch anim-done` -> `switch finish (both-ready)`. If instead you see `switch finish (both-ready)` fire before `switch anim-done`, or two finishes, that's a gate bug to fix.

- [ ] **Step 5: Squash-merge PR #103 once CI green + device feel confirmed**

Per repo convention. Update the resume doc + memory.

---

## Self-Review

**Spec coverage:**
- Root cause = animation reset mid-slide by early tmux delivery -> both-ready gate (Task 1). ✓
- Part A live drag (already fires, unmasked) -> unchanged `updateSwitchDrag`; commit no longer stomps it early (Task 1 gate). ✓
- Part B paired page-turn (old off, new in from opposite edge) -> Task 2 `commitSwitchDrag`. ✓
- Part C both-ready gate (`switchAnimDone` + `switchDelivered`) -> Task 1 `finishSwitchHandoffIfReady`. ✓
- Snapshot at final frame, no zoom mismatch -> Task 2 `layout(...)` then start off-edge (transform is a pure translation, not a scale). ✓
- 1.5 s timeout + C1 + I1 + I2 preserved -> Task 1 (timeout/flags/C1) + Task 2 (I1 guard + I2 gap-dim full). ✓
- Diagnostics (anim-start / anim-done / delivered / finish) -> Task 1 (delivered/finish) + Task 2 (anim-start/anim-done). ✓
- esc-pill switch no-op -> `completePendingSwitchIfNeeded` guards on `pendingSwitchWindow != nil` (Task 1). ✓

**Placeholder scan:** none; every code step is complete. The two "Verify" notes point at real
call-sites/closures to confirm (grounded checks, not placeholders).

**Type consistency:** `switchAnimDone`/`switchDelivered` (Bool) set/reset consistently across Task 1
(state, gate, delivery, timeout, C1) and Task 2 (commit start + completion). `finishSwitchHandoffIfReady()`
defined in Task 1, called from Task 1 (`completePendingSwitchIfNeeded`) + Task 2 (animation completion).
`inStartX`/`outX` derived from `windowSlideDirection(delta:)`'s `out`/`in` edges (`.left` -> `-w`,
`.right` -> `+w`), consistent with the direction geometry in Global Constraints.
