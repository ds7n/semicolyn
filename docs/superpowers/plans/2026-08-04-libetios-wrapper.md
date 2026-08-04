<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# libetios Wrapper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the already-linked `ETerminal.xcframework` drivable from Swift via a thin `ETSession` bridge plus three pure Linux-tested decision helpers, so a future bootstrap slice can open a real ET connection.

**Architecture:** Two-queue split. A private serial `DispatchQueue` inside an Obj-C++ `ETSession` owns the C-ABI ordering (`et_send`/`et_set_window_size`/`et_close` never race, guarded by an `isClosed` flag); callbacks arriving on ET's transport thread copy their buffer in-callback and hop to the main queue before firing Swift closures (the `App/Mosh/MoshSession.mm` shape). All wrong-able logic lives in three pure `Sources/SemicolynKit/ET/` deciders under Linux XCTest; the `.mm` is thin marshalling glue that only macOS CI compiles.

**Tech Stack:** Swift 6 (SemicolynKit, strict-concurrency, no UIKit/CryptoKit), Obj-C++ (`ETSession.mm`, gnu++17), the `eternaltermlib` C ABI (`extern/eternaltermlib/include/eternaltermlib.h`), XCTest, xcodegen.

## Global Constraints

- **Every source file carries an SPDX header:** `// SPDX-FileCopyrightText: 2026 True Positive LLC` then `// SPDX-License-Identifier: GPL-3.0-only` (Swift/Obj-C), or the `<!-- -->` form for Markdown. The repo is REUSE-compliant.
- **No em-dash (U+2014) / en-dash (U+2013) anywhere** in any generated output (code, comments, docs, commit messages). Use a colon, comma, parentheses, semicolon, or two sentences.
- **`Sources/SemicolynKit/` is Linux-tested, Swift 6 strict-concurrency, `Sendable`:** no `import UIKit`/`SwiftUI`/`CryptoKit`. Pure logic only. This is where the three deciders live.
- **`App/` + `ETSession.mm` are Apple-only, macOS-CI-verified.** They do NOT compile on Linux and are invisible to `swift test`. Validate via CI, not locally.
- **Tests must be real** (`docs/superpowers/specs/2026-06-18-testing-standards-design.md`): EP + BVA, assert observable values (no tautologies), every negative test asserts the *specific* failure (exact error case / exact output string).
- **Conventional commits** (`feat:`/`fix:`/`test:`/`docs:`/`build:`); commit after each green step. End every commit message with `Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt`.
- **Build/test entrypoints:** Kit tests run as `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter <TestClass>` (there is NO Swift toolchain on the host). Apple-tier compile/tests run only on macOS CI.
- **Spec:** `docs/superpowers/specs/2026-08-04-libetios-wrapper-design.md`. Read it before starting.
- **Precedent to mirror throughout:** `App/Mosh/MoshSession.{h,mm}`, `App/Mosh/Semicolyn-Bridging-Header.h`, `Tests/AppTests/{MoshSessionTests,fake_mosh_main}.mm`, `Sources/SemicolynKit/Mosh/*.swift`, and the `SemicolynBridgeTests` block + `schemes:` in `project.yml`.

---

## File Structure

**Pure Kit (Linux-tested), created:**
- `Sources/SemicolynKit/ET/ETConfig.swift`, `ETConfig` value type, `ETConfigError`, `validateETConfig`, `etEnvArrays`.
- `Sources/SemicolynKit/ET/ETEndReason.swift`, `sanitizeEndReason`.
- `Sources/SemicolynKit/ET/ETConnectionState.swift`, `ETConnectionState` enum, `mapETState`.
- `Tests/SemicolynKitTests/ETConfigTests.swift`
- `Tests/SemicolynKitTests/ETEndReasonTests.swift`
- `Tests/SemicolynKitTests/ETConnectionStateTests.swift`

**Apple tier (macOS-CI-only), created:**
- `App/ET/ETSession.h`, the Obj-C interface (init-with-config, start/send/setWindowSize/close, the four closures).
- `App/ET/ETSession.mm`, the Obj-C++ implementation over the `et_*` C ABI.
- `Tests/AppTests/ETSessionTests.mm`, bridge test driving `ETSession` against a fake `et_client`.
- `Tests/AppTests/fake_et_client.mm`, a loopback fake of `et_connect`/`et_send`/`et_set_window_size`/`et_close` (the ONLY definition linked into the bridge-test target).

**Apple tier, modified:**
- `App/Mosh/Semicolyn-Bridging-Header.h`, add `#import "ETSession.h"` so Swift sees `ETSession`.
- `project.yml`, extend the `SemicolynBridgeTests` target to also compile `App/ET/ETSession.mm`, and add the ET header search path.

**Note on the App target:** the `App` xcodegen target already includes all of `App/` by directory (`sources: - path: App`), so `App/ET/*.mm` is picked up automatically for the app build; no `project.yml` change is needed for the app target itself, only for the standalone bridge-test target.

---

### Task 1: `ETConfig` value type + validator

**Files:**
- Create: `Sources/SemicolynKit/ET/ETConfig.swift`
- Test: `Tests/SemicolynKitTests/ETConfigTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public struct ETConfig: Sendable, Equatable` with public members `host: String`, `port: UInt16`, `id: String`, `passkey: String`, `env: [String: String]`, `cols: UInt16`, `rows: UInt16`, `width: UInt16`, `height: UInt16`, `keepaliveSecs: Int32`, and a public memberwise-style `init`.
  - `public enum ETConfigError: Error, Equatable { case emptyHost, emptyID, emptyPasskey, missingTERM }`
  - `public func validateETConfig(_ cfg: ETConfig) throws -> ETConfig`

