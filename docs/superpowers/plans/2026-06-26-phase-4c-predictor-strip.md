<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Phase 4c — Predictor Strip Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface the (already-built, Linux-tested) `PredictorEngine` in the live session as a thin auto-hiding suggestion row above the keybar — driven by what the user types, accepted by a tap.

**Architecture:** The engine already does all ranking/learning. 4c adds the missing glue: a pure **`InputTokenTracker`** that reconstructs the current partial token + previous token from the outgoing byte stream (a terminal has no text field, so we watch `sendTerminalInput`), a tiny pure **chip filter**, the `PredictorStripView`, and the session wiring in `ConnectionViewModel` (build the engine from `LearnedStore`/`SeedStore`, observe input → publish suggestions, learn on token commit, harvest command output, accept-by-tap, flush on teardown, honor incognito).

**Tech Stack:** Swift 6 strict concurrency, XCTest on the Linux fast loop (the tracker + filter); SwiftUI + the existing `PredictorEngine`/`LearnedStore`/`SeedStore` + the `sendTerminalInput` byte path for the App tier (macOS-CI-build-validated only).

## Verification reality (unchanged)

The pure tracker + filter (Task 1) are fully Linux-tested. App tasks (2–3) compile only on the macOS CI job (no Simulator) — the strip's appearance/slide animation, chip styling, and tap-to-complete are **not** verifiable by this toolchain; they need the owed Simulator/device pass.

## Global Constraints

- **Two tiers:** pure logic in `Sources/SemicolynKit/` (no `import UIKit`/`SwiftUI`/`CryptoKit`, `Sendable`); App in `App/` (macOS-CI build only).
- **Spec locked:** `docs/superpowers/specs/2026-06-13-predictor-design.md` §"Suggestion surface".
- **Strip surface (verbatim):** thin auto-hiding row **above** the keybar, ~24pt; **auto-hides when there is no suggestion** at/above the confidence floor; ~150ms slide; **cannot reflow the keybar**; pill-shaped accent-colored chips visually distinct from keys; capacity top-K (K=3 default, from `SuggestionConfig.topK`).
- **Never silent:** tapping a chip commits that token; ignoring it changes nothing. The predictor never rewrites typed input.
- **Engine owns ranking + the confidence floor** (`SuggestionConfig`); the strip shows exactly what `suggestions(forPrefix:after:)` returns (minus the exact current token). Do not re-rank in the App.
- **Incognito:** when the resolved per-host predictor-incognito flag is on, the predictor is **disabled for the session** — no engine, no strip, no learning.
- **Theme tokens:** strip uses `theme.predictor.stripBg`/`suggestionBg`/`suggestionText`. Never inline hex.
- **SPDX header on every new file.** Conventional commits; branch `feat/phase-4c-predictor-strip`; squash-merge.
- **Test commands:** `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter <Suite>`.

---

## File Structure

**Created (SemicolynKit, Linux-tested):**
- `Sources/SemicolynKit/Predictor/InputTokenTracker.swift` — `CommittedToken`, `InputTokenTracker`, `predictorChips(...)`.

**Created (App, macOS-CI-only):**
- `App/Keybar/PredictorStripView.swift` — the auto-hiding chip row.

**Modified (App):**
- `App/AppStores.swift` — a `predictorLearnedStore()` + `predictorSeed()` (build from Application Support).
- `App/ConnectionViewModel.swift` — session `PredictorEngine`, input observation, `@Published predictorSuggestions`, `acceptSuggestion`, output harvest, flush on teardown, incognito gate.
- `App/SessionView.swift` — mount `PredictorStripView` directly above the keybar.

**Tests created:** `InputTokenTrackerTests`.

---

## Setup

- [ ] **Step 0: Branch**

```bash
cd /home/djmyers/proj/truepositive/semicolyn
git checkout -b feat/phase-4c-predictor-strip
```

---

### Task 1: InputTokenTracker + chip filter (pure)

**Files:**
- Create: `Sources/SemicolynKit/Predictor/InputTokenTracker.swift`
- Test: `Tests/SemicolynKitTests/InputTokenTrackerTests.swift`

