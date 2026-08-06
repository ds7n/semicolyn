<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Raw terminal keybar-inset + exit-flash + scroll Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the raw single-terminal path (`TerminalScreen` / `PaneTerminalView`, used by ET, Mosh, and opted-out SSH) inset its terminal to the visible height above the keybar so no rows render behind it; and make a clean ET exit cut straight to the connection list with no transient spinner.

**Architecture:** Port the proven `TmuxPaneContainer` keybar-inset mechanism to the shared `PaneTerminalView.layoutSubviews`, gated to the raw path via a mount-set flag. SwiftTerm derives rows from `frame.height / cellHeight` (verified in v1.15.0 `AppleTerminalView.swift:56,122`, no `contentInset` term), so the fix reduces the view's frame height to `usableH`. Fix the exit flash in `SessionView.statusView` by rendering blank for the transient `.idle` state. Scroll (Issue 3) is diagnosed but its code fix is gated on a post-inset device re-test.

**Tech Stack:** Swift 6, SwiftUI (`UIViewRepresentable`) + UIKit (`TerminalView` subclass), SwiftTerm v1.15.0, XCTest. Kit tier Linux-tested; `TerminalScreen`/`PaneTerminalView`/`SessionView` are App-tier (macOS-CI-compile-only, Linux-invisible).

## Global Constraints

