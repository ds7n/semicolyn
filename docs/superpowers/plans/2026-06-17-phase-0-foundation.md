# Phase 0 — Foundations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the Neotilde workspace, prove the Rust→Swift toolchain end-to-end, and build the three foundations every later phase depends on: the design-token layer, the core data model, and the at-rest encryption envelope.

**Architecture:** A Cargo workspace holds the Rust SSH core crate (`neotilde-ssh-core`), exported to Swift through a UniFFI-generated XCFramework. A SwiftPM package (`NeotildeKit`) holds the pure-Swift foundations (tokens, model, crypto). The work is split into a **platform-agnostic tier** (Rust core logic, data model, crypto envelope via Apple's `swift-crypto`, token *values*) that builds and tests on **Linux** for a fast TDD loop, and an **Apple-only tier** (the UniFFI XCFramework bridge, SwiftUI `Color`/environment) verified on **macOS CI** (GitHub Actions). `Package.swift` is host-conditional so the Linux loop never sees the iOS-only XCFramework.

**Tech Stack:** Rust (stable, `uniffi` 0.31+), Swift 6 / SwiftPM, CryptoKit on Apple / `swift-crypto` (`Crypto`) on Linux behind a `#if canImport(CryptoKit)` shim, `xcodebuild -create-xcframework`.

## Global Constraints

- **Bridge:** UniFFI 0.31+, proc-macro scaffolding (`uniffi::setup_scaffolding!()`), no UDL file. Verbatim from roadmap.
- **Rust crypto backend:** russh added in Phase 1; in Phase 0 the crate carries no SSH deps yet — keep it minimal so the toolchain proof is fast.
- **Platform split:** logic stays in the agnostic tier and must compile + test on Linux. Crypto imports go behind `#if canImport(CryptoKit) … #else import Crypto #endif`; SwiftUI-touching code goes behind `#if canImport(SwiftUI)`. Keep the Apple-only surface thin.
- **Colors:** UI/token code never inlines a hex literal outside a theme file's `private let` palette block. Palette constants verbatim from `design-tokens-design.md`.
- **Schema fidelity:** field names are lowercase camelCase matching `ssh_config(5)` stems exactly (`hostName`, `proxyJump`, `serverAliveInterval`). Verbatim from `host-config-model-design.md`.
- **Inheritance semantics:** `undefined` = inherit; `null`/`[]` = explicit "none." This distinction is baked in from day one (no later migration). Verbatim from `host-config-model-design.md`.
- **License header:** every created source file (`.swift`, `.rs`) begins with these two REUSE-compliant lines verbatim:
  ```
  // SPDX-FileCopyrightText: 2026 True Positive LLC
  // SPDX-License-Identifier: GPL-3.0-only
  ```
- **Conventional commits**; squash-merge.
- Toolchain: the Linux dev box needs the Swift toolchain + `cargo`. macOS CI additionally installs the Rust targets `aarch64-apple-ios`, `aarch64-apple-ios-sim`, `x86_64-apple-ios` before building the XCFramework (Task 1).

---

## Platform tiers — where each piece builds & tests

| Tier | Tasks / files | Builds & tests on |
|---|---|---|
| **Agnostic (fast loop)** | Rust core `core_version()` (Task 1 Rust), data model (Task 3), `RecordEnvelope` via swift-crypto (Task 4), `ThemeColor`/`Theme` + `rgba()` (Task 2) | **Linux** (`cargo test` + `swift test`) *and* macOS |
| **Apple-only (CI gate)** | UniFFI Swift bindings + XCFramework + `BridgeTests` (Task 1), SwiftUI `Color(ThemeColor)` + `EnvironmentValues.theme` (Task 2 `ThemeEnvironment.swift`) | **macOS CI only** (GitHub Actions) |

Implication for the controller: on Linux you run `cargo test` and `swift test` (the latter resolves only the agnostic targets — see the host-conditional `Package.swift` in Task 1). The XCFramework build + `BridgeTests` + the SwiftUI-compile check are the macOS-CI job.

---

## File Structure

| File | Responsibility | Tier |
|---|---|---|
| `Cargo.toml` | Workspace root | agnostic |
| `crates/neotilde-ssh-core/Cargo.toml` | Rust core crate manifest (staticlib + UniFFI) | agnostic |
| `crates/neotilde-ssh-core/src/lib.rs` | Rust exports + unit test (Phase 0: `core_version()`) | agnostic |
| `scripts/build-xcframework.sh` | Build Rust for 3 iOS triples, gen Swift bindings, package XCFramework | Apple-only |
| `Package.swift` | SwiftPM root — `NeotildeKit` always; FFI + binary + BridgeTests appended only `#if os(macOS)` | both |
| `Sources/NeotildeKit/Theme/Theme.swift` | `ThemeColor` (+ pure `rgba()`) + semantic token types — **no `import SwiftUI`** | agnostic |
| `Sources/NeotildeKit/Theme/BellBronzeTheme.swift` | The `bellBronze` theme (palette + token mapping) | agnostic |
| `Sources/NeotildeKit/Theme/ThemeEnvironment.swift` | SwiftUI `Color(ThemeColor)` + `EnvironmentValues.theme` — whole file `#if canImport(SwiftUI)` | Apple-only |
| `Sources/NeotildeKit/Model/Inherited.swift` | `Inherited<T>` (absent vs explicit-none vs value) | agnostic |
| `Sources/NeotildeKit/Model/Host.swift` | `Host`, `Defaults`, `JumpHop`, forwards, `HostKey` | agnostic |
| `Sources/NeotildeKit/Model/Identity.swift` | `Identity`, `IdentityRef`, flavor/policy enums | agnostic |
| `Sources/NeotildeKit/Model/Resolution.swift` | Field resolution (host → Defaults → fallback) + cycle check | agnostic |
| `Sources/NeotildeKit/Crypto/RecordEnvelope.swift` | AES-256-GCM seal/open (CryptoKit/swift-crypto shim) | agnostic |
| `Sources/NeotildeSSHCoreFFI/*` | Generated UniFFI Swift wrapper (created by the build script) | Apple-only |
| `Tests/NeotildeKitTests/*` | Theme / Model / RecordEnvelope tests | agnostic |
| `Tests/BridgeTests/*` | `coreVersion()` bridge round-trip | Apple-only |

---

### Task 1: Rust core crate + UniFFI bridge (toolchain proof)

The Rust logic is proven on Linux with `cargo test`; the Swift↔Rust bridge (XCFramework + `BridgeTests`) is the macOS-CI gate.

**Files:**
- Create: `Cargo.toml`, `crates/neotilde-ssh-core/Cargo.toml`, `crates/neotilde-ssh-core/src/lib.rs`, `crates/neotilde-ssh-core/src/bin/uniffi-bindgen.rs`
- Create: `scripts/build-xcframework.sh`
- Create: `Package.swift`
- Test: `Tests/BridgeTests/BridgeTests.swift`

**Interfaces:**
- Produces (Rust): `pub fn core_version() -> String` (returns `"0.1.0"`, the crate version)
- Produces (Swift, generated, Apple-only): `coreVersion() -> String` in module `NeotildeSSHCoreFFI`

- [ ] **Step 1: Scaffold the Cargo workspace + core crate**

`Cargo.toml`:
```toml
[workspace]
members = ["crates/neotilde-ssh-core"]
resolver = "2"
```

`crates/neotilde-ssh-core/Cargo.toml`:
```toml
[package]
name = "neotilde-ssh-core"
version = "0.1.0"
edition = "2021"

[lib]
name = "neotilde_ssh_core"
crate-type = ["staticlib", "lib"]

[dependencies]
uniffi = { version = "0.31", features = ["cli"] }

[[bin]]
name = "uniffi-bindgen"
path = "src/bin/uniffi-bindgen.rs"
```

`crates/neotilde-ssh-core/src/bin/uniffi-bindgen.rs`:
```rust
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
fn main() {
    uniffi::uniffi_bindgen_main()
}
```

- [ ] **Step 2: Write the failing Rust unit test (Linux fast loop)**

In `crates/neotilde-ssh-core/src/lib.rs` (header + scaffolding + the test, no impl yet):
```rust
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
uniffi::setup_scaffolding!();

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn core_version_is_the_crate_version() {
        assert_eq!(core_version(), "0.1.0");
    }
}
```

Run: `cargo test -p neotilde-ssh-core`
Expected: FAIL — `cannot find function 'core_version'`.

- [ ] **Step 3: Implement `core_version` and watch the Rust test pass (Linux)**

Add above the `#[cfg(test)]` module in `lib.rs`:
```rust
/// Returns the version string of the Neotilde SSH core crate.
///
/// Phase 0 uses this purely to prove the Rust→UniFFI→Swift toolchain end to end.
#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}
```

Run: `cargo test -p neotilde-ssh-core`
Expected: PASS. **This is the Linux-verifiable proof of the Rust logic.**

- [ ] **Step 4: Write the host-conditional SwiftPM manifest**

`Package.swift` — `NeotildeKit` (agnostic) always builds; the XCFramework bridge + `BridgeTests` are appended only when the host is macOS, so `swift test` resolves cleanly on Linux:
```swift
// swift-tools-version: 6.0
import PackageDescription

var targets: [Target] = [
    .target(
        name: "NeotildeKit",
        dependencies: [
            // Linux uses swift-crypto's `Crypto`; Apple uses system CryptoKit (no dep).
            .product(name: "Crypto", package: "swift-crypto",
                     condition: .when(platforms: [.linux])),
        ]
    ),
    .testTarget(name: "NeotildeKitTests", dependencies: ["NeotildeKit"]),
]

// The UniFFI XCFramework exists only on Apple platforms; never reference it on Linux.
#if os(macOS)
targets += [
    .target(name: "NeotildeSSHCoreFFI", dependencies: ["NeotildeSSHCore"]),
    .binaryTarget(name: "NeotildeSSHCore", path: "NeotildeSSHCore.xcframework"),
    .testTarget(name: "BridgeTests", dependencies: ["NeotildeSSHCoreFFI"]),
]
#endif

let package = Package(
    name: "Neotilde",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "NeotildeKit", targets: ["NeotildeKit"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: targets
)
```

- [ ] **Step 5: Write the XCFramework build script (macOS)**

`scripts/build-xcframework.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail

LIB_NAME="libneotilde_ssh_core.a"
BUILD_DIR="target/xcframework"
OUT="NeotildeSSHCore.xcframework"

DEVICE="aarch64-apple-ios"
SIM_ARM="aarch64-apple-ios-sim"
SIM_X86="x86_64-apple-ios"

# 1. Compile the staticlib for each iOS triple.
for triple in "$DEVICE" "$SIM_ARM" "$SIM_X86"; do
  cargo build --release -p neotilde-ssh-core --target "$triple"
done

# 2. Lipo the two simulator slices into one fat archive.
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/sim"
lipo -create \
  "target/$SIM_ARM/release/$LIB_NAME" \
  "target/$SIM_X86/release/$LIB_NAME" \
  -output "$BUILD_DIR/sim/$LIB_NAME"

# 3. Generate the Swift bindings + module map from the built library.
mkdir -p "$BUILD_DIR/Headers"
cargo run --release -p neotilde-ssh-core --bin uniffi-bindgen -- generate \
  --library "target/$DEVICE/release/$LIB_NAME" \
  --language swift \
  --out-dir "$BUILD_DIR/Generated"

# UniFFI emits <module>.swift, <module>FFI.h, <module>FFI.modulemap.
cp "$BUILD_DIR"/Generated/*.h "$BUILD_DIR/Headers/"
cp "$BUILD_DIR"/Generated/*.modulemap "$BUILD_DIR/Headers/module.modulemap"

# 4. Assemble the XCFramework (device slice + fat sim slice).
rm -rf "$OUT"
xcodebuild -create-xcframework \
  -library "target/$DEVICE/release/$LIB_NAME" -headers "$BUILD_DIR/Headers" \
  -library "$BUILD_DIR/sim/$LIB_NAME"          -headers "$BUILD_DIR/Headers" \
  -output "$OUT"

# 5. Place the generated Swift wrapper where the SwiftPM target expects it.
mkdir -p Sources/NeotildeSSHCoreFFI
cp "$BUILD_DIR"/Generated/*.swift Sources/NeotildeSSHCoreFFI/
echo "Built $OUT and copied Swift bindings to Sources/NeotildeSSHCoreFFI/"
```

Make it executable: `chmod +x scripts/build-xcframework.sh`

- [ ] **Step 6: Write the bridge test (Apple-only target)**

`Tests/BridgeTests/BridgeTests.swift`:
```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import NeotildeSSHCoreFFI

final class BridgeTests: XCTestCase {
    func testCoreVersionRoundTripsFromRust() {
        // The Rust crate version is the single source of truth; the bridge
        // must surface it verbatim to Swift, proving Rust→UniFFI→Swift works.
        XCTAssertEqual(coreVersion(), "0.1.0")
    }
}
```

- [ ] **Step 7: Build the bridge and run BridgeTests (macOS CI)**

On macOS:
```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
./scripts/build-xcframework.sh
swift test --filter BridgeTests
```
Expected: PASS — `coreVersion()` returns `"0.1.0"`. (On Linux this target does not exist; the Rust test in Step 3 is the Linux-side proof.)

- [ ] **Step 8: Commit**

```bash
git add Cargo.toml crates scripts Package.swift Tests/BridgeTests .gitignore
git commit -m "feat: scaffold Rust core + host-conditional UniFFI bridge with toolchain proof"
```
(Add `target/`, `.build/`, and `NeotildeSSHCore.xcframework` to `.gitignore` — the XCFramework is a CI build artifact, not source.)

---

### Task 2: Design-token layer

Token *values* (`ThemeColor`, `Theme`, `bellBronze`) and the hex→RGBA math are agnostic (Linux-tested). Only the SwiftUI `Color`/environment bridge is Apple-only.

**Files:**
- Create: `Sources/NeotildeKit/Theme/Theme.swift`
- Create: `Sources/NeotildeKit/Theme/BellBronzeTheme.swift`
- Create: `Sources/NeotildeKit/Theme/ThemeEnvironment.swift`
- Test: `Tests/NeotildeKitTests/ThemeTests.swift`

**Interfaces:**
- Produces: `struct ThemeColor: Equatable { let hex: String; let opacity: Double; func alpha(_:) -> ThemeColor; func rgba() -> (red: Double, green: Double, blue: Double, opacity: Double) }`
- Produces: `struct Theme` with groups `surface`, `text`, `accent`, `state`, `bell`, `focus`, `keybar`, `predictor`, `banner`, `terminal`
- Produces: `Theme.bellBronze`, `Theme.all: [Theme]`
- Produces (Apple-only): `EnvironmentValues.theme`, `Color(_:ThemeColor)`

- [ ] **Step 1: Write the failing tests (Linux)**

`Tests/NeotildeKitTests/ThemeTests.swift`:
```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

final class ThemeTests: XCTestCase {
    func testBellBronzeAccentIsBronze500() {
        XCTAssertEqual(Theme.bellBronze.accent.primary, ThemeColor("#D49A5C"))
    }

    func testSharedReferenceIsDriftProof() {
        // bell.edge and accent.primary both map to bronze500 — same value.
        XCTAssertEqual(Theme.bellBronze.bell.edge, Theme.bellBronze.accent.primary)
    }

    func testAlphaProducesOpacityVariant() {
        let promoted = Theme.bellBronze.keybar.slotBgPromoted
        XCTAssertEqual(promoted, ThemeColor("#D49A5C", opacity: 0.12))
    }

    func testRegistryContainsOnlyBellBronzeInV1() {
        XCTAssertEqual(Theme.all.count, 1)
        XCTAssertEqual(Theme.all.first, Theme.bellBronze)
    }

    func testRgbaParsesHexAndOpacity() {
        let c = ThemeColor("#D49A5C", opacity: 0.5).rgba()
        XCTAssertEqual(c.red,   Double(0xD4) / 255, accuracy: 0.0001)
        XCTAssertEqual(c.green, Double(0x9A) / 255, accuracy: 0.0001)
        XCTAssertEqual(c.blue,  Double(0x5C) / 255, accuracy: 0.0001)
        XCTAssertEqual(c.opacity, 0.5, accuracy: 0.0001)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ThemeTests`
Expected: FAIL — `cannot find 'Theme' in scope`.

- [ ] **Step 3: Implement the token types (no SwiftUI import — agnostic)**

`Sources/NeotildeKit/Theme/Theme.swift`:
```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// A resolved color reference: a palette hex plus an opacity multiplier.
/// Tokens hold `ThemeColor` values so equality is testable without rendering.
/// This type is platform-agnostic — no SwiftUI here (see ThemeEnvironment.swift).
public struct ThemeColor: Equatable, Sendable {
    public let hex: String
    public let opacity: Double

    public init(_ hex: String, opacity: Double = 1.0) {
        self.hex = hex
        self.opacity = opacity
    }

    /// Returns a copy of this color at the given opacity (0...1).
    public func alpha(_ opacity: Double) -> ThemeColor {
        ThemeColor(hex, opacity: opacity)
    }

    /// Parses the `#RRGGBB` hex into normalized components plus the opacity.
    /// Pure math — unit-tested on Linux; the SwiftUI `Color` bridge consumes it.
    public func rgba() -> (red: Double, green: Double, blue: Double, opacity: Double) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let v = UInt64(s, radix: 16) ?? 0
        return (Double((v >> 16) & 0xFF) / 255,
                Double((v >> 8) & 0xFF) / 255,
                Double(v & 0xFF) / 255,
                opacity)
    }
}

