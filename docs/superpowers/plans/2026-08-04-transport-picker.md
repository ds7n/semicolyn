<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Per-host Transport Picker + ET Interactive Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the connection transport an explicit per-host user choice (SSH / Mosh / ET, default SSH), and make ET a usable interactive terminal (typing + resize wired), so ET can be tested end-to-end on device against the now-running etserver.

**Architecture:** A pure `Transport` enum + an `Inherited<Transport>` field on `Host`/`Defaults` + a pure `resolveTransport` decider carry the choice (Linux-tested); it replaces the implicit "Mosh silently wins" branch. The App layer switches on the resolved transport, adds an `etSession` arm to the input router + a `setETClientSize` resize funnel, and adds a Transport `Picker` to the host + Defaults editors. Backward compatibility (old saved hosts have no `transport` key) is handled by a custom `init(from:)` that `decodeIfPresent`s the new field as `.inherit`.

**Tech Stack:** Swift 6 (SemicolynKit, strict-concurrency, Sendable, no UIKit/CryptoKit), the slice-1a/1b `ETSession`/`attachET`/`ETBootstrapError`, SwiftUI (host editor), XCTest, xcodegen.

## Global Constraints

- **Every source file: two-line SPDX header** (`// SPDX-FileCopyrightText: 2026 True Positive LLC` / `// SPDX-License-Identifier: GPL-3.0-only`; `<!-- -->` for Markdown). REUSE-compliant.
- **No em-dash (U+2014) / en-dash (U+2013)** anywhere (code, comments, docs, commits).
- **`Sources/SemicolynKit/` is Linux-tested, Swift 6 strict-concurrency, `Sendable`:** no `import UIKit`/`SwiftUI`/`CryptoKit`. The `Transport` enum, the model fields, `resolveTransport`, and `etFailureMessage` live here.
- **`App/` (ConnectionViewModel routing, HostEditor UI) is Apple-only, macOS-CI-verified.** Does not compile on Linux.
- **`Inherited<T>` cases are `.inherit` and `.explicit(T?)`** (NOT `.inherited`). `.value` returns the set value or nil. Default in inits is `= .inherit`.
- **Backward compatibility is mandatory:** a `Host`/`Defaults` record persisted before the `transport` field existed MUST still decode (as `.inherit`). `Host` currently uses fully-synthesized Codable, and `Inherited<Transport>` is NOT Optional, so a missing key would throw `keyNotFound`. The fix is a custom `init(from:)` using `decodeIfPresent(..., forKey: .transport) ?? .inherit`.
- **`sendTerminalInput` is a SACRED PATH:** the transport write is the FIRST thing that runs, nothing (not even a string interpolation) above it. The ET arm goes inside that write block, first-checked, matching the existing structure.
- **No silent cross-transport fallback:** the chosen transport's connect failure sets `state = .failed(<reason>)`. This deliberately changes Mosh-explicit-but-failed from silent-SSH-fallback to a visible failure.
- **Tests real** (`docs/superpowers/specs/2026-06-18-testing-standards-design.md`): EP + BVA, assert observable values, negative asserts the specific failure.
- **Conventional commits**; commit after each green step; end every commit message with `Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt`.
- **Build/test:** Kit tests via `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter <Class>` (no host Swift). If Docker hits a `.build` permission error, fix once with `docker compose run --rm --user root dev bash -c "chown -R $(id -u):$(id -g) /work/.build"`. App tier is macOS-CI-only.
- **Spec:** `docs/superpowers/specs/2026-08-04-transport-picker-design.md`. Read it first.
- **Precedent:** `Sources/SemicolynKit/Model/{Host,Inherited,Resolution}.swift`, `Tests/SemicolynKitTests/HostSchemaTests.swift` (back-compat test at line 60), `App/HostEditorSections.swift` (the three-state `Picker` pattern), `App/ConnectionViewModel.swift` (the two connect call sites at ~1458/1533, `sendTerminalInput` ~236, `setMoshClientSize` ~980).

---

## File Structure