**Interfaces:**
- Produces:
  - `struct CommittedToken: Equatable, Sendable { let token: String; let previous: String? }`
  - `struct InputTokenTracker: Equatable, Sendable { private(set) var current: String; private(set) var previous: String?; init(); mutating func observe(_ bytes: [UInt8]) -> [CommittedToken]; mutating func reset() }`
  - `func predictorChips(current: String, suggestions: [String]) -> [String]`
- `observe` folds raw outgoing bytes: printable `0x21…0x7e` append to `current`; space `0x20` commits `current` (emits `CommittedToken(current, previous)`, shifts `previous = current`, clears `current`); enter `0x0d`/`0x0a` commits then resets the line (`previous = nil`); backspace `0x7f`/`0x08` pops one char; tab `0x09` clears `current` (remote completion incoming — no commit); any other byte (ESC/control) resets the line context (`current = ""`, `previous = nil`). `predictorChips` drops the exact `current` and empty strings.

- [ ] **Step 1: Write the failing tests** (`Tests/SemicolynKitTests/InputTokenTrackerTests.swift`)

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class InputTokenTrackerTests: XCTestCase {
    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    func testTypingBuildsCurrentToken() {
        var t = InputTokenTracker()
        let committed = t.observe(bytes("clau"))
        XCTAssertTrue(committed.isEmpty)
        XCTAssertEqual(t.current, "clau")
        XCTAssertNil(t.previous)
    }

    func testSpaceCommitsAndShiftsPrevious() {
        var t = InputTokenTracker()
        let committed = t.observe(bytes("git "))
        XCTAssertEqual(committed, [CommittedToken(token: "git", previous: nil)])
        XCTAssertEqual(t.current, "")
        XCTAssertEqual(t.previous, "git")
    }

    func testSecondTokenCarriesPreviousForBigram() {
        var t = InputTokenTracker()
        let committed = t.observe(bytes("git commit"))
        XCTAssertEqual(committed, [CommittedToken(token: "git", previous: nil)])
        XCTAssertEqual(t.current, "commit")
        XCTAssertEqual(t.previous, "git")   // drives suggestions(forPrefix:"commit", after:"git")
    }

    func testMultipleTokensInOneChunk() {
        var t = InputTokenTracker()
        let committed = t.observe(bytes("a b c"))
        XCTAssertEqual(committed, [CommittedToken(token: "a", previous: nil),
                                   CommittedToken(token: "b", previous: "a")])
        XCTAssertEqual(t.current, "c")
        XCTAssertEqual(t.previous, "b")
    }

    func testEnterCommitsAndResetsLine() {
        var t = InputTokenTracker()
        _ = t.observe(bytes("git commit"))
        let committed = t.observe([0x0d])
        XCTAssertEqual(committed, [CommittedToken(token: "commit", previous: "git")])
        XCTAssertEqual(t.current, "")
        XCTAssertNil(t.previous)            // new line: no preceding token
    }

    func testBackspacePopsCurrent() {
        var t = InputTokenTracker()
        _ = t.observe(bytes("claude"))
        _ = t.observe([0x7f])
        XCTAssertEqual(t.current, "claud")
    }

    func testTabClearsCurrentWithoutCommitting() {
        var t = InputTokenTracker()
        _ = t.observe(bytes("co"))
        let committed = t.observe([0x09])
        XCTAssertTrue(committed.isEmpty)    // remote completion, not a learned token
        XCTAssertEqual(t.current, "")
    }

    func testControlByteResetsLineContext() {
        var t = InputTokenTracker()
        _ = t.observe(bytes("git commit"))
        _ = t.observe([0x03])              // Ctrl+C
        XCTAssertEqual(t.current, "")
        XCTAssertNil(t.previous)
    }

    func testChipsDropExactCurrentAndEmpties() {
        XCTAssertEqual(predictorChips(current: "clau", suggestions: ["claude", "clang"]),
                       ["claude", "clang"])
        XCTAssertEqual(predictorChips(current: "claude", suggestions: ["claude", "clangd"]),
                       ["clangd"])          // exact current dropped
        XCTAssertEqual(predictorChips(current: "x", suggestions: []), [])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter InputTokenTrackerTests`
Expected: FAIL — `cannot find 'InputTokenTracker' in scope`.

- [ ] **Step 3: Implement `InputTokenTracker.swift`**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// A token committed (completed) on the input line, with the token before it —
/// the unit the predictor learns (`record(token, after: previous)`).
public struct CommittedToken: Equatable, Sendable {
    public let token: String
    public let previous: String?
    public init(token: String, previous: String?) { self.token = token; self.previous = previous }
}

/// Reconstructs the current partial token + the previous token from the raw bytes
/// the user sends to the remote. A terminal has no text field, so the predictor's
/// prefix is derived here by watching the outgoing stream. Pure and best-effort:
/// control sequences (arrows, Ctrl-*) reset the line context rather than tracking
/// cursor motion, and remote-side tab completion (whose result arrives as output)
/// is not reflected — both are acceptable v1 limitations.
public struct InputTokenTracker: Equatable, Sendable {
    /// The token currently being typed (since the last delimiter).
    public private(set) var current: String = ""
    /// The token immediately before `current` on this line (for bigram lookup).
    public private(set) var previous: String?

    public init() {}

    /// Fold one chunk of outgoing bytes. Returns the tokens committed by this chunk
    /// (newest last), in order, for the caller to learn.
    public mutating func observe(_ bytes: [UInt8]) -> [CommittedToken] {
        var committed: [CommittedToken] = []
        for b in bytes {
            switch b {
            case 0x21...0x7e:               // printable, non-space → extend the token
                current.unicodeScalars.append(UnicodeScalar(b))
            case 0x20:                      // space → commit, keep the line
                if !current.isEmpty {
                    committed.append(CommittedToken(token: current, previous: previous))
                    previous = current
                    current = ""
                }
            case 0x0d, 0x0a:                // enter → commit, then new line
                if !current.isEmpty {
                    committed.append(CommittedToken(token: current, previous: previous))
                }
                current = ""
                previous = nil
            case 0x7f, 0x08:                // backspace → pop one char
                if !current.isEmpty { current.removeLast() }
            case 0x09:                      // tab → remote completion: drop the partial
                current = ""
            default:                        // ESC / control → reset line context
                current = ""
                previous = nil
            }
        }
        return committed
    }

    /// Clear all context (e.g. a context/host switch).
    public mutating func reset() { current = ""; previous = nil }
}

/// The chips to show for `current` given the engine's ranked `suggestions`: the
/// engine already prefix-matches, applies the confidence floor, and caps at top-K;
/// the strip only drops the exact token already typed (and any empties).
public func predictorChips(current: String, suggestions: [String]) -> [String] {
    suggestions.filter { $0 != current && !$0.isEmpty }
}
```

- [ ] **Step 4: Run to verify passing**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter InputTokenTrackerTests`
Expected: PASS (9 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Predictor/InputTokenTracker.swift Tests/SemicolynKitTests/InputTokenTrackerTests.swift
git commit -m "feat(predictor): input token tracker + strip chip filter"
```

---

### Task 2: App — predictor session wiring on the view model

**Files:**
- Modify: `App/AppStores.swift`
- Modify: `App/ConnectionViewModel.swift`

**Validation:** App tier — macOS CI build only.

**Interfaces:**
- Consumes: `PredictorEngine`, `LearnedStore`, `SeedStore`, `InputTokenTracker`, `predictorChips`, the existing `sendTerminalInput`, `output: TerminalShellOutput`, the predictor-incognito resolution.
- Produces on `AppStores`: `func predictorLearnedStore() -> LearnedStore` (directory `Application Support/semicolyn/predictor`) and `func predictorSeed() -> PredictorSeed?` (`SeedStore(...).loadSeed()`). On `ConnectionViewModel`: `@Published private(set) var predictorSuggestions: [String]`, `func acceptSuggestion(_ s: String)`, plus private predictor state (`engine`, `tracker`, `learnedStore`) and observation hooks.

- [ ] **Step 1: Add the predictor stores to `AppStores`** — mirror the existing store accessors (read the file for the Application-Support base + conventions):

```swift
    /// The on-device predictor learned-state store (per the predictor spec path).
    func predictorLearnedStore() -> LearnedStore {
        LearnedStore(directory: appSupport.appendingPathComponent("predictor", isDirectory: true))
    }

    /// The bundled/installed predictor seed, or nil if none is installed yet.
    func predictorSeed() -> PredictorSeed? {
        SeedStore(directory: appSupport.appendingPathComponent("predictor", isDirectory: true)).loadSeed()
    }
```

(If `AppStores` exposes its Application-Support base under a different name than `appSupport`, use that; read the file first. `LearnedStore.load()` returns an empty `LearnedState` when no file exists, so no install step is required.)

- [ ] **Step 2: Add predictor session state + observation to `ConnectionViewModel`**

Add the published suggestions + private state near the other session state:

```swift
    /// Top-K predictor chips for the current input token (empty → strip hidden).
    @Published private(set) var predictorSuggestions: [String] = []
    /// Nil when the predictor is disabled for this session (incognito).
    private var engine: PredictorEngine?
    private var tracker = InputTokenTracker()
    private var learnedStore: LearnedStore?
```

Add a builder called once per connect (call it from `connect(...)` after resolving defaults, before/around the shell opens — guard on the resolved incognito flag):

```swift
    /// Build the session predictor unless incognito is on for this host.
    private func startPredictor(host: Host, defaults: Defaults) {
        guard !resolvePredictorIncognito(host: host, defaults: defaults) else {
            engine = nil; return
        }
        let store = AppStores.shared.predictorLearnedStore()
        learnedStore = store
        engine = PredictorEngine(learned: store.load(), seed: AppStores.shared.predictorSeed())
    }
```

(If a `resolvePredictorIncognito` helper does not already exist in `SemicolynKit/Model/Resolution.swift`, add one mirroring `resolveTmuxAttemptControlMode` — `resolveOptional(host.semicolyn, defaults.semicolyn)?.predictor?.incognito ?? false`.)

Hook input observation into `sendTerminalInput` — at the **top** of the existing method, before routing the bytes:

```swift
        observePredictorInput(bytes)
```

and implement the observation + suggestion refresh:

```swift
    /// Fold outgoing bytes into the token tracker, learn committed tokens, and
    /// refresh the suggestion chips.
    private func observePredictorInput(_ bytes: [UInt8]) {
        guard engine != nil else { return }
        for committed in tracker.observe(bytes) {
            engine?.record(committed.token, after: committed.previous)
        }
        refreshPredictorSuggestions()
    }

    private func refreshPredictorSuggestions() {
        guard let engine else { predictorSuggestions = []; return }
        let raw = engine.suggestions(forPrefix: tracker.current, after: tracker.previous)
        predictorSuggestions = predictorChips(current: tracker.current, suggestions: raw)
    }

    /// Accept a chip: send only the missing suffix so the existing input is kept
    /// (never rewritten). The suffix flows back through `sendTerminalInput`, so the
    /// tracker and suggestions update automatically.
    func acceptSuggestion(_ s: String) {
        guard s.hasPrefix(tracker.current) else { return }
        let suffix = String(s.dropFirst(tracker.current.count))
        guard !suffix.isEmpty else { return }
        sendTerminalInput(Array(suffix.utf8))
    }
```

Harvest command output for completions — in the connect path's `output.onBytes`/sink wiring, feed text to the engine. Where the terminal output sink is set (raw path `output` and tmux pane bytes), add a harvest call. For the raw path, set on `output`:

```swift
        output.onBytes = { [weak self] bytes in
            self?.engine?.harvest(output: String(decoding: bytes, as: UTF8.self))
            // (existing onBytes behavior, if any, stays)
        }
```

(Read the existing `output.onBytes` assignments first; **append** the harvest call, do not drop existing render wiring. In tmux mode, harvesting can be wired similarly off `TmuxRuntime.onPaneBytes` — acceptable to harvest only the active path in v1; note any deferral.)

Flush + reset in `teardown()`:

```swift
        if let engine, let learnedStore { try? learnedStore.save(engine.state) }
        engine = nil
        tracker.reset()
        predictorSuggestions = []
```

- [ ] **Step 3: Commit (CI-gated, batched with Task 3)**

```bash
git add App/AppStores.swift App/ConnectionViewModel.swift
git commit -m "feat(predictor): session engine wiring — observe input, learn, harvest, accept, flush"
```

(No push yet — the strip view + mount land in Task 3, then macOS CI validates Tasks 2–3 together.)

---

### Task 3: App — PredictorStripView + mount

**Files:**
- Create: `App/Keybar/PredictorStripView.swift`
- Modify: `App/SessionView.swift`

**Validation:** App tier — macOS CI build only. Animation/appearance need a Simulator.

**Interfaces:**
- Consumes: `vm.predictorSuggestions`, `vm.acceptSuggestion`, `theme.predictor` tokens.
- Produces: `PredictorStripView(vm:)` — a ~24pt auto-hiding row of accent pill chips; mounted directly above `KeybarView` in `SessionView` (so it sits between the terminal and the keybar, never reflowing the keys).

- [ ] **Step 1: Implement `App/Keybar/PredictorStripView.swift`**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// The predictive-input row: a thin auto-hiding strip of accent chips above the
/// keybar (predictor spec §"Suggestion surface"). Hidden when there are no
/// suggestions; slides in/out; never reflows the keybar.
struct PredictorStripView: View {
    @ObservedObject var vm: ConnectionViewModel
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if !vm.predictorSuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(vm.predictorSuggestions, id: \.self) { s in
                            Text(s)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Color(theme.predictor.suggestionText))
                                .padding(.horizontal, 10).padding(.vertical, 3)
                                .background(Color(theme.predictor.suggestionBg))
                                .clipShape(Capsule())
                                .onTapGesture { vm.acceptSuggestion(s) }
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .frame(height: 24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(theme.predictor.stripBg))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.15, dampingFraction: 0.9), value: vm.predictorSuggestions)
    }
}
```

- [ ] **Step 2: Mount above the keybar in `SessionView`** — the keybar is mounted via `.safeAreaInset(edge: .bottom)` (4a). Put the strip in the **same bottom inset, above** the keybar, so it never reflows the keys. Replace the existing keybar inset content with a `VStack` stacking strip + keybar:

```swift
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        VStack(spacing: 0) {
                            PredictorStripView(vm: vm)
                            KeybarView(layout: .default, vm: vm)
                        }
                    }