/// The full semantic-token set for one theme. UI references these tokens only —
/// never palette constants or raw hex. Adding tokens is additive; never inline.
public struct Theme: Equatable, Sendable {
    public struct Surface: Equatable, Sendable {
        public let bg, panel, panelHigh, line: ThemeColor
    }
    public struct Text: Equatable, Sendable {
        public let primary, secondary, muted, inverse: ThemeColor
    }
    public struct Accent: Equatable, Sendable {
        public let primary, highlight: ThemeColor
    }
    public struct State: Equatable, Sendable {
        public let success, degraded, broken, warning: ThemeColor
    }
    public struct Bell: Equatable, Sendable {
        public let edge: ThemeColor
    }
    public struct Focus: Equatable, Sendable {
        public let paneBorder, paneBorderInactive: ThemeColor
    }
    public struct Keybar: Equatable, Sendable {
        public let slotBg, slotBgPromoted, slotBgArmed, slotBgLocked: ThemeColor
    }
    public struct Predictor: Equatable, Sendable {
        public let stripBg, suggestionBg, suggestionText: ThemeColor
    }
    public struct Banner: Equatable, Sendable {
        public let amberBg, redBg, neutralBg: ThemeColor
    }
    public struct Terminal: Equatable, Sendable {
        public let bg, fg: ThemeColor
    }

