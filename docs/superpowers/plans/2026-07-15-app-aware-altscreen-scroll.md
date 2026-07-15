<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# App-Aware Alt-Screen Scroll Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make an alt-screen drag emit PgUp/PgDn (instead of arrows) for AI-CLI TUIs that bind arrows to prompt history (Claude/Gemini/Codex/Qwen), detected reliably via tmux `pane_current_command`, behind a new Experimental settings section.

**Architecture:** Pure decision logic in Kit (registry + mode enum + decider + page-key encoder), fully Linux-tested. The App threads one begin-time snapshot into the existing alt-screen drag path and adds an Experimental settings screen. No new subsystem.

**Tech Stack:** Swift 6 (SemicolynKit, Linux-tested via Docker `semicolyn-dev`), SwiftUI/UIKit App tier (macOS-CI-only), XCTest.

## Global Constraints

- Every source file carries the SPDX header: `// SPDX-FileCopyrightText: 2026 True Positive LLC` / `// SPDX-License-Identifier: GPL-3.0-only`.
- Kit tier (`Sources/SemicolynKit/`): Swift 6 strict-concurrency, `Sendable`, NO `import UIKit`/`SwiftUI`/`CryptoKit`. Linux-tested.
- App tier: `@MainActor` reads/`DebugLog.shared.log` inside a SwiftTerm/`@objc` delegate callback must be wrapped in `MainActor.assumeIsolated { }` (recurring CI trap). UIView overrides do not need it.
- Tests are REAL: exact-value assertions, no tautologies; negative tests assert the specific outcome. Risk tier here = Core (EP + BVA + good-and-bad per partition).
- No em-dashes in generated output. Conventional commits. Kit runs via `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`.
- Branch: `feat/app-aware-altscreen-scroll` (already created; spec committed as `3c85c0e`).

---

### Task 1: `AltScrollRegistry` (Kit)

**Files:**
- Create: `Sources/SemicolynKit/Terminal/AltScrollRegistry.swift`
- Test: `Tests/SemicolynKitTests/AltScrollRegistryTests.swift`

