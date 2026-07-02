<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Mosh Transport Implementation Plan (Phases M1–M2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lay the foundation for real, interoperable Mosh: an iOS build of the vendored Mosh C++ library (`Mosh.xcframework`) and the pure, Linux-tested bootstrap/decision units in SemicolynKit.

**Architecture:** `blinksh/mosh` (GPLv3 iOS-library fork) is added as a pinned git submodule and cross-compiled by a new script into `Mosh.xcframework` (Apple-only, macOS-CI). In parallel, SemicolynKit gains three pure units — a `mosh-server` command builder, a `MOSH CONNECT` parser, and a launch decision — all Linux-tested, mirroring the existing `tmuxLaunchDecision` pattern. The SSH bootstrap reuses the russh core (so public-key login is inherited).

**Tech Stack:** Swift 6 (SemicolynKit), C++/autotools (vendored Mosh), protobuf (Mosh dependency), xcodebuild `-create-xcframework`, Rust/russh (bootstrap, existing), XCTest, Docker sshd fixture.

**Scope note:** This plan covers **M1 (build integration)** and **M2 (Kit pure units + Rust bootstrap test)** from the spec. **M3 (the `MoshSession` Obj-C++ bridge) and M4 (resilience/wiring) are a follow-up plan** — their exact interfaces depend on the `moshiosbridge.h` API surface that M1 produces, so they cannot be specified without placeholders until M1 lands.

## Global Constraints

- **License:** repo is GPL-3.0-only, REUSE-compliant. First-party files carry `SPDX-FileCopyrightText: 2026 True Positive LLC` + `SPDX-License-Identifier: GPL-3.0-only`. **Vendored Mosh files keep THEIR upstream copyright + license headers — never relicense to True Positive LLC.**
- **Mosh source:** `blinksh/mosh`, added as a **pinned** git submodule. Only Mosh + its `moshiosbridge` wrapper — not Blink's broader userland.
- **Tiers:** SemicolynKit = pure, Linux-tested, Swift 6 strict-concurrency, `Sendable`, **no `import UIKit`/`SwiftUI`/`Foundation`-UI**. `Mosh.xcframework` + build scripts = Apple-only, validated only by the macOS CI job.
- **iOS:** deployment target **17.0**; built with **Xcode 26 / iOS 26 SDK** (App Store requirement). xcframework slices: **arm64 device + arm64-simulator + x86_64-simulator**. (Drop the archived build's dead armv7/i386.)
- **Tests are real** (`docs/superpowers/specs/2026-06-18-testing-standards-design.md`): equivalence-partitioning + boundary values, assert the *specific* observable outcome, negative tests assert the specific failure.
- **Commits:** Conventional Commits; feature branch `feat/mosh-transport`; squash-merge.
- **Build/test commands:** Kit tests via `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`. Rust via the `sshd` fixture + `docker compose run --rm dev cargo test -p semicolyn-ssh-core`.

---

## Phase M2 — SemicolynKit pure units (do first: fast Linux CI, zero external deps)

> M2 is ordered before M1 in execution because it's pure Swift with an instant Linux test loop and no dependency on the risky C++ build. M1 remains the overall risk gate but blocks nothing in M2.

### Task 1: `MOSH CONNECT` parser

**Files:**
- Create: `Sources/SemicolynKit/Mosh/MoshConnect.swift`
- Test: `Tests/SemicolynKitTests/MoshConnectTests.swift`

**Interfaces:**
- Produces:
  - `enum MoshConnectError: Equatable, Sendable { case noConnectLine; case malformed(String) }`
  - `enum MoshConnect: Equatable, Sendable { case success(port: Int, key: String); case failed(MoshConnectError) }`
  - `func parseMoshConnect(_ output: String) -> MoshConnect`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/SemicolynKitTests/MoshConnectTests.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class MoshConnectTests: XCTestCase {
    // Valid partition: a clean MOSH CONNECT line.
    func testParsesValidLine() {
        let out = "MOSH CONNECT 60001 x5HdELy8n2XkX9pO4dO2Zw"
        XCTAssertEqual(parseMoshConnect(out),
                       .success(port: 60001, key: "x5HdELy8n2XkX9pO4dO2Zw"))
    }

    // Valid partition: real servers print a banner/motd before the line.
    func testParsesLineAmidChatter() {
        let out = "Last login: Tue\nMOSH CONNECT 60002 AAAABBBBCCCCDDDDEEEEFF\nbye"
        XCTAssertEqual(parseMoshConnect(out),
                       .success(port: 60002, key: "AAAABBBBCCCCDDDDEEEEFF"))
    }

    // Invalid partition: no line at all.
    func testMissingLineIsNoConnectLine() {
        XCTAssertEqual(parseMoshConnect("mosh-server: command not found"),
                       .failed(.noConnectLine))
    }

    // Invalid partition: empty output.
    func testEmptyOutputIsNoConnectLine() {
        XCTAssertEqual(parseMoshConnect(""), .failed(.noConnectLine))
    }

    // Invalid partition: line present but missing the key.
    func testTruncatedLineIsMalformed() {
        XCTAssertEqual(parseMoshConnect("MOSH CONNECT 60001"),
                       .failed(.malformed("MOSH CONNECT 60001")))
    }

    // Invalid partition: non-numeric port.
    func testNonNumericPortIsMalformed() {
        XCTAssertEqual(parseMoshConnect("MOSH CONNECT abc KEYKEYKEY"),
                       .failed(.malformed("MOSH CONNECT abc KEYKEYKEY")))
    }

    // Boundary: port 0 (min-1) is out of range.
    func testPortZeroIsMalformed() {
        XCTAssertEqual(parseMoshConnect("MOSH CONNECT 0 KEYKEYKEY"),
                       .failed(.malformed("MOSH CONNECT 0 KEYKEYKEY")))
    }

    // Boundary: port 65536 (max+1) is out of range.
    func testPortAboveMaxIsMalformed() {
        XCTAssertEqual(parseMoshConnect("MOSH CONNECT 65536 KEYKEYKEY"),
                       .failed(.malformed("MOSH CONNECT 65536 KEYKEYKEY")))
    }

    // Boundary: port 65535 (max) is valid.
    func testPortMaxIsValid() {
        XCTAssertEqual(parseMoshConnect("MOSH CONNECT 65535 KEYKEYKEY"),
                       .success(port: 65535, key: "KEYKEYKEY"))
    }

    // Invalid partition: empty key after the port.
    func testEmptyKeyIsMalformed() {
        XCTAssertEqual(parseMoshConnect("MOSH CONNECT 60001 "),
                       .failed(.malformed("MOSH CONNECT 60001 ")))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter MoshConnectTests`
Expected: FAIL — `parseMoshConnect` / `MoshConnect` are undefined.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/SemicolynKit/Mosh/MoshConnect.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Why a `MOSH CONNECT` line could not be turned into a session.
public enum MoshConnectError: Equatable, Sendable {
    /// No `MOSH CONNECT` line was found in the server output at all.
    case noConnectLine
    /// A `MOSH CONNECT` line was found but the port/key could not be parsed.
    /// Carries the offending line for diagnostics.
    case malformed(String)
}

/// Result of parsing `mosh-server`'s stdout for its handoff line.
public enum MoshConnect: Equatable, Sendable {
    case success(port: Int, key: String)
    case failed(MoshConnectError)
}

/// Parses `mosh-server new` output for its `MOSH CONNECT <port> <key>` handoff
/// line, tolerating surrounding banner/motd text. Returns a typed failure rather
/// than throwing — the caller falls back to plain SSH on any failure.
public func parseMoshConnect(_ output: String) -> MoshConnect {
    for line in output.split(whereSeparator: \.isNewline) {
        guard line.hasPrefix("MOSH CONNECT ") else { continue }
        // Split on single spaces so a trailing empty key is caught (not trimmed away).
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 4,
              let port = Int(parts[2]), (1...65535).contains(port),
              !parts[3].isEmpty
        else { return .failed(.malformed(String(line))) }
        return .success(port: port, key: String(parts[3]))
    }
    return .failed(.noConnectLine)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter MoshConnectTests`
Expected: PASS (10 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Mosh/MoshConnect.swift Tests/SemicolynKitTests/MoshConnectTests.swift
git commit -m "feat(mosh): parse MOSH CONNECT handoff line (Linux-tested)"
```

---

### Task 2: `mosh-server` command builder

**Files:**
- Create: `Sources/SemicolynKit/Mosh/MoshServerCommand.swift`
- Test: `Tests/SemicolynKitTests/MoshServerCommandTests.swift`

**Interfaces:**
- Consumes: `MoshConfig` (`Sources/SemicolynKit/Model/HostExtensions.swift`): `{ enabled: Bool, serverPath: String?, udpPortRange: [Int]?, predictionMode: MoshPredictionMode? }`.
- Produces: `func moshServerCommand(_ config: MoshConfig, locale: String = "en_US.UTF-8") -> [String]`

**Note:** `predictionMode` is a *client*-side setting (consumed later by `MoshSession` via `MOSH_PREDICTION_DISPLAY`), so it does NOT appear in the server argv.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/SemicolynKitTests/MoshServerCommandTests.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class MoshServerCommandTests: XCTestCase {
    // Default: no custom path, no port range → the standard bootstrap argv.
    func testDefaultCommand() {
        let cfg = MoshConfig(enabled: true)
        XCTAssertEqual(moshServerCommand(cfg),
                       ["mosh-server", "new", "-s", "-c", "256", "-l", "LANG=en_US.UTF-8"])
    }

    // Custom server path is honored (e.g. a non-PATH install).
    func testCustomServerPath() {
        let cfg = MoshConfig(enabled: true, serverPath: "/opt/bin/mosh-server")
        XCTAssertEqual(moshServerCommand(cfg).first, "/opt/bin/mosh-server")
    }

    // Port range appends `-p lo:hi`.
    func testPortRangeAppended() {
        let cfg = MoshConfig(enabled: true, udpPortRange: [60000, 61000])
        XCTAssertEqual(moshServerCommand(cfg),
                       ["mosh-server", "new", "-s", "-c", "256", "-l",
                        "LANG=en_US.UTF-8", "-p", "60000:61000"])
    }

    // A malformed range (not exactly two elements) is ignored, not crashed on.
    func testMalformedPortRangeIgnored() {
        let cfg = MoshConfig(enabled: true, udpPortRange: [60000])
        XCTAssertFalse(moshServerCommand(cfg).contains("-p"))
    }

    // Locale override flows into the -l argument.
    func testLocaleOverride() {
        let cfg = MoshConfig(enabled: true)
        XCTAssertEqual(moshServerCommand(cfg, locale: "C.UTF-8").suffix(2),
                       ["-l", "LANG=C.UTF-8"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter MoshServerCommandTests`
Expected: FAIL — `moshServerCommand` undefined.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/SemicolynKit/Mosh/MoshServerCommand.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Builds the `mosh-server new` argv used to bootstrap a Mosh session over the SSH
/// channel. `-s` binds to the SSH connection's address; `-c 256` requests 256-color;
/// `-l LANG=…` sets a UTF-8 locale (mosh warns/degrades without one); `-p lo:hi`
/// constrains the UDP port when a range is configured.
public func moshServerCommand(_ config: MoshConfig, locale: String = "en_US.UTF-8") -> [String] {
    var argv = [config.serverPath ?? "mosh-server", "new", "-s", "-c", "256",
                "-l", "LANG=\(locale)"]
    if let range = config.udpPortRange, range.count == 2 {
        argv += ["-p", "\(range[0]):\(range[1])"]
    }
    return argv
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter MoshServerCommandTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Mosh/MoshServerCommand.swift Tests/SemicolynKitTests/MoshServerCommandTests.swift
git commit -m "feat(mosh): build mosh-server bootstrap argv (Linux-tested)"
```

---

### Task 3: Mosh launch decision

**Files:**
- Create: `Sources/SemicolynKit/Mosh/MoshLaunchDecision.swift`
- Test: `Tests/SemicolynKitTests/MoshLaunchDecisionTests.swift`

**Interfaces:**
- Consumes: `MoshConnect` (Task 1).
- Produces:
  - `enum MoshLaunchDecision: Equatable, Sendable { case mosh(port: Int, key: String); case fallbackSSH(reason: String) }`
  - `func moshLaunchDecision(enabled: Bool, bootstrap: MoshConnect) -> MoshLaunchDecision`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/SemicolynKitTests/MoshLaunchDecisionTests.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class MoshLaunchDecisionTests: XCTestCase {
    // Enabled + a good handoff → launch Mosh with those params.
    func testEnabledAndSuccessLaunchesMosh() {
        let d = moshLaunchDecision(enabled: true, bootstrap: .success(port: 60001, key: "K"))
        XCTAssertEqual(d, .mosh(port: 60001, key: "K"))
    }

    // Disabled → never Mosh, even if a handoff somehow parsed.
    func testDisabledFallsBack() {
        let d = moshLaunchDecision(enabled: false, bootstrap: .success(port: 60001, key: "K"))
        XCTAssertEqual(d, .fallbackSSH(reason: "Mosh not enabled for this host"))
    }

    // Enabled but no MOSH CONNECT → mosh-server missing/failed → fall back.
    func testEnabledNoConnectLineFallsBack() {
        let d = moshLaunchDecision(enabled: true, bootstrap: .failed(.noConnectLine))
        XCTAssertEqual(d, .fallbackSSH(reason: "mosh-server produced no session (is mosh installed on the host?)"))
    }

    // Enabled but malformed handoff → fall back with a distinct reason.
    func testEnabledMalformedFallsBack() {
        let d = moshLaunchDecision(enabled: true, bootstrap: .failed(.malformed("MOSH CONNECT x")))
        XCTAssertEqual(d, .fallbackSSH(reason: "could not parse mosh-server output"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter MoshLaunchDecisionTests`
Expected: FAIL — `moshLaunchDecision` undefined.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/SemicolynKit/Mosh/MoshLaunchDecision.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Whether to hand off to a Mosh session or fall back to plain SSH. Mirrors the
/// `tmuxLaunchDecision` pure-decision pattern: no I/O, fully testable.
public enum MoshLaunchDecision: Equatable, Sendable {
    case mosh(port: Int, key: String)
    case fallbackSSH(reason: String)
}

/// Maps the resolved `mosh.enabled` flag + the bootstrap parse result to a launch
/// decision. Any failure yields `.fallbackSSH` so the user still gets a shell.
public func moshLaunchDecision(enabled: Bool, bootstrap: MoshConnect) -> MoshLaunchDecision {
    guard enabled else { return .fallbackSSH(reason: "Mosh not enabled for this host") }
    switch bootstrap {
    case let .success(port, key):
        return .mosh(port: port, key: key)
    case .failed(.noConnectLine):
        return .fallbackSSH(reason: "mosh-server produced no session (is mosh installed on the host?)")
    case .failed(.malformed):
        return .fallbackSSH(reason: "could not parse mosh-server output")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter MoshLaunchDecisionTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Mosh/MoshLaunchDecision.swift Tests/SemicolynKitTests/MoshLaunchDecisionTests.swift
git commit -m "feat(mosh): pure Mosh-vs-SSH launch decision (Linux-tested)"
```

---

### Task 4: Rust bootstrap interop test (real `mosh-server` in the fixture)

Proves the SSH→`mosh-server`→`MOSH CONNECT` bootstrap works against a *real* mosh-server on Linux CI. Uses the existing `open_exec` on the connection.

**Files:**
- Modify: the sshd fixture image so `mosh-server` is installed. Find the Dockerfile the `sshd` service builds (`grep -rn "sshd" docker-compose.yml` → its `build:` context) and add `mosh` to the package install line.
- Create: `crates/semicolyn-ssh-core/tests/mosh_bootstrap_integration.rs`

**Interfaces:**
- Consumes: the connection's `open_exec` (in `crates/semicolyn-ssh-core/src/connection.rs` ~line 469) and the existing test helpers in `crates/semicolyn-ssh-core/tests/auth_integration.rs` (`sshd_addr()`, `connect_core(...)`, `TrustAll`).

- [ ] **Step 1: Read the exact `open_exec` signature and the auth test helpers**

Run: `grep -n "pub async fn open_exec\|fn sshd_addr\|fn connect_core\|struct TrustAll" crates/semicolyn-ssh-core/src/connection.rs crates/semicolyn-ssh-core/tests/auth_integration.rs`
Note the exact `open_exec` parameters + return type and how `auth_integration.rs` obtains an authenticated connection — you'll copy that setup.

- [ ] **Step 2: Add `mosh` to the sshd fixture image**

In the sshd service's Dockerfile, add `mosh` to the existing `apt-get install` list (alongside `openssh-server`). Example (match the file's existing style):

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-server mosh \
 && rm -rf /var/lib/apt/lists/*
```

- [ ] **Step 3: Write the failing test**

```rust
// crates/semicolyn-ssh-core/tests/mosh_bootstrap_integration.rs
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
//
// Bootstrap interop: SSH-authenticate, run `mosh-server new` via open_exec, and
// assert a well-formed `MOSH CONNECT <port> <key>` line comes back from a REAL
// mosh-server. The UDP session itself is Apple-only (libmoshios) and not tested here.

// NOTE: mirror the connection setup from auth_integration.rs (sshd_addr, connect_core,
// TrustAll, publickey auth with /testkeys/id_ed25519). Then:
//   let out = conn.open_exec("mosh-server new -s -c 256 -l LANG=C.UTF-8".into()).await.expect("exec");
//   assert!(out.stdout.contains("MOSH CONNECT "), "got: {}", out.stdout);
//   let line = out.stdout.lines().find(|l| l.starts_with("MOSH CONNECT ")).unwrap();
//   let parts: Vec<&str> = line.split(' ').collect();
//   assert_eq!(parts.len(), 4);
//   assert!(parts[2].parse::<u16>().is_ok());   // port
//   assert!(!parts[3].is_empty());              // key
```

Fill the `NOTE` in with the concrete setup discovered in Step 1 (the `open_exec` return type dictates whether you read `.stdout` or the raw bytes). Skip gracefully (as `auth_integration.rs` does) when the fixture env is absent.

- [ ] **Step 3b: Run to verify it fails/skips correctly**

Run: `docker compose up -d sshd && HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev cargo test -p semicolyn-ssh-core --test mosh_bootstrap_integration`
Expected: FAIL first (compile error until the setup is filled in), then once implemented it PASSES against the fixture.

- [ ] **Step 4: Make it pass**

Complete the setup from Step 1's findings; rerun the command above; expect PASS.

- [ ] **Step 5: Commit**

```bash
git add crates/semicolyn-ssh-core/tests/mosh_bootstrap_integration.rs <the-sshd-Dockerfile>
git commit -m "test(mosh): SSH->mosh-server bootstrap interop against real mosh-server"
```

---

## Phase M1 — Build integration: `Mosh.xcframework` (the risk gate)

> Build/cross-compile work — verified by "it builds, links, and exposes the bridge symbol," not unit tests. This is the highest-risk phase (modernizing an archived 2020/Xcode-7 build for Xcode 26 + arm64-simulator + a current protobuf). Do it on a Mac or rely on the macOS CI job; it cannot be validated on Linux.

### Task 5: Vendor `blinksh/mosh` as a pinned submodule

**Files:**
- Create: `.gitmodules` entry + `extern/mosh` (submodule)
- Create: `docs/vendor/mosh.md` (provenance + pin + license note)

- [ ] **Step 1: Add the submodule**

```bash
git submodule add https://github.com/blinksh/mosh.git extern/mosh
cd extern/mosh && git checkout <latest-known-good-commit> && cd ../..
git add .gitmodules extern/mosh
```

- [ ] **Step 2: Record provenance + license**

Create `docs/vendor/mosh.md` stating: source repo, pinned commit SHA, that it is GPLv3 (retains upstream headers, NOT relicensed), that the App Store use relies on upstream `COPYING.iOS`, and how to bump the pin. Add its `.reuse/dep5` or per-file handling so REUSE stays green for the vendored tree (follow the repo's existing REUSE convention — `grep -rn "REUSE\|dep5\|\.license" .reuse* 2>/dev/null`).

- [ ] **Step 3: Commit**

```bash
git add .gitmodules extern/mosh docs/vendor/mosh.md
git commit -m "vendor(mosh): pin blinksh/mosh iOS-library fork as submodule"
```

### Task 6: `scripts/build-mosh-xcframework.sh` — cross-compile + package

**Files:**
- Create: `scripts/build-mosh-xcframework.sh`

Modernizes the archived `blinksh/build-mosh` recipe (`build-mosh.sh` + `create-libmoshios-framework.sh`): autotools cross-compile of `extern/mosh` with `--enable-ios-controller --disable-server --disable-client`, per-arch, then package as an **xcframework** (not a fat `.framework`).

- [ ] **Step 1: Build protobuf for iOS** (Mosh's dependency)

In the script, build `libprotobuf` for the three slices (arm64-device, arm64-sim, x86_64-sim) from a pinned protobuf release using its CMake + an iOS toolchain, or vendor a prebuilt. Output static libs + `protoc` for the host. This is the fiddliest part — keep protobuf pinned and the arch/SDK flags explicit.

- [ ] **Step 2: Cross-compile Mosh per slice**

For each slice set `CC`/`CXX` (Xcode clang), `-arch`, `-isysroot <SDK>`, `-mios-version-min=17.0` (device) / `-mios-simulator-version-min=17.0` (sim), point `--with-protobuf` at Step 1's output, then `./autogen.sh && ./configure --host=<triple> --enable-ios-controller --disable-server --disable-client && make`. Collect `libmoshios.a` (+ the protobuf static lib) per slice.

- [ ] **Step 3: Package the xcframework**

`lipo -create` the two simulator slices into one, then:

```bash
xcodebuild -create-xcframework \
  -library build/ios-arm64/libmoshios.a       -headers extern/mosh/src/frontend \
  -library build/ios-sim/libmoshios.a         -headers extern/mosh/src/frontend \
  -output Frameworks/Mosh.xcframework
```

(Header path = wherever `moshiosbridge.h` lives in `extern/mosh`; confirm with `find extern/mosh -name moshiosbridge.h`.)

- [ ] **Step 4: Verify the bridge symbol is present**

Run: `nm Frameworks/Mosh.xcframework/ios-arm64/libmoshios.a 2>/dev/null | grep -i mosh | head`
Expected: non-empty — the moshiosbridge entry points are present. This is the M1 success gate.

- [ ] **Step 5: Commit**

```bash
git add scripts/build-mosh-xcframework.sh
git commit -m "build(mosh): cross-compile blinksh/mosh into Mosh.xcframework (Xcode 26, arm64+sim)"
```

### Task 7: Link the xcframework + build it in CI

**Files:**
- Modify: `project.yml` (add the `Mosh.xcframework` dependency to the app target)
- Modify: the macOS CI workflow (`.github/workflows/*.yml` — the job that runs `scripts/build-xcframework.sh`)

- [ ] **Step 1: Link in xcodegen**

Add `Frameworks/Mosh.xcframework` to the app target's `dependencies:` in `project.yml` (mirror how `SemicolynSSHCore.xcframework` is referenced), with `embed: true` if it's dynamic / `false` for the static-lib framework as appropriate.

- [ ] **Step 2: Build the xcframework in CI**

In the macOS CI job, add a step that runs `bash scripts/build-mosh-xcframework.sh` (with `submodules: recursive` on the checkout) **before** `xcodegen generate`, so the app links against a freshly built framework. Add `submodules: recursive` to the `actions/checkout` step.

- [ ] **Step 3: Verify the app compiles + links**

Push the branch → the macOS CI job must go green (compiles the app with `Mosh.xcframework` linked, even though nothing calls it yet). A green macOS job is the proof M1 succeeded.

- [ ] **Step 4: Commit**

```bash
git add project.yml .github/workflows/<file>.yml
git commit -m "build(mosh): link Mosh.xcframework + build it in macOS CI"
```

---

## After M1 + M2

With `Mosh.xcframework` building/linking and the pure units green, the **M3/M4 follow-up plan** can be written against the *real* `moshiosbridge.h` API (create session, feed input, pump, resize, output callback, teardown): the `MoshSession` bridge, the `ConnectionViewModel` branch that runs the bootstrap → `parseMoshConnect` → `moshLaunchDecision` → `MoshSession`, roaming/network-change handling, the error banners + SSH fallback, and the Simulator/device feel pass.

## Self-review notes

- **Spec coverage:** M1 (build integration) → Tasks 5–7. M2 pure units (`MoshServerCommand`, `MoshConnect`, `MoshLaunchDecision`) → Tasks 1–3. M2 Rust bootstrap test → Task 4. M3/M4 explicitly deferred to a follow-up plan (interfaces depend on M1 output). Licensing/REUSE → Task 5 Step 2 + global constraints.
- **Types consistent:** `MoshConnect`/`MoshConnectError` defined in Task 1 and consumed unchanged in Tasks 3–4; `MoshConfig` fields match `HostExtensions.swift`; `MoshLaunchDecision` reasons match between test and impl.
- **Known soft spot:** Task 4 Step 1 and Task 6 header/protobuf specifics require reading exact signatures/paths at execution time (the plan directs *which* to read) — inherent to a Rust signature we don't re-declare and a vendored tree whose layout is confirmed on checkout, not a substitutable placeholder.
