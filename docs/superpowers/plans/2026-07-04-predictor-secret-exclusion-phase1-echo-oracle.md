<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Predictor Secret-Exclusion — Phase 1: L1 Buffer-Anchored Echo + `EchoOracle` Seam — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Upgrade the shipped byte-count `PasswordEntryDetector` (L1) into a buffer-anchored echo check that consults SwiftTerm's *rendered grid* through a pure, Linux-testable `EchoOracle` protocol seam, so the per-line learn verdict distinguishes echoed / masked / hidden keystrokes and suppresses alt-screen and output-stalled lines.

**Architecture:** All decision logic stays in `Sources/SemicolynKit/` (Swift 6 strict-concurrency, Linux-tested, no UIKit/SwiftUI import). A new `EchoOracle` protocol lets the detector sample cursor position, cell contents, and alt-screen state without depending on `Terminal`. The detector consumes the protocol; Kit tests inject a scripted fake; the App tier provides a thin `SwiftTermEchoOracle` backed by `getTerminal()` (macOS-CI-only, invisible to `swift test`). The existing prompt-text suppressor is retained as a corroborating input; the byte-count echo inference is *replaced* by the buffer check where the oracle is available and *retained as a fallback* when it is not.

**Tech Stack:** Swift 6.1, SemicolynKit (XCTest, Linux via Docker `semicolyn-dev`), SwiftTerm (App tier only), UniFFI bridge unchanged.

## Global Constraints

- **Two-tier boundary (the one rule):** L1 *logic* lives in `Sources/SemicolynKit/` — no `import UIKit`/`SwiftUI`/`SwiftTerm`/`CryptoKit`. Only the `SwiftTermEchoOracle` adapter (App tier) may import SwiftTerm. App-tier code does NOT compile on Linux and is verified only by the macOS CI job.
- **Reframe governs every default:** predictor, not scanner — a false positive costs one skipped word, a false negative leaks a credential. **Exclusion wins ties; every failure mode is `suppress`.**
- **Fail-safe verdicts:** oracle unavailable / throws / returns nil → treat as non-echoed → do not learn. Alt-screen → suppress the whole line. Output not live → bias to suppress.
- **Verdict is deferred to line commit; L1 never blocks the input hot path.** No layer interrupts typing.
- **Every source file carries the SPDX header** (`// SPDX-FileCopyrightText: 2026 True Positive LLC` / `// SPDX-License-Identifier: GPL-3.0-only`). REUSE-compliant.
- **Tests must be real** (testing-standards spec): equivalence-partitioning + boundary values, assert the *specific* observable outcome (this line suppressed / this verdict), never "excludes returned true". L1 is **Critical-tier** — adversarial negatives mandatory.
- **Conventional commits**; this Phase = feature branch `feat/predictor-secret-exclusion` (already checked out); squash-merge to `main`.
- **Build/test command (no host Swift toolchain):**
  `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter <TestClass>`

## Spec & Source References

- Spec: `docs/superpowers/specs/2026-07-04-predictor-secret-exclusion-design.md` — sections **L1** and **Data flow & layer ordering** and **Testing**.
- Research: `docs/superpowers/research/2026-07-04-echo-detection-investigation.md` — confirms all SwiftTerm APIs (`getCharData`, `getCursorLocation`, `isCurrentBufferAlternate`) are public and `getTerminal()` is already held.
- Existing detector: `Sources/SemicolynKit/Predictor/PasswordEntryDetector.swift` (byte-count L1, being upgraded).
- Existing tests: `Tests/SemicolynKitTests/PasswordEntryDetectorTests.swift`.
- Capture chokepoint: `App/ConnectionViewModel.swift:737` `observePredictorInput` (drives `noteInput`/`noteOutput`/`shouldLearnCommittedLine`/`resetLine`).

## File Structure

- **Create** `Sources/SemicolynKit/Predictor/EchoOracle.swift` — the `EchoOracle` protocol + the value types it returns (`EchoCell`, `EchoCursor`). Pure Kit, Linux-tested. One responsibility: the abstract read-only view of the rendered terminal grid.
- **Create** `Tests/SemicolynKitTests/ScriptedEchoOracle.swift` — a scripted fake `EchoOracle` for Kit tests (deterministic cursor/cell script). One responsibility: test double.
- **Modify** `Sources/SemicolynKit/Predictor/PasswordEntryDetector.swift` — add oracle-driven per-keystroke sampling + three-way (echoed/masked/hidden) classification, line-level majority aggregation, alt-screen + output-liveness gates. Keep the prompt-text suppressor as a corroborating input; keep the byte-count path as a fallback for when no oracle is set.
- **Modify** `Tests/SemicolynKitTests/PasswordEntryDetectorTests.swift` — add the L1 buffer-check units (echoed/masked/hidden/alt-screen/stall/majority) driven through `ScriptedEchoOracle`; keep the existing byte-count-fallback tests green.
- **Create** `App/SwiftTermEchoOracle.swift` — the thin `EchoOracle` adapter backed by `TerminalView.getTerminal()`. App tier, macOS-CI-only. One responsibility: map SwiftTerm's `getCharData`/`getCursorLocation`/`isCurrentBufferAlternate` onto the protocol.
- **Modify** `App/ConnectionViewModel.swift` — construct + inject the `SwiftTermEchoOracle` into `passwordDetector`; sample around each outgoing keystroke; drive settle/liveness. Thin wiring only.

---

## Task 1: Define the `EchoOracle` protocol + value types (pure Kit)

**Files:**
- Create: `Sources/SemicolynKit/Predictor/EchoOracle.swift`
- Create: `Tests/SemicolynKitTests/ScriptedEchoOracle.swift`
- Test: `Tests/SemicolynKitTests/EchoOracleTests.swift`

**Interfaces:**
- Consumes: nothing (leaf types).
- Produces (relied on by Tasks 2–5 and the App adapter):
  - `public struct EchoCursor: Equatable, Sendable { public let row: Int; public let col: Int; public init(row: Int, col: Int) }`
  - `public struct EchoCell: Equatable, Sendable { public let scalar: Unicode.Scalar?; public init(scalar: Unicode.Scalar?) }` — `scalar == nil` means an empty/blank cell.
  - `public protocol EchoOracle: Sendable { func cursor() -> EchoCursor?; func cell(row: Int, col: Int) -> EchoCell?; var isAlternateBuffer: Bool { get } }`
  - `ScriptedEchoOracle` (test-only) — a mutable fake whose `cursor()`/`cell()` return values are set by the test before each sample.