    public let surface: Surface
    public let text: Text
    public let accent: Accent
    public let state: State
    public let bell: Bell
    public let focus: Focus
    public let keybar: Keybar
    public let predictor: Predictor
    public let banner: Banner
    public let terminal: Terminal
}
```

- [ ] **Step 4: Implement the Bell Bronze theme**

`Sources/NeotildeKit/Theme/BellBronzeTheme.swift`:
```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

// Palette constants are file-private: only the semantic `Theme` is exported.
// Values verbatim from docs/superpowers/specs/2026-06-17-design-tokens-design.md.
private let bronze500       = ThemeColor("#D49A5C")
private let bronze300       = ThemeColor("#F2C58A")
private let coolDarkAnchor  = ThemeColor("#0E1116")
private let coolDarkPanel   = ThemeColor("#161A22")
private let coolDarkPanelHi = ThemeColor("#1F2530")
private let coolDarkLine    = ThemeColor("#2A323F")
private let patina500       = ThemeColor("#5FA89C")
private let amber500        = ThemeColor("#F5A524")
private let red500          = ThemeColor("#E06B6B")
private let textPrimary     = ThemeColor("#E8EBF0")
private let textMuted       = ThemeColor("#8A93A3")

extension Theme {
    public static let bellBronze = Theme(
        surface: .init(bg: coolDarkAnchor, panel: coolDarkPanel,
                       panelHigh: coolDarkPanelHi, line: coolDarkLine),
        text: .init(primary: textPrimary, secondary: textMuted,
                    muted: textMuted, inverse: coolDarkAnchor),
        accent: .init(primary: bronze500, highlight: bronze300),
        state: .init(success: patina500, degraded: amber500,
                     broken: red500, warning: amber500),
        bell: .init(edge: bronze500),
        focus: .init(paneBorder: bronze500, paneBorderInactive: coolDarkLine),
        keybar: .init(slotBg: coolDarkPanel,
                      slotBgPromoted: bronze500.alpha(0.12),
                      slotBgArmed: bronze500.alpha(0.20),
                      slotBgLocked: bronze500.alpha(0.30)),
        predictor: .init(stripBg: coolDarkPanel, suggestionBg: coolDarkPanelHi,
                         suggestionText: textPrimary),
        banner: .init(amberBg: amber500.alpha(0.15), redBg: red500.alpha(0.15),
                      neutralBg: coolDarkPanel),
        terminal: .init(bg: ThemeColor("#0A0C10"), fg: ThemeColor("#CFD6E4"))
    )

