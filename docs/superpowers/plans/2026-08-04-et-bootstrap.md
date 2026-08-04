<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# ET Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Plant the ET credential over the existing russh SSH session, read back the server's `IDPASSKEY`, build a live `ETConfig`, and drive `ETSession` (slice 1a) so a host running `etserver` yields a real, transparent ET terminal.

**Architecture:** Four pure Linux-tested Kit deciders in `Sources/SemicolynKit/ET/` (credential generation, bootstrap command builder, IDPASSKEY parser, config builder) carry all the wrong-able logic; a thin `ConnectionViewModel` ET branch (macOS-CI-only) runs the bootstrap over the existing `Connection.openExec` one-shot (mirroring `captureMoshBootstrap`), then starts `ETSession` and wires its byte stream to SwiftTerm. On any failure it surfaces a typed `ETBootstrapError` (no silent SSH fallback, per the user decision).

**Tech Stack:** Swift 6 (SemicolynKit, strict-concurrency, Sendable, no UIKit/CryptoKit), the slice-1a `ETSession`/`ETConfig`/`sanitizeEndReason`, the UniFFI `Connection.openExec`, `SystemRandomNumberGenerator` (cryptographically secure on Apple + Linux), XCTest.

## Global Constraints

- **Every source file carries the two-line SPDX header:** `// SPDX-FileCopyrightText: 2026 True Positive LLC` then `// SPDX-License-Identifier: GPL-3.0-only` (Swift/Obj-C), `<!-- -->` form for Markdown. REUSE-compliant.
- **No em-dash (U+2014) / en-dash (U+2013)** anywhere (code, comments, docs, commit messages). Use colon, comma, parentheses, semicolon, or two sentences.
- **`Sources/SemicolynKit/` is Linux-tested, Swift 6 strict-concurrency, `Sendable`:** no `import UIKit`/`SwiftUI`/`CryptoKit`. The four deciders live here.
- **`App/` (the `ConnectionViewModel` ET branch) is Apple-only, macOS-CI-verified.** It does NOT compile on Linux and is invisible to `swift test`.
- **Secrets never logged.** The `passkey`, the full `id`/`passkey` pair, and the raw `IDPASSKEY:` line are secrets. Log lengths/shape/"parsed ok|failed" only, never the value (mirrors the predictor secret-exclusion discipline).
- **ET credential facts (authoritative, from `extern/eternaltermlib/extern/eternalterminal/src/terminal/SshSetupHandler.cpp` + `TerminalMain.cpp`):** bootstrap command is `echo '<id>/<passkey>_<TERM>' | etterminal --verbose=<v>`; the client `id` is 16 alphanumeric chars with `id[0]=id[1]=id[2]='X'`; `passkey` is 32 alphanumeric chars; the server prints `IDPASSKEY:<id>/<passkey>` on stdout and the client MUST use the server's values (client-generated pair is a legacy fallback).
- **Tests must be real** (`docs/superpowers/specs/2026-06-18-testing-standards-design.md`): EP + BVA, assert observable values, negative tests assert the SPECIFIC failure; the secret-bearing + CSPRNG units are Critical tier (adversarial + exact values).
- **Conventional commits** (`feat:`/`test:`/`docs:`); commit after each green step; end every commit message with `Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt`.
- **Build/test entrypoints:** Kit tests run as `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter <TestClass>` (no host Swift toolchain). Apple-tier compile/tests run only on macOS CI.
- **Spec:** `docs/superpowers/specs/2026-08-04-et-bootstrap-design.md`. Read it before starting.
- **Precedent to mirror:** `Sources/SemicolynKit/Mosh/{MoshServerCommand,MoshConnect}.swift` (pure command + parse deciders), `App/ConnectionViewModel.swift:673-720` (`captureMoshBootstrap` + the `openExec`/2s-guard race), slice-1a `Sources/SemicolynKit/ET/*` + `App/ET/ETSession.*`.

---

## File Structure

**Pure Kit (Linux-tested), created:**
- `Sources/SemicolynKit/ET/ETCredential.swift`, `ETCredential` struct + `etGenerateCredential()`.
- `Sources/SemicolynKit/ET/ETBootstrap.swift`, `etBootstrapCommand(...)`, `ETBootstrapError`, `parseETIDPASSKEY(_:)`, `etConnectConfig(...)`.
- `Tests/SemicolynKitTests/ETCredentialTests.swift`
- `Tests/SemicolynKitTests/ETBootstrapCommandTests.swift`
- `Tests/SemicolynKitTests/ETIDPASSKEYParseTests.swift`
- `Tests/SemicolynKitTests/ETConnectConfigTests.swift`