**Pure Kit (Linux-tested):**
- Create `Sources/SemicolynKit/Model/Transport.swift`, the `Transport` enum.
- Modify `Sources/SemicolynKit/Model/Host.swift`, add `transport: Inherited<Transport>` to `Host` + `Defaults`, their inits, and a custom `init(from:)` for back-compat decode.
- Modify `Sources/SemicolynKit/Model/Resolution.swift`, add `resolveTransport`.
- Create `Sources/SemicolynKit/ET/ETFailureMessage.swift`, `etFailureMessage`.
- Tests: `Tests/SemicolynKitTests/TransportResolutionTests.swift`, `Tests/SemicolynKitTests/TransportCodableTests.swift`, `Tests/SemicolynKitTests/ETFailureMessageTests.swift`.

**App tier (macOS-CI-only):**
- Modify `App/ConnectionViewModel.swift`, the connect switch (both call sites), the `sendTerminalInput` ET arm, `setETClientSize`.
- Modify `App/SessionView.swift`, the `onResize` sink prefers ET (`setETClientSize`) over Mosh (no `TerminalScreen.swift` change needed for resize).
- Modify `App/HostEditorSections.swift`, the Transport `Picker` + per-option description.
- Modify `App/DefaultsEditorView.swift`, the same Transport picker.

---

### Task 1: `Transport` enum

**Files:**
- Create: `Sources/SemicolynKit/Model/Transport.swift`
- Test: `Tests/SemicolynKitTests/TransportCodableTests.swift`

**Interfaces:**
- Produces: `public enum Transport: String, Codable, Sendable, CaseIterable, Equatable { case ssh, mosh, et }` and a `public var displayName: String` (SSH / Mosh / ET) + `public var summary: String` (the one-line guidance).

