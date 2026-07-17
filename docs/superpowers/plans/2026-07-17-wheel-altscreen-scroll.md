<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# SGR mouse-wheel alt-screen scroll — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the alt-screen scroll mechanism with a universal SGR mouse-wheel emitter (one wheel event per line-height of drag, the Blink-validated 1-line-scroll mechanism), keeping the old arrows/PgUp behavior as a user-selectable fallback.

**Architecture:** A pure Kit emitter turns drag distance into vertical wheel-event runs (reusing the existing signed-delta accounting); a pure Kit encoder renders SGR wheel bytes. `AltScrollMode` collapses from 4 cases to 2 (`wheel` default / `pageKeysArrows` fallback); the per-app registry is retained but consulted only in fallback. The App gesture controller branches on the decision's key family and emits wheel-or-arrows via the existing `sendBytes` path.

**Tech Stack:** Swift 6, XCTest, SemicolynKit (Linux-tested pure tier) + App tier (macOS-CI-only). Docker `semicolyn-dev` for Kit tests.

## Global Constraints

- **Two tiers:** `Sources/SemicolynKit/` = pure, Linux-tested, `Sendable`, NO `import UIKit`/`SwiftUI`/`DebugLog`. App tier compiles ONLY on macOS CI.
- **SPDX header** on every source file: `// SPDX-FileCopyrightText: 2026 True Positive LLC` + `// SPDX-License-Identifier: GPL-3.0-only`.
- **Tests must be real:** assert exact observable values (exact bytes, exact runs); a negative test asserts the SPECIFIC failure.
- **No em-dash (—)** in code/comments/commit messages. The literal `→` (U+2192) in log-line format strings is intended and correct.
- **Conventional commits.** Work on branch `fix/wheel-altscreen-scroll` (branched off `main` / `tf54-known-good`).
- **Rollback anchor:** tag `tf54-known-good` = `99e90ff` (live TestFlight build 54). This work merges via PR; `main` stays clean until merge.
- **Run Kit tests:** `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter <Suite>`.
- **SGR wheel encoding (spec-fixed):** wheel-up = button `64`, wheel-down = `65`, format `ESC [ < Cb ; col ; row M`, press-only (no release), col/row 1-based.

## Design deviation from the spec (noted, intentional)

The spec proposed a new `WheelRun` struct carrying `col`/`row`. This plan instead **reuses the
existing `ArrowRun`** (direction `.up`/`.down` + count) for wheel runs and passes `col`/`row` as
parameters to the encoder. Rationale: `AltScreenScroll.wheelEvents` produces the same up/down
vertical runs as `arrows(...)`, and the coordinate is constant for a given `.changed` sample (the
drag point), so it belongs on the encode call, not duplicated into every run. This avoids a
near-duplicate type. Behavior is identical to the spec.

## File Structure

- `Sources/SemicolynKit/Terminal/AltScreenScroll.swift` (MODIFY) — add `wheelEvents(...)`; factor the shared signed-delta helper out of `arrows(...)`.
- `Sources/SemicolynKit/Terminal/ArrowEncoding.swift` (MODIFY) — add `encodeWheelRun(_:col:row:)`.
- `Sources/SemicolynKit/Terminal/AltScrollMode.swift` (MODIFY) — `AltScrollKeys.wheel`; `AltScrollMode` → `{wheel, pageKeysArrows}`; rewrite `altScrollDecision`.
- `Sources/SemicolynKit/Terminal/TerminalSettings.swift` (MODIFY) — default `.wheel` + legacy-mode migration on decode.
- `Tests/SemicolynKitTests/AltScreenScrollTests.swift` (MODIFY) — wheelEvents tests.
- `Tests/SemicolynKitTests/ArrowEncodingTests.swift` (MODIFY or CREATE) — encodeWheelRun bytes.
- `Tests/SemicolynKitTests/AltScrollDeciderTests.swift` (MODIFY) — rewrite for the 2-case model.
- `Tests/SemicolynKitTests/TerminalSettingsCodableTests.swift` (MODIFY or the existing settings test) — migration test.
- `App/TerminalGestureController.swift` (MODIFY) — wheel branch + coord math + `drag-move coord=` log.
- `App/ExperimentalSettingsView.swift` (MODIFY) — two-row picker.

---

## Task 1: Wheel emitter + shared delta helper (Kit)

**Files:**
- Modify: `Sources/SemicolynKit/Terminal/AltScreenScroll.swift`
- Test: `Tests/SemicolynKitTests/AltScreenScrollTests.swift`

