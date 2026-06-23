# Phase 3 Plan A — tmux Control-Mode Attach + Single-Pane Round-Trip

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On connect, probe the remote `tmux`, and — when it's ≥3.0 and the host allows it — **attach a `tmux -CC` control-mode session** and render the **active pane** end-to-end in the terminal (output + keyboard), otherwise fall back to a raw-PTY shell with an amber "degraded" banner.

**Architecture:** The tmux control-mode *engine* (parser, `TmuxSessionController`, session model) already exists and is tested in `GlymrKit/Tmux/`. This plan adds (1) a small engine change to **surface `%output` pane bytes** (currently dropped), (2) **pure launch-decision logic** in `GlymrKit` (version parsing, session naming, attach-vs-degrade decision) — all Linux-tested, and (3) the **iOS app glue** that runs the probe over the existing `open_exec` transport, drives the controller, routes the active pane's bytes to the existing single SwiftTerm view, and shows the degraded banner. A Rust integration test against the tmux-equipped CI sshd fixture proves the transport.

**Tech Stack:** Swift 6 `GlymrKit` (XCTest, Linux), the `GlymrSSHCoreFFI` UniFFI bridge + SwiftUI app target (macOS-CI compile gate), Rust integration test (`glymr-ssh-core`, linux-rust against the `tmux`-equipped sshd fixture).

## Scope

**This plan (Phase 3 Plan A):**
- Connect-time `tmux -V` probe over `open_exec`; decision = attach / degrade, honoring the host's `glymr.tmux.attemptControlMode`.
- Attach `tmux -CC new-session -A -s glymr-<hash>` (session name via a swappable stub provider).
- Surface `%output` from the controller; route the **active pane's** bytes into the existing single SwiftTerm `TerminalScreen`.
- Keyboard input → `send-keys` to the active pane.
- Amber transient "degraded — running as plain SSH" banner on fallback (tmux <3.0 / not found / opted out).
- Rust integration test: `tmux -CC` attach over `open_exec` produces a control-mode handshake.

**Deferred to later Phase-3 plans (do NOT build here):**
- **Multi-pane layout rendering** (one SwiftTerm view per leaf pane, `visibleLayout` walk, active-pane border, bell halo, mouse dot) — **Plan B** (the user chose *multi-window now* + *no manual pane switching* for that plan).
- **Terminal UX polish** (URL tap, OSC 52, titles, port-forward status, Terminal settings) — Plan C.
- **Context-detection state machine + mid-session tmux-crash red banner** — Plan D.
- Anything needing Apple Developer enrollment (real CloudKit-derived session hash, on-device verification). The session name uses a **local stub hash** behind a seam swappable in 2b-ii.

## File Structure

| File | Responsibility | Test surface |
|---|---|---|
| `Sources/GlymrKit/Tmux/TmuxSessionController.swift` *(modify)* | add `paneOutput` to `TmuxControllerOutput`; collect `.output` events in `feed` | Linux `swift test` |
| `Sources/GlymrKit/Tmux/TmuxLaunch.swift` *(create)* | pure: `parseTmuxVersion`, `tmuxSupportsControlMode`, `TmuxLaunchDecision`, `tmuxLaunchDecision(...)`, `SessionNameProvider` + `StubSessionNameProvider`, `tmuxSessionName(seed:)` | Linux `swift test` |
| `crates/glymr-ssh-core/tests/tmux_integration.rs` *(modify)* | add a `tmux -CC new-session -A` attach assertion | linux-rust (fixture-gated) |
| `App/TmuxRuntime.swift` *(create)* | app-side control-mode driver: owns `TmuxSessionController`, a `ShellOutput` sink that feeds it, active-pane output routing + `send-keys` input | macOS-CI compile |
| `App/ConnectionViewModel.swift` *(modify)* | probe → decision → attach-or-degrade; set degraded banner | macOS-CI compile |
| `App/DegradedBanner.swift` *(create)* | transient amber banner view | macOS-CI compile |
| `App/SessionView.swift` *(modify)* | host the banner over the terminal | macOS-CI compile |

## Global Constraints

- Every source/test file begins with `// SPDX-FileCopyrightText: 2026 True Positive LLC` then `// SPDX-License-Identifier: GPL-3.0-only` (Rust uses `//`).
- **No Apple-only APIs in `GlymrKit`** — `TmuxLaunch.swift` and the controller change are pure value-type Swift, Linux-tested. Anything touching `GlymrSSHCoreFFI`/UIKit lives in `App/`.
- **Control-mode requires tmux ≥ 3.0**; below that → raw-PTY degraded mode (roadmap cross-cutting constraint).
- Session name format is `glymr-<accountHash>` where `<accountHash>` is 8 lowercase hex chars; the real hash (`SHA-256` of the CloudKit account key) is enrollment-gated, so Plan A uses a **stub provider** — keep the `SessionNameProvider` seam so 2b-ii swaps the real one in. The attach command is exactly `tmux -CC new-session -A -s <name>` (atomic create-or-attach) — produced by the existing `TmuxSessionController.start(sessionName:)`, do not hand-roll it.
- The probe/attach reuse the existing `Connection.openExec(command:term:cols:rows:output:)` transport — do NOT add a new Rust channel type.
- Testing tier: **Core** for `TmuxLaunch` pure logic (EP + BVA on versions, good AND bad cases, exact-value assertions) and the `%output` surfacing (assert exact pane id + exact bytes). The Rust attach test is an **integration smoke** (fixture-gated, asserts the handshake is control-mode).
- Conventional commits; commit after every green step. Branch `feat/phase-3a-tmux-attach`; squash-merge at the end.
- Test commands: `docker compose run --rm dev swift test --filter <Class>`; `docker compose run --rm dev cargo test -p glymr-ssh-core` (the tmux attach test is gated behind the existing `GLYMR_TEST_SSHD` env the suite already uses).