- **Two tiers:** `Sources/SemicolynKit/` = pure logic, Linux-tested, NO UIKit/SwiftUI. `App/` = Apple-only, macOS-CI-verified, invisible to `swift test`.
- **SPDX header** on every source file (`GPL-3.0-only`, © True Positive LLC).
- **No em-dash (U+2014) / en-dash (U+2013)** anywhere. The arrow `→` (U+2192) is allowed (used in existing log lines).
- **Tests must be real:** EP + BVA, assert observable values, negative tests assert the specific value/failure.
- **Do NOT double-inset the -CC path:** `TmuxPaneContainer.layoutSubviews` already sets each pane frame to `usableH`. The new `PaneTerminalView` inset MUST be gated so it runs ONLY on the raw path.
- **SwiftTerm row math (verified, do not re-litigate):** `newRows = Int(frame.height / cellDimension.height)` (`swiftterm-150/Sources/SwiftTerm/Apple/AppleTerminalView.swift:56,122`). No `contentInset` term. The inset reduces `frame.height`, not `contentInset`.
- **Reuse existing Kit helpers:** `usableHeightFromKeyboardTop(rawHeight:keyboardTopY:)` and `visibleTerminalHeight(rawHeight:keybarHeight:)` in `Sources/SemicolynKit/Terminal/TerminalGrid.swift` (already tested).
- **Branch:** `fix/et-onend-clean-exit` (this batches onto PR #121; do NOT push early, the user runs the device test first).
- **Kit test command:** `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter <TestName>`.

---

### Task 1: Fix the exit-flash (Issue 1)

**Files:**
- Modify: `App/SessionView.swift` (the `statusView` computed property, the `switch vm.state` `.idle, .connecting` case).

**Interfaces:**
- Consumes: `vm.state` (`ConnectionState` with `.idle`/`.connecting`/`.failed`/`.shell`), the existing `dismiss()` env action wired via `.onChange(of: vm.state)`.
- Produces: nothing downstream.

**Note:** App-tier, Linux-invisible. Verification is the macOS CI compile + the device retest. Keep the edit mechanical.

- [ ] **Step 1: Split `.idle` out of the spinner case**

In `App/SessionView.swift`, the `statusView`'s `switch vm.state` currently has:

```swift
                case .idle, .connecting:
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Connecting to \(host.label)…")
                        .foregroundStyle(Color(theme.text.secondary))
```

Replace with a separate `.idle` case that renders nothing (transient teardown window), keeping `.connecting` as the spinner:

```swift
                case .idle:
                    // Transient state on the way OUT (a clean exit / disconnect sets
                    // .idle, then .onChange fires dismiss()). Render nothing so the
                    // connecting spinner does not flash for a frame before the view
                    // dismisses to the connection list. A fresh pre-connect session is
                    // .resolving or .connecting, never .idle here, so blank is correct.
                    Color.clear
                case .connecting:
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Connecting to \(host.label)…")
                        .foregroundStyle(Color(theme.text.secondary))
```

- [ ] **Step 2: Local grep sanity check**

Run:
```bash
grep -n "case .idle:\|case .connecting:\|Connecting to" App/SessionView.swift
```
Expected: a standalone `case .idle:` (with `Color.clear`) AND a standalone `case .connecting:` (with the spinner + "Connecting to"); no combined `case .idle, .connecting:` remains.

- [ ] **Step 3: Commit**

```bash
git add App/SessionView.swift
git commit -m "fix(et): exit cuts to connection list without a transient spinner

PR #121's clean-exit sets state=.idle then dismiss(); between them
SessionView rendered statusView's .idle case = the 'Connecting…' spinner
for a frame. Render blank for the transient .idle so exit is a clean cut.

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
```

---

### Task 2: Raw-path keybar inset (Issue 2)

**Files:**
- Modify: `App/PaneTerminalView.swift` (add `appliesOwnKeybarInset` flag + inset logic in `layoutSubviews`).
- Modify: `App/TerminalScreen.swift` (`makeUIView`: set the flag `true`).
- (No change to `App/TmuxPaneContainer.swift`, it leaves the flag `false` = default.)

**Interfaces:**
- Consumes (Kit, already exist): `usableHeightFromKeyboardTop(rawHeight: Double, keyboardTopY: Double?) -> Double`, `visibleTerminalHeight(rawHeight: Double, keybarHeight: Double) -> Double`.
- Consumes (UIKit): `UIView.keyboardLayoutGuide.layoutFrame` (iOS 15+), `KeybarInputAccessory.intrinsicContentSize.height`.
- Produces: `PaneTerminalView.appliesOwnKeybarInset: Bool` (default `false`), set `true` by `TerminalScreen.makeUIView`.

**Note:** App-tier, Linux-invisible. Verification = macOS CI compile + device retest. SwiftTerm row math is `frame.height / cellHeight` (verified); the inset reduces the frame height.

- [ ] **Step 1: Add the mount-set flag to `PaneTerminalView`**

In `App/PaneTerminalView.swift`, inside `final class PaneTerminalView: TerminalView`, near `onModeRelevantChange`, add:

```swift
    /// True ONLY on the raw single-terminal path (`TerminalScreen`), where SwiftUI
    /// sizes this view to the full slot and the keybar (`inputAccessoryView`) floats
    /// over the bottom rows. When set, `layoutSubviews` insets the view's frame height
    /// to the visible area above the keybar so SwiftTerm's row count (frame.height /
    /// cellHeight) equals the VISIBLE rows and no row renders behind the keybar. Left
    /// false on the -CC path (`TmuxPaneContainer`), which already sizes each pane frame
    /// to the usable height externally, so this view must NOT double-inset there.
    var appliesOwnKeybarInset = false
```

- [ ] **Step 2: Apply the inset in `layoutSubviews`**

In `App/PaneTerminalView.swift`, `layoutSubviews` currently is (diagnostic only):

```swift
    override func layoutSubviews() {
        super.layoutSubviews()
        guard DebugLog.shared.isEnabled(.geometry) else { return }
        ...geo:pane logging...
    }
```

Insert the inset BETWEEN `super.layoutSubviews()` and the geometry-logging guard, so the log reflects the post-inset frame:

```swift
    override func layoutSubviews() {
        super.layoutSubviews()
        // Raw-path keybar inset (device 2026-08-06): SwiftTerm derives its row count
        // from frame.height / cellHeight (AppleTerminalView v1.15.0), so a full-bounds
        // frame renders ~kbH/cellH bottom rows behind the floating keybar. Reduce the
        // frame height to the visible area above the keybar. Mirror TmuxPaneContainer's
        // usableH: prefer the real keybar top from keyboardLayoutGuide (re-lays-out post
        // app-switch), else the measured keybar-height reduction. Gated to the raw path;
        // the -CC path insets its panes externally and must not be double-inset.
        if appliesOwnKeybarInset {
            let raw = Double(bounds.height)
            let guideTop: Double? = {
                let f = keyboardLayoutGuide.layoutFrame
                guard f.height > 0, f.width > 0, f.minY.isFinite, f.minY > 0 else { return nil }
                return Double(f.minY)
            }()
            let usableH: Double = {
                if let guideTop {
                    return usableHeightFromKeyboardTop(rawHeight: raw, keyboardTopY: guideTop)
                }
                let kbH = isFirstResponder
                    ? Double((inputAccessoryView as? KeybarInputAccessory)?.intrinsicContentSize.height ?? -1)
                    : -1
                return visibleTerminalHeight(rawHeight: raw, keybarHeight: kbH)
            }()
            // Only mutate when it actually differs (a re-entrant pass with height already
            // == usableH must be a no-op, or layoutSubviews loops). Keep origin/width from
            // the SwiftUI slot; shrink height only. The keybar floats over the freed region.
            if usableH > 0, abs(usableH - Double(frame.height)) > 0.5 {
                frame.size.height = CGFloat(usableH)
            }
        }
        guard DebugLog.shared.isEnabled(.geometry) else { return }
        ...unchanged geo:pane logging...
    }
```

(Leave the existing `geo:pane` logging block exactly as-is below this.)

- [ ] **Step 3: Import the Kit helpers in `PaneTerminalView.swift`**

Ensure `import SemicolynKit` is present at the top of `App/PaneTerminalView.swift` (the Kit helpers `usableHeightFromKeyboardTop` / `visibleTerminalHeight` live there). If it is already imported, no change.

- [ ] **Step 4: Set the flag on the raw mount**

In `App/TerminalScreen.swift`, `makeUIView`, right after `let terminal = PaneTerminalView(frame: .zero)`, add:

```swift
        // Raw single-terminal path: this view owns its keybar inset (see
        // PaneTerminalView.appliesOwnKeybarInset). The -CC container path leaves this
        // false and insets its panes itself.
        terminal.appliesOwnKeybarInset = true
```

- [ ] **Step 5: Local grep sanity check**

Run:
```bash
grep -n "appliesOwnKeybarInset" App/PaneTerminalView.swift App/TerminalScreen.swift
grep -n "usableHeightFromKeyboardTop\|visibleTerminalHeight\|import SemicolynKit" App/PaneTerminalView.swift
grep -n "appliesOwnKeybarInset" App/TmuxPaneContainer.swift || echo "OK: TmuxPaneContainer does NOT set the flag (default false)"
```
Expected: `appliesOwnKeybarInset` in `PaneTerminalView.swift` (declaration + `layoutSubviews` use) and `TerminalScreen.swift` (set true); both Kit helpers referenced in `PaneTerminalView.swift` under an `import SemicolynKit`; NOT set in `TmuxPaneContainer.swift`.

- [ ] **Step 6: Commit**

```bash
git add App/PaneTerminalView.swift App/TerminalScreen.swift
git commit -m "fix(term): inset the raw terminal to the visible area above the keybar

The raw single-terminal path (TerminalScreen, used by ET/Mosh/opted-out
SSH) let SwiftUI size the terminal to full bounds; SwiftTerm derives rows
from frame.height/cellHeight, so the bottom ~kbH/cellH rows (incl. the shell
prompt) rendered behind the floating keybar. Port TmuxPaneContainer's usableH
inset to the shared PaneTerminalView.layoutSubviews, gated to the raw path
via appliesOwnKeybarInset so the -CC path (which insets externally) is not
double-inset. Fixes rows-behind-keybar for ET, Mosh, and raw SSH together.

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
```

---

### Task 3: Push to CI, build, and gate Issue 3 on the device retest

**Files:** none (CI + device gate only).

**Interfaces:** none.

**Note:** This task does NOT fix Issue 3 (scroll). Per the spec, Issue 3 is gated on the post-Issue-2 device re-test: fixing the usable-height mismatch may resolve scroll, so a speculative scroll fix now would be guessing. This task lands Issues 1+2, cuts a build, and defines the exact device retest whose result decides whether an Issue 3 task is needed.

- [ ] **Step 1: Push and let CI run (do NOT merge; user gates on device)**

```bash
git push github fix/et-onend-clean-exit
```
Then watch CI:
```bash
gh run watch --repo ds7n/semicolyn $(gh run list --repo ds7n/semicolyn --branch fix/et-onend-clean-exit --limit 1 --json databaseId --jq '.[0].databaseId') --exit-status
```
Expected: `macos` + `linux-swift` + `linux-rust` + `lint` all green. `macos` is the only signal the `TerminalScreen`/`PaneTerminalView`/`SessionView` edits compile. If only `linux-rust` flakes (sshd-fixtures race), rerun it.

- [ ] **Step 2: Trigger a TestFlight build (gated on the macos job passing)**

```bash
gh workflow run "Release to TestFlight" --repo ds7n/semicolyn --ref fix/et-onend-clean-exit
```
Watch the run and CONFIRM the log shows `UPLOAD SUCCEEDED` (the lane can report green even on a failed upload):
```bash
RID=$(gh run list --repo ds7n/semicolyn --workflow "Release to TestFlight" --branch fix/et-onend-clean-exit --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch --repo ds7n/semicolyn "$RID" --exit-status
gh run view --repo ds7n/semicolyn "$RID" --log | grep -iE "UPLOAD SUCCEEDED|No errors uploading|UPLOAD FAILED"
```

- [ ] **Step 3: Define + hand off the device retest (all diagnostic categories ON)**

Report to the user that the build is ready and to run, with ALL diagnostic categories enabled:
1. **Issue 2 (rows):** connect ET to the dev box. The shell prompt must sit on the last VISIBLE row; no rows behind the keybar. Show/hide the keyboard and app-switch; `rows == visible rows` in every state. Verify in the log: `geo:pane` frame height should now equal `usableH` (not full bounds), and `sizing:raw` grid rows should equal `usableH/cellH`.
2. **Issue 1 (exit):** type `exit`; a clean cut to the connection list, NO "Connecting…" spinner flash.
3. **Issue 3 (scroll):** swipe to scroll. Capture `gesture:*` / native-scroll events.
   - If scroll now works: Issue 3 was downstream of Issue 2, done, merge #121 batch.
   - If scroll still dead: DO NOT merge; open an Issue 3 task with the fresh capture (the `handlePan` / native-scroll-pan arbitration that never logged) and root-cause the recognizer arbitration in `TerminalScreen`/`TerminalGestureController` (cf. `PaneTerminalView` 61-78 `editingInteractionConfiguration=.none`, `disableStraySwiftTermPans`, `subordinateSelectionPan`).
4. **A/B path proof:** set dev host `attemptControlMode = false`, connect over plain (raw) SSH; it must show the SAME corrected behavior as ET (proves the fix is in the shared raw path, not ET-specific).

- [ ] **Step 4: Record the device result in the ledger / TODO before deciding next step**

After the user reports: if Issues 1+2 pass and Issue 3 is resolved, the batch is device-confirmed, merge PR #121 (which now carries all of it). If Issue 3 remains, add the Issue 3 root-cause task and keep the branch open.

---

## Self-review checklist (run after writing, fix inline)

- Spec coverage: Issue 1 -> Task 1; Issue 2 -> Task 2; Issue 3 -> Task 3 gate (deliberately not a code task yet, per spec). A/B path proof -> Task 3 Step 3.4.
- No placeholders: all code blocks are literal; no "add handling"/"TBD".
- Type consistency: `appliesOwnKeybarInset` (Bool), `usableHeightFromKeyboardTop(rawHeight:keyboardTopY:)`, `visibleTerminalHeight(rawHeight:keybarHeight:)`, `keyboardLayoutGuide.layoutFrame` used consistently across tasks.
