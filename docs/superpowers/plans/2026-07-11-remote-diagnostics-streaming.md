<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Remote Diagnostics Streaming Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stream verbose on-device gesture/selection/key/scroll/tmux diagnostics off-device as RFC 5424 syslog (UDP/TCP/TLS) to a developer-run sink, so the broken terminal gestures can be fixed from real evidence.

**Architecture:** Two pure, Linux-tested pieces in SemicolynKit — `syslogFrame(...)` (RFC 5424 framing) and `keystrokeLogDecision(...)` (redaction). A thin App-tier `RemoteLogSink` (`NWConnection`) that `DebugLog` forwards each line to. Config + UI (transport picker, host/port, keystroke nag) extend `DiagnosticsSettingsView`. Verbose instrumentation call sites added across the gesture/key/scroll/tmux paths, all via the existing gated `DebugLog.shared.log`. A `tools/syslog-sink/` docker-compose receiver.

**Tech Stack:** Swift 6, XCTest, Network.framework (`NWConnection`), SwiftUI, Docker (rsyslog/syslog-ng).

## Global Constraints

- **Two-tier rule:** `Sources/SemicolynKit/` = pure logic, Linux-tested, `Sendable`, **no `import UIKit`/`SwiftUI`/`Network`**. `App/` = Apple-only, validated only by the macOS CI job. — from `CLAUDE.md`.
- **SPDX header** on every new source file: `// SPDX-FileCopyrightText: 2026 True Positive LLC` / `// SPDX-License-Identifier: GPL-3.0-only`.
- **Tests are real** (`docs/superpowers/specs/2026-06-18-testing-standards-design.md`): EP + boundary values; assert exact observable values (no tautologies); a negative test asserts the specific result.
- **Conventional commits**; one feature branch `feat/remote-diagnostics`.
- **Linux test:** `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter <Name>` (no host Swift toolchain; runs in `semicolyn-dev` Docker; disable sandbox if Docker socket is blocked).
- **App-tier tasks are not Linux-buildable** — their gate is the macOS CI job on the PR, not a local command. Steps say so.
- **Syslog framing (spec §Transport):** `<135>1 TIMESTAMP HOSTNAME semicolyn - - - MSG`. PRI `<135>` = local0(16)·8 + debug(7). TCP/TLS = octet-counted (`<UTF-8-byte-len> <MSG>`); UDP = bare message, no count. TLS port 6514, TCP/UDP 514.
- **Keystroke gating (spec §Keystroke content):** default off = structural only; on = content EXCEPT password-line → visible `REDACTED len=N reason=password-line` marker; **NO un-redacted mode; redaction is never silent.**
- **Secrets:** TLS cert-verify off (developer host, documented). Diagnostics off by default. `data/`, logs stay gitignored.

## File Structure

**New (SemicolynKit, Linux-tested):**
- `Sources/SemicolynKit/Diagnostics/SyslogFrame.swift` — pure RFC 5424 framing.
- `Sources/SemicolynKit/Diagnostics/KeystrokeLogDecision.swift` — pure redaction decision.
- `Tests/SemicolynKitTests/SyslogFrameTests.swift`, `Tests/SemicolynKitTests/KeystrokeLogDecisionTests.swift`

**New (App, macOS-CI-only):**
- `App/RemoteLogSink.swift` — `NWConnection` sink (UDP/TCP/TLS), fire-and-forget send, test probe.
- `App/RemoteLogConfig.swift` — `@AppStorage`-backed config + keys + `LogTransport` enum.

**Modified (App):**
- `App/DebugLog.swift` — forward each line to an optional `RemoteLogSink`.
- `App/DiagnosticsSettingsView.swift` — streaming toggle, host/port/transport, Test button, keystroke toggle + nag.
- `App/TerminalGestureController.swift`, `App/TerminalScreen.swift`, `App/TmuxPaneContainer.swift`, `App/ConnectionViewModel.swift` — verbose instrumentation call sites.

**New (repo tooling):**
- `tools/syslog-sink/docker-compose.yml`, `tools/syslog-sink/README.md` (+ minimal syslog config).

---

## Task 1: `syslogFrame` — RFC 5424 framing (pure, Linux)

**Files:**
- Create: `Sources/SemicolynKit/Diagnostics/SyslogFrame.swift`
- Test: `Tests/SemicolynKitTests/SyslogFrameTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public enum LogTransport: String, Sendable, CaseIterable { case udp, tcp, tls }`
  - `public func syslogFrame(message: String, hostname: String, timestamp: String, transport: LogTransport) -> String`
  - Semantics: builds `<135>1 <timestamp> <hostname> semicolyn - - - <message>`. For `.tcp`/`.tls`, prefixes octet count + space: `<byteLen> <SYSLOG>` where `byteLen` = UTF-8 byte count of the `<135>1 …message` string. For `.udp`, returns the bare `<135>1 …message` with no count. Empty hostname → `-`. Any newline in `message` is replaced with a space (syslog messages are single-line; octet count must stay correct).

- [ ] **Step 1: Write the failing tests**