    /// The v1 theme registry. Picker UI stays hidden while this has one entry.
    public static let all: [Theme] = [.bellBronze]
}
```

- [ ] **Step 5: Run the agnostic tests to verify they pass (Linux)**

Run: `swift test --filter ThemeTests`
Expected: PASS (all five cases). The token layer is fully Linux-verified.

- [ ] **Step 6: Implement the SwiftUI bridge (Apple-only; compiled on macOS CI)**

`Sources/NeotildeKit/Theme/ThemeEnvironment.swift` — the whole file is guarded so Linux skips it:
```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
#if canImport(SwiftUI)
import SwiftUI

private struct ThemeKey: EnvironmentKey {
    static let defaultValue: Theme = .bellBronze
}

extension EnvironmentValues {
    /// The active theme; changing it propagates through the view tree.
    public var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

extension Color {
    /// Builds a SwiftUI `Color` from a `ThemeColor` (hex + opacity), reusing the
    /// agnostic `rgba()` parser so the math is identical to what's unit-tested.
    public init(_ themeColor: ThemeColor) {
        let c = themeColor.rgba()
        self = Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.opacity)
    }
}
#endif
```
(No Linux test asserts on `Color`; its compile is verified by the macOS CI job. The color math it depends on is covered by `testRgbaParsesHexAndOpacity` on Linux.)

- [ ] **Step 7: Commit**

```bash
git add Sources/NeotildeKit/Theme Tests/NeotildeKitTests/ThemeTests.swift
git commit -m "feat: add semantic design-token layer with Bell Bronze theme"
```

---

### Task 3: Core data model + resolution

Fully agnostic — pure Foundation `Codable`. Linux-tested.

**Files:**
- Create: `Sources/NeotildeKit/Model/Inherited.swift`
- Create: `Sources/NeotildeKit/Model/Identity.swift`
- Create: `Sources/NeotildeKit/Model/Host.swift`
- Create: `Sources/NeotildeKit/Model/Resolution.swift`
- Test: `Tests/NeotildeKitTests/ModelTests.swift`

**Interfaces:**
- Produces: `enum Inherited<T: Equatable & Codable>: Equatable, Codable { case inherit; case explicit(T?) }`
- Produces: `struct Host: Codable, Equatable` (id, label, hostName + inherited optional fields)
- Produces: `struct Defaults: Codable, Equatable`
- Produces: `enum JumpHop`, `struct LocalForward/RemoteForward/DynamicForward`, `struct HostKey`
- Produces: `struct Identity: Codable, Equatable`, `typealias IdentityRef = UUID`, `enum IdentityFlavor`, `enum BiometricPolicy`
- Produces: `func resolvePort(host:defaults:) -> Int`, `func hasCycle(savingHostId:chain:in:) -> Bool`

- [ ] **Step 1: Write the failing tests (Linux)**

`Tests/NeotildeKitTests/ModelTests.swift`:
```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