**Interfaces:**
- Produces: `AltScrollRegistry` struct with `static let bundledDefault`, `let pageKeyApps: Set<String>`, `func wantsPageKeys(command: String?) -> Bool`, `func wantsPageKeys(title: String?) -> Bool`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/SemicolynKitTests/AltScrollRegistryTests.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class AltScrollRegistryTests: XCTestCase {
    let reg = AltScrollRegistry.bundledDefault

    // The four known AI CLIs are registered.
    func testBundledDefaultContainsKnownApps() {
        XCTAssertTrue(reg.wantsPageKeys(command: "claude"))
        XCTAssertTrue(reg.wantsPageKeys(command: "gemini"))
        XCTAssertTrue(reg.wantsPageKeys(command: "codex"))
        XCTAssertTrue(reg.wantsPageKeys(command: "qwen"))
    }

    // Case-insensitive exact match.
    func testCommandMatchIsCaseInsensitive() {
        XCTAssertTrue(reg.wantsPageKeys(command: "Claude"))
        XCTAssertTrue(reg.wantsPageKeys(command: "CLAUDE"))
    }

    // An unregistered process does NOT match.
    func testUnregisteredCommandDoesNotMatch() {
        XCTAssertFalse(reg.wantsPageKeys(command: "bash"))
        XCTAssertFalse(reg.wantsPageKeys(command: "vim"))
    }

    // nil / empty / whitespace command never matches (no false positive).
    func testEmptyOrNilCommandDoesNotMatch() {
        XCTAssertFalse(reg.wantsPageKeys(command: nil))
        XCTAssertFalse(reg.wantsPageKeys(command: ""))
        XCTAssertFalse(reg.wantsPageKeys(command: "   "))
    }

    // EXACT token, not substring: a wrapper name must NOT match.
    func testCommandSubstringDoesNotFalseMatch() {
        XCTAssertFalse(reg.wantsPageKeys(command: "claude-wrapper"))
        XCTAssertFalse(reg.wantsPageKeys(command: "myclaude"))
    }

    // Title match: word-boundary token, case-insensitive.
    func testTitleWordBoundaryMatch() {
        XCTAssertTrue(reg.wantsPageKeys(title: "myrepo — claude: fix auth"))
        XCTAssertTrue(reg.wantsPageKeys(title: "CLAUDE"))
        XCTAssertFalse(reg.wantsPageKeys(title: "unclaudely commit"))  // no word boundary
        XCTAssertFalse(reg.wantsPageKeys(title: "vim README.md"))
        XCTAssertFalse(reg.wantsPageKeys(title: nil))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter AltScrollRegistryTests`
Expected: FAIL — `cannot find 'AltScrollRegistry' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/SemicolynKit/Terminal/AltScrollRegistry.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The set of foreground app command-names whose alt-screen binds arrow keys to
/// prompt-history navigation (Ink/Ratatui AI CLIs) and therefore want PgUp/PgDn from an
/// alt-screen scroll gesture instead of arrows. Extensible: adding an app is a one-line
/// change to `bundledDefault` plus a test.
public struct AltScrollRegistry: Sendable {
    /// Apps that bind arrows to history: Claude Code, Gemini CLI, OpenAI Codex, Qwen Code.
    public static let bundledDefault = AltScrollRegistry(
        pageKeyApps: ["claude", "gemini", "codex", "qwen"])

    /// Lowercased process names.
    public let pageKeyApps: Set<String>

    public init(pageKeyApps: Set<String>) {
        self.pageKeyApps = Set(pageKeyApps.map { $0.lowercased() })
    }

    /// EXACT process-name match, case-insensitive. A wrapper like `"claude-wrapper"` does
    /// NOT match (a false match would send Page keys to an app that wanted arrows, which
    /// feels broken). nil/empty/whitespace never matches.
    public func wantsPageKeys(command: String?) -> Bool {
        guard let c = command?.trimmingCharacters(in: .whitespaces).lowercased(),
              !c.isEmpty else { return false }
        return pageKeyApps.contains(c)
    }

    /// Word-boundary, case-insensitive token match against an OSC window title (title mode
    /// only). `"myrepo — claude: fix"` matches; `"unclaudely"` does not.
    public func wantsPageKeys(title: String?) -> Bool {
        guard let t = title?.lowercased(), !t.isEmpty else { return false }
        // Split on any non-alphanumeric so `claude:` / `— claude` tokenize to `claude`.
        let tokens = t.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return tokens.contains(where: pageKeyApps.contains)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter AltScrollRegistryTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Terminal/AltScrollRegistry.swift Tests/SemicolynKitTests/AltScrollRegistryTests.swift
git commit -m "feat(terminal): AltScrollRegistry — apps wanting PgUp/PgDn on alt-screen scroll"
```

---

### Task 2: `AltScrollMode` + decider (Kit)

**Files:**
- Create: `Sources/SemicolynKit/Terminal/AltScrollMode.swift`
- Test: `Tests/SemicolynKitTests/AltScrollDeciderTests.swift`

**Interfaces:**
- Consumes: `AltScrollRegistry` (Task 1).
- Produces: `enum AltScrollMode: String { case off, auto, alwaysPageKeys, autoPlusTitle }`; `enum AltScrollKeys { case arrows, pageKeys }`; `func altScrollKeys(mode:paneCommand:windowTitle:registry:) -> AltScrollKeys`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/SemicolynKitTests/AltScrollDeciderTests.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class AltScrollDeciderTests: XCTestCase {
    let reg = AltScrollRegistry.bundledDefault

    private func keys(_ mode: AltScrollMode, cmd: String?, title: String? = nil) -> AltScrollKeys {
        altScrollKeys(mode: mode, paneCommand: cmd, windowTitle: title, registry: reg)
    }

    // .off is always arrows, even for a registered app.
    func testOffAlwaysArrows() {
        XCTAssertEqual(keys(.off, cmd: "claude"), .arrows)
        XCTAssertEqual(keys(.off, cmd: "bash"), .arrows)
        XCTAssertEqual(keys(.off, cmd: nil), .arrows)
    }

    // .auto: page keys for a registered tmux app, arrows otherwise / when unknown.
    func testAutoUsesCommand() {
        XCTAssertEqual(keys(.auto, cmd: "claude"), .pageKeys)
        XCTAssertEqual(keys(.auto, cmd: "bash"), .arrows)
        XCTAssertEqual(keys(.auto, cmd: nil), .arrows)   // raw/mosh: no signal → arrows
    }

    // .auto ignores the title entirely (title only matters in .autoPlusTitle).
    func testAutoIgnoresTitle() {
        XCTAssertEqual(keys(.auto, cmd: nil, title: "claude"), .arrows)
    }

    // .alwaysPageKeys: page keys regardless of app or signal.
    func testAlwaysPageKeys() {
        XCTAssertEqual(keys(.alwaysPageKeys, cmd: "claude"), .pageKeys)
        XCTAssertEqual(keys(.alwaysPageKeys, cmd: "bash"), .pageKeys)
        XCTAssertEqual(keys(.alwaysPageKeys, cmd: nil), .pageKeys)
    }

    // .autoPlusTitle: command wins when present; falls back to title when command is nil.
    func testAutoPlusTitle() {
        XCTAssertEqual(keys(.autoPlusTitle, cmd: "claude", title: nil), .pageKeys)   // command
        XCTAssertEqual(keys(.autoPlusTitle, cmd: nil, title: "myrepo — claude: x"), .pageKeys) // title
        XCTAssertEqual(keys(.autoPlusTitle, cmd: nil, title: "vim README"), .arrows) // no match
        XCTAssertEqual(keys(.autoPlusTitle, cmd: "bash", title: "claude"), .arrows)  // command wins (no match)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter AltScrollDeciderTests`
Expected: FAIL — `cannot find 'AltScrollMode' / 'altScrollKeys' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/SemicolynKit/Terminal/AltScrollMode.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// How an alt-screen scroll gesture chooses which keys to synthesize. A single
/// user-facing setting (radio); modes are mutually exclusive by construction.
public enum AltScrollMode: String, Sendable, CaseIterable, Codable {
    case off             // always arrows (xterm standard)
    case auto            // arrows, except a registered app in a tmux pane → page keys [DEFAULT]
    case alwaysPageKeys  // every alt-screen drag → page keys (breaks less/vim line-scroll)
    case autoPlusTitle   // auto, plus best-effort OSC-title match on non-tmux (brittle)
}

/// The key family an alt-screen drag emits.
public enum AltScrollKeys: Sendable, Equatable { case arrows, pageKeys }

/// Pure decision the App snapshots once at drag `.began`.
/// - paneCommand: tmux `pane_current_command` for this pane; nil on raw/mosh.
/// - windowTitle: OSC 0/2 title; consulted only in `.autoPlusTitle`.
public func altScrollKeys(mode: AltScrollMode,
                          paneCommand: String?,
                          windowTitle: String?,
                          registry: AltScrollRegistry) -> AltScrollKeys {
    switch mode {
    case .off:
        return .arrows
    case .auto:
        return registry.wantsPageKeys(command: paneCommand) ? .pageKeys : .arrows
    case .alwaysPageKeys:
        return .pageKeys
    case .autoPlusTitle:
        if registry.wantsPageKeys(command: paneCommand) { return .pageKeys }
        return registry.wantsPageKeys(title: windowTitle) ? .pageKeys : .arrows
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter AltScrollDeciderTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Terminal/AltScrollMode.swift Tests/SemicolynKitTests/AltScrollDeciderTests.swift
git commit -m "feat(terminal): AltScrollMode + altScrollKeys decider"
```

---

### Task 3: Page-key encoder (Kit)

**Files:**
- Modify: `Sources/SemicolynKit/Terminal/ArrowEncoding.swift`
- Test: `Tests/SemicolynKitTests/PageKeyEncodingTests.swift`

**Interfaces:**
- Consumes: `ArrowRun` (existing: `.direction: ArrowDirection`, `.count: Int`), `ArrowDirection` (existing: `.up/.down/.left/.right`).
- Produces: `func encodePageKeyRun(_ run: ArrowRun) -> [UInt8]`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/SemicolynKitTests/PageKeyEncodingTests.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class PageKeyEncodingTests: XCTestCase {
    // Up → PgUp = ESC [ 5 ~  (0x1b 0x5b 0x35 0x7e). Direction convention matches arrows:
    // an .up run scrolls back, which for a pager/TUI is Page Up.
    func testUpEncodesPageUp() {
        let run = ArrowRun(direction: .up, count: 1)
        XCTAssertEqual(encodePageKeyRun(run), [0x1b, 0x5b, 0x35, 0x7e])
    }

    // Down → PgDn = ESC [ 6 ~  (0x1b 0x5b 0x36 0x7e).
    func testDownEncodesPageDown() {
        let run = ArrowRun(direction: .down, count: 1)
        XCTAssertEqual(encodePageKeyRun(run), [0x1b, 0x5b, 0x36, 0x7e])
    }

    // count repeats the sequence exactly count times.
    func testCountRepeats() {
        let run = ArrowRun(direction: .up, count: 3)
        XCTAssertEqual(encodePageKeyRun(run),
                       [0x1b,0x5b,0x35,0x7e, 0x1b,0x5b,0x35,0x7e, 0x1b,0x5b,0x35,0x7e])
    }

    // count 0 → empty.
    func testZeroCountEmpty() {
        XCTAssertEqual(encodePageKeyRun(ArrowRun(direction: .up, count: 0)), [])
    }

    // Horizontal runs have no page-key analog → empty (alt-screen scroll is vertical).
    func testHorizontalEmpty() {
        XCTAssertEqual(encodePageKeyRun(ArrowRun(direction: .left, count: 2)), [])
        XCTAssertEqual(encodePageKeyRun(ArrowRun(direction: .right, count: 2)), [])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter PageKeyEncodingTests`
Expected: FAIL — `cannot find 'encodePageKeyRun' in scope`.

- [ ] **Step 3: Write minimal implementation**

Append to `Sources/SemicolynKit/Terminal/ArrowEncoding.swift`:

```swift
/// Encode one vertical `ArrowRun` as Page Up / Page Down escape bytes, `count` times.
/// `.up` → PgUp (`ESC [ 5 ~`), `.down` → PgDn (`ESC [ 6 ~`) — the same finger-direction
/// convention as `encodeArrowRun` (finger-down reveals content above = scroll back = PgUp).
/// Horizontal runs have no page-key analog (alt-screen scroll is vertical) → empty.
/// Page keys are not affected by DECCKM, so there is no application-cursor variant.
public func encodePageKeyRun(_ run: ArrowRun) -> [UInt8] {
    guard run.count > 0 else { return [] }
    let one: [UInt8]
    switch run.direction {
    case .up:   one = [0x1b, 0x5b, 0x35, 0x7e]   // ESC [ 5 ~
    case .down: one = [0x1b, 0x5b, 0x36, 0x7e]   // ESC [ 6 ~
    case .left, .right: return []
    }
    var out: [UInt8] = []
    out.reserveCapacity(one.count * run.count)
    for _ in 0..<run.count { out.append(contentsOf: one) }
    return out
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter PageKeyEncodingTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Terminal/ArrowEncoding.swift Tests/SemicolynKitTests/PageKeyEncodingTests.swift
git commit -m "feat(terminal): encodePageKeyRun (PgUp/PgDn) for alt-screen scroll"
```

---

### Task 4: `altScrollMode` in the terminal settings model (Kit)

**Files:**
- Modify: `Sources/SemicolynKit/Terminal/TerminalSettings.swift`
- Test: `Tests/SemicolynKitTests/TerminalSettingsTests.swift` (add to it if it exists; else create)

**Interfaces:**
- Consumes: `AltScrollMode` (Task 2).
- Produces: `TerminalSettings.altScrollMode: AltScrollMode` with default `.auto`.

- [ ] **Step 1: Write the failing test**

First check for an existing test file:
Run: `ls Tests/SemicolynKitTests/TerminalSettingsTests.swift 2>/dev/null || echo NONE`

If NONE, create it with the SPDX header + `import XCTest` / `@testable import SemicolynKit` and an empty `final class TerminalSettingsTests: XCTestCase {}`. Then add:

```swift
    // altScrollMode defaults to .auto and round-trips through Codable.
    func testAltScrollModeDefaultsToAuto() {
        XCTAssertEqual(TerminalSettings().altScrollMode, .auto)
    }

    func testAltScrollModeCodableRoundTrip() throws {
        var s = TerminalSettings()
        s.altScrollMode = .alwaysPageKeys
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(TerminalSettings.self, from: data)
        XCTAssertEqual(back.altScrollMode, .alwaysPageKeys)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TerminalSettingsTests`
Expected: FAIL — `value of type 'TerminalSettings' has no member 'altScrollMode'`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/SemicolynKit/Terminal/TerminalSettings.swift`, add the stored property alongside `scrollbackLines` (around line 80) and the init parameter + assignment (around lines 89-96). Add:

- Property (with the others): `public var altScrollMode: AltScrollMode`
- Init parameter (after `scrollbackLines: Int = 5000,`): `altScrollMode: AltScrollMode = .auto,`
- Init assignment (with the others): `self.altScrollMode = altScrollMode`

Because `TerminalSettings` is `Codable` and this adds a field with a default, decoding older JSON without the key must still succeed. Confirm the type uses the synthesized `Codable`; if it decodes with `decodeIfPresent` or a custom init, mirror that pattern. If it uses synthesized `Codable`, add a `CodingKeys`-free default by making the property optional-free with a default is not enough for synthesized decode — so ALSO verify: synthesized `Codable` requires the key present. To keep backward-compat, implement a custom `init(from:)` fallback ONLY IF the existing type already has one; otherwise the synthesized decode will fail on old data. Since the store re-persists on first write and this is a device-local preference, the synthesized decode is acceptable — but to be safe, add this to the type:

```swift
// Backward-compatible decode: older persisted settings predate altScrollMode.
// (Add ONLY if the type currently relies on synthesized Codable. If it already has a
// custom init(from:), add `altScrollMode = (try? c.decode(AltScrollMode.self, forKey:
// .altScrollMode)) ?? .auto` in that init instead.)
```

Inspect the file first (`grep -n "init(from" Sources/SemicolynKit/Terminal/TerminalSettings.swift`). If no custom `init(from:)` exists, add one that decodes each existing field and defaults `altScrollMode` to `.auto` when absent, matching the field set. Keep it mechanical.

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TerminalSettingsTests`
Expected: PASS.

Also run the full Kit suite to confirm no `TerminalSettings` consumer broke:
Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Terminal/TerminalSettings.swift Tests/SemicolynKitTests/TerminalSettingsTests.swift
git commit -m "feat(terminal): add altScrollMode to TerminalSettings (default .auto)"
```

---

### Task 5: `.experimental` settings section case (Kit)

**Files:**
- Modify: `Sources/SemicolynKit/Settings/SettingsSection.swift:12`
- Test: `Tests/SemicolynKitTests/SettingsSectionTests.swift` (add to it if it exists; else create)

**Interfaces:**
- Produces: `SettingsSection.experimental` case.

- [ ] **Step 1: Write the failing test**

```swift
// If a SettingsSectionTests file exists, add this test; else create the file with the
// SPDX header + imports + `final class SettingsSectionTests: XCTestCase {}`.
    func testExperimentalCaseExists() {
        XCTAssertTrue(SettingsSection.allCases.contains(.experimental))
        XCTAssertEqual(SettingsSection.experimental.rawValue, "experimental")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter SettingsSectionTests`
Expected: FAIL — `type 'SettingsSection' has no member 'experimental'`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/SemicolynKit/Settings/SettingsSection.swift:12`, append `experimental` to the case list:

```swift
    case appearance, terminal, keybar, launcher, defaults, privacy, diagnostics, experimental
```

If the enum has a computed `title`/`icon`/`summary` switch elsewhere in the file, add an `experimental` arm to each (title: `"Experimental"`, and whatever the icon/summary pattern is — e.g. icon `"flask"`; summary `"Advanced and unreliable options."`). Make the switches exhaustive so it compiles.

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter SettingsSectionTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Settings/SettingsSection.swift Tests/SemicolynKitTests/SettingsSectionTests.swift
git commit -m "feat(settings): add .experimental SettingsSection case"
```

---

### Task 6: Alt-screen drag emits chosen keys (App)

**Files:**
- Modify: `App/TerminalGestureController.swift` (Callbacks struct; `beginDrag`; `handleAltScreenPan` `.changed`)
- Modify: `App/TerminalScreen.swift` (single-pane callback)
- Modify: `App/TmuxPaneContainer.swift` (per-pane callback)

**Interfaces:**
- Consumes: `altScrollKeys(...)`, `AltScrollKeys`, `AltScrollMode`, `AltScrollRegistry`, `encodePageKeyRun` (Kit); `TmuxRuntime.paneContext(_:)`, `vm.terminalTitle`, `AppStores.shared.terminalSettings.settings.altScrollMode`.
- Produces: end-to-end alt-screen page-key behavior (verified on device; App tier is macOS-CI-only for compile).

This task has no Linux unit test (App tier). The correctness is covered by Tasks 1-3. Steps are compile-and-wire; the gate is the macOS CI app-compile + device retest.

- [ ] **Step 1: Add the `altScrollKeys` callback to `Callbacks`**

In `App/TerminalGestureController.swift`, in `struct Callbacks`, add:

```swift
        /// Which key family an alt-screen drag should emit for THIS pane, resolved once at
        /// drag `.began` via the pure `altScrollKeys(...)` decider (mode + pane command +
        /// title). `.arrows` (xterm standard) or `.pageKeys` (PgUp/PgDn for AI-CLI TUIs).
        let altScrollKeys: () -> AltScrollKeys
```

- [ ] **Step 2: Snapshot at `.began`**

Add a stored property near `dragMode`:

```swift
    /// Key family for the in-flight alt-screen drag, snapshotted at `.began` so a single
    /// drag can't switch arrow↔page mid-flight.
    private var dragScrollKeys: AltScrollKeys = .arrows
```

In `beginDrag(_:on:)`, after `dragAppCursor = ...`, add:

```swift
        dragScrollKeys = callbacks.altScrollKeys()
```

- [ ] **Step 3: Branch the encoder in `handleAltScreenPan` `.changed`**

Replace the emit loop in `handleAltScreenPan`'s `.changed` case:

```swift
            for run in runs {
                let bytes = dragScrollKeys == .pageKeys
                    ? encodePageKeyRun(run)
                    : encodeArrowRun(run, applicationCursorKeys: dragAppCursor)
                if !bytes.isEmpty { callbacks.sendBytes(bytes) }
            }
            if !runs.isEmpty {
                DebugLog.shared.log(.gesture, "gr:altPan keys=\(dragScrollKeys) runs=\(runs.count) emittedCells=\(emittedCells)")
            }
```

- [ ] **Step 4: Supply the callback — single-pane (`TerminalScreen.swift`)**

In the `TerminalGestureController(callbacks: .init(...))` construction in `makeUIView`, add:

```swift
                altScrollKeys: { [weak coordinator = context.coordinator] in
                    let mode = AppStores.shared.terminalSettings.settings.altScrollMode
                    let title = coordinator?.vm?.terminalTitle
                    // Raw/mosh single pane: no tmux pane_current_command.
                    return altScrollKeys(mode: mode, paneCommand: nil,
                                         windowTitle: title, registry: .bundledDefault)
                },
```

(`coordinator.vm` is the existing weak VM ref used by the keystroke gate; confirm its name with `grep -n "weak var vm" App/TerminalScreen.swift`. If the VM isn't reachable here, pass `windowTitle: nil` — single-pane title mode is best-effort only.)

- [ ] **Step 5: Supply the callback — tmux (`TmuxPaneContainer.swift`)**

In the per-pane `TerminalGestureController(callbacks: .init(...))` in `installHalo`, add (the closure already captures `pane` and `self`):

```swift
                        altScrollKeys: { [weak self] in
                            let mode = AppStores.shared.terminalSettings.settings.altScrollMode
                            let cmd = self?.vm.tmuxRuntimePaneContext(pane)   // see Step 6
                            let title = self?.vm.terminalTitle
                            return altScrollKeys(mode: mode, paneCommand: cmd,
                                                 windowTitle: title, registry: .bundledDefault)
                        },
```

- [ ] **Step 6: Expose `paneContext` to the VM if not already reachable**

`TmuxRuntime.paneContext(_:)` exists (Kit-adjacent App type). Confirm how the coordinator reaches the runtime: `grep -n "tmuxRuntime\|paneContext\|TmuxRuntime" App/ConnectionViewModel.swift App/TmuxPaneContainer.swift`. If the coordinator already holds a `TmuxRuntime` (or the VM does), call `paneContext(pane)` directly and delete the `tmuxRuntimePaneContext` placeholder in Step 5, using the real accessor. If the VM needs a thin passthrough, add:

```swift
    // App/ConnectionViewModel.swift — thin passthrough for the alt-scroll decider.
    func tmuxRuntimePaneContext(_ pane: PaneID) -> String? { tmuxRuntime?.paneContext(pane) }
```

(Use the real stored-property name for the runtime, found by the grep above.)

- [ ] **Step 7: Verify the app compiles + no `@MainActor` trap**

Scan the new closures: `AppStores.shared` and `vm.terminalTitle` are `@MainActor`. The `altScrollKeys` callback is invoked from `beginDrag` (a gesture context on the main thread). Confirm the callback body doesn't need `assumeIsolated` because it is a plain closure called synchronously on the main thread from a `@MainActor`-reachable path; if the compiler flags isolation, wrap the reads in `MainActor.assumeIsolated { }` and return the value. (This is the recurring CI trap; expect to fix it here if it appears.)

Push and let macOS CI compile (there is no local Swift App-tier build).

- [ ] **Step 8: Commit**

```bash
git add App/TerminalGestureController.swift App/TerminalScreen.swift App/TmuxPaneContainer.swift App/ConnectionViewModel.swift
git commit -m "feat(terminal): alt-screen drag emits PgUp/PgDn for AI-CLI panes (app-aware)"
```

---

### Task 7: Experimental settings screen + Diagnostics relocation + revert temp hack (App)

**Files:**
- Create: `App/ExperimentalSettingsView.swift`
- Modify: `App/SettingsView.swift` (add `.experimental` row; remove top-level `.diagnostics` row)
- Modify: `App/LogCategory.swift` (revert temp `.keybar` default-on)

**Interfaces:**
- Consumes: `AltScrollMode` (Task 2), `SettingsSection.experimental` (Task 5), existing `DiagnosticsSettingsView`, `AppStores.shared.terminalSettings`.

App tier: no Linux test. Gate = macOS CI compile + device check that the screen renders and the radio persists.

- [ ] **Step 1: Create `ExperimentalSettingsView`**

```swift
// App/ExperimentalSettingsView.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// The "Experimental — advanced, may be unreliable" settings screen. Hosts the
/// alt-screen scroll mode radio and links to Diagnostics (relocated here).
struct ExperimentalSettingsView: View {
    @ObservedObject private var store = AppStores.shared.terminalSettings

    private var altScrollBinding: Binding<AltScrollMode> {
        Binding(get: { store.settings.altScrollMode },
                set: { store.settings.altScrollMode = $0 })
    }

    var body: some View {
        List {
            Section {
                Picker("Alt-screen scroll", selection: altScrollBinding) {
                    Text("Off — standard arrow keys").tag(AltScrollMode.off)
                    Text("Auto — AI CLIs use Page keys").tag(AltScrollMode.auto)
                    Text("Always Page keys").tag(AltScrollMode.alwaysPageKeys)
                    Text("Auto + window-title match (SSH/Mosh)").tag(AltScrollMode.autoPlusTitle)
                }
                .pickerStyle(.inline)
            } header: {
                Text("Alt-screen scroll")
            } footer: {
                Text("""
                Auto: Claude, Gemini, Codex, Qwen in tmux scroll with PgUp/PgDn instead of \
                arrows (which they read as prompt history). \
                Always: every full-screen app gets PgUp/PgDn — breaks line-scroll in less/vim. \
                Title match: also guesses the app from the window title on non-tmux sessions — \
                unreliable, titles are dynamic and may misfire.
                """)
            }

            Section {
                NavigationLink { DiagnosticsSettingsView() } label: {
                    Label("Diagnostics", systemImage: "ladybug")
                }
            }
        }
        .navigationTitle("Experimental")
    }
}
```

Verify `AppStores.shared.terminalSettings` is an `ObservableObject` whose `settings` is a settable `@Published` (it is, per the theme/font pickers). If the store's mutation API differs (e.g. a method), adapt the binding's `set` to match the existing pattern used by `TerminalSettingsView`.

- [ ] **Step 2: Wire the row in `SettingsView` and remove top-level Diagnostics**

In `App/SettingsView.swift`, inside the `List`, add an Experimental row and remove the standalone Diagnostics row (it now lives inside Experimental):

```swift
                // remove: row(.diagnostics, "Diagnostics", "ladybug") { DiagnosticsSettingsView() }
                row(.experimental, "Experimental", "flask") { ExperimentalSettingsView() }
```

Keep the other rows (`appearance`, `terminal`, `privacy`, …) as-is. Confirm the `row(_:_:_:)` helper signature matches (`SettingsSection`, title `String`, systemImage `String`, `@ViewBuilder destination`).

- [ ] **Step 3: Revert the temporary `.keybar` default-on hack**

In `App/LogCategory.swift`, restore the original `defaultEnabled` (drop `.keybar`):

```swift
    static let defaultEnabled: Set<LogCategory> = [.lifecycle, .connect, .tmux, .gesture, .seed]
```

Delete the "TEMP (2026-07-15, diag/terminal-sizing)" comment block above it. The `sizing:tmux`/`sizing:raw` logs now default OFF, reachable via Experimental → Diagnostics like every category.

- [ ] **Step 4: Verify app compiles**

Push; macOS CI is the compile gate. Watch for the `@MainActor` trap in the binding (SwiftUI View bodies are `@MainActor`, so this should be clean).

- [ ] **Step 5: Commit**

```bash
git add App/ExperimentalSettingsView.swift App/SettingsView.swift App/LogCategory.swift
git commit -m "feat(settings): Experimental section (alt-scroll radio) + relocate Diagnostics; revert temp keybar default-on"
```

---

### Task 8: Full Kit suite + PR

**Files:** none (verification + integration).

- [ ] **Step 1: Run the full Kit suite**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: all green (existing 1203 + the new AltScroll/PageKey/decider/settings tests).

- [ ] **Step 2: View-only lint gate**

Run: `bash scripts/check-app-view-only.sh App`
Expected: `View-only gate: clean`.

- [ ] **Step 3: Push and open PR**

```bash
git push -u github feat/app-aware-altscreen-scroll
gh pr create --repo ds7n/semicolyn --base main --head feat/app-aware-altscreen-scroll \
  --title "feat(terminal): app-aware alt-screen scroll (PgUp/PgDn for AI CLIs) + Experimental settings" \
  --body "Implements docs/superpowers/specs/2026-07-15-app-aware-altscreen-scroll-design.md. See spec for rationale (Claude/Gemini/Codex/Qwen bind arrows to history; tmux pane_current_command is the reliable signal). Kit fully tested; App tier macOS-CI-gated. Reverts the temp .keybar sizing-diagnostics default-on."
```

- [ ] **Step 4: Watch macOS CI**

Run: `gh run list --repo ds7n/semicolyn --limit 1 --json databaseId` then poll `gh run view <id> --json jobs`. The macOS app-compile is the gate for Tasks 6-7 (no local Swift App build). Fix any `@MainActor`/access-level errors and re-push.

- [ ] **Step 5: Device retest (after merge + TF build)**

Trigger a TF build (`gh workflow run "Release to TestFlight" --repo ds7n/semicolyn --ref main`), then on device: drag in a Claude tmux pane → transcript scrolls (PgUp/PgDn); drag in `less` → still line-scrolls (arrows). Toggle the Experimental radio to confirm Off/Always/Title modes behave.

---

## Self-Review

**Spec coverage:**
- §1 `AltScrollRegistry` → Task 1. `AltScrollMode` + decider → Task 2. Page-key encoding → Task 3. ✓
- §2 App wiring (snapshot at `.began`, encoder branch, callback, tmux `paneContext`, raw/mosh nil) → Task 6. ✓
- §3 `altScrollMode` setting + default → Task 4; Experimental section + radio + disclaimers → Task 7; Diagnostics relocation + `.experimental` case → Tasks 5, 7; revert temp `.keybar` hack → Task 7. ✓
- §4 testing (EP/BVA/adversarial, exact bytes) → Tasks 1-3 tests; device retest → Task 8. ✓

**Placeholder scan:** No TBD/"handle edge cases"/"similar to". Task 4 (Codable backward-compat) and Task 6 (VM/runtime accessor names) contain explicit `grep` verification steps because the exact existing symbol must be confirmed in-file, not guessed — each says precisely what to check and what to do for each outcome. This is verification, not a placeholder.

**Type consistency:** `AltScrollMode` cases (off/auto/alwaysPageKeys/autoPlusTitle), `AltScrollKeys` (arrows/pageKeys), `altScrollKeys(mode:paneCommand:windowTitle:registry:)`, `AltScrollRegistry.bundledDefault`, `wantsPageKeys(command:)`/`wantsPageKeys(title:)`, `encodePageKeyRun(_:)`, `TerminalSettings.altScrollMode`, `SettingsSection.experimental` — all consistent across Tasks 1-7. `ArrowRun`/`ArrowDirection` used per their real signatures (verified in-repo).