**Interfaces:**
- Consumes: existing `ArrowRun`, `arrowEvents(cols:rows:)`, `maxCellsPerEmit`.
- Produces:
  - `static func wheelEvents(totalDy: Double, cellHeight: Double, emittedCells: Int) -> (runs: [ArrowRun], newEmittedCells: Int)` — vertical wheel runs (`.up`/`.down` only), gain **1.0** (fixed), same signed-delta + `maxCellsPerEmit` accounting as `arrows`.
  - A private `static func signedCellDelta(totalDy:cellHeight:emittedCells:gain:) -> (delta: Int, newEmitted: Int)?` factored out and shared by `arrows` and `wheelEvents` (returns nil on non-positive cellHeight or zero delta).

- [ ] **Step 1: Write the failing tests** — append to `AltScreenScrollTests.swift`:

```swift
    // wheelEvents: gain is a FIXED 1.0 (position-tracking), independent of scrollGain.
    // One cell-height of drag = one wheel event. Finger DOWN (+dy) = wheel UP (scroll back).
    func testWheelOneCellDownEmitsOneUp() {
        let r = AltScreenScroll.wheelEvents(totalDy: 16, cellHeight: cell, emittedCells: 0)
        XCTAssertEqual(r.runs, [ArrowRun(direction: .up, count: 1)])
        XCTAssertEqual(r.newEmittedCells, 1)
    }
    // Direction: dragging up (-dy) = wheel DOWN.
    func testWheelDragUpEmitsDown() {
        let r = AltScreenScroll.wheelEvents(totalDy: -32, cellHeight: cell, emittedCells: 0)
        XCTAssertEqual(r.runs, [ArrowRun(direction: .down, count: 2)])  // 2 cells at gain 1.0
        XCTAssertEqual(r.newEmittedCells, -2)
    }
    // Sub-cell drag -> nothing (BVA below one cell at gain 1.0: 15pt < 16pt cell).
    func testWheelSubCellEmitsNothing() {
        let r = AltScreenScroll.wheelEvents(totalDy: 15, cellHeight: cell, emittedCells: 0)
        XCTAssertEqual(r.runs, [])
        XCTAssertEqual(r.newEmittedCells, 0)
    }
    // Incremental: a second sample sends only the NEW delta (no double-count).
    func testWheelIncrementalDeltaOnly() {
        let first = AltScreenScroll.wheelEvents(totalDy: 16, cellHeight: cell, emittedCells: 0)
        XCTAssertEqual(first.newEmittedCells, 1)
        let second = AltScreenScroll.wheelEvents(totalDy: 48, cellHeight: cell, emittedCells: first.newEmittedCells)
        XCTAssertEqual(second.runs, [ArrowRun(direction: .up, count: 2)])   // 3 total - 1 already
        XCTAssertEqual(second.newEmittedCells, 3)
    }
    // No new movement -> nothing.
    func testWheelNoNewCellsEmitsNothing() {
        let first = AltScreenScroll.wheelEvents(totalDy: 16, cellHeight: cell, emittedCells: 0)
        let r = AltScreenScroll.wheelEvents(totalDy: 16, cellHeight: cell, emittedCells: first.newEmittedCells)
        XCTAssertEqual(r.runs, [])
        XCTAssertEqual(r.newEmittedCells, first.newEmittedCells)
    }
    // Anti-flood: a huge flick clamps to maxCellsPerEmit.
    func testWheelHugeFlickClamped() {
        let huge = Double(AltScreenScroll.maxCellsPerEmit + 100) * cell
        let r = AltScreenScroll.wheelEvents(totalDy: huge, cellHeight: cell, emittedCells: 0)
        XCTAssertEqual(r.runs, [ArrowRun(direction: .up, count: AltScreenScroll.maxCellsPerEmit)])
        XCTAssertEqual(r.newEmittedCells, AltScreenScroll.maxCellsPerEmit)
    }
    // Guard: zero cellHeight -> nothing (fail closed).
    func testWheelZeroCellHeightEmitsNothing() {
        let r = AltScreenScroll.wheelEvents(totalDy: 100, cellHeight: 0, emittedCells: 0)
        XCTAssertEqual(r.runs, [])
        XCTAssertEqual(r.newEmittedCells, 0)
    }
    // Wheel gain is 1.0, NOT scrollGain: a 1-cell drag emits exactly 1 (arrows at 1.8 emit 1 too,
    // but a 2-cell drag distinguishes them: wheel=2, arrows=Int(2*1.8)=3).
    func testWheelGainIsOnePointZeroNotScrollGain() {
        let w = AltScreenScroll.wheelEvents(totalDy: 2 * cell, cellHeight: cell, emittedCells: 0)
        XCTAssertEqual(w.runs.first?.count, 2)                    // gain 1.0
        let a = AltScreenScroll.arrows(totalDy: 2 * cell, cellHeight: cell, emittedCells: 0)
        XCTAssertEqual(a.runs.first?.count, Int(2 * AltScreenScroll.scrollGain))  // gain 1.8 -> 3
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter AltScreenScrollTests`
Expected: FAIL (compile error: `wheelEvents` not defined).

