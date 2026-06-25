# Phase 3c — Terminal UX Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire SwiftTerm's already-parsed terminal events (bell, OSC 52 clipboard, OSC 0/2 titles, URL taps, DECSCUSR cursor, mouse mode) into real touch-native behaviors, backed by a `TerminalSettings` model — implementing the delegate callbacks that are stubbed no-ops today.

**Architecture:** Pure decision logic (settings/clamps, bell halo state machine, OSC 52 write-gate, title sanitize, URL classify/join, resize debounce, DECSCUSR map) lives in `NeotildeKit` and is XCTest-covered on the Linux fast loop. Thin SwiftTerm/UIKit wiring (delegate bodies, halo overlay, mouse dot, pinch gesture, pasteboard, URL routing) lives in `App/` and is verified only by the macOS CI job. This mirrors the established `tmuxLaunchDecision`-pure / thin-App-wiring split.

**Tech Stack:** Swift 6 (NeotildeKit) / Swift 5 (App target), SwiftTerm, XCTest, swift-crypto (Linux) / CryptoKit (Apple), the existing `Inherited<T>` host-config model and `Theme` tokens.

## Global Constraints

- **NeotildeKit is Swift 6 strict-concurrency + Linux-clean.** Pure units must be `Sendable`, must NOT `import UIKit`/`SwiftTerm`/`CryptoKit`, and must run under `docker compose run --rm dev swift test`.
- **App-target code is macOS-CI-verified only** — invisible to Linux `swift test`; the `#if os(macOS)`-gated FFI/UIKit layer compiles in Swift 5 language mode.
- **No audio bell, ever.** Bell = visual halo + haptic only.
- **OSC 52 read sequence is always a no-op** (SwiftTerm only calls `clipboardCopy` for writes; never echo clipboard back to the remote).
- **Naming:** lowercase `neotilde` in code/paths; `Neotilde…` only for PascalCase type/module names.
- **Settings have no UI in Plan C** except the one OSC 52 checkbox in the existing host-editor "Neotilde behavior" section. `TerminalSettings` defaults are baked in; a future Settings screen binds later. Title + port-forward status are observable seams with no rendered surface.
- **macOS-minute budget (private repo, 10× macOS billing):** do all NeotildeKit/pure work locally in Docker; push to trigger macOS CI only at **PR-slice boundaries**, not every commit.
- **Defaults (from spec):** font 13pt (clamp 9–24), cursor `.block`, blink off, raw-PTY scrollback 5000 (presets 1000/2000/5000/10000/∞). Bell: hold-at-peak until ~400ms quiet → 250ms fade; haptic ≤1 per ~500ms. Mouse dot: 4pt `accent.primary` @ 40%. Resize debounce ~10Hz (100ms quiet). URL schemes ∈ {http, https, ssh}. `neotilde.osc52.allow` default **true**.
- Conventional commits; commit after each green step.

## File Structure

New pure units live in a new `Sources/NeotildeKit/Terminal/` group (mirrors `Tmux/`, `Predictor/`):

- `Sources/NeotildeKit/Terminal/TerminalSettings.swift` — settings value type + font clamp + DECSCUSR→style map + scrollback presets.
- `Sources/NeotildeKit/Terminal/BellStateMachine.swift` — halo intensity + haptic throttle (timestamp-injected).
- `Sources/NeotildeKit/Terminal/Osc52.swift` — write-gate decision.
- `Sources/NeotildeKit/Terminal/TitleSanitize.swift` — title validation.
- `Sources/NeotildeKit/Terminal/UrlClassify.swift` — scheme classify + wrapped-row join.
- `Sources/NeotildeKit/Terminal/ResizeDebounce.swift` — coalesce resize bursts (timestamp-injected).
- `Sources/NeotildeKit/Model/HostExtensions.swift` *(modify)* — add `Osc52Config` + `NeotildeConfig.osc52`.
- `Sources/NeotildeKit/Model/Resolution.swift` *(modify)* — add `resolveOsc52Allow`.

Tests mirror under `Tests/NeotildeKitTests/Terminal*Tests.swift`.

App wiring (macOS-CI only):
- `App/TerminalSettingsStore.swift` *(create)* — `ObservableObject` holding `TerminalSettings`, lives in `AppStores`.
- `App/BellHaloView.swift` *(create)* — the overlay.
- `App/TerminalScreen.swift` *(modify)* — raw-PTY delegate bodies + font/scrollback/cursor config + halo + pinch + URL + mouse dot.
- `App/TmuxPaneContainer.swift` *(modify)* — per-pane delegate bodies (bell/clipboard/title/link) + halo + mouse dot.
- `App/ConnectionViewModel.swift` *(modify)* — title/clipboard seams, resize-debounce wiring, host context for OSC 52 gate.
- `App/AppStores.swift` *(modify)* — register `TerminalSettingsStore`.
- `App/HostEditorSections.swift` *(modify)* — OSC 52 checkbox row.

**Timestamp-injection idiom (used by Bell + ResizeDebounce):** mirror `HostKeyTrustEvaluator.trust(…, at now: Date)` — pass `Date` into each method; tests pass a fixed base date + offsets, App passes `Date()`. No closure/clock object.