```

(Apply on BOTH shell branches that currently mount `KeybarView`, matching the 4a mount sites.)

- [ ] **Step 3: Commit + validate on macOS CI**

```bash
git add App/Keybar/PredictorStripView.swift App/SessionView.swift
git commit -m "feat(predictor): auto-hiding suggestion strip mounted above the keybar"
git push -u github feat/phase-4c-predictor-strip
```
(The controller opens the PR + watches CI; `macos` green proves Tasks 2–3 compile. Strip appearance/animation/tap still need a Simulator.)

---

## Wrap-up

- [ ] **Full SemicolynKit suite green:** `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test` — all existing + `InputTokenTrackerTests` pass.
- [ ] **Update `TODO.md`** — Phase 4 row: 4a/4b/4c done; 4d/4e pending. Commit `docs: mark Phase 4c (predictor strip) done`.
- [ ] **Open PR** to `github` `main` (squash-merge). Note that strip interaction is pending a Simulator pass.

---

## Self-Review notes

- **Spec coverage:** auto-hiding row above the keybar, ~24pt, accent chips, top-K → Task 3 + the `vm.predictorSuggestions.isEmpty` hide; never reflows keybar → mounted in the same bottom inset above `KeybarView`; tap commits / ignore does nothing / never silent → `acceptSuggestion` sends only the missing suffix; engine owns ranking + floor → strip shows `suggestions(...)` minus the exact current token; learning → `record` on committed tokens + `harvest` on output; cross-session → `LearnedStore.load`/`save`; incognito disables the session predictor → `startPredictor` gate.
- **Deferred (documented):** the iOS field-level autocorrect disables (`autocorrectionType=.no` etc.) — SwiftTerm owns its own keyboard input, not a `UITextField` we configure here; revisit if iOS suggestions intrude. CloudKit sync of sketches (enrollment-gated, sync-scope spec). Leading-space "don't learn" opt-out (engine `TODO(predictor)`). tmux-mode output harvest may cover only the active path in v1. Time-of-day CMS (future). None are gaps for the strip slice.
- **Known App-tier ⚠️ (macOS/Simulator):** `output.onBytes` harvest append must not drop existing render wiring (read first); `AppStores` Application-Support base name; the strip's slide/▸appearance + chip styling are visually unverified; suggestion recompute runs per outgoing keystroke on the main actor (O(1) sketch reads, matches the engine design).