---

### Task 0: Branch + plan doc

- [ ] **Step 1: Create the feature branch**

```bash
git checkout -b feat/phase-3a-tmux-attach
```

- [ ] **Step 2: Commit the plan doc**

```bash
git add docs/superpowers/plans/2026-06-23-phase-3a-tmux-attach-bridge.md
git commit -m "docs: Phase 3 Plan A — tmux attach bridge plan"
```

---

### Task 1: Surface `%output` pane bytes from the controller

The parser already decodes `%output <pane> <data>` into `ControlModeEvent.output(pane:data:)`, but `TmuxSessionController.feed` passes it to `state.apply()` which **drops it** (`TmuxSessionState.apply` breaks on `.output`). Collect those bytes into the `feed` return value so the app can route them to a terminal view.

**Files:**
- Modify: `Sources/GlymrKit/Tmux/TmuxSessionController.swift`
- Test: `Tests/GlymrKitTests/TmuxControllerOutputTests.swift` (create)

**Interfaces:**
- Consumes (exist): `ControlModeEvent.output(pane: PaneID, data: [UInt8])`, `PaneID(raw: UInt32)`, `TmuxControllerOutput`, `TmuxSessionController.feed(_:)`.
- Produces (consumed by Task 4/5): `TmuxControllerOutput.paneOutput: [(pane: PaneID, data: [UInt8])]` — in-order pane output decoded during this `feed` call (empty when none).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/GlymrKitTests/TmuxControllerOutputTests.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import GlymrKit

final class TmuxControllerOutputTests: XCTestCase {
    /// Drives the controller through a minimal attach so it is `.attached`, then
    /// feeds a `%output` line and asserts the bytes surface on `paneOutput`.
    func testFeedSurfacesPaneOutputBytes() {
        let c = TmuxSessionController()
        _ = c.start(sessionName: "glymr-test")
        // Attach handshake: a spontaneous %begin/%end block + %session-changed.
        _ = c.feed(Array("\u{1b}P1000p%begin 1 0\r\n%end 1 0\r\n%session-changed $1 glymr-test\r\n".utf8))

        // tmux escapes output octally; "hi" is plain ASCII so it passes through.
        let out = c.feed(Array("%output %1 hi\r\n".utf8))

        XCTAssertEqual(out.paneOutput.count, 1)
        XCTAssertEqual(out.paneOutput.first?.pane, PaneID(raw: 1))
        XCTAssertEqual(out.paneOutput.first?.data.map { $0 }, Array("hi".utf8))
    }