- [ ] **Step 1: Write the failing test**

Create `Tests/SemicolynKitTests/EchoOracleTests.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// The value types + the scripted fake are the seam Kit tests drive; verify the
/// fake honors the protocol so the L1 tests that depend on it are trustworthy.
final class EchoOracleTests: XCTestCase {
    func testScriptedOracleReturnsScriptedCursorAndCell() {
        let oracle = ScriptedEchoOracle()
        oracle.nextCursor = EchoCursor(row: 2, col: 5)
        oracle.cellAt = { r, c in
            (r == 2 && c == 5) ? EchoCell(scalar: "k") : EchoCell(scalar: nil)
        }
        oracle.isAlternateBuffer = true

        XCTAssertEqual(oracle.cursor(), EchoCursor(row: 2, col: 5))
        XCTAssertEqual(oracle.cell(row: 2, col: 5), EchoCell(scalar: "k"))
        XCTAssertEqual(oracle.cell(row: 0, col: 0), EchoCell(scalar: nil))
        XCTAssertTrue(oracle.isAlternateBuffer)
    }

    func testEchoCellBlankIsNilScalar() {
        XCTAssertEqual(EchoCell(scalar: nil).scalar, nil)
        XCTAssertEqual(EchoCell(scalar: "*").scalar, "*")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter EchoOracleTests`
Expected: FAIL — `cannot find 'ScriptedEchoOracle' in scope` / `cannot find type 'EchoCursor'`.

- [ ] **Step 3: Write the protocol + value types**

Create `Sources/SemicolynKit/Predictor/EchoOracle.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// A cursor position on the rendered terminal grid, in cell coordinates.
public struct EchoCursor: Equatable, Sendable {
    public let row: Int
    public let col: Int
    public init(row: Int, col: Int) { self.row = row; self.col = col }
}

/// The contents of one rendered grid cell. `scalar == nil` is a blank/empty cell.
public struct EchoCell: Equatable, Sendable {
    public let scalar: Unicode.Scalar?
    public init(scalar: Unicode.Scalar?) { self.scalar = scalar }
}

/// A read-only view of the *rendered* terminal grid, injected into the L1 echo
/// detector so its logic stays pure and Linux-testable. The App tier backs this
/// with SwiftTerm's `getTerminal()`; Kit tests back it with a scripted fake.
///
/// Every accessor is failable/Optional: an unavailable or drifted backing must
/// return `nil`, which the detector treats as "not echoed" (fail-safe: suppress).
public protocol EchoOracle: Sendable {
    /// The current cursor cell, or nil if unreadable.
    func cursor() -> EchoCursor?
    /// The cell at `(row, col)`, or nil if out of range / unreadable.
    func cell(row: Int, col: Int) -> EchoCell?
    /// True when the alternate screen buffer is active (full-screen TUI).
    var isAlternateBuffer: Bool { get }
}
```

Create `Tests/SemicolynKitTests/ScriptedEchoOracle.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
@testable import SemicolynKit

/// A deterministic `EchoOracle` fake for L1 tests. Tests set `nextCursor` and
/// `cellAt` before each sample to script exactly what the "rendered grid" shows.
/// `@unchecked Sendable` is safe: only ever touched from a single test thread.
final class ScriptedEchoOracle: EchoOracle, @unchecked Sendable {
    var nextCursor: EchoCursor? = EchoCursor(row: 0, col: 0)
    var cellAt: (Int, Int) -> EchoCell? = { _, _ in EchoCell(scalar: nil) }
    var isAlternateBuffer: Bool = false

    func cursor() -> EchoCursor? { nextCursor }
    func cell(row: Int, col: Int) -> EchoCell? { cellAt(row, col) }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter EchoOracleTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Predictor/EchoOracle.swift Tests/SemicolynKitTests/ScriptedEchoOracle.swift Tests/SemicolynKitTests/EchoOracleTests.swift
git commit -m "feat(predictor): add EchoOracle protocol seam + scripted fake for L1"
```

---

## Task 2: Detector samples the oracle per keystroke — three-way classification

Add the buffer-anchored sampling to `PasswordEntryDetector`. The detector must be able to hold an injected oracle and, for each printable keystroke, record a pre-cursor and (after the caller settles) sample the echo cell to classify **echoed / masked / hidden**. This task wires the mechanism and the classifier; line-level aggregation is Task 3.

**Files:**
- Modify: `Sources/SemicolynKit/Predictor/PasswordEntryDetector.swift`
- Test: `Tests/SemicolynKitTests/PasswordEntryDetectorTests.swift`