**App tier (macOS-CI-only), modified:**
- `App/ConnectionViewModel.swift`, add `captureETBootstrap(...)` + an `attachETIfPossible(...)`-style ET branch that generates the credential, runs the bootstrap, parses, builds the config, starts `ETSession`, wires I/O, and produces a typed `ETBootstrapError` on failure. A temporary explicit entry point (dev call), NOT the Transport picker (§5).

**Note on entry point:** until the §5 Transport picker exists, the ET branch is reached by a direct/dev call (documented in Task 5). Do NOT change the existing Mosh-silently-wins routing in this slice.

---

### Task 1: `etGenerateCredential` (CSPRNG credential)

**Files:**
- Create: `Sources/SemicolynKit/ET/ETCredential.swift`
- Test: `Tests/SemicolynKitTests/ETCredentialTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public struct ETCredential: Sendable, Equatable { public let id: String; public let passkey: String; public init(id: String, passkey: String) }`
  - `public func etGenerateCredential() -> ETCredential`, `id` = 16 alphanumeric chars with `id[0..2] == "X"`; `passkey` = 32 alphanumeric chars; CSPRNG-backed via `SystemRandomNumberGenerator`.
  - `public let etAlphanumeric: [Character]`, the alphabet (A-Z a-z 0-9), exposed so tests assert the charset.

