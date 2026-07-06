<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Plan A — Testable Seams (extraction + View-only gate) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract the one remaining genuinely-trapped pure decision (window-step wrap math) into Linux-testable Kit, and add a lightweight guard that keeps pure logic from re-accumulating in the App tier.

**Architecture:** The app already follows the Humble-Object seam ~90% (four of the five audited units — cursor geometry, arrow encoding, title policy, mosh classification — are already extracted+tested in `Sources/SemicolynKit/`). Plan A closes the last gap (`stepWindow`) and installs a `lint`-tier regression guard. All of Plan A is verifiable on the Linux `swift test` + `lint` jobs; no macOS-only surface.

**Tech Stack:** Swift 6 (strict concurrency, `Sendable`), XCTest, Docker dev image `semicolyn-dev`, a shell/grep lint script wired into CI.

## Global Constraints

- Every source file carries an SPDX header: `// SPDX-FileCopyrightText: 2026 True Positive LLC` then `// SPDX-License-Identifier: GPL-3.0-only` (REUSE-compliant).
- `Sources/SemicolynKit/` is pure/Linux-tested: Swift 6 strict-concurrency, `Sendable`, **no `import UIKit`/`SwiftUI`/`CryptoKit`**.
- Tests must be real (repo standard `docs/superpowers/specs/2026-06-18-testing-standards-design.md`): EP + BVA, assert observable values (no tautologies); a negative/boundary test asserts the *specific* expected value, never "no crash"/"is-ok".
- Conventional commits (`feat:`/`fix:`/`refactor:`/`docs:`/`test:`/`ci:`). Work on branch `feat/testable-seams-verification`; squash-merge to `main`.
- Linux fast loop runs in Docker: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`. There is NO Swift toolchain on the host.

---

### Task 1: Extract `WindowNavigation.stepIndex` (window-step wrap math)

**Files:**
- Create: `Sources/SemicolynKit/Tmux/WindowNavigation.swift`
- Create: `Tests/SemicolynKitTests/WindowNavigationTests.swift`
- Modify: `App/ConnectionViewModel.swift:247-253` (`stepWindow` calls the pure fn)

**Interfaces:**
- Consumes: nothing (leaf pure function).
- Produces: `public func stepIndex(current: Int, delta: Int, count: Int) -> Int?` in `SemicolynKit` — returns the wrapped destination index, or `nil` when navigation is a no-op (`count <= 1`, or `current` out of range). The App maps the returned index → `windows[index].id`.

- [ ] **Step 1: Write the failing test**

Create `Tests/SemicolynKitTests/WindowNavigationTests.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Pure wrap-around arithmetic behind `⌘]`/`⌘[` and Esc-pill swipe window stepping.
final class WindowNavigationTests: XCTestCase {
    // EP: forward/backward within range.
    func testForwardStepMovesToNextIndex() {
        XCTAssertEqual(stepIndex(current: 0, delta: +1, count: 3), 1)
    }

    func testBackwardStepMovesToPreviousIndex() {
        XCTAssertEqual(stepIndex(current: 2, delta: -1, count: 3), 1)
    }

    // BVA: wrap at the high boundary (last → first).
    func testForwardStepWrapsPastLast() {
        XCTAssertEqual(stepIndex(current: 2, delta: +1, count: 3), 0)
    }

    // BVA: wrap at the low boundary (first → last), incl. negative-modulo correctness.
    func testBackwardStepWrapsBeforeFirst() {
        XCTAssertEqual(stepIndex(current: 0, delta: -1, count: 3), 2)
    }

    // BVA: exactly two windows toggles.
    func testTwoWindowsToggle() {
        XCTAssertEqual(stepIndex(current: 0, delta: +1, count: 2), 1)
        XCTAssertEqual(stepIndex(current: 1, delta: +1, count: 2), 0)
    }

    // Negative: a single window is a no-op (nil), not index 0 spuriously.
    func testSingleWindowIsNoOp() {
        XCTAssertNil(stepIndex(current: 0, delta: +1, count: 1))
    }

    // Negative: zero windows is a no-op.
    func testZeroWindowsIsNoOp() {
        XCTAssertNil(stepIndex(current: 0, delta: +1, count: 0))
    }