Create `Tests/SemicolynKitTests/SyslogFrameTests.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// RFC 5424 syslog framing: PRI+version header, per-transport octet counting.
final class SyslogFrameTests: XCTestCase {
    private let ts = "2026-07-11T03:40:51.123Z"

    // EP: UDP → bare message, no octet-count prefix.
    func testUDPHasNoOctetCount() {
        let out = syslogFrame(message: "hello", hostname: "iphone", timestamp: ts, transport: .udp)
        XCTAssertEqual(out, "<135>1 2026-07-11T03:40:51.123Z iphone semicolyn - - - hello")
    }

    // EP: TCP → octet-count prefix = UTF-8 byte length of the syslog message + space.
    func testTCPOctetCountPrefix() {
        let msg = "<135>1 2026-07-11T03:40:51.123Z iphone semicolyn - - - hello"
        let out = syslogFrame(message: "hello", hostname: "iphone", timestamp: ts, transport: .tcp)
        XCTAssertEqual(out, "\(msg.utf8.count) \(msg)")
    }

    // TLS frames identically to TCP (octet-counted).
    func testTLSOctetCountMatchesTCP() {
        let tcp = syslogFrame(message: "hello", hostname: "iphone", timestamp: ts, transport: .tcp)
        let tls = syslogFrame(message: "hello", hostname: "iphone", timestamp: ts, transport: .tls)
        XCTAssertEqual(tls, tcp)
    }

    // BVA: multibyte content — octet count is BYTES not characters.
    func testMultibyteOctetCountIsBytes() {
        let content = "café→x"   // é = 2 bytes, → = 3 bytes
        let msg = "<135>1 2026-07-11T03:40:51.123Z iphone semicolyn - - - \(content)"
        let out = syslogFrame(message: content, hostname: "iphone", timestamp: ts, transport: .tls)
        XCTAssertEqual(out, "\(msg.utf8.count) \(msg)")
        // Guard against a char-count regression: bytes must exceed Swift character count here.
        XCTAssertGreaterThan(msg.utf8.count, msg.count)
    }

    // Empty hostname → NILVALUE '-'.
    func testEmptyHostnameBecomesDash() {
        let out = syslogFrame(message: "x", hostname: "", timestamp: ts, transport: .udp)
        XCTAssertEqual(out, "<135>1 2026-07-11T03:40:51.123Z - semicolyn - - - x")
    }

    // Newline in message is flattened to a space (single-line syslog; count stays correct).
    func testNewlineFlattenedToSpace() {
        let out = syslogFrame(message: "a\nb", hostname: "h", timestamp: ts, transport: .udp)
        XCTAssertEqual(out, "<135>1 2026-07-11T03:40:51.123Z h semicolyn - - - a b")
    }

    // PRI is exactly <135> (local0=16 · 8 + debug=7) and version is 1.
    func testPriAndVersion() {
        let out = syslogFrame(message: "m", hostname: "h", timestamp: ts, transport: .udp)
        XCTAssertTrue(out.hasPrefix("<135>1 "), "got: \(out)")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter SyslogFrameTests`
Expected: FAIL — `cannot find 'syslogFrame' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/SemicolynKit/Diagnostics/SyslogFrame.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Wire transport for the remote diagnostics stream.
public enum LogTransport: String, Sendable, CaseIterable {
    case udp, tcp, tls
}

/// Build one RFC 5424 syslog message for `transport`. Header is
/// `<135>1 <timestamp> <hostname> semicolyn - - - <message>` (PRI 135 = local0·8 +
/// debug; version 1; NILVALUE `-` for procid/msgid/structured-data). TCP and TLS
/// (RFC 6587 / RFC 5425) are octet-counted: the returned string is
/// `<utf8-byte-length> <syslog-message>`. UDP (RFC 5426) is the bare message. An
/// empty hostname becomes `-`. Newlines in `message` are flattened to spaces so the
/// message stays single-line and the octet count is exact.
public func syslogFrame(message: String, hostname: String, timestamp: String,
                        transport: LogTransport) -> String {
    let host = hostname.isEmpty ? "-" : hostname
    let flat = message.replacingOccurrences(of: "\n", with: " ")
    let syslog = "<135>1 \(timestamp) \(host) semicolyn - - - \(flat)"
    switch transport {
    case .udp:
        return syslog
    case .tcp, .tls:
        return "\(syslog.utf8.count) \(syslog)"
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter SyslogFrameTests`
Expected: PASS (all 7).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Diagnostics/SyslogFrame.swift Tests/SemicolynKitTests/SyslogFrameTests.swift
git commit -m "feat(diagnostics): RFC 5424 syslog framing (pure)"
```

---

## Task 2: `keystrokeLogDecision` — redaction decision (pure, Linux)

**Files:**
- Create: `Sources/SemicolynKit/Diagnostics/KeystrokeLogDecision.swift`
- Test: `Tests/SemicolynKitTests/KeystrokeLogDecisionTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public func keystrokeLogDecision(event: String, content: String, logContent: Bool, isPasswordLine: Bool) -> String`
  - Semantics: `event` is the structural verb (e.g. `"insertText"`). Returns:
    - `logContent == false` → structural only: `"\(event)(len=\(content.count))"`
    - `logContent == true` && `isPasswordLine` → visible redaction marker: `"\(event)(REDACTED len=\(content.count) reason=password-line)"`
    - `logContent == true` && !`isPasswordLine` → content: `"\(event)(\"\(content)\")"`
  - `len` is the Swift `Character` count of `content` (user-visible length), consistent across all three branches.

- [ ] **Step 1: Write the failing tests**

Create `Tests/SemicolynKitTests/KeystrokeLogDecisionTests.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Keystroke log redaction: structural-only by default; content or a VISIBLE
/// redaction marker (never a silent drop) when content logging is on.
final class KeystrokeLogDecisionTests: XCTestCase {
    // EP: content logging OFF → structural only, regardless of password flag.
    func testOffIsStructuralOnly() {
        XCTAssertEqual(
            keystrokeLogDecision(event: "insertText", content: "abc", logContent: false, isPasswordLine: false),
            "insertText(len=3)")
    }

