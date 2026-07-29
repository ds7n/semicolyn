<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Alt-screen text selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make double/triple-tap text selection work inside alt-screen apps (Claude/vim under tmux -CC), using the same iOS-native path as the normal screen, with tap->chars diagnostic logging so correctness is provable on device.

**Architecture:** Subtractive. Remove the `.localScroll`-only guard that PR #102 added to `handleDoubleTap`/`handleTripleTap` so selection runs in every mode against SwiftTerm's local grid (which under tmux -CC is the visible content). Extract the pure word-expansion into a Linux-tested helper. Add one diagnostic log line per handler capturing tap->cell->chars. The whole risk is concentrated in a device-verification step before merge.

**Tech Stack:** Swift 6 (strict concurrency), SwiftTerm, tmux -CC, XCTest. Kit = Linux-tested; App = macOS-CI-validated + device-proven.

## Global Constraints

- SemicolynKit tier is pure, Linux-tested: no `import UIKit`/`SwiftUI`/`CryptoKit`; `Sendable`; Swift 6 strict concurrency.
- App tier does NOT compile on Linux (no host Swift toolchain); macOS CI is the only compile signal. Keep App changes thin.
- Every source file carries the SPDX header: `// SPDX-FileCopyrightText: 2026 True Positive LLC` / `// SPDX-License-Identifier: GPL-3.0-only`.
- No em-dash (U+2014) or en-dash (U+2013) anywhere.
- Conventional commits. Feature branch `feat/alt-screen-selection` (already created off `main`); squash-merge.
- Kit tests: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter <Name>` (from repo root).
- Privacy: selection text is logged ONLY via `DebugLog.log(.gesture, ...)`, which is an `@autoclosure` no-op when the `.gesture` category is off (diagnostics off by default). Truncate logged chars to 120. Never evaluate/stream chars when gated out.
- Existing facts (verified): the two guards to remove are `guard callbacks.currentMode() == .localScroll else { ...yield...; return }` at the top of `handleDoubleTap` (App/TerminalGestureController.swift ~657) and `handleTripleTap` (~677). `wordBounds(col:row:in:)` (~707) has an inner `isWordChar(_ c: Int) -> Bool` predicate + a walk-left/walk-right loop over `0..<cols`. `term.getCharData(col:row:)?.getCharacter()` yields a `Character` (same pattern as SwiftTermEchoOracle). `InteractionMode` cases: `localScroll`/`appOwnsInput`/`mouseReporting`.

---

## Task 1: Extract pure `wordBounds` helper (Kit, Linux-tested)

**Files:**
- Create: `Sources/SemicolynKit/Terminal/WordBounds.swift`
- Test: `Tests/SemicolynKitTests/WordBoundsTests.swift`

**Interfaces:**
- Produces: `func wordBounds(cols: Int, col: Int, isWordChar: (Int) -> Bool) -> (start: Int, end: Int)`, pure, view-free. Walks left/right from a clamped `col` over indices where `isWordChar(index)` is true, bounded to `0..<cols`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/SemicolynKitTests/WordBoundsTests.swift`. Model a row as a `[Bool]` word-mask; `isWordChar` = `mask[index]` (false when out of range).

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class WordBoundsTests: XCTestCase {
    /// Helper: build isWordChar from a mask; out-of-range -> false.
    private func pred(_ mask: [Bool]) -> (Int) -> Bool {
        { i in i >= 0 && i < mask.count && mask[i] }
    }

    // Mid-word expands both directions. "  word  " -> cols 2..5 are word.
    func testMidWordExpandsBothWays() {
        let mask = [false, false, true, true, true, true, false, false] // cols 2,3,4,5
        let r = wordBounds(cols: 8, col: 4, isWordChar: pred(mask))
        XCTAssertEqual(r.start, 2)
        XCTAssertEqual(r.end, 5)
    }

    // Word at column 0 clamps left, expands right.
    func testWordAtLeftEdgeClamps() {
        let mask = [true, true, true, false, false]
        let r = wordBounds(cols: 5, col: 0, isWordChar: pred(mask))
        XCTAssertEqual(r.start, 0)
        XCTAssertEqual(r.end, 2)
    }

    // Word at last column clamps right.
    func testWordAtRightEdgeClamps() {
        let mask = [false, false, true, true, true] // cols 2,3,4 (4 = last)
        let r = wordBounds(cols: 5, col: 4, isWordChar: pred(mask))
        XCTAssertEqual(r.start, 2)
        XCTAssertEqual(r.end, 4)
    }

    // Tap on whitespace: the tapped cell is not a word char; selection is just that cell.
    func testTapOnWhitespaceIsDegenerate() {
        let mask = [true, true, false, true, true] // col 2 is space
        let r = wordBounds(cols: 5, col: 2, isWordChar: pred(mask))
        XCTAssertEqual(r.start, 2)
        XCTAssertEqual(r.end, 2)
    }

    // Single-char word bounded by spaces.
    func testSingleCharWord() {
        let mask = [false, true, false]
        let r = wordBounds(cols: 3, col: 1, isWordChar: pred(mask))
        XCTAssertEqual(r.start, 1)
        XCTAssertEqual(r.end, 1)
    }

    // All-whitespace row: degenerate at the tapped col.
    func testAllWhitespaceRow() {
        let mask = [false, false, false, false]
        let r = wordBounds(cols: 4, col: 2, isWordChar: pred(mask))
        XCTAssertEqual(r.start, 2)
        XCTAssertEqual(r.end, 2)
    }

    // Out-of-range col clamps into [0, cols-1] before expanding.
    func testColAboveRangeClamps() {
        let mask = [true, true, true, true]
        let r = wordBounds(cols: 4, col: 99, isWordChar: pred(mask))
        XCTAssertEqual(r.start, 0)   // whole row is word, clamps to last col then expands full
        XCTAssertEqual(r.end, 3)
    }

    // Whole row is a word: full-width selection.
    func testWholeRowWord() {
        let mask = [true, true, true, true]
        let r = wordBounds(cols: 4, col: 1, isWordChar: pred(mask))
        XCTAssertEqual(r.start, 0)
        XCTAssertEqual(r.end, 3)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter WordBoundsTests`
Expected: FAIL to compile ("cannot find 'wordBounds'").

- [ ] **Step 3: Write minimal implementation**

Create `Sources/SemicolynKit/Terminal/WordBounds.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Word bounds on a single terminal row: from a tapped column, walk left and
/// right over contiguous word cells. `isWordChar(i)` reports whether column `i`
/// holds a word glyph (non-space); it must return false for out-of-range `i`.
/// `col` is clamped into `0..<cols` first. Returns the inclusive `(start, end)`
/// column range. A tap on a non-word cell yields a degenerate `(col, col)`.
///
/// Pure and view-free so it is Linux-testable; the App layer supplies
/// `isWordChar` backed by SwiftTerm's `getCharData`.
public func wordBounds(cols: Int, col: Int,
                       isWordChar: (Int) -> Bool) -> (start: Int, end: Int) {
    let maxCol = max(cols - 1, 0)
    var lo = min(max(col, 0), maxCol)
    var hi = lo
    while lo > 0, isWordChar(lo - 1) { lo -= 1 }
    while hi < maxCol, isWordChar(hi + 1) { hi += 1 }
    return (lo, hi)
}
```

Note: this matches the existing App-side walk exactly. It does NOT force the
tapped cell to be a word char (mirrors current behavior: on whitespace, both
loops fail their `isWordChar(neighbor)` guard and the range stays `(col, col)`).

- [ ] **Step 4: Run tests to verify they pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter WordBoundsTests`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Terminal/WordBounds.swift Tests/SemicolynKitTests/WordBoundsTests.swift
git commit -m "feat(kit): pure wordBounds helper for text selection"
```

---

## Task 2: Remove the guard, use the pure helper, add tap->chars logging (App, macOS-CI + device)

**Files:**
- Modify: `App/TerminalGestureController.swift` (`handleDoubleTap` ~649-670; `handleTripleTap` ~672-690; `wordBounds(col:row:in:)` ~707-720)

**Interfaces:**
- Consumes: `wordBounds(cols:col:isWordChar:)` (Task 1); existing `cell(at:in:)`, `setSelectionRange`, `presentEditMenu`, `subordinateSelectionPan`, `term.getCharData(col:row:)?.getCharacter()`.

- [ ] **Step 1: Rewrite the App-side `wordBounds(col:row:in:)` to delegate to the pure helper**

Replace the body of `wordBounds(col:row:in:)` (keep the same signature so callers are untouched) with a thin adapter that builds `isWordChar` from SwiftTerm and calls the Kit helper:

```swift
    /// Word bounds on a row, backed by SwiftTerm's grid. Delegates the walk to
    /// the pure `wordBounds(cols:col:isWordChar:)` (Kit-tested).
    private func wordBounds(col: Int, row: Int, in view: TerminalView) -> (Int, Int) {
        let term = view.getTerminal()
        let cols = max(term.cols, 1)
        func isWordChar(_ c: Int) -> Bool {
            guard c >= 0, c < cols, let cd = term.getCharData(col: c, row: row) else { return false }
            let ch = cd.getCharacter()
            return !(ch == " " || ch == "\t" || ch == "\0")
        }
        let r = SemicolynKit.wordBounds(cols: cols, col: col, isWordChar: isWordChar)
        return (r.start, r.end)
    }
```

(If `SemicolynKit.` qualification is unnecessary given the existing imports, drop it; confirm the module is imported at the top of the file. The point is the walk logic now lives in the tested helper, not duplicated here.)

- [ ] **Step 2: Add a private helper to read selected chars for logging**

Add near the selection helpers (used only by the diagnostic log line; it reads the resolved range back as text). Cap at 120 chars.

```swift
    /// The characters currently in `[startCol, endCol]` on `row`, for diagnostics.
    /// Truncated to 120. Read via `getCharData` (same source selection uses).
    private func selectedChars(row: Int, startCol: Int, endCol: Int, in view: TerminalView) -> String {
        let term = view.getTerminal()
        var s = ""
        var c = startCol
        while c <= endCol, s.count < 120 {
            if let cd = term.getCharData(col: c, row: row) { s.append(cd.getCharacter()) }
            c += 1
        }
        return s
    }
```

- [ ] **Step 3: Remove the guard from `handleDoubleTap` and add the tap->chars log**

In `handleDoubleTap`: delete the `guard callbacks.currentMode() == .localScroll else { ... return }` block (lines ~652-660, including its outdated comment about yielding on the alt-screen). Replace the leading comment with a one-line note that selection now runs in every mode against the visible grid. After computing `(start, end)` and calling `setSelectionRange`, add the diagnostic line. Final handler body:

```swift
    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        guard let view = terminalView else { return }
        DebugLog.shared.log(.gesture, "gr:\(#function) state=\(g.state.rawValue) loc=\(g.location(in: view))")
        // Word-select runs in every mode: it selects against SwiftTerm's local grid,
        // which under tmux -CC is the currently-visible content. (Pre-#102 alt-screen
        // mis-selection was a tap->cell coordinate bug, since fixed by TapRowMapping +
        // full-height panes; proven on device 2026-07-29.)
        let p = g.location(in: view)
        let (col, row) = cell(at: p, in: view)
        let (start, end) = wordBounds(col: col, row: row, in: view)
        view.setSelectionRange(start: Position(col: start, row: row), end: Position(col: end, row: row))
        subordinateSelectionPan(on: view)
        DebugLog.shared.log(.gesture,
            "sel:double loc=\(p) mode=\(callbacks.currentMode()) cell=(\(col),\(row)) word=(\(start),\(end)) chars=\"\(selectedChars(row: row, startCol: start, endCol: end, in: view))\"")
        presentEditMenu(at: p, in: view)
    }
```

(The `chars=` string is only built when `.gesture` is enabled, because `log` takes an `@autoclosure` and is a no-op when gated out. Keep or drop the old `sel:before`/`sel:after` lines as preferred; the new line supersedes them.)

- [ ] **Step 4: Remove the guard from `handleTripleTap` and add the tap->chars log**

Same for `handleTripleTap`: delete its `.localScroll` guard block, update the comment, add the diagnostic line. Final body:

```swift
    @objc private func handleTripleTap(_ g: UITapGestureRecognizer) {
        guard let view = terminalView else { return }
        DebugLog.shared.log(.gesture, "gr:\(#function) state=\(g.state.rawValue) loc=\(g.location(in: view))")
        // Line-select runs in every mode (see handleDoubleTap).
        let p = g.location(in: view)
        let (_, row) = cell(at: p, in: view)
        let cols = max(view.getTerminal().cols, 1)
        view.setSelectionRange(start: Position(col: 0, row: row),
                               end: Position(col: cols - 1, row: row))
        subordinateSelectionPan(on: view)
        DebugLog.shared.log(.gesture,
            "sel:triple loc=\(p) mode=\(callbacks.currentMode()) row=\(row) chars=\"\(selectedChars(row: row, startCol: 0, endCol: cols - 1, in: view))\"")
        presentEditMenu(at: p, in: view)
    }
```

- [ ] **Step 5: Verify (macOS CI) + commit**

App-tier: no local compile. Re-read both handlers and confirm: guards gone; `wordBounds` still called with the same signature; `selectedChars` in scope; log lines balanced; no em/en-dash; no other code path assumed selection was `.localScroll`-only (grep `currentMode() == .localScroll` in the file to confirm the only remaining uses are `handleSingleTap`'s cursor-placement branch, NOT selection). `git diff` for scope.

```bash
git add App/TerminalGestureController.swift
git commit -m "feat(app): enable text selection on alt-screen; log tap->selected-chars"
```

---

## Task 3: Push, CI, device-proof, merge

**Files:** none (verification).

- [ ] **Step 1: Push the branch**

```bash
git push -u github feat/alt-screen-selection
```

- [ ] **Step 2: Wait for CI**

`linux-swift` (WordBoundsTests included) + `lint` fast; the `macos` job (~15-18 min) is the only signal that Task 2 compiles. Confirm all green. Rerun a flaky `linux-rust` (sshd-fixtures race) if it hits.

- [ ] **Step 3: Device-proof (TestFlight) - THE GATING CHECK**

Trigger a TF build (gated on the macos job passing). Enable Settings -> Diagnostics with the `.gesture` category on; syslog-sink up (TLS 6514/TCP). In a Claude pane (alt-screen):
1. Double-tap a word -> the CORRECT visible word highlights; iOS Copy menu appears; Copy puts that word on the clipboard. Log shows `sel:double ... chars="<the word you tapped>"` matching.
2. Triple-tap -> the correct visible line highlights + copies.
3. Scroll UP to earlier output, double-tap a visible word -> correct word selected (verifies the scrolled `contentOffset` path).
4. Long-press still zooms; single-tap still focuses/places cursor; window-switch drag unaffected.
5. Repeat in vim with `mouse=a` on (`.mouseReporting`) -> select works; single-tap/drag still reach the app.

If any selection is WRONG: the `sel:*` line's `loc` vs `chars` mismatch pinpoints the residual coordinate bug. Root-cause THAT specifically (do not blind-retry); it likely lives in `cell(at:)`/`TapRowMapping`/`cellH`. Only merge after selection is confirmed correct on device.

- [ ] **Step 4: Squash-merge** `feat/alt-screen-selection` -> `main` once device-verified.

---

## Self-review notes

- **Spec coverage:** remove-guard (Task 2 Steps 3-4), both modes enabled (guard removed entirely, not replaced with `!= .mouseReporting`), one-model local selection (uses existing `setSelectionRange` path), one-screenful scope (no cross-scroll code added; `cell(at:)`/`TapRowMapping` unchanged), auto Copy menu (`presentEditMenu` retained), diagnostic logging + device-proof (Task 2 Step 2-4 + Task 3 Step 3), pure `wordBounds` + tests (Task 1). All spec sections map to a task.
- **No placeholders:** all code is concrete; the one conditional in the spec (extract `wordBounds` or not) is resolved to "extract" with full code in Task 1.
- **Type consistency:** pure helper `wordBounds(cols:col:isWordChar:) -> (start:Int, end:Int)` in Task 1 is consumed with that exact signature in Task 2 Step 1. `selectedChars(row:startCol:endCol:in:)` defined and used consistently. `InteractionMode`/`currentMode()` names match the codebase.