- [ ] **Step 1: Write the failing test**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class TransportCodableTests: XCTestCase {
    func testRawValues() {
        XCTAssertEqual(Transport.ssh.rawValue, "ssh")
        XCTAssertEqual(Transport.mosh.rawValue, "mosh")
        XCTAssertEqual(Transport.et.rawValue, "et")
    }

    func testAllCases() {
        XCTAssertEqual(Transport.allCases, [.ssh, .mosh, .et])
    }

    func testRoundTrips() throws {
        for t in Transport.allCases {
            let data = try JSONEncoder().encode(t)
            XCTAssertEqual(try JSONDecoder().decode(Transport.self, from: data), t)
        }
    }

    func testDisplayNames() {
        XCTAssertEqual(Transport.ssh.displayName, "SSH")
        XCTAssertEqual(Transport.mosh.displayName, "Mosh")
        XCTAssertEqual(Transport.et.displayName, "ET")
    }

    // Summaries are non-empty and mention the defining tradeoff (observable content check).
    func testSummariesMentionKeyTradeoff() {
        XCTAssertTrue(Transport.ssh.summary.contains("roaming"))
        XCTAssertTrue(Transport.mosh.summary.contains("panes"))
        XCTAssertTrue(Transport.et.summary.contains("etserver"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TransportCodableTests`
Expected: FAIL to compile / "cannot find 'Transport' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// The connection transport for a host: chosen explicitly by the user (no Auto).
/// SSH is the universally-available default; Mosh roams but has no panes; ET has
/// panes and roaming but needs etserver on the host.
public enum Transport: String, Codable, Sendable, CaseIterable, Equatable {
    case ssh, mosh, et

    /// Short label for the picker.
    public var displayName: String {
        switch self {
        case .ssh: return "SSH"
        case .mosh: return "Mosh"
        case .et: return "ET"
        }
    }

    /// One-line tradeoff guidance shown under the picker.
    public var summary: String {
        switch self {
        case .ssh:
            return "Works everywhere, native tmux panes, does not survive roaming."
        case .mosh:
            return "Survives roaming, no native panes, needs mosh-server + a UDP port range."
        case .et:
            return "Panes and roaming, needs etserver on the host + TCP 2022, failure is shown (no silent switch)."
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TransportCodableTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Model/Transport.swift Tests/SemicolynKitTests/TransportCodableTests.swift
git commit -m "feat(transport): Transport enum (ssh/mosh/et) with display + summary

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
```

---

### Task 2: `transport` field on `Host` + `Defaults` with back-compat decode

**Files:**
- Modify: `Sources/SemicolynKit/Model/Host.swift`
- Test: `Tests/SemicolynKitTests/TransportCodableTests.swift` (append back-compat cases)

**Interfaces:**
- Consumes: `Transport` (Task 1), `Inherited<T>` (existing).
- Produces: `Host.transport: Inherited<Transport>` and `Defaults.transport: Inherited<Transport>`, both defaulting to `.inherit` in their memberwise inits, AND both decoding a legacy record (no `transport` key) as `.inherit`.

**Critical (the back-compat linchpin):** `Host`/`Defaults` currently use synthesized Codable. Adding a non-Optional `Inherited<Transport>` field makes synthesized decode throw `keyNotFound` on any record saved before this field existed. Add a custom `init(from:)` to BOTH structs that decodes every existing field with `decode(...)` and the new `transport` with `decodeIfPresent(Inherited<Transport>.self, forKey: .transport) ?? .inherit`. Keep synthesized `encode(to:)` (it always writes the field going forward). Add the explicit `CodingKeys` listing all stored properties (required once a custom `init(from:)` exists).

- [ ] **Step 1: Write the failing back-compat test**

```swift
// Append to TransportCodableTests.

// A Host encoded BEFORE the transport field existed (no "transport" key) must
// decode with transport == .inherit, not throw keyNotFound.
func testHostWithoutTransportKeyDecodesAsInherit() throws {
    // Encode a current Host, then strip the transport key to simulate a legacy blob.
    let h = Host(id: UUID(), label: "legacy", hostName: "h.example")
    var dict = try JSONSerialization.jsonObject(
        with: try JSONEncoder().encode(h)) as! [String: Any]
    dict.removeValue(forKey: "transport")
    let legacyData = try JSONSerialization.data(withJSONObject: dict)
    let back = try JSONDecoder().decode(Host.self, from: legacyData)
    XCTAssertEqual(back.transport, .inherit)
    XCTAssertEqual(back.hostName, "h.example")
}

func testDefaultsWithoutTransportKeyDecodesAsInherit() throws {
    let d = Defaults()
    var dict = try JSONSerialization.jsonObject(
        with: try JSONEncoder().encode(d)) as! [String: Any]
    dict.removeValue(forKey: "transport")
    let legacyData = try JSONSerialization.data(withJSONObject: dict)
    let back = try JSONDecoder().decode(Defaults.self, from: legacyData)
    XCTAssertEqual(back.transport, .inherit)
}

// A Host with an explicit transport round-trips.
func testHostTransportRoundTrips() throws {
    var h = Host(id: UUID(), label: "et-host", hostName: "h")
    h.transport = .explicit(.et)
    let back = try JSONDecoder().decode(Host.self, from: JSONEncoder().encode(h))
    XCTAssertEqual(back.transport, .explicit(.et))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TransportCodableTests`
Expected: FAIL to compile / "value of type 'Host' has no member 'transport'".

- [ ] **Step 3: Add the field + custom decode**

In `Sources/SemicolynKit/Model/Host.swift`:
1. Add to `Host` (in the "Semicolyn extensions" group): `public var transport: Inherited<Transport>`
2. Add to `Host.init(...)` a parameter `transport: Inherited<Transport> = .inherit,` and `self.transport = transport`.
3. Do the same two edits for `Defaults` (field + init param + assignment).
4. Add to BOTH structs an explicit `CodingKeys` enum listing ALL stored properties (every existing key plus `transport`), and a custom `init(from decoder: Decoder) throws` that decodes each existing field with `try container.decode(Type.self, forKey: .key)` and the new one with:
   ```swift
   self.transport = try container.decodeIfPresent(Inherited<Transport>.self, forKey: .transport) ?? .inherit
   ```
   Keep the synthesized `encode(to:)` (do NOT write a custom encoder; the synthesized one writes `transport` going forward, and the `CodingKeys` you added drive it).

Concretely for `Host` (adapt field list to the actual struct; every stored property must appear in both `CodingKeys` and the decoder):

```swift
enum CodingKeys: String, CodingKey {
    case id, label, hostName
    case user, port, identities, passwordRef, proxyJump
    case localForwards, remoteForwards, dynamicForwards
    case serverAliveInterval, serverAliveCountMax, compression
    case strictHostKeyChecking, forwardAgent, preferredAuthentications
    case mosh, tailscale, semicolyn
    case transport
}

public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    label = try c.decode(String.self, forKey: .label)
    hostName = try c.decode(String.self, forKey: .hostName)
    user = try c.decode(Inherited<String>.self, forKey: .user)
    port = try c.decode(Inherited<Int>.self, forKey: .port)
    identities = try c.decode(Inherited<[IdentityRef]>.self, forKey: .identities)
    passwordRef = try c.decode(Inherited<UUID>.self, forKey: .passwordRef)
    proxyJump = try c.decode(Inherited<[JumpHop]>.self, forKey: .proxyJump)
    localForwards = try c.decode(Inherited<[LocalForward]>.self, forKey: .localForwards)
    remoteForwards = try c.decode(Inherited<[RemoteForward]>.self, forKey: .remoteForwards)
    dynamicForwards = try c.decode(Inherited<[DynamicForward]>.self, forKey: .dynamicForwards)
    serverAliveInterval = try c.decode(Inherited<Int>.self, forKey: .serverAliveInterval)
    serverAliveCountMax = try c.decode(Inherited<Int>.self, forKey: .serverAliveCountMax)
    compression = try c.decode(Inherited<Bool>.self, forKey: .compression)
    strictHostKeyChecking = try c.decode(Inherited<StrictHostKeyChecking>.self, forKey: .strictHostKeyChecking)
    forwardAgent = try c.decode(Inherited<Bool>.self, forKey: .forwardAgent)
    preferredAuthentications = try c.decode(Inherited<[AuthMethod]>.self, forKey: .preferredAuthentications)
    mosh = try c.decode(Inherited<MoshConfig>.self, forKey: .mosh)
    tailscale = try c.decode(Inherited<TailscaleConfig>.self, forKey: .tailscale)
    semicolyn = try c.decode(Inherited<SemicolynConfig>.self, forKey: .semicolyn)
    transport = try c.decodeIfPresent(Inherited<Transport>.self, forKey: .transport) ?? .inherit
}
```

Implementer note: READ the actual `Host`/`Defaults` field lists in the file first and match them EXACTLY (the list above is from a snapshot, verify every field name and its `Inherited<T>` type against the current source before writing the decoder; a wrong type or a missing field is a decode bug). Do the equivalent for `Defaults` (its fields are the same minus `id`/`label`/`hostName`).

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TransportCodableTests`
Expected: PASS (all cases). Then run the FULL suite to confirm no existing HostSchemaTests broke:
`HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter HostSchemaTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Model/Host.swift Tests/SemicolynKitTests/TransportCodableTests.swift
git commit -m "feat(transport): Host/Defaults transport field + legacy-decode back-compat

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
```

---

### Task 3: `resolveTransport` decider

**Files:**
- Modify: `Sources/SemicolynKit/Model/Resolution.swift`
- Test: `Tests/SemicolynKitTests/TransportResolutionTests.swift`

**Interfaces:**
- Consumes: `Host`, `Defaults`, `Transport` (Tasks 1-2), `resolveMoshEnabled` (existing, `Resolution.swift:147`).
- Produces: `public func resolveTransport(host: Host, defaults: Defaults) -> Transport` with precedence: explicit host.transport > explicit defaults.transport > legacy `resolveMoshEnabled` true -> `.mosh` > `.ssh`.

- [ ] **Step 1: Write the failing test**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class TransportResolutionTests: XCTestCase {
    private func host() -> Host { Host(id: UUID(), label: "h", hostName: "h") }

    func testHostExplicitETWins() {
        var h = host(); h.transport = .explicit(.et)
        XCTAssertEqual(resolveTransport(host: h, defaults: Defaults()), .et)
    }

    func testHostExplicitSSHWins() {
        var h = host(); h.transport = .explicit(.ssh)
        var d = Defaults(); d.transport = .explicit(.et)   // host beats defaults
        XCTAssertEqual(resolveTransport(host: h, defaults: d), .ssh)
    }

    func testDefaultsUsedWhenHostInherits() {
        var d = Defaults(); d.transport = .explicit(.mosh)
        XCTAssertEqual(resolveTransport(host: host(), defaults: d), .mosh)
    }

    // Legacy migration: a host with mosh enabled but no transport set resolves to .mosh.
    func testLegacyMoshEnabledMigratesToMosh() {
        var h = host(); h.mosh = .explicit(MoshConfig(enabled: true))
        XCTAssertEqual(resolveTransport(host: h, defaults: Defaults()), .mosh)
    }

    // Nothing set anywhere -> SSH default.
    func testNothingSetDefaultsToSSH() {
        XCTAssertEqual(resolveTransport(host: host(), defaults: Defaults()), .ssh)
    }

    // Explicit transport beats legacy mosh (user chose SSH on a mosh-enabled host).
    func testExplicitTransportBeatsLegacyMosh() {
        var h = host()
        h.mosh = .explicit(MoshConfig(enabled: true))
        h.transport = .explicit(.ssh)
        XCTAssertEqual(resolveTransport(host: h, defaults: Defaults()), .ssh)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TransportResolutionTests`
Expected: FAIL to compile / "cannot find 'resolveTransport' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
// Append to Sources/SemicolynKit/Model/Resolution.swift.

/// Resolve the effective transport for a host, the single explicit decision that
/// replaces the old "Mosh silently wins" inference. Precedence:
/// 1. explicit host.transport
/// 2. explicit defaults.transport
/// 3. LEGACY MIGRATION: a host/defaults with mosh enabled but no transport set
///    resolves to .mosh (so existing Mosh hosts keep working with no stored field)
/// 4. .ssh (the universally-available default)
public func resolveTransport(host: Host, defaults: Defaults) -> Transport {
    if let t = host.transport.value { return t }
    if let t = defaults.transport.value { return t }
    if resolveMoshEnabled(host: host, defaults: defaults) { return .mosh }
    return .ssh
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TransportResolutionTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Model/Resolution.swift Tests/SemicolynKitTests/TransportResolutionTests.swift
git commit -m "feat(transport): resolveTransport decider (explicit choice + legacy-mosh migration)

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
```

---

### Task 4: `etFailureMessage` (typed error to readable string)

**Files:**
- Create: `Sources/SemicolynKit/ET/ETFailureMessage.swift`
- Test: `Tests/SemicolynKitTests/ETFailureMessageTests.swift`

**Interfaces:**
- Consumes: `ETBootstrapError` (slice 1b).
- Produces: `public func etFailureMessage(_ error: ETBootstrapError) -> String` mapping each case to a readable line prefixed "Eternal Terminal could not connect: ".

- [ ] **Step 1: Write the failing test**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ETFailureMessageTests: XCTestCase {
    func testExecFailed() {
        XCTAssertEqual(etFailureMessage(.execFailed),
            "Eternal Terminal could not connect: could not start the bootstrap over SSH.")
    }

    func testNoIDPASSKEYIncludesServerHint() {
        let msg = etFailureMessage(.noIDPASSKEY(serverOutput: "command not found"))
        XCTAssertEqual(msg,
            "Eternal Terminal could not connect: no response from etserver (is it installed?). Server said: command not found")
    }

    func testMalformed() {
        XCTAssertEqual(etFailureMessage(.malformedIDPASSKEY),
            "Eternal Terminal could not connect: the server sent a malformed credential.")
    }

    func testInvalidConfig() {
        XCTAssertEqual(etFailureMessage(.invalidConfig(.missingTERM)),
            "Eternal Terminal could not connect: invalid connection settings (missingTERM).")
    }

    func testHandshakeFailedIncludesReason() {
        XCTAssertEqual(etFailureMessage(.handshakeFailed(reason: "protocol mismatch")),
            "Eternal Terminal could not connect: protocol mismatch")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ETFailureMessageTests`
Expected: FAIL to compile / "cannot find 'etFailureMessage' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Map a typed ET bootstrap failure to a readable, user-facing line for the
/// `.failed` state. The string-bearing error cases already carry SANITIZED text
/// (see parseETIDPASSKEY / ETSession.onEnd), so it is safe to render here.
public func etFailureMessage(_ error: ETBootstrapError) -> String {
    let prefix = "Eternal Terminal could not connect: "
    switch error {
    case .execFailed:
        return prefix + "could not start the bootstrap over SSH."
    case .noIDPASSKEY(let serverOutput):
        return prefix + "no response from etserver (is it installed?). Server said: \(serverOutput)"
    case .malformedIDPASSKEY:
        return prefix + "the server sent a malformed credential."
    case .invalidConfig(let e):
        return prefix + "invalid connection settings (\(e))."
    case .handshakeFailed(let reason):
        return prefix + reason
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ETFailureMessageTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/ET/ETFailureMessage.swift Tests/SemicolynKitTests/ETFailureMessageTests.swift
git commit -m "feat(et): etFailureMessage maps ETBootstrapError to a readable .failed line

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
```

---

### Task 5: Connect routing + input/resize wiring (App, macOS-CI-only)

**Files:**
- Modify: `App/ConnectionViewModel.swift` (connect switch, `sendTerminalInput` arm, `setETClientSize`, `isETActive`)
- Modify: `App/SessionView.swift` (the `onResize` sink prefers ET)

**Interfaces:**
- Consumes: `resolveTransport`, `etFailureMessage` (Tasks 3-4), `attachET`/`captureETBootstrap`/`etSession` (slice 1b), `attachMoshIfPossible`/`attachSSHShell` (existing).
- Produces: an explicit transport switch at both connect call sites; the `etSession` arm in `sendTerminalInput`; `setETClientSize` + `isETActive`; the `SessionView` `onResize` sink routing to ET.

This is Apple-tier (no Linux compile, macOS-CI-verified). Keep all decision logic in the Task 1-4 deciders; this is wiring.

- [ ] **Step 1: Replace the Mosh-wins branch at BOTH connect call sites**

READ the two call sites first (`App/ConnectionViewModel.swift` ~1458 and ~1533, each currently:
```swift
if await attachMoshIfPossible(conn: conn, host: <h>, defaults: <d>) { return }
... attachSSHShell(...)
```
). Replace each with the explicit switch (adapt the local var names `savedHost`/`hostRecord`, `defaults2` at each site):

```swift
switch resolveTransport(host: <h>, defaults: <d>) {
case .et:
    switch await attachET(conn: conn, host: <h>, defaults: <d>) {
    case .success:
        DebugLog.shared.log(.connect, "connect: went ET path")
        return
    case .failure(let e):
        DebugLog.shared.log(.connect, "connect: ET FAILED (\(e))")
        state = .failed(etFailureMessage(e))
        return
    }
case .mosh:
    if await attachMoshIfPossible(conn: conn, host: <h>, defaults: <d>) {
        DebugLog.shared.log(.connect, "connect: went MOSH path")
        return
    }
    DebugLog.shared.log(.connect, "connect: MOSH explicit but bootstrap failed → .failed")
    state = .failed("Mosh could not connect to this host.")
    return
case .ssh:
    DebugLog.shared.log(.lifecycle, "connect: → attachSSHShell (tmux/raw)")
    try await attachSSHShell(conn: conn, host: <h>, defaults: <d>)
}
```

- [ ] **Step 2: Add the `etSession` arm to `sendTerminalInput`**

In the SACRED-PATH write block (`App/ConnectionViewModel.swift` ~236), add `etSession` FIRST (it is the active transport when set), keeping the transport write as the first statement:

```swift
if let etSession {
    etSession.send(Data(bytes))
} else if let moshSession {
    moshSession.writeInput(Data(bytes))
} else if let tmux {
    tmux.sendInput(bytes)
} else {
    rawWriter?.enqueue(bytes)
}
```
Also update the `transport` label line just below (used only for the gated diagnostic) to include ET:
```swift
let transport = etSession != nil ? "ET" : (moshSession != nil ? "MOSH" : (tmux != nil ? "TMUX" : "RAW"))
```

- [ ] **Step 3: Add `setETClientSize` (mirror `setMoshClientSize` ~980)**

```swift
/// Route a debounced client-size change to the ET session. ET (like Mosh) has no
/// `ShellSession`, so `TerminalScreen`'s default `session?.resize` is a no-op.
func setETClientSize(cols: Int, rows: Int) {
    etSession?.setWindowSizeCols(UInt16(cols), rows: UInt16(rows), width: 0, height: 0)
}
```

- [ ] **Step 4: Route the resize via the explicit `onResize` sink**

The resize sink is NOT a per-transport `if` inside `TerminalScreen`; it is an explicit `onResize` closure set by the caller (`TerminalScreen`'s `onResize` OWNS delivery when non-nil, else `session?.resize` runs). Mosh sets it at `App/SessionView.swift:135-137`:
```swift
onResize: vm.isMoshActive
    ? { [weak vm] cols, rows in vm?.setMoshClientSize(cols: cols, rows: rows) }
    : nil,
```
Two edits, no change to `TerminalScreen.swift`:
1. Add an `isETActive` computed property to `ConnectionViewModel` next to `isMoshActive` (`App/ConnectionViewModel.swift:977`): `var isETActive: Bool { etSession != nil }`.
2. Update the `onResize` binding in `SessionView.swift` to prefer ET, then Mosh, else nil:
```swift
onResize: vm.isETActive
    ? { [weak vm] cols, rows in vm?.setETClientSize(cols: cols, rows: rows) }
    : (vm.isMoshActive
        ? { [weak vm] cols, rows in vm?.setMoshClientSize(cols: cols, rows: rows) }
        : nil),
```
(So `App/TerminalScreen.swift` does NOT need editing for resize; correct the Files list accordingly. The files touched in this task are `App/ConnectionViewModel.swift` and `App/SessionView.swift`.)

- [ ] **Step 5: Commit** (macOS-CI-verified; no Linux build)

```bash
git add App/ConnectionViewModel.swift App/SessionView.swift
git commit -m "feat(transport): explicit connect switch + ET input/resize wiring

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
```

---

### Task 6: Transport Picker in the host + Defaults editors (App, macOS-CI-only)

**Files:**
- Modify: `App/HostEditorSections.swift`
- Modify: `App/DefaultsEditorView.swift`

**Interfaces:**
- Consumes: `Transport`, `Host.transport`/`Defaults.transport` (Tasks 1-2).
- Produces: a Transport `Picker` bound to `host.transport` (and `defaults.transport`) with a per-option summary line.

This is Apple-tier (macOS-CI compile). Mirror the existing three-state `Picker` pattern in `HostEditorSections.swift` (compression/forwardAgent) for the binding shape.

- [ ] **Step 1: Add the Transport picker to the host connection section**

READ the existing compression/forwardAgent `Picker` in `HostEditorSections.swift` (the `Inherited<Bool>` three-state Picker with a `Binding` mapping Default/On/Off) to copy the binding idiom. Add, at the TOP of `connectionSection`, a Transport picker. Because `transport` is `Inherited<Transport>`, model it as a four-option picker (Default + SSH + Mosh + ET), mirroring the three-state pattern but with three concrete options:

```swift
// Transport: Inherited<Transport> shown as Default / SSH / Mosh / ET.
Picker("Transport", selection: Binding(
    get: {
        switch vm.host.transport {
        case .inherit: return "default"
        case .explicit(let t): return t?.rawValue ?? "default"
        }
    },
    set: { (sel: String) in
        vm.host.transport = (sel == "default") ? .inherit : .explicit(Transport(rawValue: sel))
    }
)) {
    Text("Default").tag("default")
    ForEach(Transport.allCases, id: \.rawValue) { t in
        Text(t.displayName).tag(t.rawValue)
    }
}
// Summary line for the resolved/selected transport.
if case .explicit(let t?) = vm.host.transport {
    Text(t.summary).font(.footnote).foregroundStyle(.secondary)
}
```
Adapt `vm.host` to the actual binding the section uses (it references `vm.host.<field>` for other pickers, match that exactly). If the editor mutates a local `@State host` copy rather than `vm.host`, bind to whatever the sibling pickers bind to.

- [ ] **Step 2: Add the same picker to the Defaults editor**

In `App/DefaultsEditorView.swift`, add an equivalent Transport picker bound to the Defaults `transport` field (Default + SSH + Mosh + ET), mirroring how the Defaults editor exposes other `Inherited` fields. READ how DefaultsEditorView binds an existing `Inherited` field and match it.

- [ ] **Step 3: Commit** (macOS-CI-verified)

```bash
git add App/HostEditorSections.swift App/DefaultsEditorView.swift
git commit -m "feat(transport): Transport picker in host + Defaults editors

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
```

---

### Task 7: Push, verify macOS CI, TestFlight, update TODO

**Files:**
- Modify: `TODO.md`

**Interfaces:**
- Consumes: all prior tasks.
- Produces: a green CI run + a TestFlight build for the device test + updated resume pointer.

- [ ] **Step 1: Create the feature branch + push**

```bash
git checkout -b feat/transport-picker 2>/dev/null || git checkout feat/transport-picker
git push -u github feat/transport-picker
```

- [ ] **Step 2: Open the PR**

```bash
gh pr create --repo ds7n/semicolyn --base main --head feat/transport-picker \
  --title "feat(transport): per-host Transport picker + ET interactive" \
  --body "$(cat <<'BODY'
Design: docs/superpowers/specs/2026-08-04-transport-picker-design.md. Depends on slices 1a (8cfd630) + 1b (0f1b422).

- Explicit per-host Transport (SSH/Mosh/ET, default SSH) via Inherited<Transport> + pure resolveTransport (replaces "Mosh silently wins"; legacy-mosh migration keeps old hosts working; back-compat decode for records without the field).
- ET interactive: etSession arm in sendTerminalInput + setETClientSize resize.
- Chosen-transport failure surfaces .failed with the reason (etFailureMessage), no silent fallback.
- Transport picker in the host + Defaults editors.

Enables the first on-device end-to-end ET test against a live etserver.

https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt
BODY
)"
```

- [ ] **Step 3: Verify all CI jobs green**

Run: `gh run watch --repo ds7n/semicolyn $(gh run list --repo ds7n/semicolyn --branch feat/transport-picker --limit 1 --json databaseId --jq '.[0].databaseId')`
Expected: `linux-swift`, `linux-rust`, `lint`, and **`macos`** all pass. The `macos` job is the only signal that the routing switch + editor pickers compile. If `linux-rust` flakes ("sshd fixtures not reachable"), rerun that job only.

- [ ] **Step 4: Trigger a TestFlight build (for the device test)**

Gate on the macOS job passing, then:
```bash
gh workflow run "Release to TestFlight" --repo ds7n/semicolyn --ref feat/transport-picker
```
(Per the `testflight-trigger-howto` memory: workflow_dispatch, gated on repo var TESTFLIGHT_ENABLED=true. Confirm "Ready to Test" in the TestFlight app after async processing; a transient upload -1009 clears on rerun.)

- [ ] **Step 5: Update the TODO resume block + commit**

Edit `TODO.md`: record the Transport picker + ET-interactive slice done (PR #<n>, CI green, TestFlight build N uploaded), and that the NEXT step is the ON-DEVICE ET test (set a host Transport=ET, connect to the dev box with sshd+etserver up, verify connect + typing + resize + the .failed message on a bad host). Note the protocol-6-client vs 7.0.0-server watch-item (MISMATCHED_PROTOCOL is the risk to watch at the handshake).

```bash
git add TODO.md
git commit -m "docs: record Transport picker + ET-interactive slice; next = on-device ET test

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
git push
```

---

## Self-Review

**Spec coverage:**
- §In 1 (Transport field, edited in host + Defaults editor) → Task 1 (enum) + Task 2 (field + back-compat) + Task 6 (pickers).
- §In 2 (explicit connect routing, .failed on failure, no silent fallback) → Task 3 (resolveTransport) + Task 4 (etFailureMessage) + Task 5 (the switch).
- §In 3 (ET interactive: input + resize) → Task 5 (sendTerminalInput arm, setETClientSize, TerminalScreen route).
- §Behavior-change-to-flag (Mosh-explicit-but-failed → .failed) → Task 5 Step 1 (.mosh case sets .failed).
- §Transport model (enum, Inherited field, resolveTransport with legacy migration, backward compat) → Tasks 1-3, with the back-compat linchpin as Task 2's explicit custom-decoder work + tests.
- §Host editor UI → Task 6.
- §Testing Linux table (resolveTransport / etFailureMessage / Transport Codable + back-compat) → Tasks 1-4 tests. §macOS CI compile → Task 7 Step 3. §Device test → Task 7 Step 4-5 (TestFlight + the documented on-device checklist).
- §Non-goals (no Retry/Cancel screen, no Auto, no probe, no roaming/jumphost) → respected; none implemented.

**Placeholder scan:** No "TBD"/"add error handling"/"similar to Task N". Every code step has concrete content. Task 2's decoder is shown in full with an explicit "verify field list against source" instruction (the one place the implementer must reconcile against the live struct, called out, not left blank). Task 5/6 App steps say "READ the precedent first" with the specific precedent named, because the exact binding/lines are in a large existing file the implementer must match rather than invent.

**Type consistency:** `Transport` (ssh/mosh/et, displayName, summary), `Host.transport`/`Defaults.transport: Inherited<Transport>`, `resolveTransport(host:defaults:) -> Transport`, `etFailureMessage(_:) -> String`, `setETClientSize(cols:rows:)`, and the `ETSession` methods (`send`, `setWindowSizeCols:rows:width:height:`) match across tasks and against slice 1a/1b's shipped signatures + the existing `Inherited`/`resolveMoshEnabled`/`MoshConfig` API (verified against the current source: `Inherited` cases `.inherit`/`.explicit(T?)`, `.value`; `resolveMoshEnabled` at `Resolution.swift:147`; `ETBootstrapError`'s 5 cases). The one item the implementer MUST verify live (Task 2): the exact `Host`/`Defaults` stored-property list, so the custom `CodingKeys` + decoder cover every field.