    /// A feed with no %output yields an empty paneOutput (not nil, not garbage).
    func testFeedWithoutOutputHasEmptyPaneOutput() {
        let c = TmuxSessionController()
        _ = c.start(sessionName: "glymr-test")
        let out = c.feed(Array("\u{1b}P1000p%begin 1 0\r\n%end 1 0\r\n%session-changed $1 glymr-test\r\n".utf8))
        XCTAssertTrue(out.paneOutput.isEmpty)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
docker compose run --rm dev swift test --filter TmuxControllerOutputTests
```

Expected: FAIL — `paneOutput` is not a member of `TmuxControllerOutput`.

> If the attach-handshake byte sequence in the test doesn't drive the controller to `.attached` (e.g. the spontaneous `%begin` block is consumed differently), inspect `advanceLifecycle`/`ControlModeParser` and adjust the priming bytes so the controller is attached before the `%output` feed — the assertion under test is the `paneOutput` surfacing, not the handshake shape.

- [ ] **Step 3: Add `paneOutput` to `TmuxControllerOutput` and collect it in `feed`**

In `TmuxControllerOutput`, add the field + init parameter:

```swift
public struct TmuxControllerOutput: Equatable, Sendable {
    public var lifecycleChanged: Bool
    public var stateChanged: Bool
    public var resolved: [ResolvedCommand]
    /// Pane output decoded during this feed, in arrival order. Empty when none.
    public var paneOutput: [PaneOutputChunk]
    public init(lifecycleChanged: Bool, stateChanged: Bool,
                resolved: [ResolvedCommand], paneOutput: [PaneOutputChunk]) {
        self.lifecycleChanged = lifecycleChanged
        self.stateChanged = stateChanged
        self.resolved = resolved
        self.paneOutput = paneOutput
    }
}

/// A decoded `%output` chunk: the pane it belongs to and its raw bytes.
public struct PaneOutputChunk: Equatable, Sendable {
    public let pane: PaneID
    public let data: [UInt8]
    public init(pane: PaneID, data: [UInt8]) {
        self.pane = pane
        self.data = data
    }
}
```

> `(pane: PaneID, data: [UInt8])` tuples are not `Equatable`, so the test's `out.paneOutput.first?.pane` access and `TmuxControllerOutput: Equatable` both need a named struct — hence `PaneOutputChunk`. Update the "Produces" mental model accordingly: `paneOutput: [PaneOutputChunk]`.

In `feed`, collect output events. Change the loop + return:

```swift
public func feed(_ bytes: [UInt8]) -> TmuxControllerOutput {
    let beforeState = state
    let beforeLifecycle = lifecycle
    var resolved: [ResolvedCommand] = []
    var paneOutput: [PaneOutputChunk] = []

    for event in parser.feed(bytes) {
        if case .commandResult(_, let outcome) = event {
            if !pending.isEmpty {
                resolved.append(ResolvedCommand(id: pending.removeFirst(), outcome: outcome))
            }
            continue
        }
        if case .output(let pane, let data) = event {
            paneOutput.append(PaneOutputChunk(pane: pane, data: data))
            continue   // output is application data, not a structural state event
        }
        advanceLifecycle(for: event)
        state.apply(event)
    }

    return TmuxControllerOutput(
        lifecycleChanged: lifecycle != beforeLifecycle,
        stateChanged: state != beforeState,
        resolved: resolved,
        paneOutput: paneOutput
    )
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
docker compose run --rm dev swift test --filter TmuxControllerOutputTests
```

Expected: PASS (2/2).

- [ ] **Step 5: Run the full Tmux suite to confirm no regression**

```bash
docker compose run --rm dev swift test --filter Tmux
```

Expected: all existing tmux tests still pass (the `.output`-drops-into-state behavior is replaced by `.output`-into-`paneOutput`; confirm no existing test asserted `.output` mutates `state`).

- [ ] **Step 6: Commit**

```bash
git add Sources/GlymrKit/Tmux/TmuxSessionController.swift Tests/GlymrKitTests/TmuxControllerOutputTests.swift
git commit -m "feat: surface tmux %output pane bytes from the controller"
```

---

### Task 2: Pure launch logic — version probe, decision, session name

All the attach-vs-degrade reasoning as pure functions in `GlymrKit`, so the app layer is thin I/O. Linux-tested.

**Files:**
- Create: `Sources/GlymrKit/Tmux/TmuxLaunch.swift`
- Test: `Tests/GlymrKitTests/TmuxLaunchTests.swift`

**Interfaces:**
- Produces (consumed by Task 4/5):
  - `struct TmuxVersion: Equatable, Comparable, Sendable { let major: Int; let minor: Int }`
  - `func parseTmuxVersion(_ probeOutput: String) -> TmuxVersion?` — parses `tmux -V` output like `"tmux 3.3a"` / `"tmux 3.4\n"` / `"tmux next-3.4"`; nil if unparseable.
  - `func tmuxSupportsControlMode(_ v: TmuxVersion) -> Bool` — `v >= TmuxVersion(major: 3, minor: 0)`.
  - `enum TmuxLaunchDecision: Equatable, Sendable { case attach; case degrade(DegradeReason) }`
  - `enum DegradeReason: Equatable, Sendable { case optedOut; case tmuxNotFound; case tooOld(TmuxVersion) }`
  - `func tmuxLaunchDecision(attemptControlMode: Bool, versionProbe: String?) -> TmuxLaunchDecision` — `attemptControlMode == false` → `.degrade(.optedOut)`; `versionProbe == nil` or unparseable → `.degrade(.tmuxNotFound)`; parsed but <3.0 → `.degrade(.tooOld(v))`; else `.attach`.
  - `protocol SessionNameProvider { func sessionName() -> String }`
  - `func tmuxSessionName(seed: String) -> String` — `"glymr-" + first 8 lowercase hex of SHA-256(seed)`.
  - `struct StubSessionNameProvider: SessionNameProvider { let seed: String; init(seed: String); func sessionName() -> String { tmuxSessionName(seed: seed) } }`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/GlymrKitTests/TmuxLaunchTests.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import GlymrKit

final class TmuxLaunchTests: XCTestCase {
    func testParseVersionVariants() {
        XCTAssertEqual(parseTmuxVersion("tmux 3.3a"), TmuxVersion(major: 3, minor: 3))
        XCTAssertEqual(parseTmuxVersion("tmux 3.4\n"), TmuxVersion(major: 3, minor: 4))
        XCTAssertEqual(parseTmuxVersion("tmux 2.9"), TmuxVersion(major: 2, minor: 9))
        XCTAssertEqual(parseTmuxVersion("tmux next-3.5"), TmuxVersion(major: 3, minor: 5))
        XCTAssertNil(parseTmuxVersion("bash: tmux: command not found"))
        XCTAssertNil(parseTmuxVersion(""))
    }

    func testSupportsControlModeBoundary() {
        XCTAssertFalse(tmuxSupportsControlMode(TmuxVersion(major: 2, minor: 9)))  // max-1 below floor
        XCTAssertTrue(tmuxSupportsControlMode(TmuxVersion(major: 3, minor: 0)))   // exact floor
        XCTAssertTrue(tmuxSupportsControlMode(TmuxVersion(major: 3, minor: 1)))
        XCTAssertFalse(tmuxSupportsControlMode(TmuxVersion(major: 1, minor: 9)))
    }

    func testLaunchDecisionPartitions() {
        XCTAssertEqual(tmuxLaunchDecision(attemptControlMode: false, versionProbe: "tmux 3.3a"), .degrade(.optedOut))
        XCTAssertEqual(tmuxLaunchDecision(attemptControlMode: true, versionProbe: nil), .degrade(.tmuxNotFound))
        XCTAssertEqual(tmuxLaunchDecision(attemptControlMode: true, versionProbe: "command not found"), .degrade(.tmuxNotFound))
        XCTAssertEqual(tmuxLaunchDecision(attemptControlMode: true, versionProbe: "tmux 2.9"),
                       .degrade(.tooOld(TmuxVersion(major: 2, minor: 9))))
        XCTAssertEqual(tmuxLaunchDecision(attemptControlMode: true, versionProbe: "tmux 3.0"), .attach)
    }

    func testSessionNameIsStableHexSlug() {
        let name = tmuxSessionName(seed: "device-abc")
        XCTAssertTrue(name.hasPrefix("glymr-"))
        let hex = name.dropFirst("glymr-".count)
        XCTAssertEqual(hex.count, 8)
        XCTAssertTrue(hex.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertEqual(tmuxSessionName(seed: "device-abc"), name)             // deterministic
        XCTAssertNotEqual(tmuxSessionName(seed: "device-xyz"), name)          // seed-sensitive
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
docker compose run --rm dev swift test --filter TmuxLaunchTests
```

Expected: FAIL — symbols undefined.

- [ ] **Step 3: Implement `TmuxLaunch.swift`**

```swift
// Sources/GlymrKit/Tmux/TmuxLaunch.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// A parsed `major.minor` tmux version (patch letters like `3.3a` are ignored).
public struct TmuxVersion: Equatable, Comparable, Sendable {
    public let major: Int
    public let minor: Int
    public init(major: Int, minor: Int) { self.major = major; self.minor = minor }
    public static func < (l: TmuxVersion, r: TmuxVersion) -> Bool {
        (l.major, l.minor) < (r.major, r.minor)
    }
}

/// Parses `tmux -V` output (e.g. "tmux 3.3a", "tmux next-3.5") to `major.minor`,
/// or nil when no `<int>.<int>` version token is present.
public func parseTmuxVersion(_ probeOutput: String) -> TmuxVersion? {
    // Find the first token matching <digits>.<digits>, ignoring any trailing letters.
    for token in probeOutput.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "-" }) {
        let digits = token.prefix { $0.isNumber || $0 == "." }
        let parts = digits.split(separator: ".")
        if parts.count >= 2, let maj = Int(parts[0]), let min = Int(parts[1]) {
            return TmuxVersion(major: maj, minor: min)
        }
    }
    return nil
}

/// Control mode needs tmux ≥ 3.0 (roadmap constraint).
public func tmuxSupportsControlMode(_ v: TmuxVersion) -> Bool {
    v >= TmuxVersion(major: 3, minor: 0)
}

/// Why Glymr fell back to a raw-PTY shell instead of attaching control mode.
public enum DegradeReason: Equatable, Sendable {
    case optedOut                 // host's glymr.tmux.attemptControlMode == false
    case tmuxNotFound             // probe empty / unparseable
    case tooOld(TmuxVersion)      // tmux < 3.0
}

/// The connect-time launch decision.
public enum TmuxLaunchDecision: Equatable, Sendable {
    case attach
    case degrade(DegradeReason)
}

/// Decide whether to attach control mode given the host's opt-in flag and the
/// captured `tmux -V` output (nil when the probe produced nothing).
public func tmuxLaunchDecision(attemptControlMode: Bool, versionProbe: String?) -> TmuxLaunchDecision {
    guard attemptControlMode else { return .degrade(.optedOut) }
    guard let probe = versionProbe, let v = parseTmuxVersion(probe) else { return .degrade(.tmuxNotFound) }
    return tmuxSupportsControlMode(v) ? .attach : .degrade(.tooOld(v))
}

/// Supplies the shared tmux session name. The real implementation derives it from
/// the iCloud-account-bound CloudKit key (2b-ii, enrollment-gated); Plan A uses a
/// local stub seed.
public protocol SessionNameProvider {
    func sessionName() -> String
}

/// `glymr-<first 8 lowercase hex of SHA-256(seed)>`.
public func tmuxSessionName(seed: String) -> String {
    let digest = SHA256.hash(data: Data(seed.utf8))
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return "glymr-" + hex.prefix(8)
}

/// Stub provider: a deterministic name from a local seed. Swap for a
/// CloudKit-key-derived provider in 2b-ii.
public struct StubSessionNameProvider: SessionNameProvider {
    public let seed: String
    public init(seed: String) { self.seed = seed }
    public func sessionName() -> String { tmuxSessionName(seed: seed) }
}
```

- [ ] **Step 4: Run to verify pass**

```bash
docker compose run --rm dev swift test --filter TmuxLaunchTests
```

Expected: PASS (4/4 methods).

- [ ] **Step 5: Commit**

```bash
git add Sources/GlymrKit/Tmux/TmuxLaunch.swift Tests/GlymrKitTests/TmuxLaunchTests.swift
git commit -m "feat: pure tmux launch decision + session-name logic"
```

---

### Task 3: Rust integration test — `tmux -CC` attach over `open_exec`

Prove the transport end-to-end against the CI sshd fixture (which has `tmux` installed). Extend the existing `tmux_integration.rs`.

**Files:**
- Modify: `crates/glymr-ssh-core/tests/tmux_integration.rs`

**Interfaces:**
- Consumes (exist): `connect_core`, `Connection.open_exec`, the `Collector` test sink, `TrustAll`, the `GLYMR_TEST_SSHD` gate (read the file's existing helpers/setup first and reuse them).

- [ ] **Step 1: Read the existing test file and its helpers**

```bash
sed -n '1,140p' crates/glymr-ssh-core/tests/tmux_integration.rs
```

Identify the existing connect+auth helper and how a `tmux -CC` exec smoke (if present) is structured. Reuse that scaffolding.

- [ ] **Step 2: Add the attach assertion test**

Add a test that runs the exact attach command and asserts the stream is control-mode (a `%begin` block appears, i.e. the DCS-wrapped control protocol started). Use the existing connect helper for the body; this is the shape:

```rust
#[tokio::test]
async fn tmux_cc_new_session_produces_control_mode_handshake() {
    let Some(conn) = connect_and_auth().await else { return };  // skips when GLYMR_TEST_SSHD unset
    let collector = Collector::new();
    let _session = conn
        .open_exec(
            "tmux -CC new-session -A -s glymr-itest".to_string(),
            "xterm-256color".to_string(), 80, 24,
            Arc::new(collector.clone()),
        )
        .await
        .expect("open_exec tmux -CC");

    // Control mode emits a %begin/%end block and a %session-changed line on attach.
    wait_until(Duration::from_secs(5), || collector.text().contains("%begin")).await;
    let text = collector.text();
    assert!(text.contains("%begin"), "expected a control-mode %begin block, got: {text:?}");
    assert!(text.contains("%session-changed") || text.contains("%output") || text.contains("%window"),
            "expected control-mode session events, got: {text:?}");
}
```

> Match the real helper names in the file (`connect_and_auth`/`wait_until` are illustrative — use whatever the file already defines; if there's no poll helper, loop with `tokio::time::sleep` up to ~5s checking `collector.text()`). Keep the test behind the same `GLYMR_TEST_SSHD` skip guard the other integration tests use, so it no-ops in environments without the fixture.

- [ ] **Step 3: Run the integration test**

```bash
docker compose run --rm dev cargo test -p glymr-ssh-core --test tmux_integration
```

Expected: PASS (the dev compose brings up the `tmux`-equipped sshd fixture; the new test sees a `%begin` handshake). If the suite skips when the fixture env isn't set, confirm it at least compiles and the existing tmux tests run.

- [ ] **Step 4: Commit**

```bash
git add crates/glymr-ssh-core/tests/tmux_integration.rs
git commit -m "test: tmux -CC attach produces a control-mode handshake over open_exec"
```

---

### Task 4: App control-mode runtime driver (`TmuxRuntime`)

The app-side object that owns a `TmuxSessionController`, exposes a `ShellOutput` sink that feeds inbound channel bytes into the controller, surfaces the **active pane's** output to a byte closure (for the terminal view), and encodes keyboard input as `send-keys` to the active pane. macOS-only (uses the bridge).

**Files:**
- Create: `App/TmuxRuntime.swift`

**Interfaces:**
- Consumes: `TmuxSessionController` (`start`, `submit`, `feed`, `lifecycle`, `state`), `TmuxControllerOutput.paneOutput` (Task 1), `PaneOutputChunk`, `TmuxCommand.sendKeys(target:bytes:)`, `TmuxSessionState.window(_:).activePane` / `state.activeWindow`, `GlymrSSHCoreFFI.ShellOutput` (the foreign trait `TerminalShellOutput` already implements in `App/Bridges.swift`), `ShellSession.write`.
- Produces (consumed by Task 5): `final class TmuxRuntime` with `var onActivePaneBytes: (([UInt8]) -> Void)?`, `var onAttached: (() -> Void)?`, `var onExit: ((String?) -> Void)?`, `func makeStartCommand() -> String?`, `func ingest(_ bytes: [UInt8])`, `func sendInput(_ bytes: [UInt8])`, and `var session: ShellSession?` (set by Task 5 after `open_exec`).

- [ ] **Step 1: Implement `TmuxRuntime`**

```swift
// App/TmuxRuntime.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import GlymrKit

/// Drives a tmux control-mode session in the app: feeds inbound channel bytes to
/// the pure `TmuxSessionController`, forwards the active pane's output to the
/// terminal view, and encodes keystrokes as `send-keys` to the active pane.
/// Single-pane for Plan A — multi-pane layout lands in Plan B.
@MainActor
final class TmuxRuntime {
    private let controller = TmuxSessionController()
    private let sessionName: String

    /// The live control-mode channel; Task 5 assigns it after `open_exec`.
    var session: ShellSession?

    /// Bytes for the currently-active pane, ready to feed a terminal emulator.
    var onActivePaneBytes: (([UInt8]) -> Void)?
    /// Fired once when the controller transitions to `.attached`.
    var onAttached: (() -> Void)?
    /// Fired when control mode ends; carries the exit reason if any.
    var onExit: ((String?) -> Void)?

    init(sessionName: String) { self.sessionName = sessionName }

    /// The `tmux -CC new-session -A -s <name>` command to run via `open_exec`.
    func makeStartCommand() -> String? { controller.start(sessionName: sessionName) }

    /// Feed raw channel bytes from the control-mode exec.
    func ingest(_ bytes: [UInt8]) {
        let out = controller.feed(bytes)
        if out.lifecycleChanged, case .attached = controller.lifecycle { onAttached?() }
        for chunk in out.paneOutput where chunk.pane == activePane {
            onActivePaneBytes?(chunk.data)
        }
        if out.lifecycleChanged, case .exited(let reason) = controller.lifecycle { onExit?(reason) }
    }

    /// Encode keystrokes as `send-keys` to the active pane and write to the channel.
    func sendInput(_ bytes: [UInt8]) {
        guard let pane = activePane,
              let line = TmuxCommand.sendKeys(target: pane, bytes: bytes),
              let sub = controller.submit(line),
              let session else { return }
        Task { try? await session.write(data: Data(sub.wire)) }
    }

    /// The active pane of the active window (nil until the first layout arrives).
    private var activePane: PaneID? {
        guard let win = controller.state.activeWindow else { return nil }
        return controller.state.window(win)?.activePane
    }
}
```

> Verify the generated `ShellSession.write` label (`write(data:)` per the MVP shell — `ConnectionViewModel` already calls `session.write(data:)`). If `TmuxSessionState.activeWindow`/`window(_:)`/`TmuxWindow.activePane` names differ, match the real `GlymrKit/Tmux/TmuxSessionState.swift` (Task research confirmed `state.activeWindow: WindowID?`, `state.window(_:) -> TmuxWindow?`, `TmuxWindow.activePane: PaneID?`).

- [ ] **Step 2: Commit (App target — macOS CI compiles it; no Linux test)**

```bash
git add App/TmuxRuntime.swift
git commit -m "feat: TmuxRuntime — app-side control-mode driver (single active pane)"
```

---

### Task 5: Wire probe → attach-or-degrade into `ConnectionViewModel`

After auth, run the `tmux -V` probe over `open_exec`, decide via `tmuxLaunchDecision`, then either attach control mode (drive `TmuxRuntime`, route active-pane bytes to the existing `output` sink) or fall back to the current raw-PTY `openShell` path and set a degraded banner.

**Files:**
- Modify: `App/ConnectionViewModel.swift`

**Interfaces:**
- Consumes: `tmuxLaunchDecision`, `DegradeReason`, `StubSessionNameProvider`/`tmuxSessionName`, `resolveTmuxAttemptControlMode(host:defaults:)` (exists, `Resolution.swift:104`), `TmuxRuntime` (Task 4), `Connection.openExec`, `TerminalShellOutput` (`App/Bridges.swift`), the existing `output`/`session`/`state` members.
- Produces (consumed by Task 6): `@Published var degraded: DegradeReason?` on `ConnectionViewModel` (nil unless control mode was declined/failed).

- [ ] **Step 1: Add a probe helper that captures `tmux -V`**

Add to `ConnectionViewModel` a method that runs `tmux -V` over a short-lived exec and returns its captured output (or nil). Use a local `TerminalShellOutput` to collect bytes and resolve when the channel closes:

```swift
    /// Run `tmux -V` over a one-shot exec and return its stdout (nil if nothing
    /// came back / the channel failed). Times out via the channel's own close.
    private func probeTmuxVersion(conn: Connection) async -> String? {
        let sink = TerminalShellOutput()
        var captured: [UInt8] = []
        sink.onBytes = { captured.append(contentsOf: $0) }
        let done = AsyncStream<Void> { cont in sink.onExit = { _ in cont.yield(); cont.finish() } }
        guard (try? await conn.openExec(command: "tmux -V", term: "xterm-256color",
                                        cols: 80, rows: 24, output: sink)) != nil else { return nil }
        for await _ in done { break }   // resolves when the exec channel closes
        let text = String(decoding: captured, as: UTF8.self)
        return text.isEmpty ? nil : text
    }
```

> Confirm `TerminalShellOutput.onBytes`/`onExit` names from `App/Bridges.swift` (research: `onBytes: (([UInt8]) -> Void)?`, `onExit: ((ShellExit) -> Void)?`). The `AsyncStream` close-bridge avoids a fixed sleep; if `openExec` for `tmux -V` doesn't reliably emit `onExit`, add a `Task.sleep(2s)` race guard.

- [ ] **Step 2: Branch the connect flow on the decision**

In `connect(savedHost:password:)`, after the auth `switch outcome` succeeds and before the current `openShell` call, insert the decision. Replace the direct `openShell` with:

```swift
                let defaults2 = (try? AppStores.shared.hosts.defaults()) ?? Defaults()
                let allow = resolveTmuxAttemptControlMode(host: savedHost, defaults: defaults2)
                let probe = allow ? await probeTmuxVersion(conn: conn) : nil
                switch tmuxLaunchDecision(attemptControlMode: allow, versionProbe: probe) {
                case .attach:
                    try await attachTmux(conn: conn)
                case .degrade(let reason):
                    degraded = reason
                    try await openRawShell(conn: conn)   // the existing openShell + state = .shell body, extracted
                }
```

Extract the current `openShell(...) → connection/session/state = .shell` body into `private func openRawShell(conn:) async throws`, and add the attach path:

```swift
    /// Attach tmux control mode: open the -CC exec, pump its bytes into a
    /// TmuxRuntime, and route the active pane's output into the terminal view.
    private func attachTmux(conn: Connection) async throws {
        let seed = (try? AppStores.shared.deviceSeed()) ?? "glymr-local"
        let runtime = TmuxRuntime(sessionName: tmuxSessionName(seed: seed))
        guard let startCmd = runtime.makeStartCommand() else { try await openRawShell(conn: conn); return }
        runtime.onActivePaneBytes = { [weak self] bytes in self?.output.onBytes?(bytes) }
        runtime.onExit = { [weak self] reason in self?.state = .failed(reason ?? "tmux session ended") }
        let sink = TerminalShellOutput()
        sink.onBytes = { [weak runtime] bytes in runtime?.ingest(bytes) }
        sink.onExit = { [weak self] exit in self?.state = .failed(exit.error ?? "Session closed") }
        let sess = try await conn.openExec(command: startCmd, term: "xterm-256color",
                                           cols: 80, rows: 24, output: sink)
        runtime.session = sess
        self.connection = conn
        self.session = sess
        self.tmux = runtime               // retain it
        self.state = .shell
    }
```

Add stored properties: `private var tmux: TmuxRuntime?` and `@Published var degraded: DegradeReason?`. For the input path, the terminal view writes to `vm.session` today; in tmux mode keystrokes must go through `runtime.sendInput`. Add a single indirection the terminal view calls — `func sendTerminalInput(_ bytes: [UInt8])` — that routes to `tmux?.sendInput` when attached else `session?.write`:

```swift
    /// Route terminal keystrokes: through tmux `send-keys` when attached, else
    /// straight to the raw-PTY channel.
    func sendTerminalInput(_ bytes: [UInt8]) {
        if let tmux { tmux.sendInput(bytes) }
        else { Task { try? await session?.write(data: Data(bytes)) } }
    }
```

> `AppStores.deviceSeed()` is a small stub: persist a random UUID string in `UserDefaults`/Keychain once and return it (the local stand-in for the CloudKit-derived seed). Add it to `App/AppStores.swift` as `func deviceSeed() throws -> String`. Keep it trivial — it only needs to be stable per install.

- [ ] **Step 3: Point the terminal input path at the new indirection**

In `App/TerminalScreen.swift`, the `Coordinator.send(source:data:)` currently calls `session.write(data:)`. Change `TerminalScreen` to hold a `send: ([UInt8]) -> Void` closure (wired from `SessionView` to `vm.sendTerminalInput`) and have the coordinator call that instead, so input works in both raw and tmux modes. (If `TerminalScreen` currently takes a `ShellSession`, replace that dependency with the `send` closure + keep the `output` sink for raw mode rendering.)

- [ ] **Step 4: Compile-gate (macOS CI) + commit**

This is App-target code; it builds on the macOS runner. Commit:

```bash
git add App/ConnectionViewModel.swift App/TerminalScreen.swift App/AppStores.swift
git commit -m "feat: probe tmux and attach control mode (single pane) or degrade to raw PTY"
```

---

### Task 6: Degraded-mode amber banner

A transient amber banner shown over the terminal when control mode was declined/failed.

**Files:**
- Create: `App/DegradedBanner.swift`
- Modify: `App/SessionView.swift`

**Interfaces:**
- Consumes: `DegradeReason` (Task 2), `ConnectionViewModel.degraded` (Task 5), theme tokens (`Color(theme.accent...)` per existing app style).
- Produces: `struct DegradedBanner: View` taking `reason: DegradeReason` + an `onDismiss` closure.

- [ ] **Step 1: Implement the banner**

```swift
// App/DegradedBanner.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import GlymrKit

/// Transient amber banner: control mode was declined/failed, running plain SSH.
struct DegradedBanner: View {
    let reason: DegradeReason
    let onDismiss: () -> Void
    @Environment(\.theme) private var theme

    private var message: String {
        switch reason {
        case .optedOut:        return "tmux control mode is off for this host — running as plain SSH."
        case .tmuxNotFound:    return "tmux not found — running as plain SSH."
        case .tooOld(let v):   return "tmux \(v.major).\(v.minor) is too old (need 3.0+) — running as plain SSH."
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message).font(.caption)
            Spacer()
            Button(action: onDismiss) { Image(systemName: "xmark") }.buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .foregroundStyle(.black)
        .background(Color.orange.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
    }
}
```

> If the design tokens define an amber/warning color, use it instead of `Color.orange` to match the app's token discipline; check `Sources/GlymrKit/Theme` for a warning token and substitute. `Color.orange` is the fallback only.

- [ ] **Step 2: Host the banner in `SessionView` with auto-dismiss**

Overlay the banner at the top of the terminal when `vm.degraded != nil`, auto-dismissing after ~4s:

```swift
        .overlay(alignment: .top) {
            if let reason = vm.degraded {
                DegradedBanner(reason: reason) { vm.degraded = nil }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        vm.degraded = nil
                    }
            }
        }
        .animation(.easeInOut, value: vm.degraded)
```

> `DegradeReason` must be `Equatable` (it is, Task 2) for `.animation(value:)`. Match the exact `SessionView` structure when inserting the overlay.

- [ ] **Step 3: Compile-gate (macOS CI) + commit**

```bash
git add App/DegradedBanner.swift App/SessionView.swift
git commit -m "feat: amber degraded-mode banner over the terminal"
```

---

### Task 7: CI gate, docs, and final review

- [ ] **Step 1: Open/refresh the PR and confirm CI green**

Push and open a draft PR (base `main`). Confirm `linux-rust` (incl. the new tmux attach test), `linux-swift` (incl. `TmuxControllerOutputTests` + `TmuxLaunchTests`), `lint`, and `macos` (xcframework + app build with the new App files) are all green. Re-run `linux-rust` once if it fails on the known sshd-readiness flake.

```bash
git push -u github feat/phase-3a-tmux-attach
gh pr create --draft --base main --title "feat: Phase 3 Plan A — tmux control-mode attach (single pane)" \
  --body "Probe tmux, attach tmux -CC and render the active pane end-to-end, else degrade to raw PTY with a banner. Multi-pane/multi-window + UX polish in Plan B/C. See plan doc."
```

- [ ] **Step 2: Update docs**

Update `README.md` Phase 3 row: control-mode attach + single-pane round-trip shipped; multi-pane/UX pending. `cargo fmt --all` the Rust crate before pushing (the `lint` job checks `cargo fmt --check`).

```bash
docker compose run --rm dev cargo fmt --all
git add README.md crates/glymr-ssh-core
git commit -m "docs: Phase 3 Plan A status; fmt"
```

- [ ] **Step 3: Run `superpowers:requesting-code-review`** on the full branch; resolve Critical/Important; commit fixes.

- [ ] **Step 4: Squash-merge** once CI green and review clean; delete the branch.

## Self-Review (author checklist — completed)

- **Spec coverage:** probe + decision (degraded-mode spec) → Tasks 2/5; session naming `glymr-<hash>` + `-A` attach (tmux-session spec) → Tasks 2/4; `glymr.tmux.attemptControlMode` honored → Task 5 via existing `resolveTmuxAttemptControlMode`; `%output` surfacing (the engine prerequisite) → Task 1; transport proof (control-channel spec) → Task 3; degraded banner (degraded-mode spec, connect-time amber) → Task 6. Multi-pane render, terminal UX (OSC/mouse/bell/URL), context detection, mid-session crash banner are explicitly **deferred to Plans B/C/D** (Scope) — not gaps.
- **Placeholder scan:** the Rust test (Task 3) names illustrative helpers (`connect_and_auth`/`wait_until`) with an explicit instruction to match the file's real helpers read in Step 1 — that's a "use the existing scaffolding" directive, not a TODO. No other placeholders.
- **Type consistency:** `PaneOutputChunk` (Task 1) consumed in `TmuxRuntime.ingest` (Task 4); `TmuxLaunchDecision`/`DegradeReason` (Task 2) consumed in Tasks 5/6; `TmuxRuntime` surface (Task 4) consumed in Task 5; `ConnectionViewModel.degraded: DegradeReason?` (Task 5) consumed in Task 6.
- **Open verification points flagged inline for implementers:** the attach-handshake priming bytes (Task 1), the real `tmux_integration.rs` helper names (Task 3), `ShellSession.write`/`TerminalShellOutput` member names + `TmuxSessionState` accessors (Tasks 4/5), a warning color token vs `Color.orange` (Task 6).