- [ ] **Step 1: Write the failing test**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ETConfigTests: XCTestCase {
    private func valid() -> ETConfig {
        ETConfig(host: "h.example", port: 0, id: "0123456789abcdef",
                 passkey: "0123456789abcdef0123456789abcdef",
                 env: ["TERM": "xterm-256color"], cols: 80, rows: 24,
                 width: 0, height: 0, keepaliveSecs: 0)
    }

    func testValidConfigPassesThroughUnchanged() throws {
        let cfg = valid()
        XCTAssertEqual(try validateETConfig(cfg), cfg)
    }

    func testEmptyHostThrowsEmptyHost() {
        var cfg = valid(); cfg.host = ""
        XCTAssertThrowsError(try validateETConfig(cfg)) {
            XCTAssertEqual($0 as? ETConfigError, .emptyHost)
        }
    }

    func testEmptyIDThrowsEmptyID() {
        var cfg = valid(); cfg.id = ""
        XCTAssertThrowsError(try validateETConfig(cfg)) {
            XCTAssertEqual($0 as? ETConfigError, .emptyID)
        }
    }

    func testEmptyPasskeyThrowsEmptyPasskey() {
        var cfg = valid(); cfg.passkey = ""
        XCTAssertThrowsError(try validateETConfig(cfg)) {
            XCTAssertEqual($0 as? ETConfigError, .emptyPasskey)
        }
    }

    func testMissingTERMThrowsMissingTERM() {
        var cfg = valid(); cfg.env = [:]
        XCTAssertThrowsError(try validateETConfig(cfg)) {
            XCTAssertEqual($0 as? ETConfigError, .missingTERM)
        }
    }

    func testEmptyTERMValueIsTreatedAsMissing() {
        var cfg = valid(); cfg.env = ["TERM": ""]
        XCTAssertThrowsError(try validateETConfig(cfg)) {
            XCTAssertEqual($0 as? ETConfigError, .missingTERM)
        }
    }

    // Port 0 is a valid input (the C ABI maps 0 -> default 2022); do not reject it.
    func testPortZeroIsAccepted() throws {
        XCTAssertEqual(try validateETConfig(valid()).port, 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ETConfigTests`
Expected: FAIL to compile / "cannot find 'ETConfig' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Connection parameters for one ET session, mirroring the C ABI's `et_config`
/// (`extern/eternaltermlib/include/eternaltermlib.h`). A pure value type so the
/// bootstrap slice can build + validate it on any platform before the Obj-C++
/// `ETSession` marshals it into the flat C struct.
public struct ETConfig: Sendable, Equatable {
    public var host: String
    /// 0 is kept as 0; the C ABI maps 0 to ET's default port 2022.
    public var port: UInt16
    public var id: String
    public var passkey: String
    /// Must contain a non-empty TERM (validated).
    public var env: [String: String]
    public var cols: UInt16
    public var rows: UInt16
    /// Pixel size; 0 means unknown.
    public var width: UInt16
    public var height: UInt16
    /// 0 means ET's default keepalive (5s).
    public var keepaliveSecs: Int32

    public init(host: String, port: UInt16, id: String, passkey: String,
                env: [String: String], cols: UInt16, rows: UInt16,
                width: UInt16, height: UInt16, keepaliveSecs: Int32) {
        self.host = host; self.port = port; self.id = id; self.passkey = passkey
        self.env = env; self.cols = cols; self.rows = rows
        self.width = width; self.height = height; self.keepaliveSecs = keepaliveSecs
    }
}

/// Specific, typed validation failures raised at the config boundary.
public enum ETConfigError: Error, Equatable {
    case emptyHost, emptyID, emptyPasskey, missingTERM
}

/// Validate a config before it reaches the C ABI. Raises the SPECIFIC typed
/// error for invalid input (an API-boundary guard, not a null-return miss).
public func validateETConfig(_ cfg: ETConfig) throws -> ETConfig {
    if cfg.host.isEmpty { throw ETConfigError.emptyHost }
    if cfg.id.isEmpty { throw ETConfigError.emptyID }
    if cfg.passkey.isEmpty { throw ETConfigError.emptyPasskey }
    guard let term = cfg.env["TERM"], !term.isEmpty else { throw ETConfigError.missingTERM }
    return cfg
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ETConfigTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/ET/ETConfig.swift Tests/SemicolynKitTests/ETConfigTests.swift
git commit -m "feat(et): ETConfig value type + boundary validator

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
```

---

### Task 2: `etEnvArrays` env marshalling

**Files:**
- Modify: `Sources/SemicolynKit/ET/ETConfig.swift` (append the function)
- Test: `Tests/SemicolynKitTests/ETConfigTests.swift` (append tests)

**Interfaces:**
- Consumes: `ETConfig` (Task 1).
- Produces: `public func etEnvArrays(_ env: [String: String]) -> (keys: [String], vals: [String])`, deterministic sorted-by-key parallel arrays, index-aligned, suitable for the C ABI's `env_keys`/`env_vals`.

- [ ] **Step 1: Write the failing test**

```swift
// Append inside ETConfigTests.

func testEnvArraysEmpty() {
    let (keys, vals) = etEnvArrays([:])
    XCTAssertEqual(keys, [])
    XCTAssertEqual(vals, [])
}

func testEnvArraysSingle() {
    let (keys, vals) = etEnvArrays(["TERM": "xterm-256color"])
    XCTAssertEqual(keys, ["TERM"])
    XCTAssertEqual(vals, ["xterm-256color"])
}

// Deterministic sorted-by-key order, and keys[i] pairs with vals[i].
func testEnvArraysMultiIsSortedAndIndexAligned() {
    let (keys, vals) = etEnvArrays(["TERM": "xterm", "LANG": "en_US.UTF-8", "COLORTERM": "truecolor"])
    XCTAssertEqual(keys, ["COLORTERM", "LANG", "TERM"])
    XCTAssertEqual(vals, ["truecolor", "en_US.UTF-8", "xterm"])
    for (i, k) in keys.enumerated() {
        XCTAssertEqual(vals[i], ["COLORTERM": "truecolor", "LANG": "en_US.UTF-8", "TERM": "xterm"][k])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ETConfigTests`
Expected: FAIL to compile / "cannot find 'etEnvArrays' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
// Append to Sources/SemicolynKit/ET/ETConfig.swift.

/// Flatten an env map into the two parallel arrays the C ABI wants
/// (`env_keys`/`env_vals`). Sorted by key so the output is deterministic
/// (stable tests, stable handshake payload); `keys[i]` pairs with `vals[i]`.
public func etEnvArrays(_ env: [String: String]) -> (keys: [String], vals: [String]) {
    let sorted = env.sorted { $0.key < $1.key }
    return (sorted.map(\.key), sorted.map(\.value))
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ETConfigTests`
Expected: PASS (10 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/ET/ETConfig.swift Tests/SemicolynKitTests/ETConfigTests.swift
git commit -m "feat(et): etEnvArrays deterministic parallel-array marshalling

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
```

---

### Task 3: `sanitizeEndReason` (untrusted-input security seam)

**Files:**
- Create: `Sources/SemicolynKit/ET/ETEndReason.swift`
- Test: `Tests/SemicolynKitTests/ETEndReasonTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `public func sanitizeEndReason(_ reason: String?) -> String`, `nil` becomes `"connection ended"`; strips C0/C1 control bytes and ANSI CSI/OSC escape sequences and angle-bracket markup; collapses to a single line; truncates to `etEndReasonMaxLength` (80) scalars. Also `public let etEndReasonMaxLength = 80`.

This is Critical tier (the reason may be remote-server-supplied). Assert the exact output for every case.

- [ ] **Step 1: Write the failing test**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ETEndReasonTests: XCTestCase {
    func testNilBecomesDefault() {
        XCTAssertEqual(sanitizeEndReason(nil), "connection ended")
    }

    func testEmptyBecomesDefault() {
        XCTAssertEqual(sanitizeEndReason(""), "connection ended")
    }

    func testCleanStringPassesThrough() {
        XCTAssertEqual(sanitizeEndReason("handshake rejected"), "handshake rejected")
    }

    // ANSI CSI colour sequence is stripped, surrounding text kept.
    func testCSISequenceStripped() {
        XCTAssertEqual(sanitizeEndReason("\u{1B}[31mdenied\u{1B}[0m"), "denied")
    }

    // OSC sequence (ESC ] ... BEL) is stripped whole.
    func testOSCSequenceStripped() {
        XCTAssertEqual(sanitizeEndReason("\u{1B}]0;evil\u{07}bye"), "bye")
    }

    // Carriage-return overwrite / control bytes removed (no line-overwrite attack).
    func testControlBytesStripped() {
        XCTAssertEqual(sanitizeEndReason("real\rFAKE\u{00}\u{07}"), "realFAKE")
    }

    // Newlines collapse to a single space so the reason stays one log line.
    func testNewlinesCollapsedToSpace() {
        XCTAssertEqual(sanitizeEndReason("line1\nline2"), "line1 line2")
    }

    // Angle-bracket markup stripped (no HTML/markup injection into a banner).
    func testMarkupStripped() {
        XCTAssertEqual(sanitizeEndReason("bye <b>bold</b>"), "bye bold")
    }

    // Over-long input truncated to exactly the max scalar count.
    func testOverLongTruncatedToExactMax() {
        let long = String(repeating: "a", count: 200)
        let out = sanitizeEndReason(long)
        XCTAssertEqual(out.unicodeScalars.count, etEndReasonMaxLength)
        XCTAssertEqual(out, String(repeating: "a", count: etEndReasonMaxLength))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ETEndReasonTests`
Expected: FAIL to compile / "cannot find 'sanitizeEndReason' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Max scalar length of a sanitized end-reason string.
public let etEndReasonMaxLength = 80

/// Sanitize an ET teardown reason for safe logging / banner display.
///
/// SECURITY: the raw reason may be remote-server-supplied (a handshake-rejection
/// message), so it is UNTRUSTED. This strips ANSI escape sequences (CSI + OSC),
/// C0/C1 control bytes, and angle-bracket markup; collapses whitespace to single
/// spaces so it stays one log line; and truncates to `etEndReasonMaxLength`.
/// `nil`/empty become a fixed default. Callers must route every reason through
/// this before it reaches a log or a UI banner.
public func sanitizeEndReason(_ reason: String?) -> String {
    guard let reason, !reason.isEmpty else { return "connection ended" }

    var out = String.UnicodeScalarView()
    var scalars = Array(reason.unicodeScalars)
    var i = 0
    while i < scalars.count {
        let s = scalars[i]
        // ESC-introduced sequences: CSI (ESC [ ... final 0x40-0x7E) or
        // OSC (ESC ] ... terminated by BEL 0x07 or ST = ESC \).
        if s.value == 0x1B, i + 1 < scalars.count {
            let next = scalars[i + 1]
            if next == "[" {
                i += 2
                while i < scalars.count, !(0x40...0x7E).contains(scalars[i].value) { i += 1 }
                i += 1  // consume the final byte
                continue
            }
            if next == "]" {
                i += 2
                while i < scalars.count {
                    if scalars[i].value == 0x07 { i += 1; break }               // BEL
                    if scalars[i].value == 0x1B, i + 1 < scalars.count,
                       scalars[i + 1] == "\\" { i += 2; break }                  // ST
                    i += 1
                }
                continue
            }
        }
        // Drop angle-bracket markup delimiters (keep inner text).
        if s == "<" || s == ">" { i += 1; continue }
        // Collapse any whitespace (incl. newlines) to a single space.
        if s.properties.isWhitespace {
            if out.last != " " { out.append(" ") }
            i += 1; continue
        }
        // Drop C0 (0x00-0x1F) and C1 (0x80-0x9F) control bytes and DEL (0x7F).
        if s.value < 0x20 || s.value == 0x7F || (0x80...0x9F).contains(s.value) {
            i += 1; continue
        }
        out.append(s)
        i += 1
    }

    var result = String(out)
    if result.unicodeScalars.count > etEndReasonMaxLength {
        result = String(String.UnicodeScalarView(result.unicodeScalars.prefix(etEndReasonMaxLength)))
    }
    return result.isEmpty ? "connection ended" : result
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ETEndReasonTests`
Expected: PASS (9 tests). If `testControlBytesStripped` expected `"realFAKE"` fails because `\r` is whitespace and becomes a space, adjust: `\r` is a C0 control byte (0x0D) and is also `isWhitespace`. The whitespace branch runs first, so `real\rFAKE` becomes `real FAKE`. **Update that test's expectation to `"real FAKE"`** and re-run: control-collapse-to-space is the intended, safe behavior (no line overwrite). Keep the `\u{00}\u{07}` trailing bytes dropped.

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/ET/ETEndReason.swift Tests/SemicolynKitTests/ETEndReasonTests.swift
git commit -m "feat(et): sanitizeEndReason for untrusted teardown reasons

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
```

---

### Task 4: `mapETState` defensive state map

**Files:**
- Create: `Sources/SemicolynKit/ET/ETConnectionState.swift`
- Test: `Tests/SemicolynKitTests/ETConnectionStateTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public enum ETConnectionState: Sendable, Equatable { case connecting, connected, roaming, disconnected, unknown(Int32) }`
  - `public func mapETState(_ raw: Int32) -> ETConnectionState`, 0-3 map to the named cases (matching the C `et_state` enum order CONNECTING=0, CONNECTED=1, ROAMING=2, DISCONNECTED=3); anything else is `.unknown(raw)`.

- [ ] **Step 1: Write the failing test**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ETConnectionStateTests: XCTestCase {
    func testKnownStatesMap() {
        XCTAssertEqual(mapETState(0), .connecting)
        XCTAssertEqual(mapETState(1), .connected)
        XCTAssertEqual(mapETState(2), .roaming)
        XCTAssertEqual(mapETState(3), .disconnected)
    }

    // A newer or hostile library sending an out-of-range code must not crash.
    func testUnknownHighCodeIsWrapped() {
        XCTAssertEqual(mapETState(7), .unknown(7))
    }

    func testNegativeCodeIsWrapped() {
        XCTAssertEqual(mapETState(-1), .unknown(-1))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ETConnectionStateTests`
Expected: FAIL to compile / "cannot find 'mapETState' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Swift-visible ET connection state, mapped from the C `et_state` enum.
/// `.unknown` carries the raw code so an unexpected value degrades gracefully
/// instead of crashing.
public enum ETConnectionState: Sendable, Equatable {
    case connecting, connected, roaming, disconnected
    case unknown(Int32)
}

/// Map a raw C `et_state` code to `ETConnectionState`. Codes 0-3 match the ABI's
/// enum order (CONNECTING, CONNECTED, ROAMING, DISCONNECTED); any other value
/// becomes `.unknown(raw)` (defensive against a newer/hostile library).
public func mapETState(_ raw: Int32) -> ETConnectionState {
    switch raw {
    case 0: return .connecting
    case 1: return .connected
    case 2: return .roaming
    case 3: return .disconnected
    default: return .unknown(raw)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ETConnectionStateTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/ET/ETConnectionState.swift Tests/SemicolynKitTests/ETConnectionStateTests.swift
git commit -m "feat(et): mapETState defensive C-state to Swift-enum map

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
```

---

### Task 5: `ETSession` Obj-C interface header

**Files:**
- Create: `App/ET/ETSession.h`

**Interfaces:**
- Consumes: nothing (pure Obj-C interface).
- Produces: an `ETSession` Obj-C class:
  - `- (instancetype)initWithHost:(NSString *)host port:(uint16_t)port id:(NSString *)clientID passkey:(NSString *)passkey env:(NSDictionary<NSString *, NSString *> *)env cols:(uint16_t)cols rows:(uint16_t)rows width:(uint16_t)width height:(uint16_t)height keepaliveSecs:(int32_t)keepaliveSecs NS_DESIGNATED_INITIALIZER;`
  - `- (instancetype)init NS_UNAVAILABLE;`
  - `- (void)start;`
  - `- (void)send:(NSData *)bytes;`
  - `- (void)setWindowSizeCols:(uint16_t)cols rows:(uint16_t)rows width:(uint16_t)width height:(uint16_t)height;`
  - `- (void)close;`
  - `@property (nonatomic, copy, nullable) void (^onOutput)(NSData *bytes);`
  - `@property (nonatomic, copy, nullable) void (^onState)(NSInteger state);` (raw code; Swift maps via `mapETState`)
  - `@property (nonatomic, copy, nullable) void (^onFirstFrame)(void);`
  - `@property (nonatomic, copy, nullable) void (^onEnd)(NSString *_Nullable reason);` (already sanitized)

Config is passed as flat init args (not the Swift `ETConfig`) so the header stays Swift-free and the bridge-test target needs no SemicolynKit import; the Swift caller builds args from a validated `ETConfig`.

- [ ] **Step 1: Write the header**

```objc
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Drives one `eternaltermlib` ET session over the `et_*` C ABI. Speaks only
/// bytes + size + lifecycle events (the same contract SwiftTerm consumes from the
/// SSH/tmux/Mosh paths), so the terminal view stays transport-agnostic.
///
/// Threading: a private serial queue owns every `et_send`/`et_set_window_size`/
/// `et_close` so they never race (the C ABI's serialization requirement).
/// Library callbacks arrive on ET's transport thread; this class copies the byte
/// buffer in-callback and hops to the main queue before firing the closures
/// below, so the Swift side may touch UIKit/SwiftTerm directly.
@interface ETSession : NSObject

- (instancetype)initWithHost:(NSString *)host
                        port:(uint16_t)port
                          id:(NSString *)clientID
                     passkey:(NSString *)passkey
                         env:(NSDictionary<NSString *, NSString *> *)env
                        cols:(uint16_t)cols
                        rows:(uint16_t)rows
                       width:(uint16_t)width
                      height:(uint16_t)height
               keepaliveSecs:(int32_t)keepaliveSecs NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Build the et_config and call et_connect (spawns the transport thread).
- (void)start;

/// Enqueue input bytes to the ET stream (serialized).
- (void)send:(NSData *)bytes;

/// Update the terminal window size (serialized). Pixel width/height 0 if unknown.
- (void)setWindowSizeCols:(uint16_t)cols rows:(uint16_t)rows
                    width:(uint16_t)width height:(uint16_t)height;

/// Tear down: serialized et_close (joins the transport thread), idempotent. After
/// close no closure fires.
- (void)close;

/// Decrypted output bytes (main queue). Wire to `terminalView.feed(byteArray:)`.
@property (nonatomic, copy, nullable) void (^onOutput)(NSData *bytes);

/// Raw et_state code (main queue). Swift maps it via `mapETState`.
@property (nonatomic, copy, nullable) void (^onState)(NSInteger state);

/// Fires exactly once (main queue) on the FIRST output byte. The fallback slice
/// uses this to divide pre-frame failures from mid-session teardown.
@property (nonatomic, copy, nullable) void (^onFirstFrame)(void);

/// Fires once when the session ends (main queue). `reason` is ALREADY sanitized.
@property (nonatomic, copy, nullable) void (^onEnd)(NSString *_Nullable reason);

@end

NS_ASSUME_NONNULL_END
```

- [ ] **Step 2: Commit** (no test yet; the header is exercised by Task 7's bridge test, which will not compile until Task 6 supplies the `.mm`)

```bash
git add App/ET/ETSession.h
git commit -m "feat(et): ETSession Obj-C interface header

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
```

---

### Task 6: `ETSession.mm` implementation over the C ABI

**Files:**
- Create: `App/ET/ETSession.mm`
- Modify: `App/Mosh/Semicolyn-Bridging-Header.h` (add `#import "ETSession.h"`)

**Interfaces:**
- Consumes: `ETSession.h` (Task 5); the C ABI in `extern/eternaltermlib/include/eternaltermlib.h` (`et_connect`, `et_send`, `et_set_window_size`, `et_close`, `et_config`, `et_callbacks`, `et_state`).
- Produces: the compiled bridge behind `ETSession.h`. No new Swift-visible symbols beyond the header.
- Note: sanitization of `on_end` reason is done on the **Swift** side of `onEnd` in a later wiring slice, OR inline here by calling into SemicolynKit. To keep the bridge-test target free of a SemicolynKit dependency, **this `.mm` forwards the RAW reason** to `onEnd`; the Swift caller passes it through `sanitizeEndReason` before logging/rendering. Document this in the header's `onEnd` comment adjustment if needed. (Chosen so the standalone bridge test needs no Kit link; the security guarantee is preserved because every real consumer routes through `sanitizeEndReason`, verified by Task 3's tests and enforced at the wiring slice.)

> Correction to Task 5's header comment: change the `onEnd` doc line from "`reason` is ALREADY sanitized" to "`reason` is RAW (untrusted); the Swift caller must route it through `sanitizeEndReason` before logging or display." Apply this one-line header edit as the first action of this task so the contract matches the implementation.

- [ ] **Step 1: Fix the header comment**

Edit `App/ET/ETSession.h`: replace the `onEnd` doc comment line
`/// Fires once when the session ends (main queue). `reason` is ALREADY sanitized.`
with
`/// Fires once when the session ends (main queue). `reason` is RAW/untrusted; the`
`/// Swift caller must route it through sanitizeEndReason before logging/display.`

- [ ] **Step 2: Write the implementation**

```objc
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
#import "ETSession.h"
#if __has_include(<eternaltermlib.h>)
#import <eternaltermlib.h>
#else
#import "eternaltermlib.h"
#endif

@implementation ETSession {
    NSString *_host; uint16_t _port; NSString *_id; NSString *_passkey;
    NSDictionary<NSString *, NSString *> *_env;
    uint16_t _cols, _rows, _width, _height; int32_t _keepalive;

    dispatch_queue_t _api;      // serial: owns send/resize/close ordering
    et_client *_handle;         // touched only on _api
    BOOL _closed;               // touched only on _api
    BOOL _firstFrameSent;       // touched only on main (set before onOutput)
}

- (instancetype)initWithHost:(NSString *)host port:(uint16_t)port id:(NSString *)clientID
                     passkey:(NSString *)passkey env:(NSDictionary<NSString *,NSString *> *)env
                        cols:(uint16_t)cols rows:(uint16_t)rows width:(uint16_t)width
                      height:(uint16_t)height keepaliveSecs:(int32_t)keepaliveSecs {
    if ((self = [super init])) {
        _host = [host copy]; _port = port; _id = [clientID copy]; _passkey = [passkey copy];
        _env = [env copy]; _cols = cols; _rows = rows; _width = width; _height = height;
        _keepalive = keepaliveSecs;
        _api = dispatch_queue_create("dev.truepositive.semicolyn.et.api", DISPATCH_QUEUE_SERIAL);
        _handle = NULL; _closed = NO; _firstFrameSent = NO;
    }
    return self;
}

// ---- C trampolines: ctx is the ETSession* (unretained; the object outlives the
// handle because -close joins the transport thread before dealloc). ----

static void et_on_bytes(void *ctx, const uint8_t *buf, size_t len) {
    ETSession *self = (__bridge ETSession *)ctx;
    NSData *data = [NSData dataWithBytes:buf length:len];   // COPY inside the callback
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self->_firstFrameSent) {
            self->_firstFrameSent = YES;
            if (self.onFirstFrame) self.onFirstFrame();
        }
        if (self.onOutput) self.onOutput(data);
    });
}

static void et_on_state(void *ctx, et_state state) {
    ETSession *self = (__bridge ETSession *)ctx;
    NSInteger raw = (NSInteger)state;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.onState) self.onState(raw);
    });
}

static void et_on_end(void *ctx, const char *reason) {
    ETSession *self = (__bridge ETSession *)ctx;
    NSString *r = reason ? [NSString stringWithUTF8String:reason] : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.onEnd) self.onEnd(r);   // RAW; Swift sanitizes
    });
}

- (void)start {
    dispatch_async(_api, ^{
        if (self->_closed || self->_handle) return;

        // Flat env arrays (deep-copied by et_connect; freed on return).
        NSArray<NSString *> *keys = self->_env.allKeys;
        size_t n = keys.count;
        const char **ck = (const char **)malloc(sizeof(char *) * (n ?: 1));
        const char **cv = (const char **)malloc(sizeof(char *) * (n ?: 1));
        for (size_t i = 0; i < n; i++) {
            ck[i] = [keys[i] UTF8String];
            cv[i] = [self->_env[keys[i]] UTF8String];
        }

        et_config cfg = {0};
        cfg.host = [self->_host UTF8String];
        cfg.port = self->_port;
        cfg.id = [self->_id UTF8String];
        cfg.passkey = [self->_passkey UTF8String];
        cfg.env_keys = ck; cfg.env_vals = cv; cfg.env_count = n;
        cfg.cols = self->_cols; cfg.rows = self->_rows;
        cfg.width = self->_width; cfg.height = self->_height;
        cfg.keepalive_secs = self->_keepalive;

        et_callbacks cbs = { et_on_bytes, et_on_state, et_on_end };
        self->_handle = et_connect(&cfg, &cbs, (__bridge void *)self);
        free(ck); free(cv);

        if (self->_handle == NULL) {
            // Synchronous arg failure. Report as a teardown so the caller sees it.
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.onEnd) self.onEnd(@"et_connect failed");
            });
        }
    });
}

- (void)send:(NSData *)bytes {
    NSData *copy = [bytes copy];
    dispatch_async(_api, ^{
        if (self->_closed || self->_handle == NULL) return;
        et_send(self->_handle, (const uint8_t *)copy.bytes, copy.length);
    });
}

- (void)setWindowSizeCols:(uint16_t)cols rows:(uint16_t)rows
                    width:(uint16_t)width height:(uint16_t)height {
    dispatch_async(_api, ^{
        if (self->_closed || self->_handle == NULL) return;
        et_set_window_size(self->_handle, cols, rows, width, height);
    });
}

- (void)close {
    dispatch_async(_api, ^{
        if (self->_closed) return;
        self->_closed = YES;
        if (self->_handle) { et_close(self->_handle); self->_handle = NULL; }
    });
}

@end
```

- [ ] **Step 3: Add the bridging-header import**

Edit `App/Mosh/Semicolyn-Bridging-Header.h`, add after the existing `#import "MoshSession.h"`:

```objc
#import "../ET/ETSession.h"
```

- [ ] **Step 4: Commit** (compilation is verified by Task 7's CI wiring + macOS CI; there is no Linux compile for this file)

```bash
git add App/ET/ETSession.mm App/ET/ETSession.h App/Mosh/Semicolyn-Bridging-Header.h
git commit -m "feat(et): ETSession.mm bridge over the eternaltermlib C ABI

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
```

---

### Task 7: Bridge test (fake et_client) + project.yml wiring

**Files:**
- Create: `Tests/AppTests/fake_et_client.mm`
- Create: `Tests/AppTests/ETSessionTests.mm`
- Modify: `project.yml` (extend `SemicolynBridgeTests` sources + header search path)

**Interfaces:**
- Consumes: `ETSession.h`/`ETSession.mm` (Tasks 5-6); the C ABI declarations from `eternaltermlib.h`.
- Produces: a macOS-CI test target proving the bridge's queue-hop, buffer-copy, first-frame-once, idempotent-close, and no-callback-after-close behaviors. The fake is the ONLY definition of `et_connect`/`et_send`/`et_set_window_size`/`et_close` linked into this target (no framework link, so no duplicate symbols), exactly as `fake_mosh_main.mm` is for the Mosh bridge test.

- [ ] **Step 1: Write the fake et_client**

```objc
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
//
// A test-only override of the et_* C ABI linked into SemicolynBridgeTests INSTEAD
// of ETerminal.xcframework. It proves ETSession's plumbing without a network: a
// fake handle spins a background thread that (a) reports CONNECTED, (b) echoes
// every byte from et_send back through on_bytes, (c) on et_close reports and stops.
// Deterministic, no sockets, no libsodium.
#import <eternaltermlib.h>
#import <Foundation/Foundation.h>
#include <vector>

struct et_client {
    void *ctx;
    void (*on_bytes)(void *, const uint8_t *, size_t);
    void (*on_state)(void *, et_state);
    void (*on_end)(void *, const char *);
    dispatch_queue_t work;   // serial: emulates the transport thread
    bool closed;
};

extern "C" et_client *et_connect(const et_config *cfg, const et_callbacks *cbs, void *ctx) {
    if (!cfg || !cfg->host || !cfg->id || !cfg->passkey) return NULL;   // sync arg failure
    et_client *c = new et_client();
    c->ctx = ctx; c->on_bytes = cbs->on_bytes; c->on_state = cbs->on_state;
    c->on_end = cbs->on_end;
    c->work = dispatch_queue_create("fake.et.transport", DISPATCH_QUEUE_SERIAL);
    c->closed = false;
    dispatch_async(c->work, ^{ if (c->on_state) c->on_state(c->ctx, ET_STATE_CONNECTED); });
    return c;
}

extern "C" int et_send(et_client *c, const uint8_t *buf, size_t len) {
    if (!c || c->closed) return ET_ERR_CLOSED;
    std::vector<uint8_t> bytes(buf, buf + len);
    dispatch_async(c->work, ^{
        if (!c->closed && c->on_bytes) c->on_bytes(c->ctx, bytes.data(), bytes.size());
    });
    return (int)len;
}

extern "C" int et_set_window_size(et_client *c, uint16_t cols, uint16_t rows,
                                  uint16_t w, uint16_t h) {
    (void)cols; (void)rows; (void)w; (void)h;
    if (!c || c->closed) return ET_ERR_CLOSED;
    return 0;
}

extern "C" void et_close(et_client *c) {
    if (!c || c->closed) return;
    c->closed = true;
    dispatch_sync(c->work, ^{ if (c->on_end) c->on_end(c->ctx, "closed by client"); });
    delete c;
}
```

- [ ] **Step 2: Write the bridge test**

```objc
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
#import <XCTest/XCTest.h>
#import "ETSession.h"

@interface ETSessionTests : XCTestCase
@end

@implementation ETSessionTests

- (ETSession *)makeSession {
    return [[ETSession alloc] initWithHost:@"h" port:2022 id:@"0123456789abcdef"
                                   passkey:@"0123456789abcdef0123456789abcdef"
                                       env:@{@"TERM": @"xterm-256color"}
                                      cols:80 rows:24 width:0 height:0 keepaliveSecs:0];
}

// Bytes sent via -send: echo back through onOutput (proves the queue-hop + copy).
- (void)testSendEchoesThroughOnOutput {
    ETSession *s = [self makeSession];
    XCTestExpectation *got = [self expectationWithDescription:@"output"];
    __block NSData *received = nil;
    s.onOutput = ^(NSData *bytes) { received = bytes; [got fulfill]; };
    [s start];
    [s send:[@"hi" dataUsingEncoding:NSUTF8StringEncoding]];
    [self waitForExpectations:@[got] timeout:2.0];
    XCTAssertEqualObjects(received, [@"hi" dataUsingEncoding:NSUTF8StringEncoding]);
    [s close];
}

// onFirstFrame fires exactly once even across multiple output bytes.
- (void)testFirstFrameFiresExactlyOnce {
    ETSession *s = [self makeSession];
    XCTestExpectation *second = [self expectationWithDescription:@"second output"];
    __block int firstFrameCount = 0;
    __block int outputCount = 0;
    s.onFirstFrame = ^{ firstFrameCount++; };
    s.onOutput = ^(NSData *bytes) { if (++outputCount == 2) [second fulfill]; };
    [s start];
    [s send:[@"a" dataUsingEncoding:NSUTF8StringEncoding]];
    [s send:[@"b" dataUsingEncoding:NSUTF8StringEncoding]];
    [self waitForExpectations:@[second] timeout:2.0];
    XCTAssertEqual(firstFrameCount, 1);
    [s close];
}

// -close is idempotent and no onOutput fires after it.
- (void)testCloseIdempotentAndNoOutputAfter {
    ETSession *s = [self makeSession];
    XCTestExpectation *ended = [self expectationWithDescription:@"end"];
    __block int outputAfterClose = 0;
    __block BOOL closed = NO;
    s.onOutput = ^(NSData *bytes) { if (closed) outputAfterClose++; };
    s.onEnd = ^(NSString *reason) { [ended fulfill]; };
    [s start];
    closed = YES;
    [s close];
    [s close];   // second close must be a no-op (not crash)
    [s send:[@"late" dataUsingEncoding:NSUTF8StringEncoding]];  // must be dropped
    [self waitForExpectations:@[ended] timeout:2.0];
    // Give any erroneously-queued output a chance to (not) arrive.
    XCTestExpectation *settle = [self expectationWithDescription:@"settle"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [settle fulfill]; });
    [self waitForExpectations:@[settle] timeout:2.0];
    XCTAssertEqual(outputAfterClose, 0);
}

@end
```

- [ ] **Step 3: Wire the bridge-test target in project.yml**

Edit the `SemicolynBridgeTests` target block. Add `App/ET/ETSession.mm` to `sources` (alongside the existing `App/Mosh/MoshSession.mm`), and append the ET include dir to `HEADER_SEARCH_PATHS`:

```yaml
  SemicolynBridgeTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - Tests/AppTests
      - path: App/Mosh/MoshSession.mm
      - path: App/ET/ETSession.mm
    settings:
      base:
        CLANG_CXX_LANGUAGE_STANDARD: gnu++17
        CODE_SIGNING_ALLOWED: NO
        # Mosh: resolve moshiosbridge.h without linking the framework.
        # ET: resolve eternaltermlib.h (the <eternaltermlib.h> angle include) the same way.
        HEADER_SEARCH_PATHS:
          - $(SRCROOT)/extern/mosh/src/frontend
          - $(SRCROOT)/extern/eternaltermlib/include
```

(Note: `HEADER_SEARCH_PATHS` was a single scalar before; converting it to a list is the change. Keep the existing mosh path as the first list entry.)

- [ ] **Step 4: Verify locally that the target regenerates**

Run (host has xcodegen? if not, this is CI-verified): confirm `project.yml` is valid YAML.
Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev python3 -c "import yaml,sys; yaml.safe_load(open('project.yml')); print('project.yml OK')"`
Expected: `project.yml OK`. (The full `xcodegen generate` + `xcodebuild -scheme SemicolynBridgeTests test` runs on macOS CI.)

- [ ] **Step 5: Commit**

```bash
git add Tests/AppTests/fake_et_client.mm Tests/AppTests/ETSessionTests.mm project.yml
git commit -m "test(et): ETSession bridge test over a fake et_client + CI wiring

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
```

---

### Task 8: Push, verify macOS CI, update TODO

**Files:**
- Modify: `TODO.md` (resume block)

**Interfaces:**
- Consumes: all prior tasks.
- Produces: a green CI run + an updated resume pointer.

- [ ] **Step 1: Create the feature branch retroactively (if not already on one) and push**

```bash
git branch feat/libetios-wrapper 2>/dev/null || true
git checkout feat/libetios-wrapper 2>/dev/null || git checkout -b feat/libetios-wrapper
git push -u github feat/libetios-wrapper
```

- [ ] **Step 2: Open the PR**

```bash
gh pr create --repo ds7n/semicolyn --base main --head feat/libetios-wrapper \
  --title "feat(et): libetios wrapper (ETSession + Kit deciders)" \
  --body "$(cat <<'BODY'
Wrapper-only slice of the ET transport (design: docs/superpowers/specs/2026-08-04-libetios-wrapper-design.md).

- ETSession Obj-C++ bridge over the eternaltermlib C ABI: private serial queue owns send/resize/close ordering (isClosed guard), callbacks copy-in-callback + hop to main.
- Three pure Linux-tested Kit deciders: ETConfig validate + etEnvArrays, sanitizeEndReason (untrusted), mapETState (unknown-int guard).
- macOS-CI bridge test drives ETSession against a fake et_client (send-echo, first-frame-once, idempotent-close, no-callback-after-close).

Out of scope (later slices): russh bootstrap, probe/fallback-to-SSH, Transport picker.

https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt
BODY
)"
```

- [ ] **Step 3: Wait for + verify all CI jobs green**

Run: `gh run watch --repo ds7n/semicolyn $(gh run list --repo ds7n/semicolyn --branch feat/libetios-wrapper --limit 1 --json databaseId --jq '.[0].databaseId')`
Expected: `linux-swift`, `linux-rust`, `lint`, and **`macos`** all pass. The `macos` job is the only signal that `ETSession.mm` + the `SemicolynBridgeTests` target compile and the fake-driven tests pass. If `linux-rust` flakes with "sshd fixtures not reachable", rerun that job only (`gh run rerun <id> --failed`); it is not a real failure on this non-Rust change.

- [ ] **Step 4: Update the TODO resume block**

Edit `TODO.md`: under "Resume here", record that the `libetios` wrapper slice is done (ETSession + 3 Kit deciders, PR #<n>, CI green), and that the NEXT ET slice is §3 russh bootstrap (generate id/passkey, plant the credential over the existing russh session, build a live ETConfig, feed ETSession), followed by §4 probe/fallback and §5 Transport picker. Note the wrapper is compile-and-fake-verified only; a real handshake awaits the bootstrap slice + a device pass.

- [ ] **Step 5: Commit**

```bash
git add TODO.md
git commit -m "docs: record libetios wrapper slice done; next = ET §3 russh bootstrap

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
git push
```

---

## Self-Review

**Spec coverage:**
- §Scope "In" bullet 1 (ETSession over the C ABI, bytes+size+lifecycle) → Tasks 5, 6, 7.
- §Scope "In" bullet 2 (three Kit deciders) → Tasks 1-4 (ETConfig+validate = 1, etEnvArrays = 2, sanitizeEndReason = 3, mapETState = 4).
- §Scope "In" bullet 4 (onFirstFrame hook exposed) → Task 5 header property + Task 7 first-frame-once test.
- §Architecture two-queue split + isClosed guard + buffer-copy + ctx-outlives-handle → Task 6 `.mm` + Task 7 tests.
- §Data flow error table (bad config, et_connect NULL, async handshake fail, negative et_err, untrusted reason, callback-after-close) → validate (Task 1), start NULL branch (Task 6), on_end path (Task 6), send guard (Task 6), sanitize (Task 3), close guard (Tasks 6-7).
- §Testing Linux table → Tasks 1-4 tests. §Testing macOS bridge (4 assertions) → Task 7 (send-echo, first-frame-once, idempotent-close-no-output-after; the "sanitized onEnd" assertion moved to the Swift wiring slice per Task 6's Kit-free-bridge decision, and is already covered by Task 3's unit tests).
- §Non-goals (no degradation decider, no live config, no picker) → respected; none implemented.

**Placeholder scan:** No "TBD"/"add error handling"/"similar to Task N" left. Every code step has concrete content. Task 4 repeats no code from earlier tasks. The one forward-reference (Task 5 header comment corrected in Task 6) is explicit and self-contained.

**Type consistency:** `ETConfig` members and `validateETConfig`/`etEnvArrays`/`sanitizeEndReason`/`etEndReasonMaxLength`/`mapETState`/`ETConnectionState` signatures match across the deciders and the self-review. `ETSession` init-arg names (`host/port/id/passkey/env/cols/rows/width/height/keepaliveSecs`) match between Task 5 header, Task 6 `.mm`, and Task 7 test `makeSession`. The `et_config`/`et_callbacks`/`et_state`/`et_err` names match the real ABI header read from `extern/eternaltermlib/include/eternaltermlib.h`.

**One deviation from the spec, made explicit:** the spec said the `.mm` sanitizes `on_end` before forwarding; the plan instead forwards the RAW reason and sanitizes on the Swift side, so the standalone bridge-test target needs no SemicolynKit link (matching the Mosh precedent of a Kit-free bridge). The security guarantee is preserved (every real consumer routes through `sanitizeEndReason`, unit-tested in Task 3) and enforced at the §3 wiring slice. Task 5/6 header comment reflects this.