**Reference verbatim patterns:** pure decision `Sources/NeotildeKit/Tmux/TmuxLaunch.swift:55`; host-config leaf `Sources/NeotildeKit/Model/HostExtensions.swift:54` (`TmuxConfig`); resolution `Sources/NeotildeKit/Model/Resolution.swift:104` (`resolveTmuxAttemptControlMode`); editor toggle `App/HostEditorSections.swift:592`; theme tokens `theme.accent.primary` / `theme.bell.edge` / `.alpha(0.40)`; NeotildeKit test fakes/assertions `Tests/NeotildeKitTests/SerialByteWriterTests.swift`.

## Deferred (verified-out at plan time)

- **Port-forward status seam** — the spec gates this on the Rust forward-runtime path being observable from the connect path. That observability is **not** wired today (Phase 1e established the forwards in the core, but no establish/fail signal surfaces to the app). Per the spec's own hedge ("if wiring the establishment is heavy, the status seam may narrow … until Phase 4"), this unit is **deferred to Phase 4** rather than built speculatively. Noted here so it isn't silently dropped.
- **Cursor-placement halo suspension** — the halo gesture doesn't exist yet (Phase 4 keybar). Task 5 wires the mouse-active dot + long-press-selection suspend (real, shippable) and leaves a documented seam for halo-suspension.

---

### Task 1: `TerminalSettings` model + cursor default + scrollback config

**Files:**
- Create: `Sources/NeotildeKit/Terminal/TerminalSettings.swift`
- Test: `Tests/NeotildeKitTests/TerminalSettingsTests.swift`
- Create: `App/TerminalSettingsStore.swift`
- Modify: `App/AppStores.swift`, `App/TerminalScreen.swift`

**Interfaces:**
- Produces: `struct TerminalSettings` (`fontSize: Double`, `cursorStyle: CursorStyle`, `cursorBlink: Bool`, `scrollbackLines: Int`); `enum CursorStyle { case block, underline, bar }`; `TerminalSettings.clampFont(_:) -> Double`; `TerminalSettings.cursorStyle(fromDECSCUSR:) -> (style: CursorStyle, blink: Bool)`; `TerminalSettings.scrollbackPresets: [Int]`. App: `final class TerminalSettingsStore: ObservableObject { @Published var settings: TerminalSettings }`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/NeotildeKitTests/TerminalSettingsTests.swift
import XCTest
@testable import NeotildeKit

final class TerminalSettingsTests: XCTestCase {
    func testDefaultsMatchSpec() {
        let s = TerminalSettings()
        XCTAssertEqual(s.fontSize, 13)
        XCTAssertEqual(s.cursorStyle, .block)
        XCTAssertFalse(s.cursorBlink)
        XCTAssertEqual(s.scrollbackLines, 5000)
    }

    func testFontClampBoundaries() {
        XCTAssertEqual(TerminalSettings.clampFont(8), 9)    // min-1 → min
        XCTAssertEqual(TerminalSettings.clampFont(9), 9)    // min
        XCTAssertEqual(TerminalSettings.clampFont(24), 24)  // max
        XCTAssertEqual(TerminalSettings.clampFont(25), 24)  // max+1 → max
        XCTAssertEqual(TerminalSettings.clampFont(13), 13)  // interior
    }

    func testInitClampsFontSize() {
        XCTAssertEqual(TerminalSettings(fontSize: 100).fontSize, 24)
    }

    func testDECSCUSRMap() {
        XCTAssertEqual(TerminalSettings.cursorStyle(fromDECSCUSR: 0).style, .block)
        XCTAssertTrue(TerminalSettings.cursorStyle(fromDECSCUSR: 0).blink)
        XCTAssertEqual(TerminalSettings.cursorStyle(fromDECSCUSR: 2).style, .block)
        XCTAssertFalse(TerminalSettings.cursorStyle(fromDECSCUSR: 2).blink)
        XCTAssertEqual(TerminalSettings.cursorStyle(fromDECSCUSR: 4).style, .underline)
        XCTAssertEqual(TerminalSettings.cursorStyle(fromDECSCUSR: 5).style, .bar)
        XCTAssertTrue(TerminalSettings.cursorStyle(fromDECSCUSR: 5).blink)
        XCTAssertEqual(TerminalSettings.cursorStyle(fromDECSCUSR: 99).style, .block) // unknown → default
    }