- [ ] **Step 1: Write the failing test**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ETCredentialTests: XCTestCase {
    func testIDIs16Chars() {
        XCTAssertEqual(etGenerateCredential().id.count, 16)
    }

    func testPasskeyIs32Chars() {
        XCTAssertEqual(etGenerateCredential().passkey.count, 32)
    }

    // Legacy-compat marker: the first three id chars are always 'X'.
    func testIDStartsWithXXX() {
        XCTAssertTrue(etGenerateCredential().id.hasPrefix("XXX"))
    }

    // Charset: id + passkey contain only alphanumerics.
    func testCharsetIsAlphanumericOnly() {
        let allowed = Set(etAlphanumeric)
        let cred = etGenerateCredential()
        XCTAssertTrue(cred.id.allSatisfy { allowed.contains($0) })
        XCTAssertTrue(cred.passkey.allSatisfy { allowed.contains($0) })
    }

    // Not a stub: two successive credentials differ (passkeys, and ids past the XXX marker).
    func testSuccessiveCredentialsDiffer() {
        let a = etGenerateCredential()
        let b = etGenerateCredential()
        XCTAssertNotEqual(a.passkey, b.passkey)
        XCTAssertNotEqual(a.id, b.id)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ETCredentialTests`
Expected: FAIL to compile / "cannot find 'etGenerateCredential' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// A freshly generated ET bootstrap credential. `id` is 16 alphanumeric chars
/// (first three forced to 'X', the upstream legacy-compat marker); `passkey`
/// is 32 alphanumeric chars. The MODERN etserver generates its own credential
/// and returns it via IDPASSKEY, so this pair is the bootstrap-command input
/// and the legacy fallback; the connection uses the server's returned values.
public struct ETCredential: Sendable, Equatable {
    public let id: String
    public let passkey: String
    public init(id: String, passkey: String) { self.id = id; self.passkey = passkey }
}

/// Alphanumeric alphabet (A-Z a-z 0-9), matching ET's `genRandomAlphaNum`.
public let etAlphanumeric: [Character] =
    Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")

/// Generate an ET bootstrap credential using the system CSPRNG.
/// `SystemRandomNumberGenerator` is cryptographically secure on Apple and Linux.
public func etGenerateCredential() -> ETCredential {
    var rng = SystemRandomNumberGenerator()
    func randomAlphaNum(_ n: Int) -> String {
        String((0..<n).map { _ in etAlphanumeric.randomElement(using: &rng)! })
    }
    var id = Array(randomAlphaNum(16))
    id[0] = "X"; id[1] = "X"; id[2] = "X"   // legacy-compat marker (upstream SshSetupHandler)
    return ETCredential(id: String(id), passkey: randomAlphaNum(32))
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ETCredentialTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/ET/ETCredential.swift Tests/SemicolynKitTests/ETCredentialTests.swift
git commit -m "feat(et): CSPRNG bootstrap credential generation

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
```

---

### Task 2: `etBootstrapCommand` (remote command builder)

**Files:**
- Create: `Sources/SemicolynKit/ET/ETBootstrap.swift`
- Test: `Tests/SemicolynKitTests/ETBootstrapCommandTests.swift`

**Interfaces:**
- Consumes: nothing (string builder).
- Produces: `public func etBootstrapCommand(id: String, passkey: String, term: String, verbose: Int = 0, killUser: String? = nil, etterminalPath: String? = nil) -> String`. Output: `echo '<id>/<passkey>_<term>' | <path ?? "etterminal"> --verbose=<verbose>`, optionally prefixed with `pkill etterminal -u <killUser>; sleep 0.5; ` when `killUser` is non-nil.

- [ ] **Step 1: Write the failing test**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ETBootstrapCommandTests: XCTestCase {
    func testDefaultCommand() {
        let cmd = etBootstrapCommand(id: "XXX0123456789ab",
                                     passkey: "0123456789abcdef0123456789abcdef",
                                     term: "xterm-256color")
        XCTAssertEqual(cmd,
            "echo 'XXX0123456789ab/0123456789abcdef0123456789abcdef_xterm-256color' | etterminal --verbose=0")
    }

    func testVerboseLevelAppears() {
        let cmd = etBootstrapCommand(id: "XXXa", passkey: "p", term: "xterm", verbose: 3)
        XCTAssertEqual(cmd, "echo 'XXXa/p_xterm' | etterminal --verbose=3")
    }

    func testCustomEtterminalPath() {
        let cmd = etBootstrapCommand(id: "XXXa", passkey: "p", term: "xterm",
                                     etterminalPath: "/opt/bin/etterminal")
        XCTAssertEqual(cmd, "echo 'XXXa/p_xterm' | /opt/bin/etterminal --verbose=0")
    }

    func testKillUserPrefix() {
        let cmd = etBootstrapCommand(id: "XXXa", passkey: "p", term: "xterm", killUser: "alice")
        XCTAssertEqual(cmd,
            "pkill etterminal -u alice; sleep 0.5; echo 'XXXa/p_xterm' | etterminal --verbose=0")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ETBootstrapCommandTests`
Expected: FAIL to compile / "cannot find 'etBootstrapCommand' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Build the remote command that plants the ET credential with etserver over an
/// existing SSH session, mirroring upstream `SshSetupHandler::genCommand`:
/// `echo '<id>/<passkey>_<TERM>' | etterminal --verbose=<v>`. When `killUser`
/// is set, prepend a `pkill etterminal -u <user>; sleep 0.5;` (the upstream
/// kill flag) to clear the user's old ET sessions first.
public func etBootstrapCommand(id: String, passkey: String, term: String,
                               verbose: Int = 0, killUser: String? = nil,
                               etterminalPath: String? = nil) -> String {
    let bin = etterminalPath ?? "etterminal"
    let command = "echo '\(id)/\(passkey)_\(term)' | \(bin) --verbose=\(verbose)"
    if let user = killUser {
        return "pkill etterminal -u \(user); sleep 0.5; \(command)"
    }
    return command
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ETBootstrapCommandTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/ET/ETBootstrap.swift Tests/SemicolynKitTests/ETBootstrapCommandTests.swift
git commit -m "feat(et): bootstrap command builder (echo id/passkey | etterminal)

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
```

---

### Task 3: `ETBootstrapError` + `parseETIDPASSKEY` (Critical: parse a secret from untrusted output)

**Files:**
- Modify: `Sources/SemicolynKit/ET/ETBootstrap.swift` (append the enum + parser)
- Test: `Tests/SemicolynKitTests/ETIDPASSKEYParseTests.swift`

**Interfaces:**
- Consumes: `ETCredential` (Task 1), `sanitizeEndReason` (slice 1a), `ETConfigError` (slice 1a).
- Produces:
  - `public enum ETBootstrapError: Error, Equatable { case execFailed; case noIDPASSKEY(serverOutput: String); case malformedIDPASSKEY; case invalidConfig(ETConfigError); case handshakeFailed(reason: String) }`
  - `public func parseETIDPASSKEY(_ stdout: String) -> Result<ETCredential, ETBootstrapError>`, finds `IDPASSKEY:` anywhere in `stdout`, extracts a 16-char id and 32-char passkey separated by `/`. No line → `.noIDPASSKEY(serverOutput: sanitizeEndReason(stdout))`. Wrong lengths / missing `/` → `.malformedIDPASSKEY`.

This is Critical tier: the parsed value is a live secret, and the input is untrusted server output. Assert exact extracted values and the specific failure case.

- [ ] **Step 1: Write the failing test**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ETIDPASSKEYParseTests: XCTestCase {
    private let id16 = "abcdef0123456789"                     // 16
    private let key32 = "0123456789abcdef0123456789abcdef"    // 32

    func testValidLineExtractsCredential() {
        let out = "IDPASSKEY:\(id16)/\(key32)\n"
        guard case .success(let cred) = parseETIDPASSKEY(out) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(cred.id, id16)
        XCTAssertEqual(cred.passkey, key32)
    }

    // Upstream uses find(), so the line may be embedded in surrounding server noise.
    func testEmbeddedInNoiseStillExtracts() {
        let out = "MOTD: welcome\nIDPASSKEY:\(id16)/\(key32)\nlogged in\n"
        guard case .success(let cred) = parseETIDPASSKEY(out) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(cred.id, id16)
        XCTAssertEqual(cred.passkey, key32)
    }

    func testNoLineIsNoIDPASSKEYWithSanitizedOutput() {
        guard case .failure(let err) = parseETIDPASSKEY("command not found: etterminal\n") else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(err, .noIDPASSKEY(serverOutput: "command not found: etterminal"))
    }

    func testShortIDIsMalformed() {
        let out = "IDPASSKEY:short/\(key32)\n"
        guard case .failure(let err) = parseETIDPASSKEY(out) else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(err, .malformedIDPASSKEY)
    }

    func testShortPasskeyIsMalformed() {
        let out = "IDPASSKEY:\(id16)/tooshort\n"
        guard case .failure(let err) = parseETIDPASSKEY(out) else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(err, .malformedIDPASSKEY)
    }

    func testMissingSlashIsMalformed() {
        let out = "IDPASSKEY:\(id16)\(key32)\n"   // no separator
        guard case .failure(let err) = parseETIDPASSKEY(out) else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(err, .malformedIDPASSKEY)
    }

    // An injection-laden non-IDPASSKEY output is captured but sanitized (no ANSI/markup leak).
    func testInjectionOutputIsSanitizedInNoIDPASSKEY() {
        guard case .failure(let err) = parseETIDPASSKEY("\u{1B}[31m<b>evil</b>\u{1B}[0m") else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(err, .noIDPASSKEY(serverOutput: "evil"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ETIDPASSKEYParseTests`
Expected: FAIL to compile / "cannot find 'parseETIDPASSKEY' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
// Append to Sources/SemicolynKit/ET/ETBootstrap.swift.

/// Typed failures of the ET bootstrap (planting + handshake). Each case is
/// distinct so the fallback/UI slice can render the right message. The two
/// string-bearing cases carry ALREADY-SANITIZED text (untrusted server output).
public enum ETBootstrapError: Error, Equatable {
    case execFailed
    case noIDPASSKEY(serverOutput: String)
    case malformedIDPASSKEY
    case invalidConfig(ETConfigError)
    case handshakeFailed(reason: String)
}

/// Parse the `IDPASSKEY:<id>/<passkey>` line etserver prints on stdout and
/// return the SERVER's credential (mirrors upstream `SshSetupHandler`). The id
/// is 16 chars, the passkey 32, separated by '/'. The line may be embedded in
/// surrounding server output, so we search for the marker rather than requiring
/// it at the start. No marker -> `.noIDPASSKEY` with the output sanitized (it is
/// untrusted). Wrong lengths or a missing '/' -> `.malformedIDPASSKEY`.
public func parseETIDPASSKEY(_ stdout: String) -> Result<ETCredential, ETBootstrapError> {
    let marker = "IDPASSKEY:"
    guard let range = stdout.range(of: marker) else {
        return .failure(.noIDPASSKEY(serverOutput: sanitizeEndReason(stdout)))
    }
    // Take the marker's line tail up to the next newline (or end).
    let afterMarker = stdout[range.upperBound...]
    let line = afterMarker.prefix { $0 != "\n" && $0 != "\r" }
    let parts = line.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0].count == 16, parts[1].count == 32 else {
        return .failure(.malformedIDPASSKEY)
    }
    return .success(ETCredential(id: String(parts[0]), passkey: String(parts[1])))
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ETIDPASSKEYParseTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/ET/ETBootstrap.swift Tests/SemicolynKitTests/ETIDPASSKEYParseTests.swift
git commit -m "feat(et): ETBootstrapError + IDPASSKEY parser (server credential read-back)

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
```

---

### Task 4: `etConnectConfig` (assemble + validate the live config)

**Files:**
- Modify: `Sources/SemicolynKit/ET/ETBootstrap.swift` (append the builder)
- Test: `Tests/SemicolynKitTests/ETConnectConfigTests.swift`

**Interfaces:**
- Consumes: `ETConfig`, `validateETConfig`, `ETConfigError` (slice 1a).
- Produces: `public func etConnectConfig(host: String, port: UInt16 = 2022, id: String, passkey: String, term: String, cols: UInt16, rows: UInt16) throws -> ETConfig`, builds an `ETConfig` (env = `["TERM": term]`, width/height 0, keepaliveSecs 0) and returns `try validateETConfig(cfg)`, so an invalid input throws the specific `ETConfigError`.

- [ ] **Step 1: Write the failing test**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ETConnectConfigTests: XCTestCase {
    func testBuildsValidConfig() throws {
        let cfg = try etConnectConfig(host: "h.example", id: "abcdef0123456789",
                                      passkey: "0123456789abcdef0123456789abcdef",
                                      term: "xterm-256color", cols: 80, rows: 24)
        XCTAssertEqual(cfg.host, "h.example")
        XCTAssertEqual(cfg.port, 2022)
        XCTAssertEqual(cfg.id, "abcdef0123456789")
        XCTAssertEqual(cfg.passkey, "0123456789abcdef0123456789abcdef")
        XCTAssertEqual(cfg.env["TERM"], "xterm-256color")
        XCTAssertEqual(cfg.cols, 80)
        XCTAssertEqual(cfg.rows, 24)
    }

    func testDefaultPortIs2022() throws {
        let cfg = try etConnectConfig(host: "h", id: "abcdef0123456789",
                                      passkey: "0123456789abcdef0123456789abcdef",
                                      term: "xterm", cols: 1, rows: 1)
        XCTAssertEqual(cfg.port, 2022)
    }

    // Invalid input throws the SPECIFIC ETConfigError (from slice 1a's validateETConfig).
    func testEmptyPasskeyThrowsEmptyPasskey() {
        XCTAssertThrowsError(try etConnectConfig(host: "h", id: "abcdef0123456789",
                                                 passkey: "", term: "xterm",
                                                 cols: 1, rows: 1)) {
            XCTAssertEqual($0 as? ETConfigError, .emptyPasskey)
        }
    }

    func testEmptyTermThrowsMissingTERM() {
        XCTAssertThrowsError(try etConnectConfig(host: "h", id: "abcdef0123456789",
                                                 passkey: "0123456789abcdef0123456789abcdef",
                                                 term: "", cols: 1, rows: 1)) {
            XCTAssertEqual($0 as? ETConfigError, .missingTERM)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ETConnectConfigTests`
Expected: FAIL to compile / "cannot find 'etConnectConfig' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
// Append to Sources/SemicolynKit/ET/ETBootstrap.swift.

/// Assemble the live `ETConfig` for `et_connect` from the resolved credential
/// and the terminal geometry, then validate it. Port defaults to ET's 2022.
/// `term` becomes the sole env entry (`TERM`), which `validateETConfig` requires.
/// Throws the specific `ETConfigError` on invalid input.
public func etConnectConfig(host: String, port: UInt16 = 2022, id: String, passkey: String,
                            term: String, cols: UInt16, rows: UInt16) throws -> ETConfig {
    let cfg = ETConfig(host: host, port: port, id: id, passkey: passkey,
                       env: ["TERM": term], cols: cols, rows: rows,
                       width: 0, height: 0, keepaliveSecs: 0)
    return try validateETConfig(cfg)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ETConnectConfigTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/ET/ETBootstrap.swift Tests/SemicolynKitTests/ETConnectConfigTests.swift
git commit -m "feat(et): etConnectConfig builds + validates the live ETConfig

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
```

---

### Task 5: `ConnectionViewModel` ET branch (App wiring, macOS-CI-only)

**Files:**
- Modify: `App/ConnectionViewModel.swift`

**Interfaces:**
- Consumes: `etGenerateCredential`, `etBootstrapCommand`, `parseETIDPASSKEY`, `etConnectConfig`, `ETBootstrapError` (Tasks 1-4); `ETSession`, `sanitizeEndReason` (slice 1a); `Connection.openExec`, `TerminalShellOutput` (existing App).
- Produces: an async `attachET(conn:host:defaults:) -> Result<Void, ETBootstrapError>` that: generates the credential, runs the bootstrap over `openExec` (a `captureETBootstrap` mirroring `captureMoshBootstrap`), parses IDPASSKEY, builds+validates the config, starts an `ETSession`, wires `onOutput` into the terminal view and keystrokes/resize into `send`/`setWindowSize`, and routes `onEnd` through `sanitizeEndReason` into `.handshakeFailed`. Failure returns the typed error (NO silent SSH fallback).

Because this is Apple-tier (no Linux compile, no local test run), verification is the macOS CI compile in Task 6 + a manual re-read. Keep ALL wrong-able logic in the Task 1-4 deciders; this method is wiring only.

- [ ] **Step 1: Add `captureETBootstrap` (mirror `captureMoshBootstrap`)**

Add a private method modeled exactly on `captureMoshBootstrap` (`App/ConnectionViewModel.swift:673-696`): open a one-shot `conn.openExec(command:term:cols:rows:output:)` with a `TerminalShellOutput` sink, collect bytes, race the exec-close `AsyncStream` against a 2s guard, and return the captured stdout `String`. Return `nil` (not `""`) when `openExec` returns nil, so the caller can distinguish `.execFailed` from an empty-but-open exec.

```swift
/// Run the ET bootstrap over a one-shot exec and return its stdout, or nil if
/// the exec channel could not be opened. Resolves when the exec closes or a 2s
/// guard fires (same race as captureMoshBootstrap). SECURITY: the command
/// contains the passkey; never log `command` verbatim.
private func captureETBootstrap(conn: Connection, command: String) async -> String? {
    let sink = TerminalShellOutput()
    var captured: [UInt8] = []
    sink.onBytes = { captured.append(contentsOf: $0) }
    let done = AsyncStream<Void> { cont in
        sink.onExit = { _ in cont.yield(); cont.finish() }
    }
    guard let sess = try? await conn.openExec(command: command, term: "xterm-256color",
                                              cols: 80, rows: 24, output: sink) else {
        DebugLog.shared.log(.connect, "et: bootstrap exec FAILED to open")
        return nil
    }
    defer { Task { try? await sess.close() } }
    await withTaskGroup(of: Void.self) { group in
        group.addTask { for await _ in done { break } }
        group.addTask { try? await Task.sleep(nanoseconds: 2_000_000_000) }
        await group.next(); group.cancelAll()
    }
    return String(decoding: captured, as: UTF8.self)
}
```

- [ ] **Step 2: Add the `attachET` branch**

Add an async method that runs the pure deciders in sequence and wires `ETSession`. Log decision points WITHOUT the secret (lengths / "parsed ok|failed" only). Cols/rows come from the current terminal geometry the existing tmux/mosh paths already read (reuse the same source they use; if a helper like `currentGridSize()` exists, use it, otherwise 80x24 as the other bootstraps default the exec).

```swift
/// Bootstrap + attach an ET session on the authenticated connection. Returns
/// .success when ETSession started; .failure(ETBootstrapError) otherwise. Does
/// NOT fall back to SSH (per the ET-bootstrap design: the fallback/UI slice
/// renders the error). SECURITY: never log the passkey or the raw IDPASSKEY line.
private func attachET(conn: Connection, host: Host, defaults: Defaults) async -> Result<Void, ETBootstrapError> {
    let cred = etGenerateCredential()
    let term = "xterm-256color"
    let command = etBootstrapCommand(id: cred.id, passkey: cred.passkey, term: term)
    DebugLog.shared.log(.connect, "et: bootstrap exec (idLen=\(cred.id.count) keyLen=\(cred.passkey.count))")

    guard let stdout = await captureETBootstrap(conn: conn, command: command) else {
        return .failure(.execFailed)
    }
    let parsed = parseETIDPASSKEY(stdout)
    guard case .success(let serverCred) = parsed else {
        if case .failure(let e) = parsed {
            DebugLog.shared.log(.connect, "et: IDPASSKEY parse FAILED (\(e))")
            return .failure(e)
        }
        return .failure(.malformedIDPASSKEY)
    }
    DebugLog.shared.log(.connect, "et: IDPASSKEY parsed ok")

    let cols: UInt16 = 80, rows: UInt16 = 24   // TODO-note: reuse current grid size if a helper exists
    let config: ETConfig
    do {
        config = try etConnectConfig(host: host.hostName, id: serverCred.id,
                                     passkey: serverCred.passkey, term: term,
                                     cols: cols, rows: rows)
    } catch let e as ETConfigError {
        return .failure(.invalidConfig(e))
    } catch {
        return .failure(.malformedIDPASSKEY)
    }

    // Start ETSession and wire I/O to the terminal (slice 1a).
    let session = ETSession(host: config.host, port: config.port, id: config.id,
                            passkey: config.passkey, env: config.env,
                            cols: config.cols, rows: config.rows,
                            width: config.width, height: config.height,
                            keepaliveSecs: config.keepaliveSecs)
    // onOutput -> terminal feed; onEnd -> sanitized handshakeFailed. Follow the
    // exact wiring the Mosh path uses for onOutput/onEnd into the SwiftTerm view.
    session.onOutput = { [weak self] data in self?.feedTerminal(data) }
    session.onEnd = { reason in
        let safe = sanitizeEndReason(reason)
        DebugLog.shared.log(.connect, "et: session ended (\(safe))")
    }
    session.start()
    self.etSession = session   // retain for the session's life (add the stored property)
    return .success(())
}
```

Wiring notes for the implementer (do NOT guess; match existing precedent):
- Use the SAME terminal-feed path the Mosh branch uses for `onOutput` (find how `MoshSession.onOutput` bytes reach the SwiftTerm view in `ConnectionViewModel`, and route `ETSession.onOutput` identically).
- Route keystrokes and resize to `session.send(_:)` / `session.setWindowSizeCols:rows:width:height:` at the SAME points the Mosh/raw paths send input and handle resize.
- Add a stored `private var etSession: ETSession?` so the session outlives the method (mirroring how the Mosh session is retained).
- Reach `attachET` from a TEMPORARY explicit entry point (a dev-only call or a debug menu action). Do NOT modify the existing Mosh-silently-wins routing; the Transport picker is §5.

- [ ] **Step 3: Commit** (compile-verified on macOS CI in Task 6; no Linux build for this file)

```bash
git add App/ConnectionViewModel.swift
git commit -m "feat(et): ConnectionViewModel ET bootstrap branch (attachET + captureETBootstrap)

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
```

---

### Task 6: Push, verify macOS CI, update TODO

**Files:**
- Modify: `TODO.md`

**Interfaces:**
- Consumes: all prior tasks.
- Produces: a green CI run + updated resume pointer.

- [ ] **Step 1: Create the feature branch (if not already on one) and push**

```bash
git checkout -b feat/et-bootstrap 2>/dev/null || git checkout feat/et-bootstrap
git push -u github feat/et-bootstrap
```

- [ ] **Step 2: Open the PR**

```bash
gh pr create --repo ds7n/semicolyn --base main --head feat/et-bootstrap \
  --title "feat(et): ET bootstrap (slice 1b), plant credential + drive ETSession" \
  --body "$(cat <<'BODY'
Slice 1b of the ET transport (design: docs/superpowers/specs/2026-08-04-et-bootstrap-design.md).

- Four pure Linux-tested Kit deciders: etGenerateCredential (CSPRNG), etBootstrapCommand, parseETIDPASSKEY (Critical: reads the SERVER's credential from the IDPASSKEY response, corrects the parent spec's "no response needed"), etConnectConfig.
- ConnectionViewModel ET branch: runs the bootstrap over the existing russh openExec, parses, builds+validates the config, starts ETSession, wires I/O. Typed ETBootstrapError on failure, NO silent SSH fallback (user decision; the error/retry UI is the next slice).
- Reached via a temporary explicit entry point; the Transport picker is a later slice.

Secrets (passkey, IDPASSKEY line) are never logged. Real end-to-end ET needs a live etserver host (device pass); automated tests stop at the parse/config seam.

https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt
BODY
)"
```

- [ ] **Step 3: Wait for + verify all CI jobs green**

Run: `gh run watch --repo ds7n/semicolyn $(gh run list --repo ds7n/semicolyn --branch feat/et-bootstrap --limit 1 --json databaseId --jq '.[0].databaseId')`
Expected: `linux-swift`, `linux-rust`, `lint`, and **`macos`** all pass. The `macos` job is the only signal that the `ConnectionViewModel` ET branch compiles. If `linux-rust` flakes with "sshd fixtures not reachable", rerun that job only (`gh run rerun <id> --failed`); not a real failure on this non-Rust change.

- [ ] **Step 4: Update the TODO resume block**

Edit `TODO.md`: record ET slice 1b done (4 Kit deciders + `attachET`, PR #<n>, CI green), and that the NEXT ET slice is §4 (probe + error/retry UI: render `ETBootstrapError` as "ET could not connect: <reason>" + Retry/Cancel, no silent fallback) then §5 (per-host Transport picker). Note the bootstrap is compile + seam-verified only; a real handshake awaits a live etserver device pass.

- [ ] **Step 5: Commit**

```bash
git add TODO.md
git commit -m "docs: record ET bootstrap slice 1b done; next = ET probe/error-UI (§4)

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
git push
```

---

## Self-Review

**Spec coverage:**
- §In bullet 1 (generate id/passkey, `id[0..2]='X'`, CSPRNG) → Task 1.
- §In bullet 2 (bootstrap command over openExec) → Task 2 (command) + Task 5 (openExec run).
- §In bullet 3 (parse IDPASSKEY, use server credential) → Task 3.
- §In bullet 4 (build+validate ETConfig) → Task 4.
- §In bullet 5 (start ETSession, wire I/O) → Task 5.
- §In bullet 6 (typed ETBootstrapError, no silent fallback) → Task 3 (enum) + Task 5 (returns it, no fallback).
- §Error-handling table (execFailed / noIDPASSKEY / malformedIDPASSKEY / invalidConfig / handshakeFailed) → Task 3 enum + Task 5 branches (execFailed on nil exec, invalidConfig on catch, handshakeFailed via onEnd).
- §Security (CSPRNG, never log passkey/IDPASSKEY, sanitize serverOutput) → Task 1 (CSPRNG), Task 3 (sanitize in noIDPASSKEY), Task 5 (log lengths/"parsed ok", never the value).
- §Testing Linux table → Tasks 1-4 tests. §Testing macOS seam → Task 6 CI (the bridge-style capture->parse->config test is folded into the Task 5 wiring + Task 6 CI compile; a standalone fake-stdout bridge test is optional and can be added if the macOS CI compile alone is judged insufficient, noted here rather than silently dropped).
- §Non-goals (no probe/UI, no picker, no jumphost, no serverfifo) → respected; none implemented.

**Placeholder scan:** No "TBD"/"add error handling"/"similar to Task N". Every code step has concrete content. The one `TODO-note` in Task 5 (cols/rows from current grid) is an explicit wiring instruction with a concrete fallback (80x24), not an unfilled blank.

**Type consistency:** `ETCredential(id:passkey:)`, `etGenerateCredential()`, `etAlphanumeric`, `etBootstrapCommand(id:passkey:term:verbose:killUser:etterminalPath:)`, `ETBootstrapError` (5 cases), `parseETIDPASSKEY(_:) -> Result<ETCredential, ETBootstrapError>`, `etConnectConfig(host:port:id:passkey:term:cols:rows:) throws -> ETConfig` are consistent across tasks and the self-review. `ETConfig`/`validateETConfig`/`ETConfigError`/`sanitizeEndReason`/`ETSession` init match slice 1a's shipped signatures (verified against the merged `Sources/SemicolynKit/ET/*` + `App/ET/ETSession.h`). One item the implementer must confirm against slice 1a at Task 5: the exact `ETSession` initializer label list (`initWithHost:port:id:passkey:env:cols:rows:width:height:keepaliveSecs:` in Obj-C becomes `ETSession(host:port:id:passkey:env:cols:rows:width:height:keepaliveSecs:)` in Swift). The host address field is `host.hostName` (verified against `Sources/SemicolynKit/Model/Host.swift`; NOT `host.address`), used for `config.host`, matching how the Mosh branch reads `host.hostName`.