- [ ] **Step 3: Implement** — in `AltScreenScroll.swift`, factor the shared delta math and add `wheelEvents`. Replace the body of `arrows(...)` and add the helper + `wheelEvents`:

```swift
    /// Signed cell delta since last emit, clamped to `maxCellsPerEmit`. Shared by `arrows`
    /// (gain = scrollGain) and `wheelEvents` (gain = 1.0). Returns nil when there is nothing to
    /// emit (non-positive cellHeight, or no new whole-cell movement since `emittedCells`).
    private static func signedCellDelta(totalDy: Double, cellHeight: Double,
                                        emittedCells: Int, gain: Double) -> (delta: Int, newEmitted: Int)? {
        guard cellHeight > 0 else { return nil }
        let target = Int(totalDy * gain / cellHeight)
        var delta = target - emittedCells
        if delta == 0 { return nil }
        if delta > maxCellsPerEmit { delta = maxCellsPerEmit }
        if delta < -maxCellsPerEmit { delta = -maxCellsPerEmit }
        return (delta, emittedCells + delta)
    }

    public static func arrows(totalDy: Double,
                              cellHeight: Double,
                              emittedCells: Int) -> (runs: [ArrowRun], newEmittedCells: Int) {
        guard let (delta, newEmitted) = signedCellDelta(totalDy: totalDy, cellHeight: cellHeight,
                                                        emittedCells: emittedCells, gain: scrollGain)
        else { return ([], emittedCells) }
        // +Δy (down) = UP arrows: negate the row delta for arrowEvents.
        return (arrowEvents(cols: 0, rows: -delta), newEmitted)
    }

    /// Turn an in-progress alt-screen vertical drag into vertical wheel-event runs (the Blink
    /// model): gain FIXED at 1.0 (one line-height of travel = one wheel event ≈ one line in the
    /// app), same incremental + flood-clamp accounting as `arrows`. Runs are `.up`/`.down` only;
    /// the App stamps each with the drag-point coordinate at encode time. Finger DOWN (+Δy) =
    /// wheel UP (scroll back), matching the arrows convention.
    public static func wheelEvents(totalDy: Double,
                                   cellHeight: Double,
                                   emittedCells: Int) -> (runs: [ArrowRun], newEmittedCells: Int) {
        guard let (delta, newEmitted) = signedCellDelta(totalDy: totalDy, cellHeight: cellHeight,
                                                        emittedCells: emittedCells, gain: 1.0)
        else { return ([], emittedCells) }
        return (arrowEvents(cols: 0, rows: -delta), newEmitted)
    }
```

