<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Keybar safe-area reservation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the recurring "terminal rows render behind the floating keybar" at its root by reserving the keybar band via `additionalSafeAreaInsets` (driven by the one stable signal, `accH`) and laying out into `safeAreaLayoutGuide`, so UIKit owns the reservation and no unreliable keybar-top proxy drives layout.

**Architecture:** A shared pure Kit helper computes the reservation from `accH`. Stage A: `RawTerminalContainer` pins its single child to `safeAreaLayoutGuide` (Auto Layout) and sets the reservation; delete its manual `usableH`+framing. Stage B (after Stage A is device-confirmed, same PR): `TmuxPaneContainer` sets the same reservation and sources `usableH` from `safeAreaLayoutGuide.layoutFrame.height`. A runtime invariant tripwire + a Kit regression test lock it.

**Tech Stack:** Swift 6 (strict concurrency), UIKit (`additionalSafeAreaInsets`, `safeAreaLayoutGuide`, Auto Layout), SwiftTerm; SemicolynKit (pure helper + XCTest, Linux-tested).

## Global Constraints

- **Two test surfaces.** `Sources/SemicolynKit/` + `Tests/SemicolynKitTests/` are pure, **Linux-tested** via `swift test` in the Docker `semicolyn-dev` image. `App/` is **Apple-only**, does NOT compile under `swift test`; its ONLY build signal is the **macOS CI job**. Put logic in Kit with a real XCTest; keep App a thin layer.
- **Kit test command (Linux, in Docker):** `docker compose build dev` then `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter VisibleTerminalHeightTests`. There is NO Swift toolchain on the host.
- **Every source file carries an SPDX header:** `// SPDX-FileCopyrightText: 2026 True Positive LLC` then `// SPDX-License-Identifier: GPL-3.0-only`.
- **No em-dash (U+2014) or en-dash (U+2013)** anywhere (prose, code, comments, commit messages).
- **Swift 6 strict concurrency.** `App/` may import UIKit/SwiftUI. UIView overrides (`layoutSubviews`, `init`) are MainActor-isolated already; `@objc`/delegate callbacks need `MainActor.assumeIsolated {}` (not relevant to this plan's edits, but do not break existing ones).
- **Tests must be real** (project standard): EP + BVA, assert exact observable values (no tautology), negative cases assert the specific result. Match the existing style in `Tests/SemicolynKitTests/VisibleTerminalHeightTests.swift` (device numbers, contrast-with-buggy-value assertions).
- **Conventional commits.** Branch `refactor/raw-terminal-container-wrap` (already active; this work continues on it). Squash-merge to `main`. End commit messages with the trailer `Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt`.
- **Structure-only for #121 workarounds still holds:** do NOT touch `App/PaneTerminalView.swift`'s self-inset block (it already no-ops). This plan deletes the raw container's OWN manual-framing/proxy code, which is new code from this same branch, not a #121 workaround.
- **Spec:** `docs/superpowers/specs/2026-08-08-keybar-safearea-reservation-design.md`. The build-121 device numbers (accH 56; bounds 453/499/431 -> reserved 397/443/375) are the regression-lock values.

---

## File Structure

- **Modify** `Sources/SemicolynKit/Terminal/TerminalGrid.swift`: add the pure `keybarSafeAreaReservation(accessoryHeight:isFirstResponder:)` helper (one responsibility: the reservation policy).
- **Modify** `Tests/SemicolynKitTests/VisibleTerminalHeightTests.swift`: add EP/BVA tests for the new helper (co-located with the sibling keybar-height helpers it joins).
- **Modify** `App/RawTerminalContainer.swift` (Stage A): Auto Layout pin to `safeAreaLayoutGuide` + reservation update + invariant tripwire; delete manual `usableH`/framing + the guide/converted-frame proxy helpers.
- **Modify** `App/TmuxPaneContainer.swift` (Stage B): same reservation; source `usableH` from `safeAreaLayoutGuide.layoutFrame.height`; delete the `keyboardTopInContainer()` proxy path.

## Testing note (read before Task 1)

The Kit helper (Task 1) IS Linux-unit-tested, real TDD. The App tasks (2, 4) are NOT locally testable; their gate is macOS CI compile + on-device verification (Tasks 3, 5). Stage A (raw) is device-proven BEFORE Stage B (-CC) is written/committed, per the locked staging. Commits are small so a CI failure bisects cleanly.

---

### Task 1: Kit reservation helper + tests (TDD, Linux)

**Files:**
- Modify: `Sources/SemicolynKit/Terminal/TerminalGrid.swift`
- Test: `Tests/SemicolynKitTests/VisibleTerminalHeightTests.swift`

**Interfaces:**
- Produces: `public func keybarSafeAreaReservation(accessoryHeight: Double, isFirstResponder: Bool) -> Double`. Tasks 2 and 4 call this.

- [ ] **Step 1: Write the failing tests**

Append these to `Tests/SemicolynKitTests/VisibleTerminalHeightTests.swift`, inside the final `}` of the class (before it). They use the build-121 device numbers.

```swift
    // MARK: keybarSafeAreaReservation (2026-08-08 root-cause fix)
    // The bottom safe-area reservation for the keybar accessory. The build-121 diagnostic
    // proved accH (the accessory's off-screen content measurement) is the one stable signal;
    // this helper is the whole reservation policy that both containers apply.

    // First responder + measured accH -> reserve exactly accH (device: accH 56 -> 56).
    func testReservationFirstResponderReservesAccH() {
        XCTAssertEqual(keybarSafeAreaReservation(accessoryHeight: 56, isFirstResponder: true), 56, accuracy: 1e-9)
    }
    // Not first responder (keyboard down, no accessory shown) -> reserve nothing, even if a
    // stale accH is passed. This is the state where guideTop==bounds; reservation must be 0.
    func testReservationNotFirstResponderReservesZero() {
        XCTAssertEqual(keybarSafeAreaReservation(accessoryHeight: 56, isFirstResponder: false), 0, accuracy: 1e-9)
    }
    // accH sentinel -1 (firstResponderKeybarHeight() when no accessory) -> 0.
    func testReservationSentinelNegativeReservesZero() {
        XCTAssertEqual(keybarSafeAreaReservation(accessoryHeight: -1, isFirstResponder: true), 0, accuracy: 1e-9)
    }
    // BVA at 0: accH exactly 0 -> 0 (no negative, no spurious reservation).
    func testReservationZeroAccHReservesZero() {
        XCTAssertEqual(keybarSafeAreaReservation(accessoryHeight: 0, isFirstResponder: true), 0, accuracy: 1e-9)
    }
    // The three build-121 device samples: bounds - reservation must equal the correct keybar top.
    // (bounds 453/499/431, accH 56 -> reserved band 56 -> usable 397/443/375.)
    func testReservationDeviceSamplesComposeToCorrectUsable() {
        for (bounds, expectedUsable) in [(453.0, 397.0), (499.0, 443.0), (431.0, 375.0)] {
            let reserved = keybarSafeAreaReservation(accessoryHeight: 56, isFirstResponder: true)
            XCTAssertEqual(bounds - reserved, expectedUsable, accuracy: 1e-9)
        }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter VisibleTerminalHeightTests`
Expected: FAIL to compile / "cannot find 'keybarSafeAreaReservation' in scope".

- [ ] **Step 3: Implement the helper**

Append to `Sources/SemicolynKit/Terminal/TerminalGrid.swift` (after `usableHeightFromKeyboardTop`):

```swift
/// The bottom safe-area reservation (in points) for the keybar accessory, to be applied as
/// `additionalSafeAreaInsets.bottom` on the terminal container. `accessoryHeight` is
/// `KeybarInputAccessory.intrinsicContentSize.height`, the accessory's off-screen content
/// measurement, which the 2026-08-08 build-121 device diagnostic proved to be the ONE signal
/// stable across frame/window/animation state (unlike `keyboardLayoutGuide.layoutFrame.minY`,
/// which reports the container's own bottom edge when the on-screen keyboard is dismissed but the
/// keybar is still shown, and unlike the accessory's converted window frame, which is
/// animation-transient garbage). Reserves nothing when the terminal is not first responder
/// (keyboard down -> no accessory) or when `accessoryHeight` is the `-1` sentinel / non-positive.
/// Floors at 0. This is the whole reservation policy; both the raw and tmux -CC containers apply
/// it, then lay out into their (UIKit-shrunk) `safeAreaLayoutGuide`, so no unreliable keybar-top
/// proxy drives layout. Pure; unit-tested with the build-121 device numbers.
public func keybarSafeAreaReservation(accessoryHeight: Double, isFirstResponder: Bool) -> Double {
    guard isFirstResponder, accessoryHeight > 0 else { return 0 }
    return max(0, accessoryHeight)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter VisibleTerminalHeightTests`
Expected: PASS (all existing + 5 new tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Terminal/TerminalGrid.swift Tests/SemicolynKitTests/VisibleTerminalHeightTests.swift
git commit -m "feat(kit): keybarSafeAreaReservation policy helper + tests

The one stable keybar signal (accH) as a pure reservation policy for
additionalSafeAreaInsets.bottom. Locks the build-121 device numbers
(accH 56 -> reserve 56; sentinels -> 0) so the recurring behind-keybar
regression cannot pass CI again.

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
```

---

### Task 2: Stage A - `RawTerminalContainer` structural safe-area reservation

**Files:**
- Modify: `App/RawTerminalContainer.swift`

**Interfaces:**
- Consumes: `keybarSafeAreaReservation(accessoryHeight:isFirstResponder:)` (Task 1); `KeybarInputAccessory.intrinsicContentSize` (existing).
- Produces: a `RawTerminalContainer` that reserves the keybar via safe area and pins its child with Auto Layout (no manual framing). No later task depends on its internals beyond device verification.

- [ ] **Step 1: Replace the whole file body**

Rewrite `App/RawTerminalContainer.swift` to: (a) pin the child to `safeAreaLayoutGuide` in `init`; (b) in `layoutSubviews`, set the reservation and run the invariant tripwire; (c) delete `usableH`/manual framing, `keyboardTopInContainer()`, `keybarTopInContainerViaFrame()`. Keep `firstResponderKeybarHeight()` (now used to source the reservation) and a slimmed diagnostic. Full file content:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import SemicolynKit

/// Plain-UIView leaf for the raw single-terminal path (`TerminalScreen`). The `PaneTerminalView`
/// (a `UIScrollView`) is an absolutely-... no: an AUTO-LAYOUT-pinned SUBVIEW; this container is
/// what SwiftUI sizes. The container reserves the keybar band as a bottom safe-area inset and pins
/// the child to `safeAreaLayoutGuide`, so UIKit keeps the terminal above the keybar automatically in
/// every state (rotation, keyboard show/hide, app-switch). No keybar-top proxy signal drives layout.
///
/// This replaces the manual `usableH` computation + `terminal.frame = ...` framing that recurred as
/// the "rows behind the keybar" bug (~6 prior fixes): every one drove a hand-computed frame from a
/// proxy (`keyboardLayoutGuide` / converted accessory frame) that was wrong in some state. The
/// build-121 diagnostic proved the accessory's measured height (`accH`) is the one stable signal;
/// here it feeds `additionalSafeAreaInsets.bottom` and UIKit owns the rest.
/// See `docs/superpowers/specs/2026-08-08-keybar-safearea-reservation-design.md`.
final class RawTerminalContainer: UIView {
    /// The single terminal child, pinned to `safeAreaLayoutGuide` (UIKit frames it).
    let terminal: PaneTerminalView
    /// The SwiftUI coordinator, retained weakly (mirrors `TmuxPaneContainer.ContainerView`).
    weak var coordinator: TerminalScreen.Coordinator?
    /// Last reservation set, so we only mutate `additionalSafeAreaInsets` (which triggers a layout
    /// pass) when it actually changes, avoiding a layout feedback loop.
    private var lastReservation: CGFloat = -1

    init(terminal: PaneTerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)
        terminal.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminal)
        // Pin the child to the safe-area guide (NOT self.bounds): UIKit shrinks the guide by
        // `additionalSafeAreaInsets.bottom` (the keybar reservation set in layoutSubviews), so the
        // child's frame automatically excludes the keybar band in every state.
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Reserve the keybar band via safe area, sized by the one stable signal (accH). UIKit then
        // shrinks safeAreaLayoutGuide and re-frames the pinned child. Update only on change so
        // setting the inset (which itself re-triggers layout) does not spin.
        let accH = Double(firstResponderKeybarHeight())
        let reservation = CGFloat(keybarSafeAreaReservation(accessoryHeight: accH,
                                                            isFirstResponder: terminal.isFirstResponder))
        if abs(reservation - lastReservation) > 0.5 {
            lastReservation = reservation
            additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 0, bottom: reservation, right: 0)
            // Setting the inset invalidates layout; the next pass reads the settled child frame.
        }

        // Prong 3 (runtime invariant tripwire): the reserved keybar top is UIKit's OWN post-layout
        // truth, bounds.height - safeAreaInsets.bottom (safeAreaInsets already reflects our
        // additional inset). If the child's bottom extends past it, rows would render in the reserved
        // band = the bug. Log it loud (default-on category) instead of silently hiding a row.
        let reservedTop = Double(bounds.height) - Double(safeAreaInsets.bottom)
        let childBottom = Double(terminal.frame.maxY)
        if childBottom > reservedTop + 1.0 {
            DebugLog.shared.log(.tmux,
                "keybar-inset VIOLATION reservedTop=\(String(format: "%.0f", reservedTop)) "
                + "childBottom=\(String(format: "%.0f", childBottom)) "
                + "over=\(String(format: "%.0f", childBottom - reservedTop))")
        }

        guard DebugLog.shared.isEnabled(.geometry) else { return }
        let cf = terminal.frame
        DebugLog.shared.log(.geometry,
            "geo:raw-container bounds=\(Int(bounds.width))x\(Int(bounds.height)) "
            + "saInsetBottom=\(String(format: "%.0f", Double(safeAreaInsets.bottom))) "
            + "fr=\(terminal.isFirstResponder) accH=\(String(format: "%.0f", accH)) "
            + "reservation=\(String(format: "%.0f", Double(reservation))) "
            + "childFrame=\(Int(cf.minX)),\(Int(cf.minY)),\(Int(cf.width))x\(Int(cf.height))")
    }

    /// The keybar (`inputAccessoryView`) height of the child terminal when it is first responder
    /// (iOS shows exactly that view's accessory). Returns -1 when the terminal is not first
    /// responder (keyboard down, no accessory). Feeds the safe-area reservation.
    private func firstResponderKeybarHeight() -> CGFloat {
        guard terminal.isFirstResponder,
              let acc = terminal.inputAccessoryView as? KeybarInputAccessory else { return -1 }
        return acc.intrinsicContentSize.height
    }
}
```

- [ ] **Step 2: Static self-check**

Read the rewritten file. Confirm:
- SPDX header intact; no em-dash / en-dash (note: the doc comment says "AUTO-LAYOUT-pinned"; make sure the leftover "absolutely-... no:" phrasing is removed - rewrite that sentence cleanly to just describe the Auto Layout pin. Do not leave the self-correction text in the shipped comment).
- No `usableHeightFromKeyboardTop` / `visibleTerminalHeight` / `keyboardTopInContainer` / `keybarTopInContainerViaFrame` remain (deleted).
- `keybarSafeAreaReservation` is called exactly once, in `layoutSubviews`.
- The child is pinned to `safeAreaLayoutGuide` (4 constraints) and `translatesAutoresizingMaskIntoConstraints = false`.

Run: `grep -nE "usableHeightFromKeyboardTop|visibleTerminalHeight|keyboardTopInContainer|keybarTopInContainerViaFrame|terminal.frame = CGRect" App/RawTerminalContainer.swift`
Expected: no matches (all manual-framing/proxy code gone).

- [ ] **Step 3: Rewrite the leftover self-correcting comment sentence**

In the class doc comment, replace the sentence containing "an AUTO-LAYOUT-pinned SUBVIEW; ... no:" with a single clean sentence: `The `PaneTerminalView` (a `UIScrollView`) is an Auto-Layout-pinned SUBVIEW; this container is what SwiftUI sizes.` Verify no "no:" artifact remains.

Run: `grep -n "no:" App/RawTerminalContainer.swift`
Expected: no matches.

- [ ] **Step 4: Commit**

```bash
git add App/RawTerminalContainer.swift
git commit -m "fix(keybar): reserve keybar via safe area on the raw path (Stage A)

Stop manually computing usableH + framing the child. Pin the terminal to
safeAreaLayoutGuide and set additionalSafeAreaInsets.bottom = keybarSafeAreaReservation(accH),
so UIKit keeps it above the keybar in every state (no keybar-top proxy drives
layout). Adds a runtime keybar-inset VIOLATION tripwire. Deletes the guide /
converted-frame proxy helpers. Root-cause fix for the recurring behind-keybar bug.

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
```

---

### Task 3: Stage A CI compile + device verification

**Files:** none (verification gate). Stage A must be device-confirmed before Stage B is written.

- [ ] **Step 1: Push + macOS CI**

```bash
git push github refactor/raw-terminal-container-wrap
gh run list --repo ds7n/semicolyn --branch refactor/raw-terminal-container-wrap --limit 1
```
Watch the run. The `macos` job (~47 min) is the only Apple build signal; `linux-swift` now also runs the new Kit test (`VisibleTerminalHeightTests`). If `linux-rust` flakes ("sshd fixtures not reachable"), rerun that job. Do not proceed until `macos` AND `linux-swift` are green.

- [ ] **Step 2: TestFlight build**

```bash
gh workflow run "Release to TestFlight" --repo ds7n/semicolyn --ref refactor/raw-terminal-container-wrap
```
Watch to completion; confirm the log shows `UPLOAD SUCCEEDED with no errors` (the lane reports green even on a failed upload). Note the build number (after 121).

- [ ] **Step 3: Device test matrix (raw SSH)**

Sink up (`docker compose -f tools/syslog-sink/docker-compose.yml up -d`), device log streaming on (TLS 6514, geometry + tmux categories on). Connect raw-SSH and verify:
1. **No rows behind the keybar** in the failing state (bring up keyboard, dismiss the software keyboard while the keybar stays) - the bottom prompt row is fully visible.
2. `geo:raw-container` shows `saInsetBottom ~= 56` and `childFrame` height == `bounds - 56`.
3. **No** `keybar-inset VIOLATION` line appears.
4. **App-switch away and back**: no gap above the keybar AND no hidden rows (the state that broke both historical directions).
5. Scroll still works (`scroll-trace pan=nativePan state=2`); typing / pinch / theme intact; clean exit.

- [ ] **Step 4: Read device logs**

```bash
docker exec syslog-sink-syslog-1 sh -c "tail -c 200000 /var/log/semicolyn/semicolyn.log" | tr '\r' '\n' | grep -E "geo:raw-container|keybar-inset VIOLATION|scroll-trace"
```
Confirm criteria 1-5. If any fail (especially a `VIOLATION` line or `saInsetBottom` != 56 when the keybar is up), STOP and use `superpowers:systematic-debugging` from the container-space numbers; do NOT proceed to Stage B.

---

### Task 4: Stage B - `TmuxPaneContainer` adopts the shared reservation

**Files:**
- Modify: `App/TmuxPaneContainer.swift`

**Interfaces:**
- Consumes: `keybarSafeAreaReservation(...)` (Task 1); existing `firstResponderKeybarHeight()`, `fittedPaneRects(usableHeight:)`, `safeAreaLayoutGuide`.
- Produces: `-CC` container reserves the keybar via safe area and sources `usableH` from the reserved guide. Same PR; only AFTER Task 3 confirms Stage A on device.

- [ ] **Step 1: Set the reservation in `layoutSubviews`**

In `ContainerView.layoutSubviews` (App/TmuxPaneContainer.swift), immediately after `super.layoutSubviews()` and before the early-out, add the reservation. Use the existing `firstResponderKeybarHeight()` and a first-responder check across panes:

```swift
        // Reserve the keybar band via safe area (2026-08-08 root-cause fix), sized by the stable
        // accH signal, so usableH can come from the UIKit-shrunk safeAreaLayoutGuide below instead
        // of the unreliable keyboardLayoutGuide proxy. Update only on change (setting the inset
        // re-triggers layout).
        let anyFirstResponder = panes.values.contains { $0.isFirstResponder }
        let reservation = CGFloat(keybarSafeAreaReservation(
            accessoryHeight: Double(firstResponderKeybarHeight()),
            isFirstResponder: anyFirstResponder))
        if abs(reservation - lastReservation) > 0.5 {
            lastReservation = reservation
            additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 0, bottom: reservation, right: 0)
        }
```

Add the backing property near the other `ContainerView` stored properties:

```swift
        /// Last keybar reservation set, so we only mutate additionalSafeAreaInsets on change
        /// (setting it re-triggers layout).
        private var lastReservation: CGFloat = -1
```

- [ ] **Step 2: Source `usableH` from the reserved safe area**

Replace the `usableH` closure in `layoutSubviews` (currently the `if let top = kbTop { usableHeightFromKeyboardTop(...) } else { visibleTerminalHeight(...) }` block) with the UIKit-reserved height:

```swift
            // usableH now comes from UIKit's safe-area guide, which we already shrank by the keybar
            // reservation above. This replaces the keyboardLayoutGuide/visibleTerminalHeight proxies
            // (the guide reported bounds-bottom when keyboard-down/keybar-up: build-121 diagnostic).
            let usableH = Double(safeAreaLayoutGuide.layoutFrame.height)
```

Keep everything downstream (`terminalGrid`, `fittedPaneRects(usableHeight: usableH)`, `relayoutExistingPaneFrames`) unchanged. Remove the now-unused `kbTop`/`keyboardTopInContainer()` from the layout path IF nothing else reads it; if `logGeometry` still references `kbTop`/`kbTopY` for diagnostics, leave the diagnostic-only reads but stop using them to drive `usableH`.

Also update the `apply(...)` method's parallel `usableH` computation (the one after a window switch, currently mirroring `keyboardTopInContainer()` else `visibleTerminalHeight`) to the same `Double(safeAreaLayoutGuide.layoutFrame.height)` so `apply` and `layoutSubviews` agree.

- [ ] **Step 3: Update the render-storm early-out key**

The early-out `LayoutInputs` struct includes `keyboardTop: Double?`. Since layout no longer depends on `kbTop`, replace that field with the reservation-affected `safeAreaLayoutGuide.layoutFrame.height` (or `safeAreaInsets.bottom`) so the early-out still fires on a real keybar-reservation change. Concretely, change the `LayoutInputs` field `keyboardTop` to `safeBottom: CGFloat` = `safeAreaInsets.bottom`, set it from `safeAreaInsets.bottom`, and drop the `kbTop` computation used only for the key. Verify the struct's `Equatable` still derives.

- [ ] **Step 4: Static self-check**

Run: `grep -nE "keyboardTopInContainer|usableHeightFromKeyboardTop\(rawHeight: Double\(bounds" App/TmuxPaneContainer.swift`
Expected: `keyboardTopInContainer()` remains ONLY inside `logGeometry` (diagnostic) if at all, and is NOT used to compute `usableH` in `layoutSubviews` or `apply`. No em-dash/en-dash added.

Confirm the reservation is set before the early-out (so a keybar show/hide isn't swallowed) and `usableH` reads `safeAreaLayoutGuide.layoutFrame.height` in both `layoutSubviews` and `apply`.

- [ ] **Step 5: Commit**

```bash
git add App/TmuxPaneContainer.swift
git commit -m "fix(keybar): adopt safe-area reservation on the tmux -CC path (Stage B)

Same reservation as the raw path: set additionalSafeAreaInsets.bottom =
keybarSafeAreaReservation(accH) and source usableH from the UIKit-shrunk
safeAreaLayoutGuide instead of the keyboardLayoutGuide proxy that reported
bounds-bottom when keyboard-down/keybar-up. Pane grid math unchanged; only its
usable-height input becomes the reserved safe area. Removes the latent app-switch
behind-keybar bug from the -CC path too.

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
```

---

### Task 5: Stage B CI + device verification, then finalize

**Files:** none (verification gate + docs).

- [ ] **Step 1: Push + macOS CI + TestFlight** (same as Task 3 Steps 1-2, new build number).

- [ ] **Step 2: Device matrix - tmux `-CC` multi-pane**

Connect a tmux session with `-CC` native panes (multi-pane window). Verify:
1. No rows behind the keybar in any pane; the active pane's bottom row is visible.
2. `geo:layout` / `geo:raw-container` show `saInsetBottom ~= 56`; `gapToKeybar ~= 0`; no `keybar-inset VIOLATION`.
3. Window switch + app-switch away/back: no gap, no hidden rows (the historical failure state).
4. Single-pane tmux window and raw SSH both still correct (Stage A not regressed).

- [ ] **Step 3: If device checks pass, finalize the PR + docs**

```bash
gh pr ready --repo ds7n/semicolyn <PR-122-number>
```
Update `TODO.md`: container-wrap + safe-area reservation done, device-confirmed on build <N>; note the recurring behind-keybar bug is root-fixed (UIKit-owned reservation, no proxy). Queue the still-deferred #121 workaround-cleanup (PaneTerminalView self-inset block, gesture-controller belt-and-suspenders). Commit + push.

- [ ] **Step 4: If a device check fails**

Do NOT merge. Capture the failing `geo:*` / `VIOLATION` lines, `superpowers:systematic-debugging` from UIKit's post-layout numbers (`safeAreaInsets.bottom`, `safeAreaLayoutGuide.layoutFrame`). The most likely Stage-B-specific failure is `usableH` reading full height because the reservation was set AFTER the early-out returned; verify Step 1's reservation-before-early-out ordering.

---

## Self-Review

**1. Spec coverage:**
- Shared Kit reservation helper (spec "Shared helper") -> Task 1. ✓
- Stage A raw structural (spec "Stage A") -> Task 2; device gate -> Task 3. ✓
- Stage B -CC (spec "Stage B") -> Task 4; device gate -> Task 5. ✓
- Belt-and-suspenders 4 prongs (spec): #1 reservation (Tasks 2/4), #2 accH-only signal (Task 1 helper + Tasks 2/4 consume only accH), #3 runtime VIOLATION tripwire (Task 2 Step 1; -CC inherits via same layout), #4 Kit test (Task 1). ✓
- Staging: A device-proven before B written (Task 3 gates Task 4). ✓
- Invariant reads UIKit's own `bounds - safeAreaInsets.bottom` (spec error-handling fix) -> Task 2 Step 1. ✓

**2. Placeholder scan:** No TBD/"handle edge cases"/"similar to". Every code step has full content. `<PR-122-number>` / `<N>` are runtime values the executor fills, not logic placeholders. Task 2 Step 3 explicitly removes a self-correcting comment artifact rather than shipping it. ✓

**3. Type consistency:** `keybarSafeAreaReservation(accessoryHeight:isFirstResponder:) -> Double` defined in Task 1, consumed identically in Tasks 2 and 4. `lastReservation: CGFloat` used consistently. `firstResponderKeybarHeight()` reused (exists in both containers). `safeAreaLayoutGuide.layoutFrame.height` used for `usableH` in both `layoutSubviews` and `apply` (Task 4 Steps 2). ✓
