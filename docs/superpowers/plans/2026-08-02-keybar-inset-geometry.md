# Keybar-Inset Terminal Geometry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the terminal's bottom rows (Claude Code / vim prompt + status lines) from rendering behind the floating keybar on the alt-screen, by deriving BOTH the tmux grid AND the pane frames from `bounds.height - live keybar height`, consistently.

**Architecture:** The pure height math already exists and is Kit-tested (`visibleTerminalHeight` + `terminalGrid` in `SemicolynKit`). The current `TmuxPaneContainer.ContainerView` REGRESSED to feeding the full `bounds.height` to both the grid (line ~715) and the pane rects (line ~842); this plan re-wires both call sites back to the existing `visibleTerminalHeight` helper so they use the same live-kbH-reduced height. The container's `geo:layout` diagnostic already logs `maxPaneBottom`, `gapPx`, and `keybarFrame@y`, which becomes the objective alignment check once `usableH` is correct.

**Tech Stack:** Swift 6 (App tier = macOS-CI-only, not Linux-buildable; Kit tier = Linux-tested via `swift test`), XCTest, Docker `semicolyn-dev`.

## Global Constraints

- **Two tiers:** the math is in `Sources/SemicolynKit/` (Linux-tested, no UIKit); the wiring is in `App/TmuxPaneContainer.swift` (macOS-CI + device only, NOT Linux-buildable).
- **`visibleTerminalHeight(rawHeight:keybarHeight:) -> Double`** ALREADY EXISTS (`Sources/SemicolynKit/Terminal/TerminalGrid.swift:30`), tested by `Tests/SemicolynKitTests/VisibleTerminalHeightTests.swift`. Behavior: `keybarHeight <= 0 -> rawHeight` (keyboard down / sentinel -1); else `max(0, rawHeight - keybarHeight)`. DO NOT reimplement it; USE it.
- **`kbH` is the live dynamic keybar height** from `firstResponderKeybarHeight()` (returns `-1` when no pane is first responder = keyboard down). Never a static constant.
- **SwiftTerm derives rows from `frame.height / cellHeight`** with NO inset input (verified v1.15.0). Shrinking the grid requires shrinking the pane FRAME; that is what this plan does.
- **Every source/test file keeps its 2-line SPDX header.** No em-dash (U+2014) / en-dash (U+2013) anywhere.
- **Conventional commits.** Linux test: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`.
- **The App tier is verified by macOS CI + device, not locally.** Hand-trace App edits.
- **Do NOT re-introduce the two known failure modes:** (a) grid/pane full-height -> bottom rows hidden (the current bug); (b) grid full but pane short, or a stale/mismatched kbH -> dead gap. The fix is that grid AND pane frames use the SAME `usableH = visibleTerminalHeight(bounds.height, kbH)` computed once per pass.

---

### Task 1: Add a Kit test locking the compose-to-grid contract at device values

**Files:**
- Test: `Tests/SemicolynKitTests/VisibleTerminalHeightTests.swift` (append)

**Interfaces:**
- Consumes: existing `visibleTerminalHeight(rawHeight:keybarHeight:)`, `terminalGrid(width:height:cellWidth:cellHeight:)`.
- Produces: nothing new; adds a regression test at the exact device geometry so the App re-wire has a Kit-level guardrail.

**Why this task:** the App fix is not Linux-buildable, so lock the MATH at the real device numbers from the 2026-08-02 log (`bounds 402x417`, `kbH 56`, cell `5.66x11.15`) as a permanent regression test: full-height would give 37 rows (bottom ~5 hidden); the corrected usable height gives the row count that fits above the keybar.

- [ ] **Step 1: Write the failing test**

Append to the `VisibleTerminalHeightTests` class in `Tests/SemicolynKitTests/VisibleTerminalHeightTests.swift`:

```swift
    // Device 2026-08-02 (Claude Code alt-screen hidden-rows bug): bounds 417pt, keybar 56pt,
    // cell height 11.15 -> the grid must use the keybar-reduced height, not the full 417.
    // Full 417/11.15 = 37 rows (bottom ~5 rows render behind the keybar); 361/11.15 = 32 rows fit.
    func testDeviceKeybarReducedRowCount() {
        let usable = visibleTerminalHeight(rawHeight: 417, keybarHeight: 56)
        XCTAssertEqual(usable, 361, accuracy: 1e-9)
        let grid = terminalGrid(width: 402, height: usable, cellWidth: 5.66, cellHeight: 11.15)
        XCTAssertEqual(grid?.rows, 32)
        // Contrast: the buggy full-height path yields 37 (the hidden-rows count).
        let buggy = terminalGrid(width: 402, height: 417, cellWidth: 5.66, cellHeight: 11.15)
        XCTAssertEqual(buggy?.rows, 37)
    }

    // Keyboard-down (kbH sentinel -1) MUST leave the full height so the keyboard-down layout
    // is unchanged (regression guard for the fix's kbH<=0 branch).
    func testKeyboardDownFullHeightRowCount() {
        let usable = visibleTerminalHeight(rawHeight: 417, keybarHeight: -1)
        XCTAssertEqual(usable, 417, accuracy: 1e-9)
        XCTAssertEqual(terminalGrid(width: 402, height: usable, cellWidth: 5.66, cellHeight: 11.15)?.rows, 37)
    }