final class ModelTests: XCTestCase {
    func testHostRoundTripsThroughCodable() throws {
        let id = UUID()
        let host = Host(id: id, label: "prod-db", hostName: "db.internal",
                        port: .explicit(2222))
        let data = try JSONEncoder().encode(host)
        let decoded = try JSONDecoder().decode(Host.self, from: data)
        XCTAssertEqual(decoded, host)
    }

    func testInheritFallsBackThroughDefaultsToBuiltIn() {
        // port: host inherits → Defaults inherits → built-in fallback 22.
        let host = Host(id: UUID(), label: "h", hostName: "x", port: .inherit)
        XCTAssertEqual(resolvePort(host: host, defaults: Defaults()), 22)
    }

    func testDefaultsValueWinsOverBuiltIn() {
        let host = Host(id: UUID(), label: "h", hostName: "x", port: .inherit)
        let defaults = Defaults(port: .explicit(2200))
        XCTAssertEqual(resolvePort(host: host, defaults: defaults), 2200)
    }

    func testHostValueWinsOverDefaults() {
        let host = Host(id: UUID(), label: "h", hostName: "x", port: .explicit(22))
        let defaults = Defaults(port: .explicit(2200))
        XCTAssertEqual(resolvePort(host: host, defaults: defaults), 22)
    }