    func testOffIsStructuralEvenOnPasswordLine() {
        XCTAssertEqual(
            keystrokeLogDecision(event: "insertText", content: "abc", logContent: false, isPasswordLine: true),
            "insertText(len=3)")
    }

    // EP: content ON, not a password line → logs the actual content.
    func testOnNonPasswordLogsContent() {
        XCTAssertEqual(
            keystrokeLogDecision(event: "insertText", content: "ls", logContent: true, isPasswordLine: false),
            "insertText(\"ls\")")
    }

    // EP: content ON, password line → VISIBLE redaction marker with length, no content.
    func testOnPasswordLineRedactsVisibly() {
        XCTAssertEqual(
            keystrokeLogDecision(event: "insertText", content: "hunter2", logContent: true, isPasswordLine: true),
            "insertText(REDACTED len=7 reason=password-line)")
    }

    // Redaction never leaks the content: assert the secret substring is absent.
    func testRedactionOmitsContent() {
        let out = keystrokeLogDecision(event: "insertText", content: "s3cr3t", logContent: true, isPasswordLine: true)
        XCTAssertFalse(out.contains("s3cr3t"), "redacted output must not contain the content: \(out)")
    }

    // BVA: empty content → len=0 structural.
    func testEmptyContentLenZero() {
        XCTAssertEqual(
            keystrokeLogDecision(event: "deleteBackward", content: "", logContent: false, isPasswordLine: false),
            "deleteBackward(len=0)")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter KeystrokeLogDecisionTests`
Expected: FAIL — `cannot find 'keystrokeLogDecision' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/SemicolynKit/Diagnostics/KeystrokeLogDecision.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Decide how a keystroke event is rendered in the diagnostic trace.
///
/// - `logContent == false` (default): structural only — the event verb + length, no
///   characters. Diagnoses key-path behavior (e.g. backspace repeat) without exposing
///   what was typed.
/// - `logContent == true` on a password/prompt line: a VISIBLE redaction marker with the
///   length and reason — never the content, and never a silent drop (the trace still
///   shows a password line happened).
/// - `logContent == true` otherwise: the actual content.
public func keystrokeLogDecision(event: String, content: String,
                                 logContent: Bool, isPasswordLine: Bool) -> String {
    let len = content.count
    guard logContent else { return "\(event)(len=\(len))" }
    if isPasswordLine { return "\(event)(REDACTED len=\(len) reason=password-line)" }
    return "\(event)(\"\(content)\")"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter KeystrokeLogDecisionTests`
Expected: PASS (all 6).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Diagnostics/KeystrokeLogDecision.swift Tests/SemicolynKitTests/KeystrokeLogDecisionTests.swift
git commit -m "feat(diagnostics): keystroke redaction decision (pure)"
```

---

## Task 3: `RemoteLogConfig` — config + keys (App, macOS-CI-only)

> **Not Linux-buildable.** macOS CI is the gate.

**Files:**
- Create: `App/RemoteLogConfig.swift`

**Interfaces:**
- Consumes: `LogTransport` (SemicolynKit, Task 1).
- Produces: an enum of `@AppStorage` keys + defaults the UI and sink read:
  - `enum RemoteLogConfig { static let enabledKey = "diagnostics.remoteLog.enabled"; static let hostKey = "diagnostics.remoteLog.host"; static let portKey = "diagnostics.remoteLog.port"; static let transportKey = "diagnostics.remoteLog.transport"; static let keystrokeContentKey = "diagnostics.remoteLog.keystrokeContent"; static let defaultPort = 6514 }`
  - `LogTransport` already `RawRepresentable` by `String` (Task 1), so it stores directly in `@AppStorage`.

- [ ] **Step 1: Implement**

Create `App/RemoteLogConfig.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SemicolynKit

/// UserDefaults keys + defaults for the remote diagnostics stream. All developer-facing,
/// off by default. `LogTransport` (SemicolynKit) is `RawRepresentable` by `String`, so it
/// persists directly via `@AppStorage`.
enum RemoteLogConfig {
    static let enabledKey = "diagnostics.remoteLog.enabled"
    static let hostKey = "diagnostics.remoteLog.host"
    static let portKey = "diagnostics.remoteLog.port"
    static let transportKey = "diagnostics.remoteLog.transport"
    static let keystrokeContentKey = "diagnostics.remoteLog.keystrokeContent"

    static let defaultPort = 6514
    static let defaultTransport: LogTransport = .tls
}
```

- [ ] **Step 2: Verify (macOS CI)**

Cannot build on Linux. Commit; compilation verified by the macOS CI job in Task 9.

- [ ] **Step 3: Commit**

```bash
git add App/RemoteLogConfig.swift
git commit -m "feat(app): remote-log config keys"
```

---

## Task 4: `RemoteLogSink` — NWConnection sink (App, macOS-CI-only)

> **Not Linux-buildable.** macOS CI is the gate.

**Files:**
- Create: `App/RemoteLogSink.swift`

**Interfaces:**
- Consumes: `syslogFrame(...)`, `LogTransport` (SemicolynKit, Task 1); `RemoteLogConfig` (Task 3).
- Produces:
  - `final class RemoteLogSink` with:
    - `init(host: String, port: Int, transport: LogTransport)`
    - `func send(_ line: String)` — fire-and-forget; frames via `syslogFrame`, writes to the connection; drops if not ready. Never blocks.
    - `func test(_ completion: @escaping (Bool) -> Void)` — connect + send one probe, report reachability.
    - `func stop()` — tear down.
  - The App holds one sink instance (recreated when config changes); `DebugLog` forwards to it (Task 5).

- [ ] **Step 1: Implement**

Create `App/RemoteLogSink.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Network
import SemicolynKit

/// Streams diagnostic lines to a developer-run syslog server over UDP/TCP/TLS.
/// Fire-and-forget: `send` never blocks the caller (the log path); a line is dropped if
/// the connection isn't ready. The local `DebugLog` buffer retains everything regardless.
///
/// TLS uses `NWProtocolTLS` with certificate verification DISABLED — this targets the
/// developer's own diagnostics host (self-signed cert from `tools/syslog-sink/`), not a
/// general secure channel. Documented and intentional.
final class RemoteLogSink {
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let transport: LogTransport
    private let hostname: String
    private let queue = DispatchQueue(label: "dev.truepositive.semicolyn.remotelog")
    private var connection: NWConnection?

    init(host: String, port: Int, transport: LogTransport) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? 6514
        self.transport = transport
        // Device name as syslog HOSTNAME; trimmed to a reasonable token.
        self.hostname = ProcessInfo.processInfo.hostName
        start()
    }

    private func makeParameters() -> NWParameters {
        switch transport {
        case .udp:
            return .udp
        case .tcp:
            return .tcp
        case .tls:
            // TLS with verification disabled (developer's self-signed diagnostics host).
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(
                tls.securityProtocolOptions,
                { _, _, complete in complete(true) },   // accept any certificate
                queue)
            return NWParameters(tls: tls)
        }
    }

    private func start() {
        let conn = NWConnection(host: host, port: port, using: makeParameters())
        conn.start(queue: queue)
        connection = conn
    }

    /// Frame the line and send it fire-and-forget. UDP is datagram-per-line; TCP/TLS are
    /// octet-counted so the receiver can deframe a continuous stream.
    func send(_ line: String) {
        let framed = syslogFrame(message: line, hostname: hostname,
                                 timestamp: Self.timestamp(), transport: transport)
        guard let data = framed.data(using: .utf8) else { return }
        queue.async { [weak self] in
            self?.connection?.send(content: data, completion: .idempotent)
        }
    }

    /// Connect (if needed) and send a probe line, reporting whether the connection
    /// reached `.ready`. Used by the Diagnostics "Test connection" button.
    func test(_ completion: @escaping (Bool) -> Void) {
        let probe = NWConnection(host: host, port: port, using: makeParameters())
        probe.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let framed = syslogFrame(message: "semicolyn diagnostics test",
                                         hostname: self.hostname,
                                         timestamp: Self.timestamp(), transport: self.transport)
                probe.send(content: framed.data(using: .utf8), completion: .contentProcessed { _ in
                    probe.cancel(); completion(true)
                })
            case .failed, .cancelled:
                probe.cancel(); completion(false)
            default:
                break
            }
        }
        probe.start(queue: queue)
    }

    func stop() {
        queue.async { [weak self] in
            self?.connection?.cancel()
            self?.connection = nil
        }
    }

    /// RFC 3339 timestamp with fractional seconds (syslog TIMESTAMP field).
    private static func timestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }
}
```

**Implementer note (macOS-CI-verified):** confirm `sec_protocol_options_set_verify_block` and `NWParameters(tls:)` signatures compile on the iOS SDK in CI; if the verify-block signature differs, keep the "accept any cert" intent. `ProcessInfo.processInfo.hostName` gives a device hostname; acceptable as syslog HOSTNAME.

- [ ] **Step 2: Verify (macOS CI)** — commit; compilation is the Task 9 gate.

- [ ] **Step 3: Commit**

```bash
git add App/RemoteLogSink.swift
git commit -m "feat(app): RemoteLogSink NWConnection UDP/TCP/TLS syslog stream"
```

---

## Task 5: Wire `DebugLog` → `RemoteLogSink` (App, macOS-CI-only)

> **Not Linux-buildable.** macOS CI is the gate.

**Files:**
- Modify: `App/DebugLog.swift`

**Interfaces:**
- Consumes: `RemoteLogSink` (Task 4).
- Produces: `DebugLog.shared.remote: RemoteLogSink?` — when set, each logged line is also forwarded. `DebugLog` gains `func setRemote(_ sink: RemoteLogSink?)`.

- [ ] **Step 1: Add the forward hook**

In `App/DebugLog.swift`, add a `remote` property and forward in `log()`. The existing method is:
```swift
    func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let now = Date().timeIntervalSinceReferenceDate
        if start == nil { start = now }
        let t = now - (start ?? now)
        let line = String(format: "%7.2f  %@", t, message())
        lines.append(line)
        if lines.count > cap { lines.removeFirst(lines.count - cap) }
        logger.debug("\(line, privacy: .public)")
    }
```
Add, near the other stored properties:
```swift
    /// Optional off-device stream. Set from Diagnostics when remote logging is enabled;
    /// nil disables forwarding. Each recorded line is also sent here.
    private var remote: RemoteLogSink?

    func setRemote(_ sink: RemoteLogSink?) {
        remote?.stop()
        remote = sink
    }
```
And append, as the LAST line inside `log()` (after `logger.debug(...)`):
```swift
        remote?.send(line)
```

- [ ] **Step 2: Verify (macOS CI)** — commit; Task 9 gate.

- [ ] **Step 3: Commit**

```bash
git add App/DebugLog.swift
git commit -m "feat(app): DebugLog forwards lines to RemoteLogSink"
```

---

## Task 6: Diagnostics UI — streaming controls + keystroke nag (App, macOS-CI-only)

> **Not Linux-buildable.** macOS CI is the gate.

**Files:**
- Modify: `App/DiagnosticsSettingsView.swift`

**Interfaces:**
- Consumes: `RemoteLogConfig` (Task 3), `LogTransport` (Task 1), `RemoteLogSink` (Task 4), `DebugLog` (Task 5).
- Produces: UI that binds the config keys, (re)builds the sink on change via `DebugLog.shared.setRemote`, exposes a Test button, and gates keystroke content behind a confirm dialog.

- [ ] **Step 1: Implement the extended view**

Replace `App/DiagnosticsSettingsView.swift` body with the streaming controls added below the existing panel toggle:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// Settings → Diagnostics. Gates the on-screen debug panel AND the off-device log stream.
struct DiagnosticsSettingsView: View {
    static let showDebugPanelKey = "diagnostics.showDebugPanel"
    @AppStorage(Self.showDebugPanelKey) private var showDebugPanel = false

    @AppStorage(RemoteLogConfig.enabledKey) private var remoteEnabled = false
    @AppStorage(RemoteLogConfig.hostKey) private var remoteHost = ""
    @AppStorage(RemoteLogConfig.portKey) private var remotePort = RemoteLogConfig.defaultPort
    @AppStorage(RemoteLogConfig.transportKey) private var transportRaw = RemoteLogConfig.defaultTransport.rawValue
    @AppStorage(RemoteLogConfig.keystrokeContentKey) private var keystrokeContent = false

    @State private var testResult: String?
    @State private var showKeystrokeNag = false

    private var transport: LogTransport { LogTransport(rawValue: transportRaw) ?? .tls }

    var body: some View {
        List {
            Section {
                Toggle("Show debug log panel", isOn: $showDebugPanel)
                    .onChange(of: showDebugPanel) { _, on in DebugLog.shared.enabled = on }
            } footer: {
                Text("Adds a 🐞 button in a connected session that opens a scrollable "
                     + "diagnostic log with a Copy button. For troubleshooting; leave off for normal use.")
            }

            Section("Stream logs to a server") {
                Toggle("Enable remote log stream", isOn: $remoteEnabled)
                    .onChange(of: remoteEnabled) { _, _ in rebuildSink() }
                if remoteEnabled {
                    TextField("Host", text: $remoteHost)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onChange(of: remoteHost) { _, _ in rebuildSink() }
                    TextField("Port", value: $remotePort, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                        .onChange(of: remotePort) { _, _ in rebuildSink() }
                    Picker("Transport", selection: $transportRaw) {
                        Text("UDP (514)").tag(LogTransport.udp.rawValue)
                        Text("TCP (514)").tag(LogTransport.tcp.rawValue)
                        Text("TLS (6514)").tag(LogTransport.tls.rawValue)
                    }
                    .onChange(of: transportRaw) { _, _ in rebuildSink() }
                    Button("Test connection") { runTest() }
                    if let testResult { Text(testResult).font(.footnote).foregroundStyle(.secondary) }
                }
            } footer: {
                Text("Streams the verbose diagnostic trace off-device as RFC 5424 syslog. "
                     + "Receiver setup: see tools/syslog-sink (docker compose up). "
                     + "TLS uses a self-signed cert (verification off).")
            }

            Section {
                Toggle("Log keystroke content", isOn: $keystrokeContent)
                    .onChange(of: keystrokeContent) { _, on in
                        if on { keystrokeContent = false; showKeystrokeNag = true }  // require confirm
                    }
            } footer: {
                Text("Off: only structural key events (lengths, backspace) are logged. On: the "
                     + "actual keys are logged too — password/prompt lines are still redacted "
                     + "(shown as REDACTED, never dropped). Off by default.")
            }
        }
        .navigationTitle("Diagnostics")
        .onAppear { DebugLog.shared.enabled = showDebugPanel; rebuildSink() }
        .confirmationDialog("Log keystroke content?", isPresented: $showKeystrokeNag, titleVisibility: .visible) {
            Button("Turn On", role: .destructive) { keystrokeContent = true }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Diagnostic traces will include the actual keys you type, including anything "
                 + "sensitive, and stream to your configured host if remote logging is on. "
                 + "Password/prompt lines are still redacted.")
        }
    }

    /// Recreate the sink from current config, or clear it when disabled/host empty.
    private func rebuildSink() {
        guard remoteEnabled, !remoteHost.isEmpty else { DebugLog.shared.setRemote(nil); return }
        DebugLog.shared.setRemote(RemoteLogSink(host: remoteHost, port: remotePort, transport: transport))
    }

    private func runTest() {
        guard !remoteHost.isEmpty else { testResult = "Enter a host first."; return }
        testResult = "Testing…"
        let sink = RemoteLogSink(host: remoteHost, port: remotePort, transport: transport)
        sink.test { ok in
            DispatchQueue.main.async { testResult = ok ? "✓ Connected" : "✗ Failed" }
        }
    }
}
```

**Implementer note:** the keystroke toggle uses the "reset + confirm" pattern (set back to false, present the dialog, only the dialog's Turn On sets it true) so enabling always requires the nag. Verify the `@AppStorage(Int)` `TextField(value:format:)` binding compiles on the CI SDK; if not, bind via a `String` proxy.

- [ ] **Step 2: Verify (macOS CI)** — commit; Task 9 gate.

- [ ] **Step 3: Commit**

```bash
git add App/DiagnosticsSettingsView.swift
git commit -m "feat(app): Diagnostics UI — remote stream controls + keystroke nag"
```

---

## Task 7: Instrumentation call sites (App, macOS-CI-only)

> **Not Linux-buildable.** macOS CI is the gate. This is the payload — verbose, inclusive.

**Files:**
- Modify: `App/TerminalGestureController.swift`, `App/TerminalScreen.swift`, `App/TmuxPaneContainer.swift`, `App/ConnectionViewModel.swift`

**Interfaces:**
- Consumes: `DebugLog.shared.log(...)` (existing), `keystrokeLogDecision(...)` (Task 2), the password-line flag from `PasswordEntryDetector` where available, `RemoteLogConfig.keystrokeContentKey`.
- Produces: verbose trace lines (no new public API).

**MainActor note:** several of these sites are `@objc`/nonisolated gesture handlers or delegate callbacks. `DebugLog.shared` is `@MainActor`. Wrap those calls in `MainActor.assumeIsolated { DebugLog.shared.log(...) }` (the established idiom — see `TerminalScreen.swift:287`). `TerminalGestureController` is already `@MainActor`, so its handlers can call directly.

- [ ] **Step 1: Gesture lifecycle in `TerminalGestureController`**

In each `@objc` handler (`handleScrollViewPan`, `handleSingleTap`, `handleDoubleTap`, `handleTripleTap`, `handleLongPress`, `handleTwoFingerTap`) add a log at entry with state + geometry. Example for the pan (add as the first line after the mouse-reporting guard):
```swift
        DebugLog.shared.log("gr:scrollPan state=\(g.state.rawValue) t=\(g.translation(in: view)) mouseReporting=\(callbacks.mouseReportingActive())")
```
And in `handleSingleTap`/`handleDoubleTap`/`handleTripleTap`/`handleLongPress`/`handleTwoFingerTap`, at entry:
```swift
        DebugLog.shared.log("gr:\(#function) state=\(g.state.rawValue) loc=\(g.location(in: view))")
```
In `disableSwiftTermRecognizers`, log the count disabled and whether the native pan was preserved:
```swift
        DebugLog.shared.log("sweep: disabled \(view.gestureRecognizers?.filter { !$0.isEnabled }.count ?? 0) recognizers; nativePan kept=\(view.panGestureRecognizer.isEnabled)")
```

- [ ] **Step 2: Selection logging in `TerminalGestureController`**

Around `setSelectionRange`/`presentEditMenu` in `handleDoubleTap`/`handleTripleTap`, log before/after:
```swift
        DebugLog.shared.log("sel:before hasActive=\(view.hasActiveSelection)")
        view.setSelectionRange(start: Position(col: start, row: row), end: Position(col: end, row: row))
        DebugLog.shared.log("sel:after set (\(start),\(row))-(\(end),\(row)) hasActive=\(view.hasActiveSelection)")
```
(Apply the same `sel:before`/`sel:after` pattern in triple-tap.)

- [ ] **Step 3: Scroll / contentOffset in `TerminalScreen` + `TmuxPaneContainer`**

Where the terminal is configured (raw mount `makeUIView` in `TerminalScreen.swift`, tmux `installHalo` in `TmuxPaneContainer.swift`), after installing the gesture controller, log the scroll state once:
```swift
        MainActor.assumeIsolated {
            DebugLog.shared.log("scroll:init isScrollEnabled=\(terminal.isScrollEnabled) nativePan=\(terminal.panGestureRecognizer.isEnabled) contentSize=\(terminal.contentSize) offset=\(terminal.contentOffset)")
        }
```
(In the tmux mount use the per-pane `view` in place of `terminal`.)

- [ ] **Step 4: Key input logging (structural + gated content) in `TerminalScreen.Coordinator.send`**

`Coordinator.send(source:data:)` (line ~292) already logs `send[..]`. Extend it to classify the bytes and honor the keystroke gate. Replace the existing `DebugLog` call in `send` with:
```swift
            MainActor.assumeIsolated {
                let logContent = UserDefaults.standard.bool(forKey: RemoteLogConfig.keystrokeContentKey)
                let isBackspace = data.count == 1 && (data.first == 0x7f || data.first == 0x08)
                let event = isBackspace ? "deleteBackward" : "insertText"
                // Best-effort content as UTF-8 for the gate; password-line flag from the VM if reachable.
                let content = String(decoding: Array(data), as: UTF8.self)
                let isPwd = false   // wired to the detector in the VM path below when available
                DebugLog.shared.log("key:\(keystrokeLogDecision(event: event, content: content, logContent: logContent, isPasswordLine: isPwd))")
            }
```
And in `TerminalScreen`'s `handleRestoreTap`/first-responder path, log responder changes:
```swift
                MainActor.assumeIsolated { DebugLog.shared.log("key:firstResponder becomeFirstResponder=\(ok) isFirstResponder=\(terminal.isFirstResponder)") }
```

**Implementer note:** the password-line flag (`isPwd`) is best sourced from the VM's `passwordDetector`. If exposing it cleanly to `Coordinator.send` is awkward, add a `ConnectionViewModel` method `currentLineIsPassword() -> Bool` (reading `passwordDetector.shouldLearnCommittedLine() == false`) and call it here via the coordinator's VM reference; otherwise leave `isPwd = false` (redaction still applies whenever the detector-backed VM path logs keys). Prefer wiring it; document if you can't.

- [ ] **Step 5: Window-switch + tmux redraw in `ConnectionViewModel` + `TmuxPaneContainer`**

In `ConnectionViewModel.selectWindow` / `selectAdjacentWindowClamped`, log the request + resulting active window:
```swift
    func selectWindow(_ id: WindowID) {
        DebugLog.shared.log("win:select id=\(id) activeBefore=\(String(describing: tmuxState?.activeWindow))")
        tmux?.selectWindow(id)
    }
```
In `TmuxPaneContainer` where it re-renders on a tmux state change (the container's `updateUIView`/render path), log the active window + pane count so a "switched but didn't redraw" shows up:
```swift
        MainActor.assumeIsolated {
            DebugLog.shared.log("tmux:render active=\(String(describing: state.activeWindow)) windows=\(state.windows.count) panes=\(state.windows.first { $0.id == state.activeWindow }?.visibleLayout?.paneCount ?? -1)")
        }
```
**Implementer note:** use whatever the real pane-count accessor is on `PaneLayout` (check `PaneLayout.swift`); if there's no `paneCount`, log the layout description instead. Keep it a single verbose line.

- [ ] **Step 6: Verify (macOS CI)** — commit; Task 9 gate.

- [ ] **Step 7: Commit**

```bash
git add App/TerminalGestureController.swift App/TerminalScreen.swift App/TmuxPaneContainer.swift App/ConnectionViewModel.swift
git commit -m "feat(app): verbose gesture/selection/key/scroll/tmux instrumentation"
```

---

## Task 8: `tools/syslog-sink/` docker-compose receiver

**Files:**
- Create: `tools/syslog-sink/docker-compose.yml`, `tools/syslog-sink/README.md`, `tools/syslog-sink/syslog-ng.conf`

**Interfaces:** none (repo tooling). Produces a one-command TLS syslog listener writing to `./logs/semicolyn.log`.

- [ ] **Step 1: Write the compose + config**

Create `tools/syslog-sink/syslog-ng.conf`:
```
@version: 4.0
source s_net {
    network(transport("udp") port(514));
    network(transport("tcp") port(514) flags(no-parse));
    network(transport("tls") port(6514) flags(no-parse)
        tls(key-file("/etc/syslog-ng/cert/key.pem")
            cert-file("/etc/syslog-ng/cert/cert.pem")
            peer-verify(optional-untrusted)));
};
destination d_file { file("/var/log/semicolyn/semicolyn.log"); };
log { source(s_net); destination(d_file); };
```

Create `tools/syslog-sink/docker-compose.yml`:
```yaml
# SPDX-License-Identifier: GPL-3.0-only
services:
  syslog:
    image: balabit/syslog-ng:4.8.0
    command: ["--foreground", "-f", "/etc/syslog-ng/syslog-ng.conf"]
    ports:
      - "514:514/udp"
      - "514:514/tcp"
      - "6514:6514/tcp"
    volumes:
      - ./syslog-ng.conf:/etc/syslog-ng/syslog-ng.conf:ro
      - ./cert:/etc/syslog-ng/cert:ro
      - ./logs:/var/log/semicolyn
```

Create `tools/syslog-sink/README.md`:
```markdown
# semicolyn diagnostics syslog sink

One-command TLS/TCP/UDP syslog receiver for the app's remote diagnostics stream
(Settings → Diagnostics → Stream logs to a server).

## Setup
1. Generate a self-signed cert (the app skips verification):
       mkdir -p cert logs
       openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
         -keyout cert/key.pem -out cert/cert.pem -subj "/CN=semicolyn-diag"
2. Start it:
       docker compose up
3. In the app: Diagnostics → set Host to this machine's IP, Transport = TLS, Port 6514.
4. Watch the trace:
       tail -f logs/semicolyn.log

UDP/TCP on 514 also work (Transport = UDP/TCP) for quick tests without certs.
```

- [ ] **Step 2: Sanity-check the compose file parses**

Run: `cd tools/syslog-sink && docker compose config >/dev/null && echo OK`
Expected: `OK` (compose file is valid YAML/schema). Do NOT need to actually run the container in CI.

- [ ] **Step 3: Ensure `logs/` and `cert/` are gitignored**

Add to `.gitignore` if not covered:
```
tools/syslog-sink/logs/
tools/syslog-sink/cert/
```

- [ ] **Step 4: Commit**

```bash
git add tools/syslog-sink/docker-compose.yml tools/syslog-sink/syslog-ng.conf tools/syslog-sink/README.md .gitignore
git commit -m "feat(tools): syslog-sink docker-compose receiver for diagnostics stream"
```

---

## Task 9: Push, macOS CI, PR, TestFlight

**Files:** none.

- [ ] **Step 1: Full Linux Kit suite (pure tasks)**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS — `SyslogFrameTests` (7) + `KeystrokeLogDecisionTests` (6) green; nothing else broken.

- [ ] **Step 2: Push + PR**

```bash
git push github feat/remote-diagnostics
gh pr create --repo ds7n/semicolyn --title "feat: remote diagnostics streaming + gesture/input instrumentation" --body "Verbose gesture/selection/key/scroll/tmux trace streamed as RFC 5424 syslog (UDP/TCP/TLS) to a developer sink, to fix the on-device gesture failures from evidence. Pure syslogFrame + redaction (Linux-tested); NWConnection sink + UI + instrumentation (macOS-CI-gated). Keystroke content off-by-default with nag + password-line redaction. Includes tools/syslog-sink compose.

https://claude.ai/code/session_01VxDe5tUsrrkhgX9SSADJPp"
```

- [ ] **Step 3: Wait for macOS CI (the App-tier gate)**

Run: `gh pr checks <PR#> --repo ds7n/semicolyn` until `macos` is `pass`. Fix any isolation/API mismatch (esp. `NWProtocolTLS` verify-block, `@AppStorage(Int)` TextField, `MainActor.assumeIsolated` around `DebugLog` in nonisolated handlers) and re-push.

- [ ] **Step 4: Merge + dispatch TestFlight**

After green + user approval: squash-merge, sync main, dispatch `release-testflight.yml` on main. That build lets the user turn on streaming and capture the real gesture trace.

---

## Self-Review

**Spec coverage:**
- Transport UDP/TCP/TLS + RFC 5424 framing → Task 1 (`syslogFrame`) + Task 4 (`RemoteLogSink` parameters). ✓
- Keystroke gating (off=structural / on=content+redaction / no-raw / visible marker) → Task 2 (`keystrokeLogDecision`) + Task 6 (nag) + Task 7 step 4. ✓
- Config keys + Diagnostics UI + Test button + docker link → Task 3 + Task 6. ✓
- DebugLog forwards to sink → Task 5. ✓
- Instrumentation: gesture/selection/key/scroll/window-switch → Task 7 (all five). ✓
- Fire-and-forget, never blocks; TLS cert-verify off; Test-only error surfacing → Task 4. ✓
- `tools/syslog-sink/` compose receiver → Task 8. ✓
- Testing: pure framing + pure redaction Linux-tested; sink/UI/instrumentation device → Tasks 1,2 (Linux) + Task 9 (CI/device). ✓

**Placeholder scan:** no TBD/"add error handling"/"similar to Task N". Three implementer notes (password-line flag wiring, `PaneLayout` pane-count accessor, `@AppStorage(Int)` TextField) are genuine "verify the real signature on macOS CI" seams with a stated fallback — not vague requirements.

**Type consistency:** `LogTransport` (Task 1) used in Tasks 3,4,6. `syslogFrame(message:hostname:timestamp:transport:)` (Task 1) called in Task 4. `keystrokeLogDecision(event:content:logContent:isPasswordLine:)` (Task 2) called in Task 7 step 4. `RemoteLogConfig.*Key` (Task 3) used in Tasks 5? (no — used in Task 6 UI + Task 7 key gate) and Task 6. `RemoteLogSink(host:port:transport:)` + `.send`/`.test`/`.stop` (Task 4) used in Tasks 5,6. `DebugLog.setRemote(_:)` (Task 5) called in Task 6. Consistent.