    // Negative: an out-of-range current index is a no-op (guards stale state).
    func testOutOfRangeCurrentIsNoOp() {
        XCTAssertNil(stepIndex(current: 5, delta: +1, count: 3))
        XCTAssertNil(stepIndex(current: -1, delta: +1, count: 3))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter WindowNavigationTests`
Expected: FAIL to compile — `cannot find 'stepIndex' in scope`.

- [ ] **Step 3: Write the minimal implementation**

Create `Sources/SemicolynKit/Tmux/WindowNavigation.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Wrap-around destination index for stepping between tmux windows (`⌘]`/`⌘[`,
/// Esc-pill swipe). Returns the destination index, or `nil` when stepping is a
/// no-op: fewer than two windows, or a `current` index outside `0..<count`
/// (guards against stale published state). `delta` is typically ±1 but any
/// integer wraps correctly, including negative modulo.
public func stepIndex(current: Int, delta: Int, count: Int) -> Int? {
    guard count > 1, current >= 0, current < count else { return nil }
    return ((current + delta) % count + count) % count
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter WindowNavigationTests`
Expected: PASS (8 test methods).

- [ ] **Step 5: Rewrite the App call site to use the pure fn**

Modify `App/ConnectionViewModel.swift` — replace the body of `stepWindow` (lines ~247-253) with:

```swift
    private func stepWindow(_ delta: Int) {
        guard let state = tmuxState,
              let active = state.activeWindow,
              let idx = state.windows.firstIndex(where: { $0.id == active }),
              let next = stepIndex(current: idx, delta: delta, count: state.windows.count)
        else { return }
        selectWindow(state.windows[next].id)
    }
```

(The `count > 1` guard now lives inside `stepIndex`, so it is removed from the App-side `guard`.)

- [ ] **Step 6: Commit**

```bash
git add Sources/SemicolynKit/Tmux/WindowNavigation.swift \
        Tests/SemicolynKitTests/WindowNavigationTests.swift \
        App/ConnectionViewModel.swift
git commit -m "refactor(kit): extract window-step wrap math to WindowNavigation.stepIndex + BVA tests"
```

Note: the `App/ConnectionViewModel.swift` change compiles only on the macOS CI job; the Kit function + tests are the Linux-verifiable deliverable. Do not block the commit on a local App build (there is no Swift toolchain able to build the App target on the host or in the Linux dev image).

---

### Task 2: View-only gate (anti-regression lint)

**Files:**
- Create: `scripts/check-app-view-only.sh`
- Modify: `.github/workflows/ci.yml` (add a step to the existing `lint` job)
- Create: `docs/app-view-only-gate.md` (rationale + how to satisfy/allowlist)

**Interfaces:**
- Consumes: nothing.
- Produces: an executable `scripts/check-app-view-only.sh` that exits non-zero when an `App/**.swift` file contains a pure-logic smell not on the allowlist, printing `file:line` + a pointer to move the logic to `Sources/SemicolynKit/`.

- [ ] **Step 1: Write the failing check (test-first via a fixture)**

The script's "test" is a self-check block it runs when invoked with `--selftest`: it greps two inline fixtures (one clean, one dirty) and asserts the exit codes. Create `scripts/check-app-view-only.sh`:

```bash
#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 True Positive LLC
# SPDX-License-Identifier: GPL-3.0-only
#
# View-only gate: fail if an App/**.swift file contains pure decision logic that
# belongs in Sources/SemicolynKit/. Heuristic + allowlisted; see
# docs/app-view-only-gate.md. Low-false-positive by design — flag only the
# clearest smells (free-function value-returning math on plain Int/Double).
set -euo pipefail

APP_DIR="${1:-App}"

# Smell: a private/free func returning a scalar computed from scalar args with a
# modulo/arithmetic body — the window-step class. Extended cautiously over time.
# Allowlist: SwiftUI/UIKit wiring never matches because it returns View/Void or
# touches self./view./@Published — excluded below.
scan() {
  local dir="$1"
  # -P: Perl regex; match a func returning a bare scalar (`-> Int|Double|Bool {`),
  # then subtract the wiring allowlist: methods that touch `self.`/`view.`, carry
  # an attribute (`@`), return/compose SwiftUI (`View`/`Binding`/`some `), or take
  # a UIKit / gesture / capitalized-type parameter (delegate & gesture handlers).
  # Verified 2026-07-06 against the real App tree: flags the window-step math class,
  # excludes `gestureRecognizerShouldBegin(_:UIGestureRecognizer)->Bool` & bindings.
  grep -rnP --include='*.swift' \
    'func\s+\w+\([^)]*\)\s*->\s*(Int|Double|Bool)\s*\{' "$dir" 2>/dev/null \
    | grep -vP '(self\.|view\.|@|View|Binding|some |UI[A-Z]\w+|Gesture|Recognizer|_ [a-z]\w*: [A-Z])' || true
}

selftest() {
  local tmp; tmp="$(mktemp -d)"
  cat >"$tmp/Clean.swift" <<'SW'
struct V { var body: some View { Text("hi") }
  func makeBinding() -> Binding<Int> { .constant(0) } }
SW
  cat >"$tmp/Dirty.swift" <<'SW'
func wrap(current: Int, count: Int) -> Int {
  return (current + 1) % count
}
SW
  local dirty_hits clean_hits
  dirty_hits="$(scan "$tmp/Dirty.swift" | wc -l | tr -d ' ')"
  clean_hits="$(scan "$tmp/Clean.swift" | wc -l | tr -d ' ')"
  rm -rf "$tmp"
  [ "$dirty_hits" -ge 1 ] || { echo "SELFTEST FAIL: dirty fixture not flagged"; exit 1; }
  [ "$clean_hits" -eq 0 ] || { echo "SELFTEST FAIL: clean fixture false-positived"; exit 1; }
  echo "selftest OK"
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit 0; fi

hits="$(scan "$APP_DIR")"
if [ -n "$hits" ]; then
  echo "View-only gate: pure logic found in App/ — move it to Sources/SemicolynKit/ and unit-test it:" >&2
  echo "$hits" >&2
  echo "(See docs/app-view-only-gate.md. If this is a false positive, refine the allowlist there.)" >&2
  exit 1
fi
echo "View-only gate: clean"
```

- [ ] **Step 2: Make it executable and run the selftest to verify it fails first**

Run:
```bash
chmod +x scripts/check-app-view-only.sh
bash scripts/check-app-view-only.sh --selftest
```
Expected first run: `selftest OK` (the selftest is self-contained; if it prints `SELFTEST FAIL`, the regex is wrong — fix the `scan` function until the dirty fixture is flagged and the clean one is not).

- [ ] **Step 3: Run the gate against the real App tree; confirm it passes after Task 1**

Run: `bash scripts/check-app-view-only.sh App`
Expected: `View-only gate: clean` — because Task 1 already moved the only trapped math out. If it flags anything, that is a *real* finding: either extract it (repeat Task 1's pattern) or, if it is genuinely wiring the regex misread, tighten the `grep -vP` allowlist and note the pattern in `docs/app-view-only-gate.md`.

- [ ] **Step 4: Document the gate**

Create `docs/app-view-only-gate.md`:

```markdown
<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# The View-only gate

`App/**.swift` is a humble View tier: SwiftUI/UIKit/SwiftTerm wiring + `@Published`
state only. Pure decision logic (arithmetic, parsing, validation, value-returning
state machines) belongs in `Sources/SemicolynKit/`, where it is unit-tested on Linux
in ~2 min instead of discovered on-device after a ~40-min CI/TestFlight round-trip.

`scripts/check-app-view-only.sh` (run in the CI `lint` job) flags the clearest smell:
a free/private function that returns a scalar computed by arithmetic and does not
touch `self.`/`view.`/a SwiftUI type. It is deliberately conservative (low false
positive), so it will miss subtler logic — the primary defence is code review; the
gate is the backstop that catches the obvious regressions.

**If flagged:** move the function to `Sources/SemicolynKit/`, give it a test
(EP + BVA, assert exact expected values), and have the View call it. See
`Sources/SemicolynKit/Tmux/WindowNavigation.swift` for the canonical example.

**False positive?** Tighten the allowlist in the `scan()` function's `grep -vP`
and record the excluded pattern here. Do not disable the gate wholesale.

**Escape hatch:** if the gate proves too noisy in practice, downgrade it from a
hard CI failure to an informational `lint`-job annotation (drop the `exit 1`) and
rely on the code-review checklist — this is the spec's documented fallback.
```

- [ ] **Step 5: Wire the gate into the CI `lint` job**

Modify `.github/workflows/ci.yml` — inside the existing `lint` job's steps, after the checkout/`cargo fmt`/clippy steps, add:

```yaml
      - name: View-only gate (App tier has no pure logic)
        run: |
          bash scripts/check-app-view-only.sh --selftest
          bash scripts/check-app-view-only.sh App
```

(Read the current `lint` job first to match its exact indentation and step ordering; the two lines are: run the selftest so a broken regex fails loudly, then run the real gate.)

- [ ] **Step 6: Commit**

```bash
git add scripts/check-app-view-only.sh docs/app-view-only-gate.md .github/workflows/ci.yml
git commit -m "ci(lint): add View-only gate keeping pure logic out of the App tier"
```

Note: pushing a `.github/workflows/` change requires the `gh` `workflow` scope on the token (see the GitHub CI memory). If the push is rejected for scope, surface that to the user rather than retrying.

---

## Self-Review

**1. Spec coverage (Plan A = spec §A1 + §A2):**
- §A1 "extract genuinely-trapped pure units" → Task 1 (corrected to the one real unit, `stepIndex`; the other four are already extracted+tested, documented in the spec amendment). ✅
- §A2 "View-only gate + documented downgrade path" → Task 2 (script + CI wire + `docs/app-view-only-gate.md`, including the explicit escape-hatch/downgrade). ✅
- Plan B scope (ViewModel split, PredictorActor, measurement) is intentionally **not** in this plan — written separately after Plan A lands. ✅

**2. Placeholder scan:** No TBD/TODO/"handle edge cases"/"similar to". Every code step shows complete code and exact `docker compose`/`bash`/`git` commands with expected output. ✅

**3. Type consistency:** `stepIndex(current:delta:count:) -> Int?` is defined identically in Task 1 Interfaces, the test, the implementation, and the App call site. The `nil`-means-no-op contract is consistent across all four. ✅ The View-only gate script name `scripts/check-app-view-only.sh` is identical across Task 2's Files, all steps, `docs/`, and CI. ✅

## Notes carried to Plan B

- The real value/risk lives in Plan B (god-ViewModel split into `SessionCoreModel`/`TmuxViewModel`/`PredictorViewModel`; `PredictorActor` fork of the keystroke path; first `os_signpost` measurement). Plan B is App-tier-heavy → macOS-CI-verified only.
- Plan B is gated on Plan A landing green.