(Delete the old inline body of `arrows` that this replaces.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter AltScreenScrollTests`
Expected: PASS (new wheel tests + all pre-existing `arrows` tests still green — the refactor is behavior-preserving).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Terminal/AltScreenScroll.swift Tests/SemicolynKitTests/AltScreenScrollTests.swift
git commit -m "feat(kit): AltScreenScroll.wheelEvents (gain 1.0) + shared signed-delta helper"
```

---

## Task 2: SGR wheel byte encoder (Kit)

**Files:**
- Modify: `Sources/SemicolynKit/Terminal/ArrowEncoding.swift`
- Test: `Tests/SemicolynKitTests/ArrowEncodingTests.swift` (create if absent)

**Interfaces:**
- Consumes: `ArrowRun` (`.up`/`.down` direction + count), `ArrowDirection`.
- Produces: `func encodeWheelRun(_ run: ArrowRun, col: Int, row: Int) -> [UInt8]` — `ESC [ < Cb ; col ; row M` repeated `count` times; `Cb` = 64 (`.up`) / 65 (`.down`); horizontal directions → empty.

- [ ] **Step 1: Write the failing test** — create/append `Tests/SemicolynKitTests/ArrowEncodingTests.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class WheelEncodingTests: XCTestCase {
    // SGR wheel-up at col 3, row 5: ESC [ < 6 4 ; 3 ; 5 M
    func testWheelUpBytes() {
        let bytes = encodeWheelRun(ArrowRun(direction: .up, count: 1), col: 3, row: 5)
        XCTAssertEqual(bytes, Array("\u{1b}[<64;3;5M".utf8))
    }
    // Wheel-down uses button 65 (swap-detecting: differs from up).
    func testWheelDownBytes() {
        let bytes = encodeWheelRun(ArrowRun(direction: .down, count: 1), col: 3, row: 5)
        XCTAssertEqual(bytes, Array("\u{1b}[<65;3;5M".utf8))
        XCTAssertNotEqual(bytes, encodeWheelRun(ArrowRun(direction: .up, count: 1), col: 3, row: 5))
    }
    // count repeats the event exactly count times.
    func testWheelCountRepeats() {
        let one = encodeWheelRun(ArrowRun(direction: .up, count: 1), col: 1, row: 1)
        let three = encodeWheelRun(ArrowRun(direction: .up, count: 3), col: 1, row: 1)
        XCTAssertEqual(three, one + one + one)
    }
    // Multi-digit coordinates render as decimal.
    func testWheelMultiDigitCoords() {
        let bytes = encodeWheelRun(ArrowRun(direction: .down, count: 1), col: 80, row: 40)
        XCTAssertEqual(bytes, Array("\u{1b}[<65;80;40M".utf8))
    }
    // count 0 or horizontal -> empty.
    func testWheelZeroAndHorizontalEmpty() {
        XCTAssertEqual(encodeWheelRun(ArrowRun(direction: .up, count: 0), col: 1, row: 1), [])
        XCTAssertEqual(encodeWheelRun(ArrowRun(direction: .left, count: 2), col: 1, row: 1), [])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter WheelEncodingTests`
Expected: FAIL (`encodeWheelRun` not defined).

- [ ] **Step 3: Implement** — append to `ArrowEncoding.swift`:

```swift
/// Encode one vertical `ArrowRun` as SGR mouse-wheel event bytes, `count` times:
/// `ESC [ < Cb ; col ; row M`, where Cb = 64 (`.up`) / 65 (`.down`). Press-only (SGR wheel
/// sends no release). `col`/`row` are 1-based cell coordinates (the drag point). Horizontal
/// directions have no wheel analog -> empty. This is the Blink-validated alt-screen scroll
/// mechanism: many terminal apps (Claude/vim/less) scroll ~one line per wheel event.
public func encodeWheelRun(_ run: ArrowRun, col: Int, row: Int) -> [UInt8] {
    guard run.count > 0 else { return [] }
    let button: Int
    switch run.direction {
    case .up:   button = 64
    case .down: button = 65
    case .left, .right: return []
    }
    let one = Array("\u{1b}[<\(button);\(col);\(row)M".utf8)
    var out: [UInt8] = []
    out.reserveCapacity(one.count * run.count)
    for _ in 0..<run.count { out.append(contentsOf: one) }
    return out
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter WheelEncodingTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Terminal/ArrowEncoding.swift Tests/SemicolynKitTests/ArrowEncodingTests.swift
git commit -m "feat(kit): encodeWheelRun — SGR mouse-wheel event bytes (ESC[<64/65;col;rowM)"
```

---

## Task 3: Collapse AltScrollMode to 2 cases + wheel-default decider (Kit)

**Files:**
- Modify: `Sources/SemicolynKit/Terminal/AltScrollMode.swift`
- Test: `Tests/SemicolynKitTests/AltScrollDeciderTests.swift` (rewrite)

**Interfaces:**
- Consumes: `AltScrollRegistry` (`wantsPageKeys(command:)`).
- Produces:
  - `enum AltScrollKeys: Sendable, Equatable { case arrows, pageKeys, wheel }`
  - `enum AltScrollMode: String, Sendable, CaseIterable, Codable { case wheel, pageKeysArrows }`
  - `altScrollDecision(mode:paneCommand:windowTitle:registry:)` returns `keys=.wheel reason="wheel"` in `.wheel` mode (any app); registry logic (`claude→pageKeys`, else `arrows`) in `.pageKeysArrows`.
  - `altScrollKeys(...)` wrapper unchanged in shape.
  - Reasons: `"wheel"`, `"fallback:registered"`, `"fallback:unregistered"`.

- [ ] **Step 1: Rewrite the decider tests** — REPLACE the entire body of `AltScrollDeciderTests.swift` (the legacy 4-mode cases no longer compile) with:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class AltScrollDeciderTests: XCTestCase {
    let reg = AltScrollRegistry.bundledDefault

    private func decide(_ mode: AltScrollMode, cmd: String?) -> AltScrollDecision {
        altScrollDecision(mode: mode, paneCommand: cmd, windowTitle: nil, registry: reg)
    }

    // .wheel: EVERY app -> wheel, regardless of command (app-agnostic universal scroll).
    func testWheelModeAlwaysWheel() {
        for cmd in ["claude", "bash", nil] {
            let d = decide(.wheel, cmd: cmd)
            XCTAssertEqual(d.keys, .wheel, "cmd=\(cmd ?? "nil")")
            XCTAssertEqual(d.reason, "wheel")
        }
    }

    // .pageKeysArrows: registered AI-CLI -> pageKeys.
    func testFallbackRegisteredIsPageKeys() {
        let d = decide(.pageKeysArrows, cmd: "claude")
        XCTAssertEqual(d.keys, .pageKeys)
        XCTAssertEqual(d.reason, "fallback:registered")
    }
    // .pageKeysArrows: unregistered app -> arrows.
    func testFallbackUnregisteredIsArrows() {
        let d = decide(.pageKeysArrows, cmd: "bash")
        XCTAssertEqual(d.keys, .arrows)
        XCTAssertEqual(d.reason, "fallback:unregistered")
    }
    // .pageKeysArrows: nil command -> arrows (raw/mosh, no signal). NEGATIVE: not pageKeys.
    func testFallbackNilCommandIsArrows() {
        let d = decide(.pageKeysArrows, cmd: nil)
        XCTAssertEqual(d.keys, .arrows)
        XCTAssertEqual(d.reason, "fallback:unregistered")
    }

    // logLine self-contained.
    func testWheelLogLine() {
        XCTAssertEqual(decide(.wheel, cmd: "claude").logLine,
                       "mode=wheel app=claude → keys=wheel reason=wheel")
    }

    // Wrapper round-trip: altScrollKeys == altScrollDecision(...).keys for every mode.
    func testWrapperMatchesDecisionKeys() {
        for mode in AltScrollMode.allCases {
            for cmd in ["claude", "bash", nil] {
                XCTAssertEqual(
                    altScrollKeys(mode: mode, paneCommand: cmd, windowTitle: nil, registry: reg),
                    altScrollDecision(mode: mode, paneCommand: cmd, windowTitle: nil, registry: reg).keys,
                    "drift mode=\(mode) cmd=\(cmd ?? "nil")")
            }
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter AltScrollDeciderTests`
Expected: FAIL (compile: `.wheel`/`.pageKeysArrows` not defined).

- [ ] **Step 3: Implement** — in `AltScrollMode.swift`, replace the enums (lines 6-14) and the decider (lines 46-70):

```swift
/// How an alt-screen scroll gesture synthesizes input. Two mutually-exclusive modes.
public enum AltScrollMode: String, Sendable, CaseIterable, Codable {
    case wheel           // synthesize SGR mouse-wheel events for every alt-screen app [DEFAULT]
    case pageKeysArrows  // FALLBACK: arrows (less/vim) vs PgUp/PgDn (registered AI-CLIs)
}

/// The input family an alt-screen drag emits.
public enum AltScrollKeys: Sendable, Equatable { case arrows, pageKeys, wheel }
```

and the decider:

```swift
/// The pure alt-scroll decision the App snapshots once at drag `.began`. `.wheel` (default) is
/// app-agnostic: every alt-screen app scrolls via synthetic mouse-wheel events (the Blink model,
/// ~1 line each). `.pageKeysArrows` is the fallback for setups where wheel bytes do not reach the
/// app under tmux -CC: registered AI-CLIs -> PgUp/PgDn, everything else -> arrows.
/// - windowTitle: retained for signature stability; not consulted in either current mode.
public func altScrollDecision(mode: AltScrollMode,
                              paneCommand: String?,
                              windowTitle: String?,
                              registry: AltScrollRegistry) -> AltScrollDecision {
    let (keys, reason): (AltScrollKeys, String)
    switch mode {
    case .wheel:
        (keys, reason) = (.wheel, "wheel")
    case .pageKeysArrows:
        let page = registry.wantsPageKeys(command: paneCommand)
        (keys, reason) = (page ? .pageKeys : .arrows,
                          page ? "fallback:registered" : "fallback:unregistered")
    }
    return AltScrollDecision(keys: keys, mode: mode, paneCommand: paneCommand, reason: reason)
}
```

(The `altScrollKeys(...)` wrapper below is unchanged. `_ = windowTitle` is not needed — the param is simply unused now; keep it for signature stability, Swift does not warn on unused function params.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter AltScrollDeciderTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Terminal/AltScrollMode.swift Tests/SemicolynKitTests/AltScrollDeciderTests.swift
git commit -m "feat(kit): AltScrollMode -> {wheel default, pageKeysArrows fallback}; wheel-agnostic decider"
```

---

## Task 4: TerminalSettings default + legacy migration (Kit)

**Files:**
- Modify: `Sources/SemicolynKit/Terminal/TerminalSettings.swift`
- Test: the existing settings Codable test file (find with `grep -rln "altScrollMode" Tests/`; likely `TerminalSettingsTests.swift`).

**Interfaces:**
- Consumes: `AltScrollMode` (now `{wheel, pageKeysArrows}`).
- Produces: `TerminalSettings.altScrollMode` defaults to `.wheel`; a legacy persisted raw string (`off`/`auto`/`alwaysPageKeys`/`autoPlusTitle`, or anything not decodable to the 2-case enum) migrates to `.wheel` without throwing.

- [ ] **Step 1: Write the failing migration test** — add to the settings Codable test file:

```swift
    // Migration: a settings blob persisted with a LEGACY altScrollMode ("auto") must decode to
    // .wheel (the new default) AND preserve every other field at its non-default value. The
    // 4-case modes no longer exist; decodeIfPresent on the new 2-case enum would throw on the
    // unknown string, so the migration must swallow it and fall back to .wheel.
    func testLegacyAltScrollModeMigratesToWheel() throws {
        let json = """
        {"fontSize":18,"cursorStyle":"bar","cursorBlink":true,"scrollbackLines":9000,
         "fontFace":{"family":"JetBrains Mono","style":"Regular"},"altScrollMode":"auto"}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(TerminalSettings.self, from: json)
        XCTAssertEqual(s.altScrollMode, .wheel)            // legacy "auto" -> wheel
        XCTAssertEqual(s.fontSize, 18)                     // other fields preserved
        XCTAssertEqual(s.cursorBlink, true)
        XCTAssertEqual(s.scrollbackLines, 9000)
    }

    // A blob with a VALID new mode round-trips unchanged.
    func testValidAltScrollModePreserved() throws {
        let json = #"{"altScrollMode":"pageKeysArrows"}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(TerminalSettings.self, from: json)
        XCTAssertEqual(s.altScrollMode, .pageKeysArrows)
    }
```

(If the test file references the `fontFace` JSON shape differently, match the existing tests' shape; the load-bearing assertion is `altScrollMode "auto" -> .wheel` with other fields intact.)

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TerminalSettingsTests`
Expected: FAIL — `decodeIfPresent(AltScrollMode…)` throws on `"auto"` (unknown case), or the default is still `.auto` (which no longer exists → compile error first). Fix the default first (Step 3) if it is a compile error, then the test shows the throw.

- [ ] **Step 3: Implement** — in `TerminalSettings.swift`:

  (a) Change the memberwise-init default (line 94): `altScrollMode: AltScrollMode = .wheel`.

  (b) Replace the decode line (line 119) with a migration that tolerates a legacy/unknown raw string:

```swift
        // altScrollMode migrated to a 2-case enum (wheel/pageKeysArrows). A blob persisted with a
        // legacy 4-case value (off/auto/alwaysPageKeys/autoPlusTitle) would throw on the new enum,
        // so decode the raw string and map anything not in the new set to .wheel (the new default).
        // Pre-release migration: no back-compat burden, a clean remap to the default is correct.
        if let raw = try c.decodeIfPresent(String.self, forKey: .altScrollMode),
           let mode = AltScrollMode(rawValue: raw) {
            self.altScrollMode = mode
        } else {
            self.altScrollMode = .wheel
        }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TerminalSettingsTests`
Expected: PASS. Also run the FULL suite to catch any other `AltScrollMode` switch that no longer compiles:
`HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: all green (any remaining `.off/.auto/...` reference in Kit is a compile error to fix here).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Terminal/TerminalSettings.swift Tests/SemicolynKitTests/TerminalSettingsTests.swift
git commit -m "feat(kit): default altScrollMode .wheel + migrate legacy 4-case values to .wheel"
```

---

## Task 5: Gesture-controller wheel branch + coordinates (App)

**Files:**
- Modify: `App/TerminalGestureController.swift` (the `handleAltScreenPan` `.changed` case)

**Interfaces:**
- Consumes: `AltScreenScroll.wheelEvents(...)`, `encodeWheelRun(_:col:row:)`, `AltScrollKeys.wheel`, `dragDecision`.
- Produces: wheel bytes emitted via `callbacks.sendBytes`; `drag-move ... coord=(col,row)` log.
- Note: App tier — NOT locally buildable; macOS-CI + device gated.

- [ ] **Step 1: Replace the `.changed` emit block** — in `handleAltScreenPan`, replace the `.changed` case body (the `let cellH … drag-move …` block) with:

```swift
        case .changed:
            guard dragMode == .appOwnsInput else { return }
            let term = view.getTerminal()
            let cols = max(term.cols, 1), rows = max(term.rows, 1)
            let cellH = view.bounds.height / CGFloat(rows)
            let cellW = view.bounds.width / CGFloat(max(cols, 1))
            let loc = g.location(in: view)
            // 1-based cell coordinate of the drag point, clamped to the pane (SGR coords are 1-based).
            let col = min(max(1, Int(loc.x / max(cellW, 1)) + 1), cols)
            let row = min(max(1, Int(loc.y / max(cellH, 1)) + 1), rows)
            let dy = Double(g.translation(in: view).y)
            var sent = 0
            switch dragDecision.keys {
            case .wheel:
                let (runs, newEmitted) = AltScreenScroll.wheelEvents(
                    totalDy: dy, cellHeight: Double(cellH), emittedCells: emittedCells)
                emittedCells = newEmitted
                for run in runs {
                    let bytes = encodeWheelRun(run, col: col, row: row)
                    if !bytes.isEmpty { callbacks.sendBytes(bytes); sent += run.count }
                }
                if !runs.isEmpty {
                    DebugLog.shared.log(.gesture,
                        "drag-move keys=wheel runs=\(runs.count) sent=\(sent) total=\(emittedCells) coord=(\(col),\(row))")
                }
            case .arrows, .pageKeys:
                let (runs, newEmitted) = AltScreenScroll.arrows(
                    totalDy: dy, cellHeight: Double(cellH), emittedCells: emittedCells)
                emittedCells = newEmitted
                for run in runs {
                    let bytes = dragDecision.keys == .pageKeys
                        ? encodePageKeyRun(run)
                        : encodeArrowRun(run, applicationCursorKeys: dragAppCursor)
                    if !bytes.isEmpty { callbacks.sendBytes(bytes); sent += run.count }
                }
                if !runs.isEmpty {
                    DebugLog.shared.log(.gesture,
                        "drag-move keys=\(dragDecision.keys) runs=\(runs.count) sent=\(sent) total=\(emittedCells)")
                }
            }
```

  (This preserves the existing arrows/pageKeys behavior verbatim under the `.arrows/.pageKeys` branch and adds the `.wheel` branch. `emittedCells`, `dragDecision`, `dragAppCursor` are the existing controller fields.)

- [ ] **Step 2: Verify by reading (no local build)** — confirm: (a) `emittedCells` is assigned in both branches; (b) `.wheel` uses `encodeWheelRun` with the computed `col`/`row`; (c) the `.ended` outcome computation below still reads `emittedCells` (unchanged); (d) no reference to a removed symbol; (e) the `drag-move` log for wheel includes `coord=`. Grep: `grep -n "wheelEvents\|encodeWheelRun\|coord=" App/TerminalGestureController.swift`.

- [ ] **Step 3: Update the `.ended` outcome to name wheel** — in the same handler's `.ended` case, the `outcome` currently maps pageKeys/arrows. Extend it:

```swift
            let outcome: String
            if emittedCells != 0 {
                switch dragDecision.keys {
                case .wheel:    outcome = "wheel"
                case .pageKeys: outcome = "pageKeys"
                case .arrows:   outcome = "arrows"
                }
            } else {
                outcome = "none"
            }
```

  (Note `emittedCells != 0`, not `> 0`: an up-drag leaves a negative total but still scrolled.)

- [ ] **Step 4: Commit**

```bash
git add App/TerminalGestureController.swift
git commit -m "feat(terminal): emit SGR wheel events on alt-screen drag (wheel mode); coord in drag-move log"
```

---

## Task 6: Experimental settings two-row picker (App)

**Files:**
- Modify: `App/ExperimentalSettingsView.swift`

**Interfaces:**
- Consumes: `AltScrollMode.{wheel, pageKeysArrows}`.
- Produces: a 2-row inline picker + footers; keeps `.labelsHidden()` + the `user-action: mode-switch` `.lifecycle` log.

- [ ] **Step 1: Replace the 4-tag Picker** — replace the `Picker(...) { Text(...).tag(AltScrollMode.off) … }` block (the four `.tag` rows) with two:

```swift
                Picker("Alt-screen scroll", selection: $store.settings.altScrollMode) {
                    Text("Line scroll (mouse wheel)").tag(AltScrollMode.wheel)
                    Text("Fallback (Page/arrow keys)").tag(AltScrollMode.pageKeysArrows)
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .onChange(of: store.settings.altScrollMode) { _, newValue in
                    DebugLog.shared.log(.lifecycle, "user-action: mode-switch \(newValue.rawValue)")
                }
```

  and replace the footer text with:

```swift
            } footer: {
                Text("""
                Line scroll: sends mouse-wheel events so full-screen apps (Claude, vim, less) \
                scroll one line at a time, like Blink. If an app does not respond to it, switch \
                to Fallback. Fallback: arrow keys for less/vim, PgUp/PgDn for AI CLIs (older method).
                """)
            }
```

  (Keep the `header: { Text("Alt-screen scroll") }` and the section structure exactly as shipped in the flatten/labelsHidden work.)

- [ ] **Step 2: Verify by reading** — grep confirms no `.off/.auto/.alwaysPageKeys/.autoPlusTitle` tag remains: `grep -n "AltScrollMode\." App/ExperimentalSettingsView.swift` should show only `.wheel` and `.pageKeysArrows`.

- [ ] **Step 3: Commit**

```bash
git add App/ExperimentalSettingsView.swift
git commit -m "feat(settings): alt-scroll picker -> Line scroll (wheel) / Fallback (page-arrows)"
```

---

## Task 7: Retest note (docs)

**Files:**
- Modify: `TODO.md`

- [ ] **Step 1: Add the retest procedure** — add under the alt-scroll section:

```markdown
### Wheel-scroll retest (the -CC unknown)
Enable Gesture logging (Settings > Diagnostics > Gesture). Drag to scroll a Claude pane:
- EXPECT: `drag-move keys=wheel runs=… coord=(c,r)` in the trace, and Claude's transcript
  scrolls ~one line per line-height of drag (crisp, not half-screen jumps).
- IF Claude does NOT scroll: our synthetic wheel bytes are not reaching the app under tmux -CC.
  Switch Settings > Experimental > Alt-screen scroll to "Fallback" and confirm PgUp/arrows still
  scroll (isolates the -CC-drops-wheel case). If wheel fails, plan B = the local-scrollback-buffer
  project (docs: tmux-cc-scrollback-architecture).
Also verify less/vim scroll one line per line-height in wheel mode.
```

- [ ] **Step 2: Commit**

```bash
git add TODO.md
git commit -m "docs(todo): wheel-scroll retest procedure (-CC wheel-forwarding unknown)"
```

---

## Self-Review

**Spec coverage:**
- §1 wheel mechanism (wheelEvents gain 1.0, shared delta) → Task 1. ✓
- §1 encodeWheelRun → Task 2. ✓
- §1 `AltScrollKeys.wheel` → Task 3. ✓
- §2 `AltScrollMode` 2-case + wheel-default decider + registry-only-in-fallback → Task 3. ✓
- §2 migration legacy → `.wheel` → Task 4. ✓
- §3 gesture-controller wheel branch + coord math + `drag-move coord=` → Task 5. ✓
- §4 two-row picker → Task 6. ✓
- Testing (wheelEvents, encodeWheelRun, decider 2-case, migration) → Tasks 1,2,3,4. ✓
- Retest note → Task 7. ✓
- Implementation note (4→2 sweep) → covered by Task 3 (decider) + Task 4 full-suite compile check + Task 6 (picker) + Task 3 test rewrite.

**Placeholder scan:** none (`<SettingsTestSuite>` / `TerminalSettingsTests.swift` is a lookup instruction with the exact grep given, not a code placeholder; the load-bearing assertion is spelled out).

**Type consistency:**
- `wheelEvents(totalDy:cellHeight:emittedCells:) -> ([ArrowRun], Int)` — same shape as `arrows`; used in Task 5 identically. ✓
- `encodeWheelRun(_:col:row:)` — defined Task 2, called Task 5 with the computed `col`/`row`. ✓
- `AltScrollKeys` now 3 cases (`arrows, pageKeys, wheel`) — the Task 5 `.ended` switch (Task 5 Step 3) is exhaustive over all 3. ✓
- `AltScrollMode` 2 cases — Task 3 decider switch exhaustive; Task 6 picker has exactly 2 tags; Task 4 migration handles unknown-string → `.wheel`. ✓
- `reason` strings (`wheel`/`fallback:registered`/`fallback:unregistered`) — asserted in Task 3 tests, produced in Task 3 decider. ✓

Fixed inline: none needed. Plan complete.