```

- [ ] **Step 2: Run to verify it passes immediately (this locks existing behavior)**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter VisibleTerminalHeightTests`
Expected: PASS. (These assert the EXISTING helper's behavior at device values; they pass now and would FAIL if someone changed the helper. They are the guardrail for the App re-wire in Task 2.)

Note: this is a characterization/regression test, not TDD-red, the helper already exists and is correct; the bug is in the App tier that stopped calling it. Verify the arithmetic by hand before trusting a green: `417 - 56 = 361`; `floor(361/11.15) = floor(32.37) = 32`; `floor(417/11.15) = floor(37.4) = 37`. If any assert fails, the helper regressed; STOP and report.

- [ ] **Step 3: Commit**

```bash
git add Tests/SemicolynKitTests/VisibleTerminalHeightTests.swift
git commit -m "test(kit): lock keybar-reduced grid row count at device geometry"
```

---

### Task 2: Re-wire the container to inset by the live keybar height (the fix)

**Files:**
- Modify: `App/TmuxPaneContainer.swift` (`ContainerView.layoutSubviews` ~715; `fittedPaneRects` ~839-843; its callers `relayoutExistingPaneFrames` ~821 and `apply` ~933)

**Interfaces:**
- Consumes: `SemicolynKit.visibleTerminalHeight(rawHeight:keybarHeight:)`, `SemicolynKit.terminalGrid`, `SemicolynKit.fitPaneRects`, existing `firstResponderKeybarHeight()`, `resolvedCell()`.
- Produces: `fittedPaneRects(layout:cell:usableHeight:)` (adds a `usableHeight` parameter so all callers pass the SAME keybar-reduced height the grid uses).

**Design note:** the grid (line 715) and the pane rects (line 842) MUST use the identical `usableH` value. Today the grid line is hardcoded `Double(bounds.height)` and `fittedPaneRects` hardcodes `toHeight: Double(bounds.height)`. The `logGeometry` comment (~755-756) already documents the intended design (`fitPaneRects` targets `usableH`, `gapPx = usableH - maxPaneBottom`); this restores it consistently.

- [ ] **Step 1: Fix the grid's usable height in `layoutSubviews`**

In `App/TmuxPaneContainer.swift`, replace line ~715:

```swift
            let usableH = Double(bounds.height)
```

with:

```swift
            // Inset by the LIVE keybar height so the grid (and the pane frames below, via
            // fittedPaneRects(usableHeight:)) end at the keybar's top edge. SwiftTerm pins its
            // row count to frame.height/cellHeight with no inset input, so the ONLY way to keep
            // the bottom rows (Claude Code / vim prompt + status) from rendering behind the
            // floating keybar (unreachable on the alt-screen, which cannot scroll) is to shrink
            // the frame. `visibleTerminalHeight` is the Kit-tested reduction (kbH<=0 => full
            // height for keyboard-down). Grid AND pane frames use this SAME value = no dead gap.
            let usableH = visibleTerminalHeight(rawHeight: Double(bounds.height), keybarHeight: Double(kbH))
```

Then update the comment block above it (the 2026-07-27 "compute the grid from the FULL container height" paragraph, ~703-714) to reflect the NEW model: grid and pane frames BOTH use `bounds - kbH` consistently; the keybar floats over the region below the pane, which the pane no longer occupies, so nothing renders behind it. Do NOT delete the historical context; revise it to say the full-height approach hid the bottom rows on the alt-screen and was replaced by the consistent-inset model (ref `docs/superpowers/specs/2026-08-02-keybar-inset-geometry-design.md`).

- [ ] **Step 2: Add a `usableHeight` parameter to `fittedPaneRects`**

Replace the `fittedPaneRects` definition (~839-843):

```swift
        private func fittedPaneRects(layout: PaneLayout,
                                     cell: (w: Double, h: Double)) -> [PaneRect] {
            let raw = paneRects(in: layout, cellWidth: cell.w, cellHeight: cell.h)
            return fitPaneRects(raw, toWidth: Double(bounds.width), toHeight: Double(bounds.height))
        }
```

with:

```swift
        /// Pane rects fitted to the container's width and the keybar-REDUCED usable height, so
        /// each pane's bottom edge lands at the keybar's top (not behind it). `usableHeight` is
        /// `visibleTerminalHeight(bounds.height, kbH)` = the SAME value the grid uses, so the
        /// reported grid and the actual pane frame agree and no dead band is reserved.
        private func fittedPaneRects(layout: PaneLayout,
                                     cell: (w: Double, h: Double),
                                     usableHeight: Double) -> [PaneRect] {
            let raw = paneRects(in: layout, cellWidth: cell.w, cellHeight: cell.h)
            return fitPaneRects(raw, toWidth: Double(bounds.width), toHeight: usableHeight)
        }
```

- [ ] **Step 3: Thread `usableHeight` through the three callers**

There are three call sites of `fittedPaneRects`; each must pass the keybar-reduced height computed the SAME way.

(a) In `layoutSubviews`, the `relayoutExistingPaneFrames(cell:)` call (~743) runs after `usableH` is computed. Change `relayoutExistingPaneFrames` to accept and forward the usable height. Update its signature (~819):

```swift
        private func relayoutExistingPaneFrames(cell: (w: Double, h: Double), usableHeight: Double) {
            guard let layout = lastAppliedLayout else { return }
            for rect in fittedPaneRects(layout: layout, cell: cell, usableHeight: usableHeight) {
                guard let view = panes[rect.pane] else { continue }
                view.frame = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
            }
        }
```

and its call in `layoutSubviews` (~743): `relayoutExistingPaneFrames(cell: cell, usableHeight: usableH)`.

(b) In `apply` (~933), the `let rects = fittedPaneRects(layout: layout, cell: cell)` call: it needs the same usable height. Compute it there from the live kbH exactly as `layoutSubviews` does. Read the `apply` function to find where `cell` is obtained; immediately before the `fittedPaneRects` call add:

```swift
            let usableH = visibleTerminalHeight(rawHeight: Double(bounds.height),
                                                keybarHeight: Double(firstResponderKeybarHeight()))
```

and change the call to `fittedPaneRects(layout: layout, cell: cell, usableHeight: usableH)`. (If `apply` already has a local named `usableH`/`kbH`, reuse it instead of shadowing; grep `apply` first.)

- [ ] **Step 4: Confirm `logGeometry` still receives the corrected `usableH`**

`layoutSubviews` calls `logGeometry(reason:cell:kbH:usableH:grid:)` (~744) with `usableH`. Since `usableH` is now the keybar-reduced value, `gapPx = usableH - maxPaneBottom` (~788) now measures the pane bottom against the intended usable region: `gapPx ~= 0` = pane fills exactly to the keybar top (correct); `gapPx > 0` = dead band; `gapPx < 0` = pane still overshoots behind the keybar. Also confirm `keybarFrame=...@y{minY}` (~792-793) is still logged. NO code change needed here; verify by reading that `logGeometry`'s `usableH` argument is the new value. If `apply` also logs geometry, ensure it passes its `usableH` too.

- [ ] **Step 5: Verify no other consumer assumed full-height pane frames**

Grep for anything that recomputed a pane's expected height from full bounds: `grep -n "bounds.height\|fittedPaneRects\|toHeight" App/TmuxPaneContainer.swift`. Every `fittedPaneRects` call must now pass `usableHeight`. Confirm there is no remaining `fitPaneRects(... toHeight: Double(bounds.height))` outside the helper. If the split/relayout paths have their own frame math keyed to full bounds, reconcile them to `usableH` (they should already route through `fittedPaneRects`).

- [ ] **Step 6: Kit still green (App verified by CI)**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS (Kit unaffected; this confirms no accidental Kit edit). The App compile is verified by macOS CI after push.

- [ ] **Step 7: Commit**

```bash
git add App/TmuxPaneContainer.swift
git commit -m "fix(app): inset grid and pane frames by live keybar height (bottom rows behind keybar)"
```

---

### Task 3: Push, macOS CI, TestFlight, device-verify the `gap`

**Files:** none (verification).

**Interfaces:** none.

- [ ] **Step 1: Push and trigger macOS CI**

```bash
git push github feat/gesture-diagnostics
gh workflow run CI --ref feat/gesture-diagnostics
```

Wait for the `macos` job green (the only App compile signal, ~15-18 min): `gh run list --branch feat/gesture-diagnostics --limit 1`. If `linux-rust` flakes on sshd readiness, rerun that job only.

- [ ] **Step 2: TestFlight (only after `macos` green)**

```bash
gh workflow run "Release to TestFlight" --repo ds7n/semicolyn --ref feat/gesture-diagnostics
```

- [ ] **Step 3: Device-verify with the objective `geo:layout` gap**

Capture on device (syslog sink UP, TLS 6514/TCP, `.geometry` category on) in a Claude Code (alt-screen) pane, keyboard UP. Read the newest `geo:layout` line and confirm ALL of:
- `gapPx` is approximately 0 (pane bottom meets the intended usable region), NOT a large positive (dead band returned) or negative (rows still hidden).
- `maxPaneBottom` is approximately equal to `keybarFrame ...@y{minY}` (pane bottom == keybar top edge), the direct alignment check.
- `grid` rows dropped from the buggy count (e.g. 37 -> 32 at the 417/56 geometry).
- Visually: the Claude Code prompt box + status line + tmux status bar are VISIBLE above the keybar (matching the Blink reference), no dead black band.
- Keyboard DOWN: the terminal fills the full height (no shrink when there is no accessory).
- A split window still tiles with no gap and no hidden bottom row.

If `gapPx` is non-zero on device, the `geo:layout` sign says which way (positive = band, negative = still-behind); report the exact numbers rather than re-guessing.

---

## Self-Review notes (for the implementer)

- **Spec coverage:** consistent grid+frame inset (Task 2 steps 1-3), works alt-screen by shrinking the real grid (Task 1 locks the row count), kbH dynamic (uses `firstResponderKeybarHeight()` live), keyboard-down full height (Task 1 test + the helper's `kbH<=0` branch), self-verifying diagnostic (Task 2 step 4 confirms `gapPx`/`keybarFrame@y` are meaningful; `geo:layout` already logs them). Edge cases (kbH>=bounds -> min 1 row) are covered by the existing helper + `terminalGrid` fail-closed clamp.
- **The one invariant:** grid (line 715) and every `fittedPaneRects` call use the SAME `usableH = visibleTerminalHeight(bounds.height, kbH)`. If they ever diverge, the gap/hidden-rows bug returns. Task 2 step 5 grep guards this.
- **No new Kit code:** `visibleTerminalHeight`, `terminalGrid`, `fitPaneRects` all already exist and are tested. This plan is a re-wire, not a new subsystem.
- **Diagnostic already present:** `geo:layout` logs `maxPaneBottom`, `gapPx`, `keybarFrame@y`. The fix makes `gapPx` meaningful (measured against the corrected `usableH`). No new logging field is strictly required; if the per-pane `geo:pane` (PaneTerminalView) alignment is also wanted, add `keybarFrame@y` there too, but the container `geo:layout` is the authoritative alignment line.