    func testScrollbackPresetsIncludeSpecValues() {
        XCTAssertEqual(TerminalSettings.scrollbackPresets, [1000, 2000, 5000, 10000, Int.max])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose run --rm dev swift test --filter TerminalSettingsTests`
Expected: FAIL — `cannot find 'TerminalSettings' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/NeotildeKit/Terminal/TerminalSettings.swift
import Foundation

/// Caret rendering style, independent of blink (mirrors DECSCUSR families).
public enum CursorStyle: Equatable, Sendable { case block, underline, bar }

/// Terminal rendering preferences. Pure value type; defaults baked in per the
/// Plan C spec. A future Settings screen binds to this; Plan C ships defaults.
public struct TerminalSettings: Equatable, Sendable {
    public var fontSize: Double
    public var cursorStyle: CursorStyle
    public var cursorBlink: Bool
    public var scrollbackLines: Int

    /// Allowed font-point range (touch-legible floor, sane ceiling).
    public static let fontRange: ClosedRange<Double> = 9...24
    /// Raw-PTY scrollback presets; `Int.max` represents "unlimited".
    public static let scrollbackPresets: [Int] = [1000, 2000, 5000, 10000, Int.max]

    public init(fontSize: Double = 13,
                cursorStyle: CursorStyle = .block,
                cursorBlink: Bool = false,
                scrollbackLines: Int = 5000) {
        self.fontSize = TerminalSettings.clampFont(fontSize)
        self.cursorStyle = cursorStyle
        self.cursorBlink = cursorBlink
        self.scrollbackLines = scrollbackLines
    }

    /// Clamp a requested font size into the legible range.
    public static func clampFont(_ pt: Double) -> Double {
        min(max(pt, fontRange.lowerBound), fontRange.upperBound)
    }

    /// Map a DECSCUSR parameter (`ESC [ <n> q`) to caret style + blink.
    public static func cursorStyle(fromDECSCUSR n: Int) -> (style: CursorStyle, blink: Bool) {
        switch n {
        case 0, 1: return (.block, true)
        case 2:    return (.block, false)
        case 3:    return (.underline, true)
        case 4:    return (.underline, false)
        case 5:    return (.bar, true)
        case 6:    return (.bar, false)
        default:   return (.block, false)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `docker compose run --rm dev swift test --filter TerminalSettingsTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/NeotildeKit/Terminal/TerminalSettings.swift Tests/NeotildeKitTests/TerminalSettingsTests.swift
git commit -m "feat(terminal): TerminalSettings model with font clamp + DECSCUSR map"
```

- [ ] **Step 6: Add the App-side store + apply to the raw-PTY view (macOS-CI verified)**

Create `App/TerminalSettingsStore.swift`:

```swift
import Foundation
import NeotildeKit

/// App-lifetime holder for terminal preferences. Plan C exposes defaults only;
/// a future Settings screen mutates `settings` and views react.
@MainActor final class TerminalSettingsStore: ObservableObject {
    @Published var settings: TerminalSettings = TerminalSettings()
}
```

In `App/AppStores.swift`, add a stored property next to the other stores:

```swift
let terminalSettings = TerminalSettingsStore()
```

In `App/TerminalScreen.swift` `makeUIView(context:)`, after `terminal.terminalDelegate = context.coordinator`, apply font, cursor, and scrollback from the injected settings (pass the store's `settings` into the view; see existing `output` injection):

```swift
let s = context.coordinator.settings   // TerminalSettings passed into the Coordinator
terminal.font = UIFont.monospacedSystemFont(ofSize: CGFloat(s.fontSize), weight: .regular)
terminal.getTerminal().options.scrollback = s.scrollbackLines == Int.max ? Int.max : s.scrollbackLines
applyCursor(to: terminal, style: s.cursorStyle, blink: s.cursorBlink)   // helper below
```

Add a `applyCursor` free helper in `TerminalScreen.swift` mapping `CursorStyle` → SwiftTerm `CursorStyle` (`.blinkBlock/.steadyBlock/.blinkUnderline/.steadyUnderline/.blinkBar/.steadyBar`). Thread `TerminalSettings` into the `Coordinator.init`.

- [ ] **Step 7: Push the slice and confirm macOS CI is green**

```bash
git add App/TerminalSettingsStore.swift App/AppStores.swift App/TerminalScreen.swift
git commit -m "feat(app): apply TerminalSettings (font/cursor/scrollback) to raw-PTY view"
git push github main
```
Run: `gh run watch --repo ds7n/neotilde` (or `gh run list`). Expected: `macos` job **success** (only Apple-side validation of the App wiring).

---

### Task 2: Bell — halo state machine (pure) + overlay + haptic

**Files:**
- Create: `Sources/NeotildeKit/Terminal/BellStateMachine.swift`
- Test: `Tests/NeotildeKitTests/BellStateMachineTests.swift`
- Create: `App/BellHaloView.swift`
- Modify: `App/TerminalScreen.swift`, `App/TmuxPaneContainer.swift`

**Interfaces:**
- Consumes: `Theme.bell.edge` (existing).
- Produces: `struct BellStateMachine { mutating func ring(at: Date) -> Bool; func intensity(at: Date) -> Double }` — `ring` returns `shouldHaptic`; `intensity` ∈ [0,1].

- [ ] **Step 1: Write the failing test**

```swift
// Tests/NeotildeKitTests/BellStateMachineTests.swift
import XCTest
@testable import NeotildeKit

final class BellStateMachineTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func testFirstRingRequestsHaptic() {
        var b = BellStateMachine()
        XCTAssertTrue(b.ring(at: t0))
    }

    func testHapticThrottledWithin500ms() {
        var b = BellStateMachine()
        _ = b.ring(at: t0)
        XCTAssertFalse(b.ring(at: t0.addingTimeInterval(0.3)))   // < 500ms gap
        XCTAssertTrue(b.ring(at: t0.addingTimeInterval(0.6)))    // > 500ms gap
    }

    func testIntensityHoldsAtPeakThenFades() {
        var b = BellStateMachine()
        _ = b.ring(at: t0)
        XCTAssertEqual(b.intensity(at: t0), 1.0, accuracy: 0.0001)               // peak
        XCTAssertEqual(b.intensity(at: t0.addingTimeInterval(0.4)), 1.0, accuracy: 0.0001) // hold edge
        XCTAssertEqual(b.intensity(at: t0.addingTimeInterval(0.525)), 0.5, accuracy: 0.01)  // mid-fade
        XCTAssertEqual(b.intensity(at: t0.addingTimeInterval(0.65)), 0.0, accuracy: 0.0001)  // faded out
    }

    func testIntensityZeroBeforeAnyRing() {
        XCTAssertEqual(BellStateMachine().intensity(at: t0), 0.0)
    }

    func testNewRingResetsTheHold() {
        var b = BellStateMachine()
        _ = b.ring(at: t0)
        _ = b.ring(at: t0.addingTimeInterval(0.6))   // second ring re-arms peak
        XCTAssertEqual(b.intensity(at: t0.addingTimeInterval(0.6)), 1.0, accuracy: 0.0001)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose run --rm dev swift test --filter BellStateMachineTests`
Expected: FAIL — `cannot find 'BellStateMachine' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/NeotildeKit/Terminal/BellStateMachine.swift
import Foundation

/// Drives the visual bell halo + haptic. Timestamp-injected (no internal clock)
/// for deterministic Linux tests. Intensity holds at peak for `holdQuiet` after
/// the last ring, then fades over `fade`. Haptic fires at most once per `hapticMinGap`.
public struct BellStateMachine: Equatable, Sendable {
    public static let holdQuiet: TimeInterval = 0.4
    public static let fade: TimeInterval = 0.25
    public static let hapticMinGap: TimeInterval = 0.5

    private var lastRing: Date?
    private var lastHaptic: Date?

    public init() {}

    /// Register a bell at `now`. Returns whether a haptic should fire (throttled).
    public mutating func ring(at now: Date) -> Bool {
        lastRing = now
        if let lh = lastHaptic, now.timeIntervalSince(lh) < Self.hapticMinGap {
            return false
        }
        lastHaptic = now
        return true
    }

    /// Halo intensity ∈ [0,1] at `now`.
    public func intensity(at now: Date) -> Double {
        guard let r = lastRing else { return 0 }
        let dt = now.timeIntervalSince(r)
        if dt <= 0 { return 1 }
        if dt <= Self.holdQuiet { return 1 }
        let f = (dt - Self.holdQuiet) / Self.fade
        return f >= 1 ? 0 : 1 - f
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `docker compose run --rm dev swift test --filter BellStateMachineTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/NeotildeKit/Terminal/BellStateMachine.swift Tests/NeotildeKitTests/BellStateMachineTests.swift
git commit -m "feat(terminal): bell halo/haptic state machine (timestamp-injected)"
```

- [ ] **Step 6: Build the halo overlay + wire delegate `bell` (macOS-CI verified)**

Create `App/BellHaloView.swift`: a `UIView` that draws an inset border glow using `theme.bell.edge`, with `alpha` driven by `BellStateMachine.intensity`. Drive a `CADisplayLink` from the first `ring` until `intensity == 0`, reading `intensity(at: Date())` each frame; stop the display link when faded.

In **both** `App/TerminalScreen.swift` and `App/TmuxPaneContainer.swift` `Coordinator`, replace the `bell(source:)` stub:

```swift
func bell(source: TerminalView) {
    let haptic = bellMachine.ring(at: Date())   // bellMachine: BellStateMachine on the Coordinator
    halo.start(machine: bellMachine)             // halo: BellHaloView overlay for this view/pane
    if haptic {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }
}
```

For `TmuxPaneContainer`, the halo overlays the **active pane** (use the active-pane view; per-pane `bellMachine` keyed by `PaneID`, or one machine on the container scoped to the active pane).

- [ ] **Step 7: Push the slice and confirm macOS CI is green**

```bash
git add App/BellHaloView.swift App/TerminalScreen.swift App/TmuxPaneContainer.swift
git commit -m "feat(app): visual bell halo + soft haptic on bell()"
git push github main
```
Expected: `macos` job success. (No audio path exists — constraint upheld.)

---

### Task 3: OSC 52 write-gate + title seam + host model field

**Files:**
- Create: `Sources/NeotildeKit/Terminal/Osc52.swift`, `Sources/NeotildeKit/Terminal/TitleSanitize.swift`
- Modify: `Sources/NeotildeKit/Model/HostExtensions.swift`, `Sources/NeotildeKit/Model/Resolution.swift`
- Test: `Tests/NeotildeKitTests/Osc52Tests.swift`, `Tests/NeotildeKitTests/TitleSanitizeTests.swift`, `Tests/NeotildeKitTests/ResolutionTests.swift` (extend)
- Modify: `App/HostEditorSections.swift`, `App/TerminalScreen.swift`, `App/TmuxPaneContainer.swift`, `App/ConnectionViewModel.swift`

**Interfaces:**
- Consumes: `Inherited<NeotildeConfig>` (existing), `resolveOptional` (existing).
- Produces: `enum Osc52Action { case write([UInt8]); case drop }`; `func osc52Action(allow: Bool, content: [UInt8]) -> Osc52Action`; `func sanitizeTerminalTitle(_:) -> String?`; `struct Osc52Config { var allow: Bool? }`; `NeotildeConfig.osc52: Osc52Config?`; `func resolveOsc52Allow(host: Host, defaults: Defaults) -> Bool`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/NeotildeKitTests/Osc52Tests.swift
import XCTest
@testable import NeotildeKit

final class Osc52Tests: XCTestCase {
    func testAllowedNonEmptyWrites() {
        XCTAssertEqual(osc52Action(allow: true, content: [0x68, 0x69]), .write([0x68, 0x69]))
    }
    func testDeniedDrops() {
        XCTAssertEqual(osc52Action(allow: false, content: [0x68, 0x69]), .drop)
    }
    func testAllowedEmptyDropsToAvoidClobberingClipboard() {
        XCTAssertEqual(osc52Action(allow: true, content: []), .drop)
    }
}
```

```swift
// Tests/NeotildeKitTests/TitleSanitizeTests.swift
import XCTest
@testable import NeotildeKit

final class TitleSanitizeTests: XCTestCase {
    func testNormalTitlePassesTrimmed() {
        XCTAssertEqual(sanitizeTerminalTitle("  ~/code — vim  "), "~/code — vim")
    }
    func testEmptyOrWhitespaceRejected() {
        XCTAssertNil(sanitizeTerminalTitle(""))
        XCTAssertNil(sanitizeTerminalTitle("   "))
    }
    func testControlCharsRejected() {
        XCTAssertNil(sanitizeTerminalTitle("ev\u{07}il"))      // BEL
        XCTAssertNil(sanitizeTerminalTitle("line\u{0A}break")) // LF
        XCTAssertNil(sanitizeTerminalTitle("\u{7f}"))          // DEL
    }
}
```

Extend `Tests/NeotildeKitTests/ResolutionTests.swift` with:

```swift
func testOsc52AllowResolves() {
    XCTAssertTrue(resolveOsc52Allow(host: host(), defaults: Defaults()))   // builtin true
    XCTAssertFalse(resolveOsc52Allow(
        host: host { $0.neotilde = .explicit(NeotildeConfig(osc52: Osc52Config(allow: false))) },
        defaults: Defaults()))
    XCTAssertTrue(resolveOsc52Allow(                                       // host inherits, defaults set true
        host: host(),
        defaults: Defaults(neotilde: .explicit(NeotildeConfig(osc52: Osc52Config(allow: true))))))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `docker compose run --rm dev swift test --filter Osc52Tests --filter TitleSanitizeTests --filter ResolutionTests`
Expected: FAIL — `osc52Action`, `sanitizeTerminalTitle`, `Osc52Config`, `resolveOsc52Allow` not found.

- [ ] **Step 3: Write the implementations**

```swift
// Sources/NeotildeKit/Terminal/Osc52.swift
import Foundation

/// Result of gating an OSC 52 clipboard-write request.
public enum Osc52Action: Equatable, Sendable {
    case write([UInt8])
    case drop
}

/// Gate an OSC 52 *write* (SwiftTerm only invokes the clipboard delegate for
/// writes; reads are never echoed back — read = always no-op by construction).
/// Empty payloads drop so a stray sequence can't clear the system clipboard.
public func osc52Action(allow: Bool, content: [UInt8]) -> Osc52Action {
    guard allow, !content.isEmpty else { return .drop }
    return .write(content)
}
```

```swift
// Sources/NeotildeKit/Terminal/TitleSanitize.swift
import Foundation

/// Validate/normalize an OSC 0/2 window title. Returns the trimmed title, or
/// nil if empty or containing C0/DEL control characters.
public func sanitizeTerminalTitle(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) {
        return nil
    }
    return trimmed
}
```

In `Sources/NeotildeKit/Model/HostExtensions.swift`, add the leaf struct (mirror `TmuxConfig` at line 54) and extend `NeotildeConfig`:

```swift
// neotilde.osc52.* — per-host clipboard policy
public struct Osc52Config: Codable, Equatable, Sendable {
    public var allow: Bool?
    public init(allow: Bool? = nil) { self.allow = allow }
}
```
Then add `public var osc52: Osc52Config?` to `NeotildeConfig` and to its `init` (default `nil`), exactly mirroring the existing `predictor`/`tmux` members.

In `Sources/NeotildeKit/Model/Resolution.swift`, after `resolveTmuxAttemptControlMode` (line 104):

```swift
/// Resolve whether OSC 52 clipboard writes are permitted (builtin default: true).
public func resolveOsc52Allow(host: Host, defaults: Defaults) -> Bool {
    resolveOptional(host.neotilde, defaults.neotilde)?.osc52?.allow ?? true
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `docker compose run --rm dev swift test --filter Osc52Tests --filter TitleSanitizeTests --filter ResolutionTests`
Expected: PASS. Also run the model schema suite to catch Codable drift: `docker compose run --rm dev swift test --filter HostSchemaTests` → PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/NeotildeKit/Terminal/Osc52.swift Sources/NeotildeKit/Terminal/TitleSanitize.swift \
        Sources/NeotildeKit/Model/HostExtensions.swift Sources/NeotildeKit/Model/Resolution.swift \
        Tests/NeotildeKitTests/Osc52Tests.swift Tests/NeotildeKitTests/TitleSanitizeTests.swift \
        Tests/NeotildeKitTests/ResolutionTests.swift
git commit -m "feat(terminal): OSC 52 write-gate, title sanitize, neotilde.osc52.allow host field"
```

- [ ] **Step 6: Wire delegates + editor checkbox + title seam (macOS-CI verified)**

Add an observable title seam — in `App/ConnectionViewModel.swift` add `@Published var terminalTitle: String?` (the Phase-4 Esc-pill Live row reads it).

In `App/HostEditorSections.swift` `neotildeSection`, insert an OSC 52 toggle mirroring the tmux toggle at line 592:

```swift
Toggle(isOn: Binding(
    get: { vm.host.neotilde.value?.osc52?.allow ?? true },
    set: { newAllow in
        var cfg = vm.host.neotilde.value ?? NeotildeConfig()
        var osc52 = cfg.osc52 ?? Osc52Config()
        osc52.allow = newAllow
        cfg.osc52 = osc52
        vm.host.neotilde = .explicit(cfg)
        vm.revalidate()
    }
)) {
    VStack(alignment: .leading, spacing: 2) {
        Text("Allow OSC 52 clipboard").foregroundStyle(Color(theme.text.primary))
        Text("Let remote programs copy to your clipboard (default on).")
            .font(.caption).foregroundStyle(Color(theme.text.secondary))
    }
}
```

In **both** `Coordinator`s replace `clipboardCopy` and `setTerminalTitle`:

```swift
func clipboardCopy(source: TerminalView, content: Data) {
    if case let .write(bytes) = osc52Action(allow: osc52Allowed, content: Array(content)) {
        UIPasteboard.general.string = String(decoding: bytes, as: UTF8.self)
    }
}
func setTerminalTitle(source: TerminalView, title: String) {
    if let t = sanitizeTerminalTitle(title) { onTitle?(t) }   // onTitle → vm.terminalTitle
}
```

`osc52Allowed: Bool` is captured into the Coordinator at connect time via `resolveOsc52Allow(host:defaults:)` (the VM already resolves the connecting host/defaults). `onTitle` is a closure set to publish into `vm.terminalTitle`.

- [ ] **Step 7: Push the slice and confirm macOS CI is green**

```bash
git add App/HostEditorSections.swift App/TerminalScreen.swift App/TmuxPaneContainer.swift App/ConnectionViewModel.swift
git commit -m "feat(app): OSC 52 clipboard gate, title seam, host-editor OSC 52 toggle"
git push github main
```
Expected: `macos` job success.

---

### Task 4: URL tap — classify + wrapped-join + routing

**Files:**
- Create: `Sources/NeotildeKit/Terminal/UrlClassify.swift`
- Test: `Tests/NeotildeKitTests/UrlClassifyTests.swift`
- Modify: `App/TerminalScreen.swift`, `App/TmuxPaneContainer.swift`

**Interfaces:**
- Produces: `enum URLKind { case http, https, ssh }`; `func classifyURL(_:) -> URLKind?`; `func joinWrappedURL(part1: String, part2: String) -> String?`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/NeotildeKitTests/UrlClassifyTests.swift
import XCTest
@testable import NeotildeKit

final class UrlClassifyTests: XCTestCase {
    func testClassifiesAllowedSchemes() {
        XCTAssertEqual(classifyURL("https://example.com"), .https)
        XCTAssertEqual(classifyURL("http://example.com"), .http)
        XCTAssertEqual(classifyURL("ssh://user@host"), .ssh)
        XCTAssertEqual(classifyURL("HTTPS://Example.com"), .https)   // case-insensitive
    }
    func testRejectsDisallowedSchemes() {
        XCTAssertNil(classifyURL("mailto:a@b.com"))
        XCTAssertNil(classifyURL("ftp://host/x"))
        XCTAssertNil(classifyURL("javascript:alert(1)"))
        XCTAssertNil(classifyURL(""))
        XCTAssertNil(classifyURL("example.com"))                     // no scheme
    }
    func testJoinsWrappedURLOnlyWhenTight() {
        XCTAssertEqual(joinWrappedURL(part1: "https://exa", part2: "mple.com"), "https://example.com")
        XCTAssertNil(joinWrappedURL(part1: "https://exa ", part2: "mple.com"))  // trailing space
        XCTAssertNil(joinWrappedURL(part1: "https://exa", part2: " mple.com"))  // leading space
        XCTAssertNil(joinWrappedURL(part1: "", part2: "mple.com"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose run --rm dev swift test --filter UrlClassifyTests`
Expected: FAIL — symbols not found.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/NeotildeKit/Terminal/UrlClassify.swift
import Foundation

/// Tappable-URL schemes recognized by Plan C.
public enum URLKind: Equatable, Sendable { case http, https, ssh }

/// Classify a detected link by scheme; nil for anything outside the allowlist.
public func classifyURL(_ link: String) -> URLKind? {
    let lower = link.lowercased()
    if lower.hasPrefix("https://") { return .https }
    if lower.hasPrefix("http://")  { return .http }
    if lower.hasPrefix("ssh://")   { return .ssh }
    return nil
}

/// Join a URL split across a hard row wrap — only when part1 ends mid-token
/// (no trailing whitespace) and part2 starts at column 0 (no leading whitespace).
public func joinWrappedURL(part1: String, part2: String) -> String? {
    guard let last = part1.last, !last.isWhitespace else { return nil }
    guard let first = part2.first, !first.isWhitespace else { return nil }
    return part1 + part2
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `docker compose run --rm dev swift test --filter UrlClassifyTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/NeotildeKit/Terminal/UrlClassify.swift Tests/NeotildeKitTests/UrlClassifyTests.swift
git commit -m "feat(terminal): URL scheme classify + wrapped-row join"
```

- [ ] **Step 6: Route taps (macOS-CI verified)**

In both `Coordinator`s, replace `requestOpenLink`:

```swift
func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
    guard let kind = classifyURL(link), let url = URL(string: link) else { return }
    switch kind {
    case .http, .https:
        UIApplication.shared.open(url)        // system browser / in-app per OS
    case .ssh:
        onSSHLink?(url)                        // seam: prefill the connect form (set by ConnectionView)
    }
}
```

`onSSHLink` is a real, optional closure (not a no-op): wire it to populate the connect sheet's host/user/port from the `ssh://` URL when present; if unset, the link is ignored. SwiftTerm already joins display-wrapped URLs in `link`; `joinWrappedURL` is exercised by tests and available for any manual reconstruction path.

- [ ] **Step 7: Push the slice and confirm macOS CI is green**

```bash
git add App/TerminalScreen.swift App/TmuxPaneContainer.swift
git commit -m "feat(app): open tapped http(s) links; ssh-link connect seam"
git push github main
```
Expected: `macos` job success.

---

### Task 5: Mouse-active dot + resize debounce

**Files:**
- Create: `Sources/NeotildeKit/Terminal/ResizeDebounce.swift`
- Test: `Tests/NeotildeKitTests/ResizeDebounceTests.swift`
- Modify: `App/TerminalScreen.swift`, `App/TmuxPaneContainer.swift`, `App/ConnectionViewModel.swift`

**Interfaces:**
- Produces: `struct ResizeDebounce { mutating func note(cols: Int, rows: Int, at: Date); mutating func tick(at: Date) -> (cols: Int, rows: Int)? }`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/NeotildeKitTests/ResizeDebounceTests.swift
import XCTest
@testable import NeotildeKit

final class ResizeDebounceTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 2_000_000)

    func testHoldsBeforeQuietWindow() {
        var d = ResizeDebounce()
        d.note(cols: 80, rows: 24, at: t0)
        XCTAssertNil(d.tick(at: t0.addingTimeInterval(0.05)))   // < 100ms
    }
    func testEmitsAfterQuietWindow() {
        var d = ResizeDebounce()
        d.note(cols: 80, rows: 24, at: t0)
        let out = d.tick(at: t0.addingTimeInterval(0.1))
        XCTAssertEqual(out?.cols, 80); XCTAssertEqual(out?.rows, 24)
    }
    func testCoalescesBurstToLatest() {
        var d = ResizeDebounce()
        d.note(cols: 80, rows: 24, at: t0)
        d.note(cols: 100, rows: 30, at: t0.addingTimeInterval(0.03))   // resets the quiet timer
        XCTAssertNil(d.tick(at: t0.addingTimeInterval(0.1)))           // only 70ms since last note
        let out = d.tick(at: t0.addingTimeInterval(0.14))
        XCTAssertEqual(out?.cols, 100); XCTAssertEqual(out?.rows, 30)  // latest wins
    }
    func testEmitsOnceThenClears() {
        var d = ResizeDebounce()
        d.note(cols: 80, rows: 24, at: t0)
        _ = d.tick(at: t0.addingTimeInterval(0.1))
        XCTAssertNil(d.tick(at: t0.addingTimeInterval(0.2)))           // nothing pending
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose run --rm dev swift test --filter ResizeDebounceTests`
Expected: FAIL — `ResizeDebounce` not found.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/NeotildeKit/Terminal/ResizeDebounce.swift
import Foundation

/// Coalesce a burst of size changes (rotation / keyboard show-hide) into a single
/// resize once input goes quiet for `quiet` seconds (~10Hz). Timestamp-injected.
public struct ResizeDebounce: Equatable, Sendable {
    public static let quiet: TimeInterval = 0.1

    private var pendingCols: Int?
    private var pendingRows: Int?
    private var lastChange: Date?

    public init() {}

    /// Record a requested size; resets the quiet timer.
    public mutating func note(cols: Int, rows: Int, at now: Date) {
        pendingCols = cols; pendingRows = rows; lastChange = now
    }

    /// If a pending size has been quiet for `quiet`, return and clear it; else nil.
    public mutating func tick(at now: Date) -> (cols: Int, rows: Int)? {
        guard let lc = lastChange, let c = pendingCols, let r = pendingRows else { return nil }
        guard now.timeIntervalSince(lc) >= Self.quiet else { return nil }
        pendingCols = nil; pendingRows = nil; lastChange = nil
        return (c, r)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `docker compose run --rm dev swift test --filter ResizeDebounceTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/NeotildeKit/Terminal/ResizeDebounce.swift Tests/NeotildeKitTests/ResizeDebounceTests.swift
git commit -m "feat(terminal): resize-debounce coalescer (timestamp-injected)"
```

- [ ] **Step 6: Wire debounce + mouse dot (macOS-CI verified)**

Raw-PTY path (`App/TerminalScreen.swift` `sizeChanged`): instead of resizing immediately, `note(cols:rows:at: Date())` into a `ResizeDebounce` and schedule a `tick` ~100ms later on the main queue; on a non-nil `tick`, call `session.resize`. Tmux path: same, feeding `ConnectionViewModel.setTmuxClientSize`.

Mouse dot: add a 4pt dot subview to each `TerminalView` host, colored `theme.accent.primary.alpha(0.40)`, shown when the terminal's `mouseMode != .off` (read `terminalView.getTerminal().mouseMode` after feeds / on a lightweight poll). While mouse mode is active, suspend the Neotilde long-press selection gesture (disable the recognizer). Leave a `// TODO(phase4): also suspend cursor-placement halo here` seam comment at that exact point.

- [ ] **Step 7: Push the slice and confirm macOS CI is green**

```bash
git add App/TerminalScreen.swift App/TmuxPaneContainer.swift App/ConnectionViewModel.swift
git commit -m "feat(app): debounced resize + mouse-active bronze dot + selection suspend"
git push github main
```
Expected: `macos` job success.

---

### Task 6: Pinch-zoom font (per-window)

**Files:**
- Modify: `App/TerminalScreen.swift`, `App/TmuxPaneContainer.swift`

**Interfaces:**
- Consumes: `TerminalSettings.clampFont(_:)` (Task 1).

> App-only slice — no new pure unit. Font clamping is already covered by `TerminalSettingsTests` (Task 1), so this task's correctness gate is the macOS build + a manual check; no Linux test is added.

- [ ] **Step 1: Add the pinch gesture (macOS-CI verified)**

Attach a `UIPinchGestureRecognizer` to each `TerminalView`. On `.changed`, compute `newSize = TerminalSettings.clampFont(baseSize * recognizer.scale)` and set `terminal.font = UIFont.monospacedSystemFont(ofSize: CGFloat(newSize), weight: .regular)`; reset `recognizer.scale = 1` and update `baseSize` on `.ended`. The size persists for the window's lifetime (not stored to the host — per spec, persistence beyond window lifetime is v1.5+). For `TmuxPaneContainer`, invalidate `cachedCell` after a font change so pane-rect metrics recompute.

- [ ] **Step 2: Push the slice and confirm macOS CI is green**

```bash
git add App/TerminalScreen.swift App/TmuxPaneContainer.swift
git commit -m "feat(app): pinch-to-zoom terminal font (clamped, per-window)"
git push github main
```
Expected: `macos` job success.

- [ ] **Step 3: Manual verification on the Simulator**

Per `docs/mvp-app-testing.md`, connect to a host, pinch to resize, fire a bell (`printf '\a'`), tap a URL, run `tmux` and split a pane, and confirm: font scales + clamps, halo+haptic fires, http(s) opens, mouse-mode dot appears under a mouse-mode TUI (e.g. `vim` with mouse on), and rotation triggers a single debounced resize.

---

## Verification

- **Pure units (every task, Linux):** `docker compose run --rm dev swift test` — the full `NeotildeKit` suite stays green; new `Terminal*Tests` + extended `ResolutionTests`/`HostSchemaTests` pass. This is the primary correctness gate and runs free/local.
- **App wiring (per slice, macOS):** push at the slice boundary → `gh run watch --repo ds7n/neotilde` → `macos` job **success**. This is the only validation of UIKit/SwiftTerm wiring (App code is invisible to Linux `swift test`).
- **Model integrity:** `HostSchemaTests` must pass after the `Osc52Config` addition (Codable round-trip), and `HostFormValidationTests` stays green (no new constraints).
- **End-to-end:** the Task 6 Simulator pass exercises bell, OSC 52 copy, title capture, URL tap, mouse dot, pinch-zoom, and debounced resize against a real `sshd`/`tmux`.
- **Budget discipline:** 6 macOS pushes for the 6 slices (+ reruns for the known `linux-rust` DNS flake, which doesn't gate macOS). Comfortably within the private-repo free quota; flip the repo public only if iteration on a slice needs many macOS round-trips.

## Self-review notes (spec coverage)

Spec units → tasks: `TerminalSettings`/cursor/scrollback → T1; bell state machine + halo + haptic → T2; OSC 52 write-gate + title sanitize + title seam + `neotilde.osc52.allow` + editor checkbox → T3; URL classify/join + routing → T4; resize debounce + mouse-active dot + selection-suspend (with halo-suspend seam) → T5; pinch-zoom font → T6. DECSCUSR map folded into T1 (pure) + applied in T1 App step. **Deferred with rationale:** port-forward status seam (runtime path not observable today — Phase 4); cursor-placement halo suspension (gesture is Phase 4 — seam left in T5). Out-of-scope items (audio bell, bracketed paste, OSC 8, sixel, cursor color, per-host font persistence, ad-hoc forwards) are not tasked, per spec §"Out of scope".