    func testCycleDetectionRefusesSelfReferentialJump() {
        let a = UUID()
        let host = Host(id: a, label: "a", hostName: "x",
                        proxyJump: .explicit([.ref(hostId: a)]))
        XCTAssertTrue(hasCycle(savingHostId: a, chain: host.resolvedJumpChain,
                               in: [a: host]))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ModelTests`
Expected: FAIL — `cannot find 'Host' in scope`.

- [ ] **Step 3: Implement `Inherited<T>`**

`Sources/NeotildeKit/Model/Inherited.swift`:
```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Distinguishes three states the schema requires from day one:
/// `.inherit` (field absent → inherit from Defaults, then built-in),
/// `.explicit(value)` (set), and `.explicit(nil)` (explicitly cleared to "none").
/// Baked in now so per-group/pattern defaults never need a migration.
public enum Inherited<T: Equatable & Codable>: Equatable, Codable {
    case inherit
    case explicit(T?)

    /// The set value if explicitly set to a non-nil value, else nil.
    public var value: T? {
        if case let .explicit(v) = self { return v }
        return nil
    }
}
```

- [ ] **Step 4: Implement identities + supporting types**

`Sources/NeotildeKit/Model/Identity.swift`:
```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public typealias IdentityRef = UUID

public enum IdentityFlavor: String, Codable, Equatable, Sendable {
    case iCloudKeychain
    case secureEnclave
}

public enum KeyAlgorithm: String, Codable, Equatable, Sendable {
    case ed25519, ecdsaP256 = "ecdsa-p256", ecdsaP384 = "ecdsa-p384", rsa
}

public enum BiometricPolicy: String, Codable, Equatable, Sendable {
    case never, anyUse, afterUnlock
}

public struct Identity: Codable, Equatable, Sendable {
    public let id: UUID
    public var displayName: String
    public var flavor: IdentityFlavor
    public var algorithm: KeyAlgorithm
    public var publicKey: String
    public var fingerprint: String          // SHA256:base64
    public var createdAt: Date
    public var biometricPolicy: BiometricPolicy

    public init(id: UUID, displayName: String, flavor: IdentityFlavor,
                algorithm: KeyAlgorithm, publicKey: String, fingerprint: String,
                createdAt: Date, biometricPolicy: BiometricPolicy) {
        self.id = id; self.displayName = displayName; self.flavor = flavor
        self.algorithm = algorithm; self.publicKey = publicKey
        self.fingerprint = fingerprint; self.createdAt = createdAt
        self.biometricPolicy = biometricPolicy
    }
}
```

- [ ] **Step 5: Implement the host model + supporting records**

`Sources/NeotildeKit/Model/Host.swift`:
```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public enum JumpHop: Codable, Equatable, Sendable {
    case ref(hostId: UUID)
    case inline(hostName: String, port: Int?, user: String?, identities: [IdentityRef]?)
}

public struct LocalForward: Codable, Equatable, Sendable {
    public var bindAddress: String?; public var bindPort: Int
    public var hostAddress: String; public var hostPort: Int
}
public struct RemoteForward: Codable, Equatable, Sendable {
    public var bindAddress: String?; public var bindPort: Int
    public var hostAddress: String; public var hostPort: Int
}
public struct DynamicForward: Codable, Equatable, Sendable {
    public var bindAddress: String?; public var bindPort: Int
}

public enum HostKeySource: String, Codable, Equatable, Sendable {
    case manual, trustOnFirstUse = "trust-on-first-use", imported
}
public struct HostKey: Codable, Equatable, Sendable {
    public var algorithm: String; public var fingerprint: String
    public var addedAt: Date; public var source: HostKeySource
}

public enum StrictHostKeyChecking: String, Codable, Equatable, Sendable {
    case yes, acceptNew = "accept-new", ask, no
}

/// A Neotilde host record. Required fields are non-optional; every OpenSSH-derived
/// optional uses `Inherited<T>` so "inherit" vs "explicitly none" never collide.
public struct Host: Codable, Equatable, Sendable {
    // Required
    public let id: UUID
    public var label: String
    public var hostName: String

    // OpenSSH Tier 1 (subset modeled in Phase 0; remaining fields follow the
    // identical Inherited<T> pattern and are added as later phases consume them).
    public var user: Inherited<String>
    public var port: Inherited<Int>
    public var identities: Inherited<[IdentityRef]>
    public var proxyJump: Inherited<[JumpHop]>

    public init(id: UUID, label: String, hostName: String,
                user: Inherited<String> = .inherit,
                port: Inherited<Int> = .inherit,
                identities: Inherited<[IdentityRef]> = .inherit,
                proxyJump: Inherited<[JumpHop]> = .inherit) {
        self.id = id; self.label = label; self.hostName = hostName
        self.user = user; self.port = port
        self.identities = identities; self.proxyJump = proxyJump
    }

    /// The resolved jump chain (empty when inherited/unset for cycle-checking).
    public var resolvedJumpChain: [JumpHop] { proxyJump.value ?? [] }
}

/// Singleton defaults record: same optional fields as Host, no required ones.
public struct Defaults: Codable, Equatable, Sendable {
    public var user: Inherited<String>
    public var port: Inherited<Int>
    public init(user: Inherited<String> = .inherit,
                port: Inherited<Int> = .inherit) {
        self.user = user; self.port = port
    }
}
```

- [ ] **Step 6: Implement resolution + cycle detection**

`Sources/NeotildeKit/Model/Resolution.swift`:
```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Built-in fallback for `port` per host-config-model resolution table.
private let builtInPort = 22

/// Resolves `port`: per-host value → Defaults value → built-in fallback (22).
/// Verbatim resolution order from the host-config-model spec.
public func resolvePort(host: Host, defaults: Defaults) -> Int {
    if let v = host.port.value { return v }
    if let v = defaults.port.value { return v }
    return builtInPort
}

/// Returns true if saving `savingHostId` with `chain` would loop back through a
/// host already reachable in the chain. Walks `ref` hops via `hosts`.
public func hasCycle(savingHostId: UUID, chain: [JumpHop],
                     in hosts: [UUID: Host]) -> Bool {
    var seen: Set<UUID> = [savingHostId]
    var frontier = chain
    while let hop = frontier.first {
        frontier.removeFirst()
        guard case let .ref(hostId) = hop else { continue }
        if !seen.insert(hostId).inserted { return true }
        if let next = hosts[hostId] { frontier.append(contentsOf: next.resolvedJumpChain) }
    }
    return false
}
```

- [ ] **Step 7: Run the tests to verify they pass (Linux)**

Run: `swift test --filter ModelTests`
Expected: PASS (all five cases).

- [ ] **Step 8: Commit**

```bash
git add Sources/NeotildeKit/Model Tests/NeotildeKitTests/ModelTests.swift
git commit -m "feat: add core host/identity data model with inheritance resolution"
```

---

### Task 4: AES-256-GCM record envelope

Agnostic via the swift-crypto shim — Linux-tested. `AES.GCM`/`SymmetricKey` are API-identical between CryptoKit and swift-crypto, so the same code runs both places.

**Files:**
- Create: `Sources/NeotildeKit/Crypto/RecordEnvelope.swift`
- Test: `Tests/NeotildeKitTests/RecordEnvelopeTests.swift`

**Interfaces:**
- Consumes: `Host`/`Defaults` (any `Codable & Equatable`) from Task 3
- Produces: `enum RecordEnvelope { static func seal<T: Encodable>(_:key:) throws -> Data; static func open<T: Decodable>(_:as:key:) throws -> T }`
- Produces: `enum RecordEnvelopeError: Error { case decryptionFailed }`

- [ ] **Step 1: Write the failing tests (Linux)**

`Tests/NeotildeKitTests/RecordEnvelopeTests.swift`:
```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import NeotildeKit

final class RecordEnvelopeTests: XCTestCase {
    private let key = SymmetricKey(size: .bits256)

    func testSealThenOpenRoundTripsRecord() throws {
        let host = Host(id: UUID(), label: "prod", hostName: "db.internal",
                        port: .explicit(2222))
        let sealed = try RecordEnvelope.seal(host, key: key)
        let opened: Host = try RecordEnvelope.open(sealed, as: Host.self, key: key)
        XCTAssertEqual(opened, host)
    }

    func testCiphertextDiffersFromPlaintext() throws {
        let host = Host(id: UUID(), label: "prod", hostName: "db.internal")
        let sealed = try RecordEnvelope.seal(host, key: key)
        let plain = try JSONEncoder().encode(host)
        XCTAssertNotEqual(sealed, plain)
    }

    func testWrongKeyFailsToOpen() throws {
        let host = Host(id: UUID(), label: "prod", hostName: "db.internal")
        let sealed = try RecordEnvelope.seal(host, key: key)
        XCTAssertThrowsError(
            try RecordEnvelope.open(sealed, as: Host.self,
                                    key: SymmetricKey(size: .bits256))
        )
    }

    func testTamperedCiphertextFailsToOpen() throws {
        let host = Host(id: UUID(), label: "prod", hostName: "db.internal")
        var sealed = try RecordEnvelope.seal(host, key: key)
        sealed[sealed.count - 1] ^= 0xFF   // flip a bit in the GCM tag region
        XCTAssertThrowsError(
            try RecordEnvelope.open(sealed, as: Host.self, key: key)
        )
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter RecordEnvelopeTests`
Expected: FAIL — `cannot find 'RecordEnvelope' in scope`.

- [ ] **Step 3: Implement the envelope (CryptoKit/swift-crypto shim)**

`Sources/NeotildeKit/Crypto/RecordEnvelope.swift`:
```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto   // Apple's swift-crypto — API-compatible on Linux
#endif

public enum RecordEnvelopeError: Error, Equatable {
    case decryptionFailed
}

/// Client-side AES-256-GCM seal/open for records written to CloudKit, so Apple
/// sees only ciphertext. The 32-byte key lives in iCloud Keychain (Phase 2).
public enum RecordEnvelope {
    /// JSON-encodes then seals `value` with AES-GCM, returning the combined
    /// nonce+ciphertext+tag blob.
    public static func seal<T: Encodable>(_ value: T, key: SymmetricKey) throws -> Data {
        let plaintext = try JSONEncoder().encode(value)
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let combined = box.combined else { throw RecordEnvelopeError.decryptionFailed }
        return combined
    }

    /// Opens a blob produced by `seal` and decodes it as `T`. Throws if the key
    /// is wrong or the ciphertext was tampered with (GCM tag mismatch).
    public static func open<T: Decodable>(_ blob: Data, as type: T.Type,
                                          key: SymmetricKey) throws -> T {
        let box = try AES.GCM.SealedBox(combined: blob)
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(box, using: key)
        } catch {
            throw RecordEnvelopeError.decryptionFailed
        }
        return try JSONDecoder().decode(T.self, from: plaintext)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass (Linux)**

Run: `swift test --filter RecordEnvelopeTests`
Expected: PASS (all four cases) — using swift-crypto on Linux.

- [ ] **Step 5: Commit**

```bash
git add Sources/NeotildeKit/Crypto Tests/NeotildeKitTests/RecordEnvelopeTests.swift
git commit -m "feat: add AES-256-GCM record envelope for at-rest CloudKit records"
```

---

## Phase 0 exit criteria

**Linux fast loop (every task's logic):**
- [ ] `cargo test` green (Task 1 Rust core).
- [ ] `swift test` green across `ThemeTests`, `ModelTests`, `RecordEnvelopeTests` (using swift-crypto).

**macOS CI gate (Apple-only surface):**
- [ ] `./scripts/build-xcframework.sh` produces `NeotildeSSHCore.xcframework`.
- [ ] `swift test` green including `BridgeTests` (`coreVersion()` round-trips Rust→Swift).
- [ ] `NeotildeKit` compiles for iOS (the `#if canImport(SwiftUI)` `ThemeEnvironment` bridge builds).

**Both:**
- [ ] Four conventional commits, one per task.
- [ ] No hex literals outside `BellBronzeTheme.swift`'s palette block.
- [ ] Every source file carries the REUSE header.

## Self-review notes

- **Platform split rationale:** Neotilde ships only via macOS-built iOS binaries, but most of Phase 0 is platform-agnostic logic. Putting it behind `#if canImport` shims (crypto) and keeping SwiftUI out of the value types lets the Linux dev box run a real red→green TDD loop for Tasks 1 (Rust), 3, 4, and the token values of 2 — only the XCFramework bridge and the SwiftUI `Color`/environment wait for macOS CI. The host-conditional `Package.swift` is what lets `swift test` resolve on Linux without the iOS-only XCFramework.
- **Spec coverage:** `design-tokens` (Task 2 — full token registry + theme + the `Color` bridge); `host-config-model` schema (Task 3 — entities, `Inherited<T>` semantics, resolution table for `port`, cycle prevention) and its AES storage primitive (Task 4). Remaining host fields (Tier 2, mosh/tailscale/neotilde extensions, full fallback table) are deferred to Phase 2, where the storage/CRUD layer consumes them — they follow the identical `Inherited<T>` pattern established here.
- **Bridge scope:** Phase 0 proves only `coreVersion()`. All SSH surface (connect/auth/channels/forwards) is Phase 1, by design — Task 1 exists to de-risk the toolchain, not the protocol.
</content>