**Interfaces:**
- Consumes: `EchoOracle`, `EchoCursor`, `EchoCell` (Task 1).
- Produces (relied on by Task 3 aggregation + Task 6 App wiring):
  - `public mutating func setOracle(_ oracle: EchoOracle?)` — inject/clear the oracle (nil ⇒ byte-count fallback path).
  - `public mutating func beginKeystroke(scalar: Unicode.Scalar)` — call *before* delivering a printable keystroke; snapshots the pre-cursor via the oracle.
  - `public mutating func settleKeystroke()` — call *after* the settle window; samples the echo cell and classifies the pending keystroke into `echoed`/`masked`/`hidden`, folding the result into the line tally.
  - Internal `enum EchoClass { case echoed, masked, hidden }`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/SemicolynKitTests/PasswordEntryDetectorTests.swift`:

```swift
    // MARK: - L1 buffer-anchored echo (oracle-driven)

    /// Drive one printable keystroke through the oracle path and return the
    /// classification implied by the resulting tally. Cursor pre = (0,0);
    /// after settle the oracle reports cursor advanced to (0,1) and the cell the
    /// test scripts. Uses the *internal* tallies to assert the class precisely.
    private func classifyOne(
        typed: Unicode.Scalar,
        preCursor: EchoCursor,
        postCursor: EchoCursor?,
        echoCell: EchoCell?,
        alt: Bool = false
    ) -> PasswordEntryDetector.EchoClass? {
        var d = PasswordEntryDetector()
        let oracle = ScriptedEchoOracle()
        oracle.isAlternateBuffer = alt
        oracle.nextCursor = preCursor
        d.setOracle(oracle)
        d.beginKeystroke(scalar: typed)          // snapshots preCursor
        oracle.nextCursor = postCursor
        oracle.cellAt = { r, c in
            (r == preCursor.row && c == preCursor.col) ? echoCell : EchoCell(scalar: nil)
        }
        d.settleKeystroke()                      // samples + classifies
        return d.lastClass
    }

    func testKeystrokeEchoedWhenScalarAtCellAndCursorAdvanced() {
        let cls = classifyOne(
            typed: "k",
            preCursor: EchoCursor(row: 0, col: 0),
            postCursor: EchoCursor(row: 0, col: 1),
            echoCell: EchoCell(scalar: "k"))
        XCTAssertEqual(cls, .echoed)
    }

    func testKeystrokeMaskedWhenConstantMaskCharDespiteAdvance() {
        let cls = classifyOne(
            typed: "s",
            preCursor: EchoCursor(row: 0, col: 0),
            postCursor: EchoCursor(row: 0, col: 1),
            echoCell: EchoCell(scalar: "*"))     // cursor advanced but wrong glyph
        XCTAssertEqual(cls, .masked)
    }

    func testKeystrokeHiddenWhenCursorDidNotAdvance() {
        let cls = classifyOne(
            typed: "h",
            preCursor: EchoCursor(row: 0, col: 0),
            postCursor: EchoCursor(row: 0, col: 0),   // no advance
            echoCell: EchoCell(scalar: nil))
        XCTAssertEqual(cls, .hidden)
    }

    func testKeystrokeHiddenWhenOracleCursorUnreadable() {
        // Oracle drift: post-cursor nil → cannot confirm echo → hidden (suppress).
        let cls = classifyOne(
            typed: "x",
            preCursor: EchoCursor(row: 0, col: 0),
            postCursor: nil,
            echoCell: EchoCell(scalar: "x"))
        XCTAssertEqual(cls, .hidden)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter PasswordEntryDetectorTests`
Expected: FAIL — `value of type 'PasswordEntryDetector' has no member 'setOracle'` / `no type named 'EchoClass'` / `no member 'lastClass'`.

- [ ] **Step 3: Add the sampling mechanism + classifier**

In `Sources/SemicolynKit/Predictor/PasswordEntryDetector.swift`, add the three-way class enum and the oracle-driven fields/methods. Add inside the struct body (after the existing stored properties, before `init`):

```swift
    /// The three-way per-keystroke echo verdict (spec L1).
    public enum EchoClass: Equatable, Sendable { case echoed, masked, hidden }

    /// The injected read-only grid view. Nil ⇒ fall back to byte-count inference.
    private var oracle: EchoOracle?
    /// Cursor cell recorded just before the pending keystroke was delivered.
    private var preCursor: EchoCursor?
    /// The scalar of the pending (delivered, not-yet-settled) keystroke.
    private var pendingScalar: Unicode.Scalar?
    /// Classification of the most recently settled keystroke (test-observable).
    public private(set) var lastClass: EchoClass?
    /// Count of positively-`echoed` printables on the current line (oracle path).
    private var oracleEchoedThisLine = 0
    /// Count of printables classified via the oracle on the current line.
    private var oracleClassifiedThisLine = 0
    /// Set once the oracle path has classified at least one keystroke this line,
    /// so `shouldLearnCommittedLine` knows to trust the buffer tally over bytes.
    private var oracleActiveThisLine = false
```

Add these methods (place after `noteInput`):

```swift
    /// Inject (or clear with nil) the buffer oracle. Clearing reverts to the
    /// byte-count echo inference for subsequent keystrokes.
    public mutating func setOracle(_ oracle: EchoOracle?) {
        self.oracle = oracle
    }

    /// Call BEFORE delivering a printable keystroke: snapshot the cursor cell the
    /// echo would land in. A no-op if no oracle is set or the cursor is unreadable.
    public mutating func beginKeystroke(scalar: Unicode.Scalar) {
        guard let oracle else { preCursor = nil; pendingScalar = nil; return }
        preCursor = oracle.cursor()
        pendingScalar = scalar
    }

    /// Call AFTER the settle window: sample the echo cell + new cursor, classify
    /// the pending keystroke, and fold it into the line tally. Fail-safe: any
    /// unreadable signal classifies `hidden` (suppress).
    public mutating func settleKeystroke() {
        guard let oracle, let pre = preCursor, let scalar = pendingScalar else {
            pendingScalar = nil
            return
        }
        defer { preCursor = nil; pendingScalar = nil }
        let cls = Self.classify(oracle: oracle, pre: pre, scalar: scalar)
        lastClass = cls
        oracleActiveThisLine = true
        oracleClassifiedThisLine += 1
        if cls == .echoed { oracleEchoedThisLine += 1 }
    }

    /// Pure three-way classifier: echoed (scalar at the pre-cell + cursor
    /// advanced), masked (cursor advanced but cell holds a different glyph),
    /// hidden (no advance, or any signal unreadable). Static so it is trivially
    /// unit-testable and has no hidden state.
    private static func classify(
        oracle: EchoOracle, pre: EchoCursor, scalar: Unicode.Scalar
    ) -> EchoClass {
        guard let post = oracle.cursor() else { return .hidden }
        let advanced = post.col > pre.col || post.row > pre.row
        guard advanced else { return .hidden }
        guard let cell = oracle.cell(row: pre.row, col: pre.col),
              let shown = cell.scalar else { return .hidden }
        return shown == scalar ? .echoed : .masked
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter PasswordEntryDetectorTests`
Expected: PASS — the 4 new L1 classification tests pass and all pre-existing tests stay green.

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Predictor/PasswordEntryDetector.swift Tests/SemicolynKitTests/PasswordEntryDetectorTests.swift
git commit -m "feat(predictor): L1 buffer-anchored per-keystroke echo classifier"
```

---

## Task 3: Line-level majority aggregation + alt-screen gate in the verdict

Fold the per-keystroke oracle tally into `shouldLearnCommittedLine`: when the oracle path was active this line, the verdict is **learn only if a strong majority of classified printables were `echoed`**, and **alt-screen forces suppression**. When the oracle path was NOT active (no oracle set), the existing byte-count verdict is unchanged (fallback). Also extend `resetLine`/`reset` to clear the new tallies.

**Files:**
- Modify: `Sources/SemicolynKit/Predictor/PasswordEntryDetector.swift`
- Test: `Tests/SemicolynKitTests/PasswordEntryDetectorTests.swift`

**Interfaces:**
- Consumes: the Task 2 tallies (`oracleActiveThisLine`, `oracleEchoedThisLine`, `oracleClassifiedThisLine`, `lastClass`) and `EchoOracle.isAlternateBuffer`.
- Produces: `shouldLearnCommittedLine()` unchanged signature (`-> Bool`), now oracle-aware. `resetLine()`/`reset()` clear oracle tallies too.

- [ ] **Step 1: Write the failing test**

Append to `Tests/SemicolynKitTests/PasswordEntryDetectorTests.swift`:

```swift
    // MARK: - L1 line-level aggregation

    /// Drive a whole typed line through the oracle path. `perChar` gives, per
    /// typed scalar, the (postCursor, echoCell) the oracle should report at settle;
    /// pre-cursor advances one column per accepted char. Returns the learn verdict.
    private func oracleVerdict(
        typed: String,
        alt: Bool,
        perChar: (Int) -> (EchoCursor?, EchoCell?)
    ) -> Bool {
        var d = PasswordEntryDetector()
        let oracle = ScriptedEchoOracle()
        oracle.isAlternateBuffer = alt
        d.setOracle(oracle)
        var col = 0
        for (i, ch) in typed.unicodeScalars.enumerated() {
            let pre = EchoCursor(row: 0, col: col)
            oracle.nextCursor = pre
            d.beginKeystroke(scalar: ch)
            d.noteInput(Array(String(ch).utf8))
            let (post, cell) = perChar(i)
            oracle.nextCursor = post
            oracle.cellAt = { r, c in (r == 0 && c == pre.col) ? cell : EchoCell(scalar: nil) }
            d.settleKeystroke()
            col += 1
        }
        let learn = d.shouldLearnCommittedLine()
        d.noteInput([0x0d])
        return learn
    }

    func testAllEchoedLineLearnsViaOracle() {
        let s = Array("kubectl".unicodeScalars)
        let learn = oracleVerdict(typed: "kubectl", alt: false) { i in
            (EchoCursor(row: 0, col: i + 1), EchoCell(scalar: s[i]))
        }
        XCTAssertTrue(learn)
    }

    func testAllHiddenLineSuppressedViaOracle() {
        // A hidden password: cursor never advances, cell stays blank → suppress.
        let learn = oracleVerdict(typed: "hunter2", alt: false) { _ in
            (EchoCursor(row: 0, col: 0), EchoCell(scalar: nil))
        }
        XCTAssertFalse(learn)
    }

    func testMaskedLineSuppressedViaOracle() {
        // Every char masked with '*' (advance but wrong glyph) → suppress.
        let learn = oracleVerdict(typed: "s3cr3t!", alt: false) { i in
            (EchoCursor(row: 0, col: i + 1), EchoCell(scalar: "*"))
        }
        XCTAssertFalse(learn)
    }

    func testAltScreenLineSuppressedEvenIfEchoed() {
        let s = Array("dd".unicodeScalars)
        let learn = oracleVerdict(typed: "dd", alt: true) { i in
            (EchoCursor(row: 0, col: i + 1), EchoCell(scalar: s[i]))
        }
        XCTAssertFalse(learn)   // alt-screen ⇒ suppress the whole line
    }

    func testMajorityEchoedLineLearns() {
        // 6 of 7 echoed, 1 hidden (a settle miss) → majority ⇒ learn.
        let s = Array("kubectl".unicodeScalars)
        let learn = oracleVerdict(typed: "kubectl", alt: false) { i in
            i == 3
                ? (EchoCursor(row: 0, col: 3), EchoCell(scalar: nil))   // one miss, no advance
                : (EchoCursor(row: 0, col: i + 1), EchoCell(scalar: s[i]))
        }
        XCTAssertTrue(learn)
    }

    func testMinorityEchoedLineSuppressed() {
        // Only 2 of 7 echoed → below majority ⇒ suppress (bias to not-learn).
        let s = Array("secret7".unicodeScalars)
        let learn = oracleVerdict(typed: "secret7", alt: false) { i in
            i < 2
                ? (EchoCursor(row: 0, col: i + 1), EchoCell(scalar: s[i]))
                : (EchoCursor(row: 0, col: i), EchoCell(scalar: nil))
        }
        XCTAssertFalse(learn)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter PasswordEntryDetectorTests`
Expected: FAIL — `testAllHiddenLineSuppressedViaOracle` and others fail because `shouldLearnCommittedLine` still uses only the byte-count path (which sees no `noteOutput` echoes and would suppress — but `testAllEchoedLineLearnsViaOracle` fails, since the byte path never saw echoes so it returns false where the test expects true).

- [ ] **Step 3: Make the verdict oracle-aware + gate alt-screen**

In `Sources/SemicolynKit/Predictor/PasswordEntryDetector.swift`, replace the body of `shouldLearnCommittedLine()`:

```swift
    public func shouldLearnCommittedLine() -> Bool {
        if promptSuppressedThisLine { return false }
        // Oracle path: when the buffer check classified this line, trust the
        // majority-echoed statistic (the far stronger signal per spec L1).
        if oracleActiveThisLine {
            if oracle?.isAlternateBuffer == true { return false }   // alt-screen ⇒ suppress
            guard oracleClassifiedThisLine > 0 else { return false }
            // Strong majority required (> 50%). A tie or worse suppresses —
            // exclusion wins ties.
            return oracleEchoedThisLine * 2 > oracleClassifiedThisLine
        }
        // Byte-count fallback (no oracle set): unchanged positive-echo-required.
        guard typedThisLine > 0 else { return false }
        return echoedThisLine + 1 >= typedThisLine
    }
```

Extend `resetLine()` — add these lines at the top of its body (before the existing assignments):

```swift
        oracleEchoedThisLine = 0
        oracleClassifiedThisLine = 0
        oracleActiveThisLine = false
        lastClass = nil
        preCursor = nil
        pendingScalar = nil
```

Extend `reset()` — add the same six lines at the top of its body. Do **not** clear `oracle` in `reset()` (the injected adapter survives a session reset; the App re-injects on host switch anyway, but a nil-out here would silently drop the oracle mid-session).

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter PasswordEntryDetectorTests`
Expected: PASS — all L1 aggregation tests + the pre-existing byte-count tests are green.

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Predictor/PasswordEntryDetector.swift Tests/SemicolynKitTests/PasswordEntryDetectorTests.swift
git commit -m "feat(predictor): L1 line-majority echo verdict + alt-screen suppression"
```

---

## Task 4: Output-liveness gate (ambiguous non-echo under a stall ⇒ suppress)

Per spec L1: when no output is arriving at all, an "unechoed" reading is ambiguous (network stall vs. real non-echo) → bias to suppress. The detector already sees output via `noteOutput`; give it a per-line "did any output arrive while typing this line" flag and require it before an *oracle* line can be learned. (A truly echoing line necessarily produced output, so this never suppresses a real echo; it only kills the stall-ambiguous case.)

**Files:**
- Modify: `Sources/SemicolynKit/Predictor/PasswordEntryDetector.swift`
- Test: `Tests/SemicolynKitTests/PasswordEntryDetectorTests.swift`

**Interfaces:**
- Consumes: existing `noteOutput`.
- Produces: no new public method; `shouldLearnCommittedLine` additionally requires per-line output liveness on the oracle path. `resetLine`/`reset` clear the liveness flag.

- [ ] **Step 1: Write the failing test**

Append to `Tests/SemicolynKitTests/PasswordEntryDetectorTests.swift`:

```swift
    // MARK: - L1 output-liveness gate

    func testOracleLineWithNoOutputIsSuppressed() {
        // Cursor "advances" and cells "match" per the oracle, but NO output byte
        // ever arrived (a stall) → ambiguous → suppress. This drives the oracle
        // path directly WITHOUT calling noteOutput.
        var d = PasswordEntryDetector()
        let oracle = ScriptedEchoOracle()
        d.setOracle(oracle)
        let s = Array("kubectl".unicodeScalars)
        var col = 0
        for (i, ch) in "kubectl".unicodeScalars.enumerated() {
            let pre = EchoCursor(row: 0, col: col)
            oracle.nextCursor = pre
            d.beginKeystroke(scalar: ch)
            d.noteInput(Array(String(ch).utf8))
            oracle.nextCursor = EchoCursor(row: 0, col: col + 1)
            oracle.cellAt = { r, c in (r == 0 && c == pre.col) ? EchoCell(scalar: s[i]) : EchoCell(scalar: nil) }
            d.settleKeystroke()
            col += 1
        }
        XCTAssertFalse(d.shouldLearnCommittedLine())   // no noteOutput ⇒ not live ⇒ suppress
    }

    func testOracleLineWithOutputStaysLearnable() {
        // Same as above but a single output byte arrives → liveness satisfied,
        // majority echoed ⇒ learn. Proves the gate doesn't suppress real echoes.
        var d = PasswordEntryDetector()
        let oracle = ScriptedEchoOracle()
        d.setOracle(oracle)
        let s = Array("kubectl".unicodeScalars)
        var col = 0
        for (i, ch) in "kubectl".unicodeScalars.enumerated() {
            let pre = EchoCursor(row: 0, col: col)
            oracle.nextCursor = pre
            d.beginKeystroke(scalar: ch)
            d.noteInput(Array(String(ch).utf8))
            d.noteOutput(Array(String(ch).utf8))       // echoing shell emits output
            oracle.nextCursor = EchoCursor(row: 0, col: col + 1)
            oracle.cellAt = { r, c in (r == 0 && c == pre.col) ? EchoCell(scalar: s[i]) : EchoCell(scalar: nil) }
            d.settleKeystroke()
            col += 1
        }
        XCTAssertTrue(d.shouldLearnCommittedLine())
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter PasswordEntryDetectorTests`
Expected: FAIL — `testOracleLineWithNoOutputIsSuppressed` fails (currently the oracle path learns without requiring output liveness).

- [ ] **Step 3: Add the liveness flag**

In `Sources/SemicolynKit/Predictor/PasswordEntryDetector.swift`, add a stored property alongside the other oracle fields:

```swift
    /// True once any output byte arrived while the current line was being typed.
    /// Gates the oracle verdict: a "clean echo" reading during a total stall is
    /// ambiguous, so an oracle line with no output is suppressed.
    private var outputSeenThisLine = false
```

In `noteOutput(_:)`, set the flag when any byte is folded — add at the very top of the method body:

```swift
        if !bytes.isEmpty { outputSeenThisLine = true }
```

In `shouldLearnCommittedLine()`, add the liveness requirement to the oracle branch — change:

```swift
        if oracleActiveThisLine {
            if oracle?.isAlternateBuffer == true { return false }   // alt-screen ⇒ suppress
            guard oracleClassifiedThisLine > 0 else { return false }
            return oracleEchoedThisLine * 2 > oracleClassifiedThisLine
        }
```

to:

```swift
        if oracleActiveThisLine {
            if oracle?.isAlternateBuffer == true { return false }   // alt-screen ⇒ suppress
            guard outputSeenThisLine else { return false }          // stall ⇒ ambiguous ⇒ suppress
            guard oracleClassifiedThisLine > 0 else { return false }
            return oracleEchoedThisLine * 2 > oracleClassifiedThisLine
        }
```

Add `outputSeenThisLine = false` to both `resetLine()` and `reset()` (with the other cleared oracle fields).

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter PasswordEntryDetectorTests`
Expected: PASS — both liveness tests pass; every earlier test that calls `noteOutput` (all of Task 3's `oracleVerdict` helper *does* call `noteOutput`? — no, it does not) stays consistent.

> Note for the implementer: Task 3's `oracleVerdict` helper does **not** call `noteOutput`, so after this task its "learn" expectations would break. Fix the helper in this same task: add `d.noteOutput(Array(String(ch).utf8))` immediately after the `d.noteInput(...)` line inside `oracleVerdict`'s loop, then re-run. The masked/hidden/alt tests still suppress (liveness is necessary, not sufficient); the echoed/majority tests now have liveness satisfied and still learn.

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Predictor/PasswordEntryDetector.swift Tests/SemicolynKitTests/PasswordEntryDetectorTests.swift
git commit -m "feat(predictor): L1 output-liveness gate — suppress stall-ambiguous echo"
```

---

## Task 5: Prompt-text suppressor corroborates the oracle verdict

Per spec L1: the existing prompt-text suppressor "becomes a corroborating input (a `Password:`-style tail ⇒ force the line to non-echoed)". Today `promptSuppressedThisLine` already forces `shouldLearnCommittedLine` to `false` first — verify that still holds on the oracle path and add an explicit adversarial test: an oracle line that reads as fully echoed but was preceded by a `Password:` prompt must STILL be suppressed (a masked prompt that echoes the literal — the exact case the buffer check alone would miss).

**Files:**
- Modify: `Sources/SemicolynKit/Predictor/PasswordEntryDetector.swift` (only if the test reveals a gap — likely none; the early `promptSuppressedThisLine` return already dominates).
- Test: `Tests/SemicolynKitTests/PasswordEntryDetectorTests.swift`

**Interfaces:**
- Consumes: existing `promptSuppressedThisLine`, `resetLine`.
- Produces: no interface change; a corroboration guarantee locked by test.

- [ ] **Step 1: Write the failing test**

Append to `Tests/SemicolynKitTests/PasswordEntryDetectorTests.swift`:

```swift
    // MARK: - L1 prompt-text corroboration

    func testPromptPrecededLineSuppressedEvenIfOracleSaysEchoed() {
        // Adversarial: a prompt that ECHOES the literal password (e.g. `read`
        // without -s after a "Password:" prompt). The oracle sees clean echo, but
        // the prompt tail forces non-echoed. Must NOT learn.
        var d = PasswordEntryDetector()
        d.noteOutput(Array("Password: ".utf8))
        d.resetLine()                                  // classify the prompt tail
        let oracle = ScriptedEchoOracle()
        d.setOracle(oracle)
        let s = Array("hunter2".unicodeScalars)
        var col = 0
        for (i, ch) in "hunter2".unicodeScalars.enumerated() {
            let pre = EchoCursor(row: 0, col: col)
            oracle.nextCursor = pre
            d.beginKeystroke(scalar: ch)
            d.noteInput(Array(String(ch).utf8))
            d.noteOutput(Array(String(ch).utf8))       // literal echoed back
            oracle.nextCursor = EchoCursor(row: 0, col: col + 1)
            oracle.cellAt = { r, c in (r == 0 && c == pre.col) ? EchoCell(scalar: s[i]) : EchoCell(scalar: nil) }
            d.settleKeystroke()
            col += 1
        }
        XCTAssertFalse(d.shouldLearnCommittedLine())   // prompt corroboration wins
    }
```

- [ ] **Step 2: Run test to verify it fails or passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter PasswordEntryDetectorTests`
Expected: PASS immediately (the `if promptSuppressedThisLine { return false }` at the top of `shouldLearnCommittedLine` already dominates the oracle branch). If it FAILS, the early return was reordered — restore `promptSuppressedThisLine` as the first check in `shouldLearnCommittedLine`.

> This is a guard test locking an invariant (prompt suppression precedes the oracle verdict). It is real: delete the `if promptSuppressedThisLine { return false }` line and it fails.

- [ ] **Step 3: (Only if failing) restore prompt precedence**

If Step 2 failed, ensure `shouldLearnCommittedLine()` opens with:

```swift
        if promptSuppressedThisLine { return false }
```

before the `if oracleActiveThisLine` block. Otherwise no code change.

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter PasswordEntryDetectorTests`
Expected: PASS (full detector suite).

- [ ] **Step 5: Commit**

```bash
git add Tests/SemicolynKitTests/PasswordEntryDetectorTests.swift Sources/SemicolynKit/Predictor/PasswordEntryDetector.swift
git commit -m "test(predictor): lock prompt-text corroboration precedence over L1 oracle"
```

---

## Task 6: App-tier `SwiftTermEchoOracle` adapter + capture wiring (macOS-CI-only)

Provide the concrete oracle backed by the **active pane's** SwiftTerm `TerminalView` and wire it into `observePredictorInput`: inject the oracle once, snapshot before each printable keystroke, and settle after a bounded window off the input hot path. **This tier does not build on Linux and is verified only by the macOS CI job** — there is no local `swift test` step. Keep it a thin mapping; all logic already lives in Kit.

> **Real wiring (verified against source):** `ConnectionViewModel` is `@MainActor` (`:32`) and does NOT hold a single terminal view — it holds `paneViews: [PaneID: TerminalView]` (`:94`), populated via `registerPane` (`:194`). The active pane is resolved exactly like the existing `activePaneApplicationCursor()` helper (`:183`): `tmuxState.activeWindow → window.activePane → paneViews[pane]`. For a raw (non-tmux) session `tmuxState` is nil and there is a single entry in `paneViews`. So the oracle must resolve the active view **on each sample** via a closure — not capture one fixed view — mirroring the existing closure-based deps (e.g. `applicationCursorKeys:` at `:135`). This is why the adapter takes a `resolveActiveView` thunk, not a `TerminalView`.

**Files:**
- Create: `App/SwiftTermEchoOracle.swift`
- Modify: `App/ConnectionViewModel.swift` (add an active-view resolver; inject the oracle once in `init`/setup; drive `beginKeystroke`/`settleKeystroke` in `observePredictorInput`).

**Interfaces:**
- Consumes: `EchoOracle`, `EchoCursor`, `EchoCell` (Task 1); `PasswordEntryDetector.setOracle`/`beginKeystroke`/`settleKeystroke` (Tasks 2–4); the active-pane resolution pattern of `activePaneApplicationCursor()` (`App/ConnectionViewModel.swift:183`).
- Produces: `SwiftTermEchoOracle(resolveActiveView:)` conforming to `EchoOracle`.

- [ ] **Step 1: Write the adapter**

Create `App/SwiftTermEchoOracle.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
#if canImport(SwiftTerm)
import SwiftTerm
import SemicolynKit

/// App-tier `EchoOracle` backed by the *active pane's* live SwiftTerm terminal.
/// Maps the rendered grid onto the pure Kit protocol so the L1 detector's logic
/// stays Linux-tested. macOS-CI-only: this file does not build on the Linux job.
///
/// Resolves the active view on EACH sample via `resolveActiveView` (the active
/// pane changes across tmux windows/panes; a fixed capture would read the wrong
/// grid after a pane switch). Every accessor is defensive: a nil view, SwiftTerm
/// API drift, or out-of-range read returns nil / false, which the detector
/// treats as "not echoed" (suppress).
///
/// The resolver is `@MainActor`-bound (it reads `paneViews` on the view model);
/// the detector only calls it from the main-actor settle closure, so this stays
/// on-actor. Marked `@unchecked Sendable` because the closure is main-isolated in
/// practice; it is never invoked off the main actor.
struct SwiftTermEchoOracle: EchoOracle, @unchecked Sendable {
    let resolveActiveView: @MainActor () -> TerminalView?

    init(resolveActiveView: @escaping @MainActor () -> TerminalView?) {
        self.resolveActiveView = resolveActiveView
    }

    func cursor() -> EchoCursor? {
        MainActor.assumeIsolated {
            guard let term = resolveActiveView()?.getTerminal() else { return nil }
            let pos = term.getCursorLocation()   // (x, y) column/row
            return EchoCursor(row: pos.y, col: pos.x)
        }
    }

    func cell(row: Int, col: Int) -> EchoCell? {
        MainActor.assumeIsolated {
            guard let term = resolveActiveView()?.getTerminal() else { return nil }
            // getCharData(col:row:) is 0-based; nil when out of range.
            guard let cd = term.getCharData(col: col, row: row) else { return nil }
            // CharData.getCharacter() yields the rendered Character; blank → nil.
            let ch = cd.getCharacter()
            if ch == "\u{0}" || ch == " " { return EchoCell(scalar: nil) }
            return EchoCell(scalar: ch.unicodeScalars.first)
        }
    }

    var isAlternateBuffer: Bool {
        MainActor.assumeIsolated {
            resolveActiveView()?.getTerminal().isCurrentBufferAlternate ?? false
        }
    }
}
#endif
```

> **Implementer note (CI-verified):** the exact SwiftTerm accessor names (`getCursorLocation()` returning a `Position`/tuple with `.x`/`.y`; `getCharData(col:row:)`; `CharData.getCharacter()`; `isCurrentBufferAlternate`) are the public APIs the research doc identified; `getTerminal().applicationCursor` is already used at `:187`, confirming `getTerminal()` availability. If the macOS CI build reports a signature mismatch (or `MainActor.assumeIsolated` is unnecessary because `EchoOracle` calls are already synchronous on-actor), adjust **inside this file only** — the Kit protocol and all Kit tests are unaffected. Do not move logic out of Kit to "fix" a compile error here.

- [ ] **Step 2: Add an active-view resolver + inject the oracle once**

In `App/ConnectionViewModel.swift`, add a private resolver that mirrors `activePaneApplicationCursor()` but returns the view (and falls back to the sole pane for a raw session). Add it right after `activePaneApplicationCursor()` (`:188`):

```swift
    /// The `TerminalView` the user is currently typing into: the tmux active
    /// pane, or — in a raw (non-tmux) session — the single registered pane.
    /// Nil until a pane is registered. Used by the L1 echo oracle.
    private func activePaneView() -> TerminalView? {
        if let win = tmuxState?.activeWindow,
           let pane = tmuxState?.window(win)?.activePane,
           let tv = paneViews[pane] {
            return tv
        }
        // Raw session: exactly one pane view once registered.
        return paneViews.count == 1 ? paneViews.first?.value : nil
    }
```

Inject the oracle once, where `passwordDetector` is created (`:69`) or in `init` after the pane deps are set up. The cleanest spot is right after the `passwordDetector` property is initialized — but since `setOracle` is `mutating` and needs `self`, do it in `init` (or the setup method that already configures closures like `applicationCursorKeys`). Add to `init` (after the existing closure wiring):

```swift
        // L1: back the echo detector with the active pane's rendered grid.
        passwordDetector.setOracle(
            SwiftTermEchoOracle(resolveActiveView: { [weak self] in self?.activePaneView() })
        )
```

> Do **not** clear the oracle in `passwordDetector.reset()` at `:312` — the resolver is stateless and valid for the whole VM lifetime; only per-line/echo tallies reset. (Task 3 already ensures `reset()` does not nil the oracle.)

- [ ] **Step 3: Drive begin/settle around each printable keystroke in the capture path**

In `observePredictorInput(_:)` (`App/ConnectionViewModel.swift:737`), snapshot before delivery and settle after a bounded window. Replace the method body's keystroke handling so each printable byte is bracketed. The settle must be **deferred, off the hot path** — schedule it after ~1 RTT (bounded, e.g. 40 ms) so the verdict is ready by line commit, and it must never block input. Concretely, restructure to:

```swift
    private func observePredictorInput(_ bytes: [UInt8]) {
        guard engine != nil else { return }
        // L1: snapshot cursor before each printable keystroke, then settle after a
        // bounded window (off the hot path; verdict is consumed at line commit).
        for b in bytes where (0x21...0x7e).contains(b) || b == 0x20 {
            if let scalar = Unicode.Scalar(exactly: UInt32(b)) {
                passwordDetector.beginKeystroke(scalar: scalar)
            }
        }
        passwordDetector.noteInput(bytes)
        for committed in tracker.observe(bytes) {
            pendingLineTokens.append(committed)
        }
        // Settle the just-typed keystrokes after a short window so the echo has
        // arrived. Hop through main; never awaited on the input path.
        let deadline = DispatchTime.now() + .milliseconds(40)
        DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] in
            self?.passwordDetector.settleKeystroke()
            self?.refreshPredictorSuggestions()
        }
        // Flush the line's buffered tokens on each line commit (Enter / newline).
        for b in bytes where b == 0x0d || b == 0x0a {
            // Give the last keystrokes their settle window before judging the line.
            DispatchQueue.main.asyncAfter(deadline: deadline + .milliseconds(10)) { [weak self] in
                guard let self else { return }
                if self.passwordDetector.shouldLearnCommittedLine() {
                    for c in self.pendingLineTokens { self.engine?.record(c.token, after: c.previous) }
                }
                self.pendingLineTokens.removeAll(keepingCapacity: true)
                self.passwordDetector.resetLine()
            }
        }
        refreshPredictorSuggestions()
    }
```

> **Concurrency caution (CI-verified):** `passwordDetector` is a value-type `struct` on a main-actor-isolated view model. The `asyncAfter` closures run on the main queue, so mutations stay serialized on the main actor — consistent with the existing code that already mutates `passwordDetector` synchronously. Do **not** introduce a background queue for settle; the whole point is that it stays on the same actor as the rest of the view model. If the view model is `@MainActor`, the `DispatchQueue.main.asyncAfter` closures are already main-actor; keep them.
>
> The 40 ms settle is a starting value; it is tuned on-device in the Phase-1 device pass, not here. It must be **bounded and non-blocking** by construction.

- [ ] **Step 4: Verify via CI (no local Swift build for App tier)**

Push the branch and let the **macOS CI job** compile the App target:

```bash
git add App/SwiftTermEchoOracle.swift App/ConnectionViewModel.swift
git commit -m "feat(app): SwiftTermEchoOracle adapter + L1 capture wiring (macOS-CI-only)"
git push github feat/predictor-secret-exclusion
gh run watch --exit-status   # or: gh run list --branch feat/predictor-secret-exclusion
```

Expected: the `linux-swift` job stays green (App file is `#if canImport(SwiftTerm)`-gated and invisible to `swift test`); the `macos` job compiles `SwiftTermEchoOracle.swift` + the wiring. If `macos` reports a SwiftTerm signature mismatch, fix the mapping in `SwiftTermEchoOracle.swift` only (Step 1 note), re-push, re-watch.

> `linux-rust` may flake with `sshd fixtures not reachable` — that is unrelated to this change; rerun the failed job (`gh run rerun <id> --failed`).

- [ ] **Step 5: Commit (already committed in Step 4)**

No additional commit unless CI required an adapter fix; if so:

```bash
git add App/SwiftTermEchoOracle.swift
git commit -m "fix(app): align SwiftTermEchoOracle with SwiftTerm grid API"
git push github feat/predictor-secret-exclusion
```

---

## Task 7: Update the detector doc-comment + spec/plan bookkeeping

The `PasswordEntryDetector` header still describes the byte-count-only design ("SwiftTerm exposes no echo/SRM flag"). Correct it to reflect the oracle upgrade, and record Phase-1 completion so a cold resume knows Phase 2 is next.

**Files:**
- Modify: `Sources/SemicolynKit/Predictor/PasswordEntryDetector.swift` (doc comment only).
- Modify: `docs/superpowers/specs/2026-07-04-predictor-secret-exclusion-design.md` (Current-state note).

**Interfaces:** none (docs).

- [ ] **Step 1: Correct the detector header**

In `PasswordEntryDetector.swift`, update the "Why it is heuristic" paragraph. Replace the sentence:

```
/// no echo/SRM flag; russh surfaces no termios-change event). So the only observable signals are:
```

with:

```
/// no deterministic echo/SRM flag; russh surfaces no termios-change event). L1
/// therefore infers echo from the *rendered grid* via an injected `EchoOracle`
/// (buffer-anchored, three-way echoed/masked/hidden, line-majority aggregated,
/// gated on alt-screen + output liveness); when no oracle is injected it falls
/// back to the byte-count inference below. The observable signals are:
```

- [ ] **Step 2: Record Phase-1 completion in the spec**

In `docs/superpowers/specs/2026-07-04-predictor-secret-exclusion-design.md`, under `## Current state (for a cold resume)`, change the `**Next step:**` line to:

```
- **Phase 1 (L1 buffer echo + `EchoOracle` seam) IMPLEMENTED** — plan
  `docs/superpowers/plans/2026-07-04-predictor-secret-exclusion-phase1-echo-oracle.md`.
  **Next step:** invoke `writing-plans` for **Phase 2** (L3 paste + L4 context/leading-space).
```

- [ ] **Step 3: Run the full Kit suite once more (regression guard)**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS — entire SemicolynKit + SeedKit suite green.

- [ ] **Step 4: Commit**

```bash
git add Sources/SemicolynKit/Predictor/PasswordEntryDetector.swift docs/superpowers/specs/2026-07-04-predictor-secret-exclusion-design.md
git commit -m "docs(predictor): reflect L1 EchoOracle upgrade + mark Phase 1 done"
```

---

## Self-Review

**Spec coverage (L1 + Data-flow + Testing sections):**

| Spec requirement | Task |
|---|---|
| Buffer-anchored check: pre-cursor snapshot, settle, sample cell + new cursor | Task 2 |
| Three-way echoed / masked / hidden classification | Task 2 |
| `masked` and `hidden` both count as not-echoed | Tasks 2–3 |
| Alt-screen ⇒ skip check + suppress the whole line | Task 3 |
| Output-liveness gate (stall ⇒ suppress) | Task 4 |
| Line-level majority aggregation (verdict per committed line) | Task 3 |
| Prompt-text suppressor folds in as corroborating input (force non-echoed) | Task 5 |
| `EchoOracle` protocol seam (`sampleCell`/`cursor`/`isAlternate`) keeps logic pure-Kit | Task 1 |
| App `SwiftTermEchoOracle` backed by `getTerminal()` | Task 6 |
| Kit tests use a scripted fake | Tasks 1–5 |
| Failure mode = suppress (oracle unavailable/throws → non-echoed) | Tasks 2 (`classify` nil→hidden), 3, 4 |
| Verdict deferred to line commit, never blocks input | Task 6 (deferred `asyncAfter`) |
| Testing table L1 row (echoed→learn / hidden→suppress / masked→suppress / alt→suppress / majority) | Tasks 2–5 |
| Adapter adapter + reads `getTerminal()` correctly (macOS CI) | Task 6 |

Note: the spec's "rename to `SecretExclusionPipeline`" is a *later-phase* aggregation (it composes L1/L3/L4 — L3/L4 arrive in Phase 2). Phase 1 keeps the `PasswordEntryDetector` name and upgrades it in place; the rename is deferred to the phase that first has multiple layers to compose. This is intentional (YAGNI: no multi-layer object to name yet).

**Placeholder scan:** no TBD/TODO/"add error handling"/"similar to Task N"; every code step shows complete code; the two App-tier steps that can't be locally verified are explicitly marked CI-verified with a signature-drift fallback rather than left vague.

**Type consistency:** `EchoCursor`/`EchoCell`/`EchoClass`/`EchoOracle` names, `setOracle`/`beginKeystroke`/`settleKeystroke`/`lastClass`/`shouldLearnCommittedLine` signatures, and the `oracleEchoedThisLine`/`oracleClassifiedThisLine`/`oracleActiveThisLine`/`outputSeenThisLine` field names are used identically across Tasks 1–6. `SwiftTermEchoOracle(resolveActiveView:)` matches its consumption in Task 6, and the resolver mirrors the verified `activePaneApplicationCursor()`/`paneViews` pattern (`App/ConnectionViewModel.swift:183`,`:94`) rather than a non-existent single `terminalView` property.

**Fresh-eyes gap found + fixed inline:** Task 4's liveness gate breaks Task 3's `oracleVerdict` helper (which didn't call `noteOutput`); Task 4 Step 4 now explicitly patches that helper so the suite stays green — surfaced rather than left as a latent break.
