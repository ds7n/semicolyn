# Selection UI (Slice 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the locked Topic 3 selection UI: a visible selection highlight on the alt-screen (root-cause fix), sub-word double-tap, focus-on-select, bracketed paste, draggable endpoint handles, and a custom magnifier loupe.

**Architecture:** Every decision-shaped computation is a pure, Linux-tested `SemicolynKit` function (row math, sub-word boundary, selection ordering, handle hit-test, bracketed-paste bytes, loupe geometry). The App tier (`TerminalGestureController`, a new loupe overlay view) is a thin wiring layer over SwiftTerm's public `setSelectionRange` / `getCharData` / `sendBytes`, validated on macOS CI and device. SwiftTerm draws the highlight fill + handle circles in its own `drawRect`, so once the stored selection row is in the draw loop's absolute content space, the highlight renders for free.

**Tech Stack:** Swift 6 (SemicolynKit: strict-concurrency, Sendable, no UIKit; App: UIKit + SwiftTerm v1.15.0), XCTest, Docker `semicolyn-dev` for Linux `swift test`.

## Global Constraints

- **Two tiers:** decision logic in `Sources/SemicolynKit/` (Linux-tested, no `import UIKit`/`SwiftUI`/`CryptoKit`); App wiring in `App/` (macOS-CI + device only, invisible to `swift test`).
- **SwiftTerm resolves to v1.15.0** (SPM `from: "1.0.0"`). The repo's `swiftterm-150/` clone is mis-tagged 1.5.0 = WRONG version; do not trust it. `buffer.yDisp` is NOT public in 1.15.0.
- **`setSelectionRange(start:end:)`** (public, iOS view) expects **absolute buffer-relative** `Position` rows. **`getCharData(col:row:)`** expects a **viewport** row (0..<rows).
- **Every source file carries the SPDX header** (`// SPDX-FileCopyrightText: 2026 True Positive LLC` / `// SPDX-License-Identifier: GPL-3.0-only`). Kit files: 2 lines at top. Test files: same.
- **No em-dash (U+2014) / en-dash (U+2013)** anywhere (prose, code, comments, commits). Use colon/comma/parens/semicolon.
- **Conventional commits** (`feat:`/`fix:`/`refactor:`/`test:`/`docs:`).
- **Tests must be real:** EP + BVA, assert exact expected values, negatives assert the specific outcome. No tautologies.
- **Linux test command:** `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter <Name>`.
- **Carry-forward before any main-merge (from Slice 1):** remove the `.selection` diagnostics (`SelectionDiagnostics.snapshot`, set/redraw/repaint phase logs) and flip `InputClickFeedback.diagnosticsEnabled` back to `false`. These are Task 9.

---

### Task 1: Absolute-row mapping in Kit

**Files:**
- Modify: `Sources/SemicolynKit/Terminal/TapRowMapping.swift`
- Test: `Tests/SemicolynKitTests/TapRowMappingTests.swift`

**Interfaces:**
- Consumes: nothing (extends existing `TapRowMapping`).
- Produces: `TapRowMapping.absoluteRow(contentY: Double, cellHeight: Double, totalRows: Int) -> Int` (content-space absolute buffer row for a tap; clamps into `0..<totalRows`; returns 0 when `cellHeight <= 0` or `totalRows <= 0`).

- [ ] **Step 1: Write the failing tests**

Append to `Tests/SemicolynKitTests/TapRowMappingTests.swift` (inside the existing `TapRowMappingTests` class):

```swift
// absoluteRow: content y maps directly to a content/buffer row (NO offset subtraction);
// this is the row space SwiftTerm's iOS draw loop + selection use (Int(contentY/cellHeight)).
// EP: top of content (unscrolled viewport).
func testAbsoluteRowAtTop() {
    XCTAssertEqual(
        TapRowMapping.absoluteRow(contentY: 105, cellHeight: 10, totalRows: 1000),
        10)
}

// EP: deep in the scrollback / alt-screen (yDisp>0 case): a large content y -> a large
// absolute row, WITHOUT the offset subtraction the viewport mapping does.
func testAbsoluteRowDeepInContent() {
    XCTAssertEqual(
        TapRowMapping.absoluteRow(contentY: 5255, cellHeight: 10, totalRows: 1000),
        525)
}

// BVA: exactly on a row top.
func testAbsoluteRowBoundary() {
    XCTAssertEqual(
        TapRowMapping.absoluteRow(contentY: 320, cellHeight: 10, totalRows: 1000),
        32)
}

// BVA: past the last content row clamps to totalRows-1.
func testAbsoluteRowClampsToLast() {
    XCTAssertEqual(
        TapRowMapping.absoluteRow(contentY: 999999, cellHeight: 10, totalRows: 33),
        32)
}

// Negative: non-positive cellHeight -> 0 (defensive, no divide-by-zero).
func testAbsoluteRowZeroCellHeight() {
    XCTAssertEqual(
        TapRowMapping.absoluteRow(contentY: 105, cellHeight: 0, totalRows: 1000),
        0)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TapRowMappingTests`
Expected: FAIL, `absoluteRow` is not a member of `TapRowMapping`.

- [ ] **Step 3: Add the implementation**

Add to `TapRowMapping` in `Sources/SemicolynKit/Terminal/TapRowMapping.swift`:

```swift
    /// The ABSOLUTE content/buffer row for a tap. Unlike `row(...)` (which subtracts the
    /// scroll offset to get a VIEWPORT row for SwiftTerm's `getCharData`/`getLine`), this
    /// keeps the content-space row: `Int(contentY / cellHeight)`, the same value SwiftTerm's
    /// iOS draw loop uses as `firstRow`. It is the row space `setSelectionRange` and the
    /// selection highlight/copy paths want (they index `buffer.lines[row]` absolutely).
    /// `contentY` is `gesture.location(in: view).y`, already in content space.
    public static func absoluteRow(contentY: Double, cellHeight: Double,
                                   totalRows: Int) -> Int {
        guard cellHeight > 0, totalRows > 0 else { return 0 }
        let r = Int(contentY / cellHeight)
        return min(totalRows - 1, max(0, r))
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TapRowMappingTests`
Expected: PASS (all, including the pre-existing viewport-row tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Terminal/TapRowMapping.swift Tests/SemicolynKitTests/TapRowMappingTests.swift
git commit -m "feat(kit): add TapRowMapping.absoluteRow for selection row space"
```

---

### Task 2: Wire the absolute row into selection (the highlight fix)

**Files:**
- Modify: `App/TerminalGestureController.swift` (`cell(at:)` ~311-330; `handleDoubleTap` ~649; `handleTripleTap` ~689)

**Interfaces:**
- Consumes: `TapRowMapping.absoluteRow(contentY:cellHeight:totalRows:)` (Task 1); existing `TapRowMapping.row(...)`.
- Produces: `cell(at:in:)` now returns `(col: Int, viewportRow: Int, absoluteRow: Int)`. Selection call sites pass `absoluteRow` to `setSelectionRange`; word/char reads keep `viewportRow`.

- [ ] **Step 1: Change `cell(at:)` to return both rows**

In `App/TerminalGestureController.swift`, replace the `cell(at:in:)` body's return and signature. New version:

```swift
    private func cell(at point: CGPoint, in view: TerminalView) -> (col: Int, viewportRow: Int, absoluteRow: Int) {
        let term = view.getTerminal()
        let cols = max(term.cols, 1)
        let rows = max(term.rows, 1)
        let cellW = view.bounds.width / CGFloat(cols)
        let cellH = view.bounds.height / CGFloat(rows)
        guard cellW > 0, cellH > 0 else { return (0, 0, 0) }
        let col = min(cols - 1, max(0, Int(point.x / cellW)))
        // `point` is content-space (the view is a UIScrollView). Two row spaces are needed:
        //  - viewportRow (0..<rows) for getCharData/getLine (SwiftTerm adds yDisp itself).
        //  - absoluteRow (content/buffer row) for setSelectionRange: the highlight draw loop
        //    and the copy path index buffer.lines[row] ABSOLUTELY, so a viewport row never
        //    matches once scrolled/alt-screen (yDisp>0) => the invisible-highlight bug.
        let viewportRow = TapRowMapping.row(contentY: Double(point.y),
                                            contentOffsetY: Double(view.contentOffset.y),
                                            cellHeight: Double(cellH), rows: rows)
        let totalRows = max(Int(view.contentSize.height / cellH), rows)
        let absoluteRow = TapRowMapping.absoluteRow(contentY: Double(point.y),
                                                    cellHeight: Double(cellH),
                                                    totalRows: totalRows)
        return (col, viewportRow, absoluteRow)
    }
```

- [ ] **Step 2: Update the single-tap place-cursor caller (~638-642)**

The `.active(.placeCursor)` branch reads `cell(at:)` then calls `callbacks.onPlaceCursor(target.col, target.row)` and logs `target.row`. The new tuple renames `row` to `viewportRow`, so BOTH the call and the log must change (place-cursor uses the viewport row: it feeds mouse reporting / cursor synthesis):

```swift
            let target = cell(at: p, in: view)
            callbacks.onPlaceCursor(target.col, target.viewportRow)
            DebugLog.shared.log(.gesture, "gesture:singleTap action=place at=(\(target.col),\(target.viewportRow))")
```

- [ ] **Step 3: Update `handleDoubleTap` (~657-659)**

`wordBounds` reads cells via `getCharData` (viewport row); `setSelectionRange` gets the absolute row:

```swift
        let (col, viewportRow, absoluteRow) = cell(at: p, in: view)
        let (start, end) = wordBounds(col: col, row: viewportRow, in: view)
        view.setSelectionRange(start: Position(col: start, row: absoluteRow),
                               end: Position(col: end, row: absoluteRow))
```

- [ ] **Step 4: Update `handleTripleTap` (~694-697)**

```swift
        let (_, _, absoluteRow) = cell(at: p, in: view)
        let cols = max(view.getTerminal().cols, 1)
        view.setSelectionRange(start: Position(col: 0, row: absoluteRow),
                               end: Position(col: cols - 1, row: absoluteRow))
```

- [ ] **Step 5: Remove the guessed `setNeedsDisplay`**

Delete the two `view.setNeedsDisplay(view.bounds)` lines (in `handleDoubleTap` ~672 and `handleTripleTap` ~706) and their preceding "Force a synchronous repaint" comment blocks. The guess (commit 64dc281) was not the fix.

- [ ] **Step 6: Build check (macOS CI is the only signal; do a local Kit test to confirm no Kit break)**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS (App does not compile on Linux; this confirms Kit is unbroken). App compile is verified by macOS CI after push.

- [ ] **Step 7: Commit**

```bash
git add App/TerminalGestureController.swift
git commit -m "fix(app): store selection at absolute content row so highlight draws (yDisp fix)"
```

---

### Task 3: Sub-word boundary in Kit

**Files:**
- Modify: `Sources/SemicolynKit/Terminal/WordBounds.swift`
- Test: `Tests/SemicolynKitTests/WordBoundsTests.swift` (create if absent; otherwise append)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum SemicolynKit.CharClass { case word, space, punct }`
  - `SemicolynKit.subWordBounds(cols: Int, col: Int, classOf: (Int) -> CharClass) -> (start: Int, end: Int)` (extends left/right while the class stays equal to the tapped cell's class; clamps `col` into `0..<cols`; degenerate `(col,col)` on a space cell; out-of-range `classOf(i)` must be treated as a boundary by returning `.space`).
  - `SemicolynKit.selectionPunctuation: Set<Character>` (the locked break set `. - / _ , :` plus `; = @ ~ ( ) [ ] { } < > | & ! ? * "` and `'`).

- [ ] **Step 1: Write the failing tests**

Create `Tests/SemicolynKitTests/WordBoundsTests.swift` (or append if it exists):

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Sub-word selection breaks on a character-class change (word / space / punct), matching
/// iOS/desktop double-click. Fixes the "double-tap grabbed the whole .claude-staging-oauth.json"
/// bug: double-tapping `staging` selects `staging`, not the whole token.
final class SubWordBoundsTests: XCTestCase {
    // Model the string ".claude-staging-oauth.json" as a class function over columns.
    private func classer(_ s: String) -> (Int) -> CharClass {
        let chars = Array(s)
        return { i in
            guard i >= 0, i < chars.count else { return .space }
            let c = chars[i]
            if c == " " || c == "\t" || c == "\0" { return .space }
            if SemicolynKit.selectionPunctuation.contains(c) { return .punct }
            return .word
        }
    }

    // EP: a word run is bounded by the surrounding punctuation.
    func testWordRunBreaksOnPunct() {
        let s = ".claude-staging-oauth.json"     // indices: 0='.' 1..6='claude' 7='-' 8..14='staging' ...
        let (start, end) = SemicolynKit.subWordBounds(cols: s.count, col: 10, classOf: classer(s))
        XCTAssertEqual(start, 8)   // 's' of staging
        XCTAssertEqual(end, 14)    // 'g' of staging
    }

    // EP: tapping ON punctuation selects the contiguous punct run (here a single '-').
    func testPunctRun() {
        let s = ".claude-staging-oauth.json"
        let (start, end) = SemicolynKit.subWordBounds(cols: s.count, col: 7, classOf: classer(s))
        XCTAssertEqual(start, 7)
        XCTAssertEqual(end, 7)
    }

    // EP: tapping a space yields a degenerate single-cell range.
    func testSpaceDegenerate() {
        let s = "ab cd"
        let (start, end) = SemicolynKit.subWordBounds(cols: s.count, col: 2, classOf: classer(s))
        XCTAssertEqual(start, 2)
        XCTAssertEqual(end, 2)
    }

    // BVA: first column, word run to the left edge.
    func testFirstColumnWord() {
        let s = "abc def"
        let (start, end) = SemicolynKit.subWordBounds(cols: s.count, col: 0, classOf: classer(s))
        XCTAssertEqual(start, 0)
        XCTAssertEqual(end, 2)
    }

    // BVA: last column, word run to the right edge.
    func testLastColumnWord() {
        let s = "abc def"
        let (start, end) = SemicolynKit.subWordBounds(cols: s.count, col: 6, classOf: classer(s))
        XCTAssertEqual(start, 4)
        XCTAssertEqual(end, 6)
    }

    // BVA: col past cols clamps in.
    func testColClamped() {
        let s = "abc"
        let (start, end) = SemicolynKit.subWordBounds(cols: s.count, col: 99, classOf: classer(s))
        XCTAssertEqual(start, 0)
        XCTAssertEqual(end, 2)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter SubWordBoundsTests`
Expected: FAIL, `CharClass` / `subWordBounds` / `selectionPunctuation` undefined.

- [ ] **Step 3: Add the implementation**

Append to `Sources/SemicolynKit/Terminal/WordBounds.swift`:

```swift
/// Character class for sub-word selection boundaries.
public enum CharClass: Sendable {
    case word
    case space
    case punct
}

/// The punctuation set that breaks a sub-word selection (double-tap), matching iOS/desktop
/// double-click. Single source of truth: the App classifier and any docs read this.
public let selectionPunctuation: Set<Character> = [
    ".", "-", "/", "_", ",", ":", ";", "=", "@", "~",
    "(", ")", "[", "]", "{", "}", "<", ">",
    "|", "&", "!", "?", "*", "\"", "'"
]

/// Sub-word bounds on a single terminal row: from the tapped column, extend left and right
/// while the character CLASS stays equal to the tapped cell's class. `classOf(i)` returns the
/// class of column `i` and MUST return `.space` for out-of-range `i` (so the run stops at the
/// row edges). `col` is clamped into `0..<cols`. A tap on a `.space` cell yields the degenerate
/// `(col, col)`. Returns the inclusive `(start, end)` column range.
///
/// Pure and view-free (Linux-testable); the App supplies `classOf` backed by `getCharData`.
public func subWordBounds(cols: Int, col: Int,
                          classOf: (Int) -> CharClass) -> (start: Int, end: Int) {
    let maxCol = max(cols - 1, 0)
    let clamped = min(max(col, 0), maxCol)
    let tapped = classOf(clamped)
    if tapped == .space { return (clamped, clamped) }

    var lo = clamped
    var hi = clamped
    while lo > 0, classOf(lo - 1) == tapped { lo -= 1 }
    while hi < maxCol, classOf(hi + 1) == tapped { hi += 1 }
    return (lo, hi)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter SubWordBoundsTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Terminal/WordBounds.swift Tests/SemicolynKitTests/WordBoundsTests.swift
git commit -m "feat(kit): add class-based subWordBounds for double-tap sub-word select"
```

---

### Task 4: Wire sub-word into double-tap + focus-on-select

**Files:**
- Modify: `App/TerminalGestureController.swift` (`wordBounds` ~739-749; `handleDoubleTap` ~649; `handleTripleTap` ~689; `handleLongPress` ~723 if it selects)

**Interfaces:**
- Consumes: `SemicolynKit.subWordBounds`, `SemicolynKit.CharClass`, `SemicolynKit.selectionPunctuation` (Task 3); `callbacks.onSelectPane` (existing).
- Produces: `subWordBoundsApp(col:row:in:) -> (Int, Int)` (App helper backed by `getCharData`); selection handlers now call `callbacks.onSelectPane()` before presenting the menu.

- [ ] **Step 1: Add the App-side class-backed sub-word helper**

In `App/TerminalGestureController.swift`, add next to `wordBounds`:

```swift
    /// Sub-word bounds on `row` using SwiftTerm's `getCharData` to classify each cell.
    /// `row` is the VIEWPORT row (getCharData adds yDisp itself).
    private func subWordBoundsApp(col: Int, row: Int, in view: TerminalView) -> (Int, Int) {
        let term = view.getTerminal()
        let cols = max(term.cols, 1)
        func classOf(_ c: Int) -> CharClass {
            guard c >= 0, c < cols, let cd = term.getCharData(col: c, row: row) else { return .space }
            let ch = cd.getCharacter()
            if ch == " " || ch == "\t" || ch == "\0" { return .space }
            if SemicolynKit.selectionPunctuation.contains(ch) { return .punct }
            return .word
        }
        let r = SemicolynKit.subWordBounds(cols: cols, col: col, classOf: classOf)
        return (r.start, r.end)
    }
```

- [ ] **Step 2: Use sub-word in `handleDoubleTap`**

Replace the `wordBounds(...)` call from Task 2 Step 3 with `subWordBoundsApp`:

```swift
        let (col, viewportRow, absoluteRow) = cell(at: p, in: view)
        let (start, end) = subWordBoundsApp(col: col, row: viewportRow, in: view)
        callbacks.onSelectPane()   // focus-on-select (Topic 1): optimistic local focus + select-pane
        view.setSelectionRange(start: Position(col: start, row: absoluteRow),
                               end: Position(col: end, row: absoluteRow))
```

- [ ] **Step 3: Add focus-on-select to `handleTripleTap`**

After computing `absoluteRow` and before `setSelectionRange`:

```swift
        callbacks.onSelectPane()   // focus-on-select (Topic 1)
```

- [ ] **Step 4: Leave `handleLongPress` (long-press-zoom) unchanged in this slice**

`handleLongPress` (~723) currently calls `callbacks.onLongPressZoom()`. In the full redesign (Topic 6, the Pad), zoom moves to the Pad double-tap and long-press becomes from-scratch selection (Topic 3a long-press-drag). That reassignment is the LATER Pad slice, not this one: removing long-press-zoom now would drop the only current zoom trigger before its replacement exists. So DO NOT touch `handleLongPress` here. Double-tap + triple-tap + draggable handles (Task 6) give complete selection coverage for Slice 2; long-press-drag from-scratch selection lands with the Pad slice when long-press-zoom is retired. Make NO edit in this step; it exists to record the deliberate deferral.

- [ ] **Step 5: Keep or retire the old `wordBounds` App wrapper**

If `wordBounds` (the whole-token App wrapper ~739) has no remaining caller after Step 2, delete it and its `SemicolynKit.wordBounds` usage is unaffected (the Kit `wordBounds` stays for any other consumer). Grep to confirm: `grep -n "wordBounds(" App/TerminalGestureController.swift`. Remove only the now-unused App private method, not the Kit function.

- [ ] **Step 6: Kit still green (App verified by CI)**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add App/TerminalGestureController.swift
git commit -m "feat(app): sub-word double-tap + focus-on-select in selection handlers"
```

---

### Task 5: Bracketed paste to the focused pane

**Files:**
- Create: `Sources/SemicolynKit/Terminal/BracketedPaste.swift`
- Test: `Tests/SemicolynKitTests/BracketedPasteTests.swift`
- Modify: `App/TerminalGestureController.swift` (edit-menu Paste action ~828-829)

**Interfaces:**
- Consumes: `callbacks.sendBytes([UInt8])` (existing); `callbacks.currentMode()` (existing).
- Produces: `SemicolynKit.bracketedPasteBytes(_ text: String, bracketed: Bool) -> [UInt8]` (wraps UTF-8 in `ESC[200~` ... `ESC[201~` when `bracketed`; raw UTF-8 otherwise).

- [ ] **Step 1: Write the failing tests**

Create `Tests/SemicolynKitTests/BracketedPasteTests.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Bracketed paste wraps clipboard text in ESC[200~ ... ESC[201~ so multi-line pastes stay
/// intact (not auto-executed / not editor-auto-indent-mangled). Raw when the app has it off.
final class BracketedPasteTests: XCTestCase {
    private let start: [UInt8] = [0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e]  // ESC [ 2 0 0 ~
    private let end: [UInt8]   = [0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e]  // ESC [ 2 0 1 ~

    // EP: bracketed=true wraps the UTF-8 payload with the exact markers.
    func testBracketedWraps() {
        let out = SemicolynKit.bracketedPasteBytes("hi", bracketed: true)
        XCTAssertEqual(out, start + Array("hi".utf8) + end)
    }

    // EP: bracketed=false sends raw UTF-8, no markers.
    func testRawNoMarkers() {
        let out = SemicolynKit.bracketedPasteBytes("hi", bracketed: false)
        XCTAssertEqual(out, Array("hi".utf8))
    }

    // BVA: empty string, bracketed -> just the two markers (still valid bracketed paste).
    func testEmptyBracketed() {
        let out = SemicolynKit.bracketedPasteBytes("", bracketed: true)
        XCTAssertEqual(out, start + end)
    }

    // Multi-byte UTF-8 payload is preserved between the markers.
    func testMultiByteUTF8() {
        let out = SemicolynKit.bracketedPasteBytes("é", bracketed: true)
        XCTAssertEqual(out, start + Array("é".utf8) + end)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter BracketedPasteTests`
Expected: FAIL, `bracketedPasteBytes` undefined.

- [ ] **Step 3: Add the implementation**

Create `Sources/SemicolynKit/Terminal/BracketedPaste.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Bytes to send for pasting `text`. When `bracketed`, wrap the UTF-8 payload in the
/// xterm bracketed-paste markers `ESC[200~` ... `ESC[201~` so the receiving app treats it
/// as pasted text (multi-line stays intact, editors do not auto-indent it, shells do not
/// auto-execute it). When not bracketed, send raw UTF-8.
public func bracketedPasteBytes(_ text: String, bracketed: Bool) -> [UInt8] {
    let payload = Array(text.utf8)
    guard bracketed else { return payload }
    let start: [UInt8] = [0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e]
    let end: [UInt8]   = [0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e]
    return start + payload + end
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter BracketedPasteTests`
Expected: PASS.

- [ ] **Step 5: Wire the Paste action to bracketed bytes on the focused pane**

In `App/TerminalGestureController.swift`, replace the edit-menu Paste action (~828-829). Paste goes to the FOCUSED pane via `sendBytes` (not `view.paste(nil)`, which is SwiftTerm's own paste). `InteractionMode` has exactly three cases (`.localScroll`, `.appOwnsInput`, `.mouseReporting`) and no raw-byte mode. Bracketed paste is ALWAYS the correct choice for pasting typed text: an app that enabled bracketed paste receives properly-delimited text, and a shell/app that did NOT enable it treats `ESC[200~`/`ESC[201~` as no-op escape sequences it ignores. So always bracket. (This also fixes the multi-line-paste-mangling and auto-execute risks Topic 3d calls out.)

```swift
        if UIPasteboard.general.hasStrings {
            items.append(UIAction(title: "Paste") { [weak self] _ in
                guard let self, let text = UIPasteboard.general.string, !text.isEmpty else { return }
                // Always bracket: apps that enabled bracketed paste get delimited text; apps
                // that did not simply ignore the ESC[200~/ESC[201~ markers.
                let bytes = SemicolynKit.bracketedPasteBytes(text, bracketed: true)
                self.callbacks.sendBytes(bytes)
            })
        }
```

`sendBytes` already routes to the focused pane (Topic 1), so paste lands where you are working.

- [ ] **Step 6: Kit green + commit**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS.

```bash
git add Sources/SemicolynKit/Terminal/BracketedPaste.swift Tests/SemicolynKitTests/BracketedPasteTests.swift App/TerminalGestureController.swift
git commit -m "feat: bracketed paste to focused pane via sendBytes"
```

**CHECKPOINT A (device):** Build to TestFlight after Tasks 1-5. Device-verify: (1) highlight VISIBLE on alt-screen double/triple-tap; (2) double-tap `staging` in a long dotted filename selects `staging` only; (3) selecting an inactive pane focuses it; (4) paste lands in the focused pane, multi-line intact. Do NOT start Task 6 until the highlight is confirmed on device (it is the whole point of the slice).

---

### Task 6: Draggable endpoint handles

**Files:**
- Create: `Sources/SemicolynKit/Terminal/SelectionHandles.swift`
- Test: `Tests/SemicolynKitTests/SelectionHandlesTests.swift`
- Modify: `App/TerminalGestureController.swift` (add a handle pan recognizer + its handler; reuse the `subordinateSelectionPan` / role machinery)

**Interfaces:**
- Consumes: `view.setSelectionRange(start:end:)`, `view.getSelection()` / `view.hasActiveSelection` (existing public); `cell(at:)` (Task 2); the endpoint cell rects (App computes from stored Positions + cell size).
- Produces:
  - `enum SemicolynKit.SelectionEnd { case start, end }`
  - `SemicolynKit.hitTestHandle(point: CGPoint, startRect: CGRect, endRect: CGRect, slop: CGFloat) -> SelectionEnd?` (which handle the point is on, start takes precedence on overlap).
  - `SemicolynKit.orderedSelection(a: (col: Int, row: Int), b: (col: Int, row: Int)) -> (start: (col: Int, row: Int), end: (col: Int, row: Int))` (normalize so start precedes end in reading order; row-major).

- [ ] **Step 1: Write the failing tests**

Create `Tests/SemicolynKitTests/SelectionHandlesTests.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import CoreGraphics
@testable import SemicolynKit

/// Handle hit-test picks which selection end a touch grabs; ordering normalizes a flipped
/// drag so the selection never inverts.
final class SelectionHandlesTests: XCTestCase {
    // EP: a point inside the start handle's rect (plus slop) grabs .start.
    func testHitStart() {
        let s = CGRect(x: 0, y: 0, width: 10, height: 20)
        let e = CGRect(x: 100, y: 0, width: 10, height: 20)
        XCTAssertEqual(SemicolynKit.hitTestHandle(point: CGPoint(x: 5, y: 10),
                                                  startRect: s, endRect: e, slop: 8), .start)
    }

    // EP: a point inside the end handle grabs .end.
    func testHitEnd() {
        let s = CGRect(x: 0, y: 0, width: 10, height: 20)
        let e = CGRect(x: 100, y: 0, width: 10, height: 20)
        XCTAssertEqual(SemicolynKit.hitTestHandle(point: CGPoint(x: 104, y: 10),
                                                  startRect: s, endRect: e, slop: 8), .end)
    }

    // Negative: a point far from both handles grabs neither.
    func testHitNone() {
        let s = CGRect(x: 0, y: 0, width: 10, height: 20)
        let e = CGRect(x: 100, y: 0, width: 10, height: 20)
        XCTAssertNil(SemicolynKit.hitTestHandle(point: CGPoint(x: 50, y: 50),
                                                startRect: s, endRect: e, slop: 8))
    }

    // BVA: just inside slop hits, just outside misses.
    func testSlopBoundary() {
        let s = CGRect(x: 0, y: 0, width: 10, height: 20)
        let e = CGRect(x: 100, y: 0, width: 10, height: 20)
        XCTAssertEqual(SemicolynKit.hitTestHandle(point: CGPoint(x: -7, y: 10),
                                                  startRect: s, endRect: e, slop: 8), .start)
        XCTAssertNil(SemicolynKit.hitTestHandle(point: CGPoint(x: -9, y: 10),
                                                startRect: s, endRect: e, slop: 8))
    }

    // Ordering: a drag that moves the start below/after the end normalizes (row-major).
    func testOrderingFlipsWhenReversed() {
        let r = SemicolynKit.orderedSelection(a: (col: 5, row: 10), b: (col: 2, row: 3))
        XCTAssertEqual(r.start.row, 3); XCTAssertEqual(r.start.col, 2)
        XCTAssertEqual(r.end.row, 10);  XCTAssertEqual(r.end.col, 5)
    }

    // Ordering: same row, col decides.
    func testOrderingSameRow() {
        let r = SemicolynKit.orderedSelection(a: (col: 8, row: 4), b: (col: 3, row: 4))
        XCTAssertEqual(r.start.col, 3); XCTAssertEqual(r.end.col, 8)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter SelectionHandlesTests`
Expected: FAIL, symbols undefined.

- [ ] **Step 3: Add the implementation**

Create `Sources/SemicolynKit/Terminal/SelectionHandles.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import CoreGraphics

/// Which end of a selection a handle-drag grabs.
public enum SelectionEnd: Sendable {
    case start
    case end
}

/// Pick which selection handle `point` is on, given each end's on-screen cell rect padded by
/// `slop` (touch tolerance). `start` wins if the padded rects overlap the point. Returns nil
/// when the point is on neither (the caller then treats the drag as content, not a handle drag).
public func hitTestHandle(point: CGPoint, startRect: CGRect, endRect: CGRect,
                          slop: CGFloat) -> SelectionEnd? {
    if startRect.insetBy(dx: -slop, dy: -slop).contains(point) { return .start }
    if endRect.insetBy(dx: -slop, dy: -slop).contains(point) { return .end }
    return nil
}

/// Normalize two grid positions so `start` precedes `end` in reading (row-major) order.
public func orderedSelection(a: (col: Int, row: Int), b: (col: Int, row: Int))
    -> (start: (col: Int, row: Int), end: (col: Int, row: Int)) {
    if a.row < b.row || (a.row == b.row && a.col <= b.col) { return (a, b) }
    return (b, a)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter SelectionHandlesTests`
Expected: PASS.

- [ ] **Step 5: Add the handle pan recognizer in the App**

In `App/TerminalGestureController.swift`, add a `UIPanGestureRecognizer` (call it `handlePan`) created alongside the other recognizers, with `self` as delegate, added to `ours`, and subordinated like `selectionPan` (mutually exclusive with `scrollPan`/`switchPan`). Its handler:

```swift
    @objc private func handleHandlePan(_ g: UIPanGestureRecognizer) {
        guard let view = terminalView, view.hasActiveSelection else { return }
        let p = g.location(in: view)
        let term = view.getTerminal()
        let cols = max(term.cols, 1), rows = max(term.rows, 1)
        let cellW = view.bounds.width / CGFloat(cols)
        let cellH = view.bounds.height / CGFloat(rows)

        switch g.state {
        case .began:
            // Compute each endpoint's on-screen rect from the STORED selection Positions.
            // (Read the current selection ends: see note below on reading start/end.)
            guard let ends = currentSelectionEnds(in: view) else { g.state = .cancelled; return }
            let startRect = cellRect(col: ends.start.col, row: ends.start.row, cellW: cellW, cellH: cellH, in: view)
            let endRect   = cellRect(col: ends.end.col,   row: ends.end.row,   cellW: cellW, cellH: cellH, in: view)
            draggingEnd = SemicolynKit.hitTestHandle(point: p, startRect: startRect, endRect: endRect, slop: 22)
            if draggingEnd == nil { g.state = .cancelled; return }   // not a handle: let content own it
            anchoredEnd = (draggingEnd == .start) ? ends.end : ends.start
            callbacks.onSelectPane()   // handle-drag focuses too
        case .changed:
            guard let anchor = anchoredEnd else { return }
            let (_, _, absRow) = cell(at: p, in: view)
            let col = min(cols - 1, max(0, Int(p.x / cellW)))
            let moving = (col: col, row: absRow)
            let o = SemicolynKit.orderedSelection(a: anchor, b: moving)
            view.setSelectionRange(start: Position(col: o.start.col, row: o.start.row),
                                   end: Position(col: o.end.col, row: o.end.row))
            loupe?.show(around: p, in: view)   // Task 7
        case .ended, .cancelled, .failed:
            anchoredEnd = nil; draggingEnd = nil
            loupe?.hide()                       // Task 7
            presentEditMenu(at: p, in: view)
        default: break
        }
    }
```

Add stored properties `private var draggingEnd: SelectionEnd?` and `private var anchoredEnd: (col: Int, row: Int)?`. Add helpers `cellRect(col:row:cellW:cellH:in:)` (content-space rect for a cell; row is absolute content row -> `y = CGFloat(row) * cellH`) and `currentSelectionEnds(in:)`.

For `currentSelectionEnds`: SwiftTerm's `selection` is `internal`, so the App cannot read `selection.start/.end` directly. Track them in the controller instead: store `private var storedStart/storedEnd: (col: Int, row: Int)?` and set them in EVERY `setSelectionRange` call site (double/triple-tap and this handler). `currentSelectionEnds` returns them. This keeps the App as the source of truth for endpoint rects without needing SwiftTerm internals.

- [ ] **Step 6: Set stored ends at every selection site**

In `handleDoubleTap` and `handleTripleTap`, after each `setSelectionRange`, add:

```swift
        storedStart = (col: start, row: absoluteRow); storedEnd = (col: end, row: absoluteRow)
```

(triple-tap: `start = 0`, `end = cols - 1`). Clear them (`storedStart = nil; storedEnd = nil`) wherever the selection is cleared (single-tap-outside -> `view.clearSelection()`).

- [ ] **Step 7: Kit green + commit**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS.

```bash
git add Sources/SemicolynKit/Terminal/SelectionHandles.swift Tests/SemicolynKitTests/SelectionHandlesTests.swift App/TerminalGestureController.swift
git commit -m "feat: draggable selection endpoint handles"
```

---

### Task 7: Custom magnifier loupe

**Files:**
- Create: `Sources/SemicolynKit/Terminal/LoupeGeometry.swift`
- Test: `Tests/SemicolynKitTests/LoupeGeometryTests.swift`
- Create: `App/SelectionLoupeView.swift`
- Modify: `App/TerminalGestureController.swift` (own a `SelectionLoupeView?`; the `show`/`hide` calls are already placed in Task 6 Step 5)

**Interfaces:**
- Consumes: nothing in Kit; the App view uses `UIView` snapshotting.
- Produces:
  - `SemicolynKit.loupeCenter(finger: CGPoint, bounds: CGRect, loupeSize: CGSize, verticalOffset: CGFloat) -> CGPoint` (loupe center sits `verticalOffset` above the finger, clamped so the loupe stays fully inside `bounds`).
  - `App SelectionLoupeView: UIView` with `func show(around point: CGPoint, in view: UIView)` and `func hide()`.

- [ ] **Step 1: Write the failing Kit tests**

Create `Tests/SemicolynKitTests/LoupeGeometryTests.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import CoreGraphics
@testable import SemicolynKit

/// The loupe floats above the finger and stays fully inside the pane bounds.
final class LoupeGeometryTests: XCTestCase {
    private let size = CGSize(width: 100, height: 100)
    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)

    // EP: mid-screen finger -> loupe centered horizontally on finger, offset up.
    func testCentersAboveFinger() {
        let c = SemicolynKit.loupeCenter(finger: CGPoint(x: 200, y: 400),
                                         bounds: bounds, loupeSize: size, verticalOffset: 80)
        XCTAssertEqual(c.x, 200, accuracy: 0.001)
        XCTAssertEqual(c.y, 320, accuracy: 0.001)   // 400 - 80
    }

    // BVA: finger near the left edge clamps the loupe so its left stays >= bounds.minX.
    func testClampsLeft() {
        let c = SemicolynKit.loupeCenter(finger: CGPoint(x: 10, y: 400),
                                         bounds: bounds, loupeSize: size, verticalOffset: 80)
        XCTAssertEqual(c.x, 50, accuracy: 0.001)     // half of width (100/2)
    }

    // BVA: finger near the top clamps the loupe so its top stays >= bounds.minY.
    func testClampsTop() {
        let c = SemicolynKit.loupeCenter(finger: CGPoint(x: 200, y: 20),
                                         bounds: bounds, loupeSize: size, verticalOffset: 80)
        XCTAssertEqual(c.y, 50, accuracy: 0.001)     // half of height, cannot go above 0
    }

    // BVA: finger near the right edge clamps the loupe right to bounds.maxX.
    func testClampsRight() {
        let c = SemicolynKit.loupeCenter(finger: CGPoint(x: 395, y: 400),
                                         bounds: bounds, loupeSize: size, verticalOffset: 80)
        XCTAssertEqual(c.x, 350, accuracy: 0.001)    // 400 - 50
    }
}
```

- [ ] **Step 2: Run to verify fail**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter LoupeGeometryTests`
Expected: FAIL, `loupeCenter` undefined.

- [ ] **Step 3: Add the Kit implementation**

Create `Sources/SemicolynKit/Terminal/LoupeGeometry.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import CoreGraphics

/// The center point for a floating magnifier loupe of `loupeSize`, placed `verticalOffset`
/// points above the `finger`, clamped so the whole loupe stays inside `bounds` (so it never
/// leaves the visible pane, even at the edges where the finger is near a border).
public func loupeCenter(finger: CGPoint, bounds: CGRect, loupeSize: CGSize,
                        verticalOffset: CGFloat) -> CGPoint {
    let halfW = loupeSize.width / 2
    let halfH = loupeSize.height / 2
    let rawX = finger.x
    let rawY = finger.y - verticalOffset
    let x = min(max(rawX, bounds.minX + halfW), bounds.maxX - halfW)
    let y = min(max(rawY, bounds.minY + halfH), bounds.maxY - halfH)
    return CGPoint(x: x, y: y)
}
```

- [ ] **Step 4: Run to verify pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter LoupeGeometryTests`
Expected: PASS.

- [ ] **Step 5: Create the loupe view (App)**

Create `App/SelectionLoupeView.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import SemicolynKit

/// A floating circular magnifier shown while dragging a selection handle. It snapshots the
/// region of the terminal under the finger, scales it up, and tracks the finger, clamped
/// inside the pane. Snapshotting is throttled so the tmux -CC repaint stream cannot choke it.
final class SelectionLoupeView: UIView {
    private let magnification: CGFloat = 1.4
    private let diameter: CGFloat = 110
    private let verticalOffset: CGFloat = 80
    private let imageLayer = CALayer()
    private var lastSnapshot: CFTimeInterval = 0
    private let minSnapshotInterval: CFTimeInterval = 1.0 / 30.0   // <= 30 snapshots/sec

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        isUserInteractionEnabled = false
        layer.cornerRadius = diameter / 2
        layer.masksToBounds = true
        layer.borderWidth = 3
        layer.borderColor = UIColor.white.withAlphaComponent(0.85).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 2)
        imageLayer.frame = bounds
        imageLayer.contentsGravity = .center
        layer.addSublayer(imageLayer)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Show/track the loupe around `point` (in `terminal`'s coordinate space), snapshotting
    /// the region under the finger. Adds self to `terminal.superview` on first show.
    func show(around point: CGPoint, in terminal: UIView) {
        guard let host = terminal.superview else { return }
        if superview !== host { host.addSubview(self) }
        isHidden = false
        let center = SemicolynKit.loupeCenter(finger: point, bounds: terminal.frame,
                                              loupeSize: bounds.size, verticalOffset: verticalOffset)
        self.center = center

        let now = CACurrentMediaTime()
        guard now - lastSnapshot >= minSnapshotInterval else { return }
        lastSnapshot = now
        // Snapshot a source region (diameter/magnification) centered on the finger, scaled up.
        let src = diameter / magnification
        let region = CGRect(x: point.x - src / 2, y: point.y - src / 2, width: src, height: src)
        let renderer = UIGraphicsImageRenderer(size: region.size)
        let image = renderer.image { ctx in
            ctx.cgContext.translateBy(x: -region.minX, y: -region.minY)
            terminal.layer.render(in: ctx.cgContext)
        }
        imageLayer.contents = image.cgImage
        imageLayer.contentsScale = magnification
    }

    func hide() { isHidden = true }
}
```

Note: `CACurrentMediaTime()` is a monotonic clock (not `Date()`); it is available in the App tier at runtime and is fine here (this file is App-only, not a Workflow script). If macOS CI flags `magnification`/unused, keep them (they are used).

- [ ] **Step 6: Own the loupe in the controller**

In `App/TerminalGestureController.swift`, add `private lazy var loupe: SelectionLoupeView? = SelectionLoupeView()`. The `loupe?.show(...)` / `loupe?.hide()` calls are already in Task 6 Step 5's handle-pan handler; that is the only loupe-driving path in this slice (long-press-drag from-scratch selection is deferred to the Pad slice, Task 4 Step 4).

- [ ] **Step 7: Kit green + commit**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS.

```bash
git add Sources/SemicolynKit/Terminal/LoupeGeometry.swift Tests/SemicolynKitTests/LoupeGeometryTests.swift App/SelectionLoupeView.swift App/TerminalGestureController.swift
git commit -m "feat: custom magnifier loupe for selection handle drag"
```

**CHECKPOINT B (device):** Build to TestFlight after Tasks 6-7. Device-verify: grab a handle, grow/shrink the selection, the opposite end stays anchored; the loupe appears while dragging, tracks the finger, shows the character under the fingertip, does not choke on a busy tmux pane; releases cleanly and the copy menu reappears.

---

### Task 8: Copy-menu re-summon (tap-on-selection / two-finger-tap)

**Files:**
- Modify: `Sources/SemicolynKit/Terminal/TapAction.swift` (add `.reSummonMenu`; `tapAction` takes `tapInsideSelection`)
- Modify: `Sources/SemicolynKit/Terminal/PaneTapAction.swift` (re-summon/clear runs in EVERY mode, before the mode-yield branch)
- Modify: `Tests/SemicolynKitTests/` (find/append the existing PaneTapAction/TapAction tests, else create `PaneTapActionTests.swift`)
- Modify: `App/TerminalGestureController.swift` (single-tap handler ~618-646; add a two-finger tap recognizer; extend `Callbacks`)

**Design note (why extend the Kit deciders, not an inline branch):** single-tap routing already goes through the pure `paneTapAction` / `tapAction` deciders. Topic 3c ("tap ON selection re-summons; tap OUTSIDE clears") is a routing rule, so it belongs IN those deciders, tested in Kit, not hand-coded in the handler. A selection can exist on the alt-screen (double-tap works in every mode), so the re-summon/clear decision must run BEFORE `paneTapAction`'s `.appOwnsInput`/`.mouseReporting` yield.

**Interfaces:**
- Consumes: existing `paneTapAction(isActivePane:mode:hasSelection:)`, `tapAction(hasSelection:)`; `SemicolynKit.orderedSelection` (Task 6); `storedStart`/`storedEnd` (Task 6); `presentEditMenu`, `callbacks.clearSelection` (existing).
- Produces:
  - `TapAction.reSummonMenu` (new case).
  - `tapAction(hasSelection: Bool, tapInsideSelection: Bool) -> TapAction` (selection + tap-inside -> `.reSummonMenu`; selection + tap-outside -> `.clearSelection`; no selection -> `.placeCursor`).
  - `paneTapAction(isActivePane: Bool, mode: InteractionMode, hasSelection: Bool, tapInsideSelection: Bool) -> PaneTapAction` (a `.clearSelection`/`.reSummonMenu` result is returned in EVERY mode when a selection exists; the mode-yield applies only when there is no selection).
  - `SemicolynKit.isWithinSelection(col:row:start:end:) -> Bool` (in `SelectionHandles.swift`).
  - `Callbacks.reSummonMenu: () -> Void` (App presents the edit menu at the tap point).

- [ ] **Step 1a: Update the EXISTING decider tests to the new signatures**

`Tests/SemicolynKitTests/TapActionTests.swift` and `Tests/SemicolynKitTests/PaneTapActionTests.swift` already exist and call the OLD signatures (`tapAction(hasSelection:)`, `paneTapAction(isActivePane:mode:hasSelection:)`). The Task 8 signature change will not compile until they are updated. Add the new argument to every existing call: `tapAction(hasSelection: X, tapInsideSelection: false)` and `paneTapAction(..., hasSelection: X, tapInsideSelection: false)`. Every existing EXPECTED result is UNCHANGED: all existing cases pass `tapInsideSelection: false`, and the two active+app-owned cases both use `hasSelection: false` (so they still `.yield`), while active+localScroll+selection still `.clearSelection`s. Only the call arguments change, not the assertions. Grep to find them: `grep -rn "tapAction(\|paneTapAction(" Tests/`.

- [ ] **Step 1b: Write the new failing Kit tests**

Create `Tests/SemicolynKitTests/PaneTapActionTests.swift` additions in a NEW class (do not collide with the existing `PaneTapActionTests` class name; use `TapActionReSummonTests`):

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Single-tap routing: tap ON an active selection re-summons the copy menu (does NOT clear);
/// tap OUTSIDE it clears; with no selection, place cursor. Re-summon/clear apply in EVERY mode.
final class TapActionReSummonTests: XCTestCase {
    // No selection -> place cursor (unchanged).
    func testNoSelectionPlaces() {
        XCTAssertEqual(tapAction(hasSelection: false, tapInsideSelection: false), .placeCursor)
    }
    // Selection + tap inside -> re-summon.
    func testInsideReSummons() {
        XCTAssertEqual(tapAction(hasSelection: true, tapInsideSelection: true), .reSummonMenu)
    }
    // Selection + tap outside -> clear.
    func testOutsideClears() {
        XCTAssertEqual(tapAction(hasSelection: true, tapInsideSelection: false), .clearSelection)
    }
    // Alt-screen (.appOwnsInput) WITH a selection: tap-inside still re-summons (not yield).
    func testAltScreenInsideReSummons() {
        XCTAssertEqual(
            paneTapAction(isActivePane: true, mode: .appOwnsInput,
                          hasSelection: true, tapInsideSelection: true),
            .active(.reSummonMenu))
    }
    // Alt-screen WITHOUT a selection: yields (unchanged app-owned behavior).
    func testAltScreenNoSelectionYields() {
        XCTAssertEqual(
            paneTapAction(isActivePane: true, mode: .appOwnsInput,
                          hasSelection: false, tapInsideSelection: false),
            .yield)
    }
    // Inactive pane always focuses, regardless of selection.
    func testInactiveFocuses() {
        XCTAssertEqual(
            paneTapAction(isActivePane: false, mode: .localScroll,
                          hasSelection: true, tapInsideSelection: true),
            .focusPane)
    }
    // isWithinSelection: single row bounds.
    func testWithinSelectionSingleRow() {
        let s = (col: 2, row: 5), e = (col: 8, row: 5)
        XCTAssertTrue(SemicolynKit.isWithinSelection(col: 5, row: 5, start: s, end: e))
        XCTAssertFalse(SemicolynKit.isWithinSelection(col: 1, row: 5, start: s, end: e))
        XCTAssertFalse(SemicolynKit.isWithinSelection(col: 9, row: 5, start: s, end: e))
    }
    // isWithinSelection: multi-row (reversed input) bounds.
    func testWithinSelectionMultiRow() {
        let s = (col: 5, row: 3), e = (col: 2, row: 7)
        XCTAssertTrue(SemicolynKit.isWithinSelection(col: 0, row: 5, start: s, end: e))
        XCTAssertTrue(SemicolynKit.isWithinSelection(col: 6, row: 3, start: s, end: e))
        XCTAssertFalse(SemicolynKit.isWithinSelection(col: 4, row: 3, start: s, end: e))
        XCTAssertFalse(SemicolynKit.isWithinSelection(col: 3, row: 7, start: s, end: e))
    }
}
```

- [ ] **Step 2: Run to verify fail**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TapActionReSummonTests`
Expected: FAIL (new `.reSummonMenu` case, new params, `isWithinSelection` undefined).

- [ ] **Step 3: Extend the Kit deciders**

`Sources/SemicolynKit/Terminal/TapAction.swift` -> replace the enum + function:

```swift
public enum TapAction: Equatable, Sendable {
    case clearSelection
    case placeCursor
    /// Tap landed ON an active selection: re-present the copy menu (do NOT clear).
    case reSummonMenu
}

/// Pure tap decider. With a selection: tap INSIDE it re-summons the menu, tap OUTSIDE clears.
/// With no selection: place the cursor at the tapped cell.
public func tapAction(hasSelection: Bool, tapInsideSelection: Bool) -> TapAction {
    guard hasSelection else { return .placeCursor }
    return tapInsideSelection ? .reSummonMenu : .clearSelection
}
```

`Sources/SemicolynKit/Terminal/PaneTapAction.swift` -> update the decider so a live selection is handled in EVERY mode (the mode-yield only applies with no selection):

```swift
public func paneTapAction(isActivePane: Bool,
                          mode: InteractionMode,
                          hasSelection: Bool,
                          tapInsideSelection: Bool) -> PaneTapAction {
    guard isActivePane else { return .focusPane }
    // A live selection's tap-to-(re-summon/clear) applies in every mode, before the
    // app-owned yield: double-tap can create a selection on the alt-screen too.
    if hasSelection {
        return .active(tapAction(hasSelection: true, tapInsideSelection: tapInsideSelection))
    }
    switch mode {
    case .localScroll:
        return .active(tapAction(hasSelection: false, tapInsideSelection: false))
    case .appOwnsInput, .mouseReporting:
        return .yield
    }
}
```

Add `isWithinSelection` to `Sources/SemicolynKit/Terminal/SelectionHandles.swift`:

```swift
/// Whether the grid cell (col,row) lies within the selection spanning `start`..`end`
/// (row-major, inclusive). Handles reversed input via `orderedSelection`.
public func isWithinSelection(col: Int, row: Int,
                              start: (col: Int, row: Int), end: (col: Int, row: Int)) -> Bool {
    let o = orderedSelection(a: start, b: end)
    if row < o.start.row || row > o.end.row { return false }
    if row == o.start.row && col < o.start.col { return false }
    if row == o.end.row && col > o.end.col { return false }
    return true
}
```

- [ ] **Step 4: Run to verify pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TapActionReSummonTests`
Expected: PASS.

- [ ] **Step 5: Update the App single-tap handler + Callbacks**

The handler at ~629 calls `paneTapAction(isActivePane:mode:hasSelection:)`. Add the `tapInsideSelection` argument (compute it) and a `.reSummonMenu` branch. Any OTHER caller of `tapAction`/`paneTapAction` in the App must also pass the new params (grep: `grep -rn "paneTapAction\|tapAction(" App/`).

```swift
        let p = g.location(in: view)
        let tapInside: Bool = {
            guard callbacks.hasSelection(), let s = storedStart, let e = storedEnd else { return false }
            let (_, _, absRow) = cell(at: p, in: view)
            let cols = max(view.getTerminal().cols, 1)
            let col = min(cols - 1, max(0, Int(p.x / (view.bounds.width / CGFloat(cols)))))
            return SemicolynKit.isWithinSelection(col: col, row: absRow, start: s, end: e)
        }()
        switch paneTapAction(isActivePane: callbacks.isActivePane(),
                             mode: callbacks.currentMode(),
                             hasSelection: callbacks.hasSelection(),
                             tapInsideSelection: tapInside) {
        case .focusPane:
            callbacks.onSelectPane()
            DebugLog.shared.log(.gesture, "gesture:singleTap action=focus-pane")
        case .active(.reSummonMenu):
            presentEditMenu(at: p, in: view)
            DebugLog.shared.log(.gesture, "gesture:singleTap action=reSummonMenu")
        case .active(.clearSelection):
            callbacks.clearSelection()
            storedStart = nil; storedEnd = nil
            DebugLog.shared.log(.gesture, "gesture:singleTap action=clear")
        case .active(.placeCursor):
            let target = cell(at: p, in: view)
            callbacks.onPlaceCursor(target.col, target.viewportRow)
            DebugLog.shared.log(.gesture, "gesture:singleTap action=place at=(\(target.col),\(target.viewportRow))")
        case .yield:
            DebugLog.shared.log(.gesture, "gesture:singleTap action=appOwns mode=\(callbacks.currentMode())")
            return
        }
```

(This supersedes the Task 2 Step 2 edit of the same branch; both use `target.viewportRow`, consistent.) No new `Callbacks` field is needed after all: re-summon uses the existing `presentEditMenu`. (Drop the `Callbacks.reSummonMenu` idea from Interfaces above; keep `presentEditMenu`.)

- [ ] **Step 6: Gate the existing two-finger-tap on an active selection**

`handleTwoFingerTap` ALREADY exists (~729) and currently presents the edit menu unconditionally. Topic 3c only re-summons when a selection is active, so add the guard:

```swift
    @objc private func handleTwoFingerTap(_ g: UITapGestureRecognizer) {
        guard let view = terminalView, view.hasActiveSelection else { return }
        DebugLog.shared.log(.gesture, "gr:\(#function) state=\(g.state.rawValue) loc=\(g.location(in: view))")
        presentEditMenu(at: g.location(in: view), in: view)
    }
```

- [ ] **Step 7: Kit green + commit**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS.

```bash
git add App/TerminalGestureController.swift Sources/SemicolynKit/Terminal/TapAction.swift Sources/SemicolynKit/Terminal/PaneTapAction.swift Sources/SemicolynKit/Terminal/SelectionHandles.swift Tests/SemicolynKitTests/
git commit -m "feat: re-summon copy menu on tap-in-selection, clear on tap-outside"
```

---

### Task 9: Remove Slice-1 diagnostics and flip the feedback flag

**Files:**
- Modify: `App/TerminalGestureController.swift` (remove `SelectionDiagnostics.snapshot` calls + set/redraw/repaint phase logs)
- Modify: `App/InputClickFeedback.swift` (flip `diagnosticsEnabled` to false)
- Delete (if now unused): `App/SelectionDiagnostics.swift`, the `.selection` case in `App/LogCategory.swift` if nothing else uses it

**Interfaces:**
- Consumes / Produces: none (cleanup).

- [ ] **Step 1: Remove the diagnostic snapshot + phase logs**

In `handleDoubleTap` and `handleTripleTap`, delete every `DebugLog.shared.log(.selection, SelectionDiagnostics.snapshot(...))` line, the `Task { @MainActor ... phase: "repaint" ... }` blocks, and the `modeStr` local if it becomes unused. Keep the `.gesture` `sel:double`/`sel:triple` action lines (those are normal decision logs, not Slice-1 scaffolding), but drop their `chars=...` diagnostic suffix if it calls the removed `selectedChars` helper; remove `selectedChars` if unused.

- [ ] **Step 2: Flip the feedback diagnostics flag**

In `App/InputClickFeedback.swift`, set `diagnosticsEnabled = false` (grep to find it: `grep -n diagnosticsEnabled App/InputClickFeedback.swift`).

- [ ] **Step 3: Delete now-unused diagnostic files**

Grep for remaining references before deleting:
`grep -rn "SelectionDiagnostics" App/` and `grep -rn "\.selection" App/LogCategory.swift App/*.swift`. If `SelectionDiagnostics.swift` has no remaining references, delete it. Leave `LogCategory.selection` if any other file logs to it; remove the enum case only if fully unused.

- [ ] **Step 4: Kit green + commit**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS.

```bash
git add -A
git commit -m "refactor(app): remove Slice-1 selection diagnostics, disable feedback probe"
```

---

### Task 10: Final verification + push

- [ ] **Step 1: Full Kit test run**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS (all suites, including the four new selection suites).

- [ ] **Step 2: Push and trigger macOS CI (the only App build signal)**

```bash
git push github feat/gesture-diagnostics
```

Then confirm CI: `gh run list --branch feat/gesture-diagnostics --limit 1`. Wait for the `macos` job green (~15-18 min). It is the only signal the App compiles. If `linux-rust` flakes on sshd readiness, rerun that job only (`gh run rerun <id> --failed`); it is unrelated to this Swift-only change.

- [ ] **Step 3: Trigger TestFlight for device verification**

Only after the `macos` job is green:
`gh workflow run "Release to TestFlight" --repo ds7n/semicolyn --ref feat/gesture-diagnostics`
(builds the last PUSHED commit; ensure Step 2's push landed first).

- [ ] **Step 4: Device verify against the checkpoints**

Run the CHECKPOINT A and CHECKPOINT B verifications on device. Only when all pass is the slice done; then reconcile PR #113 (superseded) and prepare the squash-merge.

---

## Self-Review notes (for the implementer)

- **Spec coverage:** 3a sub-word (Task 3/4), 3a focus-on-select (Task 4), 3b handles (Task 6), 3b/3h loupe (Task 7), 3c menu auto + re-summon (Tasks 4/8), 3d bracketed paste to focused pane (Task 5), 3e scope-after-scroll (Task 1/2 absoluteRow handles any offset), 3g highlight fix (Task 2). Engine stays SwiftTerm (no swap). All covered.
- **Row-space invariant (do not violate):** `getCharData`/`wordBounds`/`subWordBoundsApp` take the VIEWPORT row; `setSelectionRange` and endpoint rects take the ABSOLUTE row. `cell(at:)` returns both; never cross them.
- **Type consistency:** `cell(at:) -> (col, viewportRow, absoluteRow)` is used identically in every caller; `storedStart`/`storedEnd` are `(col: Int, row: Int)?` everywhere; `SelectionEnd`, `CharClass`, `selectionPunctuation`, `bracketedPasteBytes`, `hitTestHandle`, `orderedSelection`, `isWithinSelection`, `loupeCenter`, `absoluteRow`, `subWordBounds` names match across tasks.
