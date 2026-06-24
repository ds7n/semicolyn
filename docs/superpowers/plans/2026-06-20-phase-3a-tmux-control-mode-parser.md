# Phase 3a — tmux control-mode parser Implementation Plan

**Status:** Complete — 49 tests green (`swift test`); parser on `master`. A code review caught a fail-open octal-digit validation bug (non-ASCII Unicode numerics), fixed before merge.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a pure, streaming Swift parser that turns the `tmux -CC` control-mode byte stream into typed `ControlModeEvent`s for the native pane/window model.

**Architecture:** A parser-only unit in `NeotildeKit` (no I/O, no command-sending). `ControlModeParser.feed([UInt8]) -> [ControlModeEvent]` buffers partial lines and emits one or more typed events per complete line. Sub-units: typed ID wrappers, an octal `%output` decoder, and a recursive-descent layout-string scanner. Lenient and never-throwing.

**Tech Stack:** Swift 6 (`NeotildeKit`, platform-agnostic), XCTest, run on Linux via `docker compose run --rm dev swift test`.

## Global Constraints

- Every source/test file begins with `// SPDX-FileCopyrightText: 2026 True Positive LLC` then `// SPDX-License-Identifier: GPL-3.0-only`.
- Spec of record: `docs/superpowers/specs/2026-06-20-tmux-control-mode-parser-design.md`.
- Placement: Swift in `Sources/NeotildeKit/Tmux/`. No Apple-only APIs (must compile + test on Linux).
- Error policy: **lenient, never-throw** — no `throws`, no `fatalError`, no `precondition` on input. Unknown verb → `.unknown`; recoverable parse failure → `.malformed`.
- Public model types are `Equatable, Sendable`; ID types also `Hashable`.
- Testing tier: **Critical** (protocol boundary over untrusted bytes) — EP + BVA + adversarial; every assertion checks the exact event/payload, never merely "did not crash".
- Conventional commits; commit after every green step. Work on a branch `feat/phase-3a-tmux-parser`; squash-merge at the end.
- Test command (all tasks): `docker compose run --rm dev swift test --filter <TestClassName>`.

---

### Task 0: Branch

- [ ] **Step 1: Create the feature branch**

Run:
```bash
git checkout -b feat/phase-3a-tmux-parser
```

---

### Task 1: Typed tmux ID wrappers

**Files:**
- Create: `Sources/NeotildeKit/Tmux/TmuxIDs.swift`
- Test: `Tests/NeotildeKitTests/TmuxIDTests.swift`

**Interfaces:**
- Produces: `PaneID(raw: UInt32)`, `WindowID(raw: UInt32)`, `SessionID(raw: UInt32)` — each `Hashable, Sendable`. Internal failable `init?(token: Substring)` parsing `%N` / `@N` / `$N` respectively (nil if the sigil is wrong or the remainder is not all decimal digits).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/NeotildeKitTests/TmuxIDTests.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

final class TmuxIDTests: XCTestCase {
    func testPaneIDParsesValidToken() {
        XCTAssertEqual(PaneID(token: "%7"), PaneID(raw: 7))
    }
    func testWindowIDParsesValidToken() {
        XCTAssertEqual(WindowID(token: "@0"), WindowID(raw: 0))
    }
    func testSessionIDParsesValidToken() {
        XCTAssertEqual(SessionID(token: "$13"), SessionID(raw: 13))
    }
    func testWrongSigilIsRejected() {
        XCTAssertNil(PaneID(token: "@7"))   // pane needs %
        XCTAssertNil(WindowID(token: "%0")) // window needs @
    }
    func testNonNumericRemainderIsRejected() {
        XCTAssertNil(PaneID(token: "%x"))
        XCTAssertNil(PaneID(token: "%"))    // empty remainder
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose run --rm dev swift test --filter TmuxIDTests`
Expected: FAIL — `cannot find 'PaneID' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/NeotildeKit/Tmux/TmuxIDs.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public struct PaneID: Hashable, Sendable {
    public let raw: UInt32
    public init(raw: UInt32) { self.raw = raw }
}
public struct WindowID: Hashable, Sendable {
    public let raw: UInt32
    public init(raw: UInt32) { self.raw = raw }
}
public struct SessionID: Hashable, Sendable {
    public let raw: UInt32
    public init(raw: UInt32) { self.raw = raw }
}

private func parseSigiled(_ token: Substring, _ sigil: Character) -> UInt32? {
    guard token.first == sigil else { return nil }
    let rest = token.dropFirst()
    guard !rest.isEmpty, rest.allSatisfy(\.isNumber), let n = UInt32(rest) else { return nil }
    return n
}

extension PaneID {
    init?(token: Substring) {
        guard let n = parseSigiled(token, "%") else { return nil }
        self.init(raw: n)
    }
}
extension WindowID {
    init?(token: Substring) {
        guard let n = parseSigiled(token, "@") else { return nil }
        self.init(raw: n)
    }
}
extension SessionID {
    init?(token: Substring) {
        guard let n = parseSigiled(token, "$") else { return nil }
        self.init(raw: n)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `docker compose run --rm dev swift test --filter TmuxIDTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/NeotildeKit/Tmux/TmuxIDs.swift Tests/NeotildeKitTests/TmuxIDTests.swift
git commit -m "feat: add typed tmux ID wrappers (pane/window/session)"
```

---

### Task 2: `%output` octal unescaping

**Files:**
- Create: `Sources/NeotildeKit/Tmux/OutputUnescape.swift`
- Test: `Tests/NeotildeKitTests/OutputUnescapeTests.swift`

**Interfaces:**
- Produces: `func unescapeTmuxOutput(_ s: Substring) -> [UInt8]?` — decodes tmux's `%output` data field. `\\` → one `0x5C`; `\` + exactly three octal digits (value ≤ 255) → that byte; any other printable char → its UTF-8 bytes. Returns nil on a malformed escape (lone trailing `\`, non-octal triplet, value > 255).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/NeotildeKitTests/OutputUnescapeTests.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

final class OutputUnescapeTests: XCTestCase {
    func testPlainAsciiPassesThrough() {
        XCTAssertEqual(unescapeTmuxOutput("hello"), Array("hello".utf8))
    }
    func testEmptyIsEmpty() {
        XCTAssertEqual(unescapeTmuxOutput(""), [])
    }
    func testOctalEscapeDecodesToByte() {
        // \033 == ESC (0x1B), \015 == CR, \012 == LF
        XCTAssertEqual(unescapeTmuxOutput("\\033[0m"), [0x1B, 0x5B, 0x30, 0x6D])
        XCTAssertEqual(unescapeTmuxOutput("a\\015\\012"), [0x61, 0x0D, 0x0A])
    }
    func testEscapedBackslash() {
        XCTAssertEqual(unescapeTmuxOutput("a\\\\b"), [0x61, 0x5C, 0x62])
    }
    func testMaxOctalValue() {
        XCTAssertEqual(unescapeTmuxOutput("\\377"), [0xFF])
    }
    func testLoneTrailingBackslashIsMalformed() {
        XCTAssertNil(unescapeTmuxOutput("abc\\"))
    }
    func testNonOctalTripletIsMalformed() {
        XCTAssertNil(unescapeTmuxOutput("\\09a")) // 9 is not an octal digit
    }
    func testOutOfRangeOctalIsMalformed() {
        XCTAssertNil(unescapeTmuxOutput("\\400")) // 256 > 255
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose run --rm dev swift test --filter OutputUnescapeTests`
Expected: FAIL — `cannot find 'unescapeTmuxOutput' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/NeotildeKit/Tmux/OutputUnescape.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Decodes a tmux `%output` data field. tmux escapes `\` as `\\` and any
/// non-passthrough byte as `\` + three octal digits. Returns nil on a malformed
/// escape so the caller can surface a `.malformed` event.
func unescapeTmuxOutput(_ s: Substring) -> [UInt8]? {
    let chars = Array(s)
    var out: [UInt8] = []
    out.reserveCapacity(chars.count)
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if c != "\\" {
            out.append(contentsOf: String(c).utf8)
            i += 1
            continue
        }
        // c == backslash: need an escape body.
        guard i + 1 < chars.count else { return nil }
        if chars[i + 1] == "\\" {
            out.append(0x5C)
            i += 2
            continue
        }
        guard i + 3 < chars.count, let byte = octalByte(chars[i + 1], chars[i + 2], chars[i + 3]) else {
            return nil
        }
        out.append(byte)
        i += 4
    }
    return out
}

/// Three octal digit characters → one byte, or nil if any is not an octal digit
/// or the value exceeds 255.
private func octalByte(_ a: Character, _ b: Character, _ c: Character) -> UInt8? {
    func digit(_ ch: Character) -> Int? {
        guard let v = ch.wholeNumberValue, (0...7).contains(v) else { return nil }
        return v
    }
    guard let x = digit(a), let y = digit(b), let z = digit(c) else { return nil }
    let value = x * 64 + y * 8 + z
    guard value <= 255 else { return nil }
    return UInt8(value)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `docker compose run --rm dev swift test --filter OutputUnescapeTests`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/NeotildeKit/Tmux/OutputUnescape.swift Tests/NeotildeKitTests/OutputUnescapeTests.swift
git commit -m "feat: add tmux %output octal unescaping"
```

---

### Task 3: Layout-string parser

**Files:**
- Create: `Sources/NeotildeKit/Tmux/PaneLayout.swift`
- Test: `Tests/NeotildeKitTests/PaneLayoutTests.swift`

**Interfaces:**
- Consumes: `PaneID` (Task 1).
- Produces: `Geometry(w:h:x:y:)` (`UInt16` fields, `Equatable, Sendable`); `PaneLayout` (`indirect enum`, `Equatable, Sendable`) with cases `.leaf(PaneID, Geometry)`, `.columns([PaneLayout], Geometry)`, `.rows([PaneLayout], Geometry)`; and `static func PaneLayout.parse(_ input: some StringProtocol) -> PaneLayout?` (accepts String/Substring/literal; nil on any grammar error; leading 4-hex checksum ignored).

**Swift note:** in tests, anchor multi-node expected values in an explicitly-typed local (`let expected: PaneLayout = .columns([...], ...)`) — Swift can't infer deeply-nested `.case` array literals passed straight into `XCTAssertEqual`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/NeotildeKitTests/PaneLayoutTests.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

final class PaneLayoutTests: XCTestCase {
    func testSingleLeaf() {
        // checksum,80x24,0,0,1
        let layout = PaneLayout.parse("bc62,80x24,0,0,1")
        XCTAssertEqual(layout, .leaf(PaneID(raw: 1), Geometry(w: 80, h: 24, x: 0, y: 0)))
    }
    func testTwoColumnSplit() {
        let layout = PaneLayout.parse("e5e4,80x24,0,0{40x24,0,0,1,39x24,41,0,2}")
        XCTAssertEqual(layout, .columns([
            .leaf(PaneID(raw: 1), Geometry(w: 40, h: 24, x: 0, y: 0)),
            .leaf(PaneID(raw: 2), Geometry(w: 39, h: 24, x: 41, y: 0)),
        ], Geometry(w: 80, h: 24, x: 0, y: 0)))
    }
    func testTwoRowSplit() {
        let layout = PaneLayout.parse("aaaa,80x24,0,0[80x12,0,0,1,80x11,0,13,2]")
        XCTAssertEqual(layout, .rows([
            .leaf(PaneID(raw: 1), Geometry(w: 80, h: 12, x: 0, y: 0)),
            .leaf(PaneID(raw: 2), Geometry(w: 80, h: 11, x: 0, y: 13)),
        ], Geometry(w: 80, h: 24, x: 0, y: 0)))
    }
    func testNestedSplit() {
        // a column whose second child is a row split
        let s = "bbbb,80x24,0,0{40x24,0,0,1,39x24,41,0[39x12,41,0,2,39x11,41,13,3]}"
        let layout = PaneLayout.parse(s)
        XCTAssertEqual(layout, .columns([
            .leaf(PaneID(raw: 1), Geometry(w: 40, h: 24, x: 0, y: 0)),
            .rows([
                .leaf(PaneID(raw: 2), Geometry(w: 39, h: 12, x: 41, y: 0)),
                .leaf(PaneID(raw: 3), Geometry(w: 39, h: 11, x: 41, y: 13)),
            ], Geometry(w: 39, h: 24, x: 41, y: 0)),
        ], Geometry(w: 80, h: 24, x: 0, y: 0)))
    }
    func testUnbalancedBracketsIsNil() {
        XCTAssertNil(PaneLayout.parse("bc62,80x24,0,0{40x24,0,0,1"))
    }
    func testMissingChecksumIsNil() {
        XCTAssertNil(PaneLayout.parse("80x24,0,0,1")) // no leading checksum comma-field
            // NOTE: "80x24" before the first comma is treated as the (ignored)
            // checksum, leaving "0,0,1" which is not a valid node -> nil.
    }
    func testNonNumericFieldIsNil() {
        XCTAssertNil(PaneLayout.parse("bc62,80xZZ,0,0,1"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose run --rm dev swift test --filter PaneLayoutTests`
Expected: FAIL — `cannot find 'PaneLayout' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/NeotildeKit/Tmux/PaneLayout.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public struct Geometry: Equatable, Sendable {
    public let w, h, x, y: UInt16
    public init(w: UInt16, h: UInt16, x: UInt16, y: UInt16) {
        self.w = w; self.h = h; self.x = x; self.y = y
    }
}

public indirect enum PaneLayout: Equatable, Sendable {
    case leaf(PaneID, Geometry)
    case columns([PaneLayout], Geometry)   // {…} panes left→right
    case rows([PaneLayout], Geometry)      // […] panes top→bottom
}

extension PaneLayout {
    /// Parse a tmux layout string (`checksum,WxH,X,Y{…}`). The leading 4-hex
    /// checksum is parsed and ignored. Returns nil on any grammar violation.
    /// Accepts any string type (`String`, `Substring`, literal).
    public static func parse(_ input: some StringProtocol) -> PaneLayout? {
        let s = Substring(input)
        guard let comma = s.firstIndex(of: ",") else { return nil }
        var scanner = Scanner(s[s.index(after: comma)...])
        guard let node = scanner.node(), scanner.isAtEnd else { return nil }
        return node
    }

    /// Recursive-descent scanner over the layout body (checksum already stripped).
    private struct Scanner {
        private let chars: [Character]
        private var i = 0
        init(_ s: Substring) { chars = Array(s) }

        var isAtEnd: Bool { i == chars.count }
        private func peek() -> Character? { i < chars.count ? chars[i] : nil }
        private mutating func expect(_ c: Character) -> Bool {
            if peek() == c { i += 1; return true }
            return false
        }
        /// Read a run of decimal digits as UInt32 (nil if none).
        private mutating func number() -> UInt32? {
            var digits = ""
            while let c = peek(), c.isNumber { digits.append(c); i += 1 }
            return UInt32(digits)
        }
        /// A geometry dimension: a number that fits in UInt16.
        private mutating func dim() -> UInt16? {
            guard let n = number(), let v = UInt16(exactly: n) else { return nil }
            return v
        }

        /// node := WxH,X,Y ( ,paneid | {list} | [list] )
        mutating func node() -> PaneLayout? {
            guard let w = dim(), expect("x"), let h = dim(),
                  expect(","), let x = dim(),
                  expect(","), let y = dim() else { return nil }
            let geo = Geometry(w: w, h: h, x: x, y: y)
            switch peek() {
            case "{": return list(open: "{", close: "}").map { .columns($0, geo) }
            case "[": return list(open: "[", close: "]").map { .rows($0, geo) }
            case ",":
                i += 1
                guard let pane = number() else { return nil }
                return .leaf(PaneID(raw: pane), geo)
            default:
                return nil
            }
        }

        /// list := open node (,node)* close
        private mutating func list(open: Character, close: Character) -> [PaneLayout]? {
            guard expect(open), let first = node() else { return nil }
            var nodes = [first]
            while expect(",") {
                guard let next = node() else { return nil }
                nodes.append(next)
            }
            guard expect(close) else { return nil }
            return nodes
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `docker compose run --rm dev swift test --filter PaneLayoutTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/NeotildeKit/Tmux/PaneLayout.swift Tests/NeotildeKitTests/PaneLayoutTests.swift
git commit -m "feat: add tmux layout-string parser (pane geometry tree)"
```

---

### Task 4: Event type + parser core (framing + notifications)

**Files:**
- Create: `Sources/NeotildeKit/Tmux/ControlModeEvent.swift`
- Create: `Sources/NeotildeKit/Tmux/ControlModeParser.swift`
- Test: `Tests/NeotildeKitTests/ControlModeParserTests.swift`

**Interfaces:**
- Consumes: `PaneID`/`WindowID`/`SessionID` (Task 1), `PaneLayout` (Task 3, referenced by the `.layoutChange` case but wired in Task 7).
- Produces:
  - `enum CommandOutcome: Equatable, Sendable { case ok([String]); case error([String]) }`
  - `enum ControlModeEvent: Equatable, Sendable` with all cases from the spec.
  - `final class ControlModeParser { init(); func feed(_ bytes: [UInt8]) -> [ControlModeEvent] }`.
- This task wires the simple one-line notifications (`%window-*`, `%session-*`, `%sessions-changed`, `%exit`), the `%begin`/`%end`/`%error` skeleton is added in Task 6, `%output` in Task 5, `%layout-change` in Task 7. For now `%begin`/`%output`/`%layout-change` fall through to `.unknown` (replaced in later tasks). Unknown verbs → `.unknown`; non-`%` lines → `.malformed`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/NeotildeKitTests/ControlModeParserTests.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

final class ControlModeParserTests: XCTestCase {
    private func feed(_ s: String) -> [ControlModeEvent] {
        ControlModeParser().feed(Array(s.utf8))
    }

    func testWindowAddAndClose() {
        XCTAssertEqual(feed("%window-add @3\n"), [.windowAdd(WindowID(raw: 3))])
        XCTAssertEqual(feed("%window-close @3\n"), [.windowClose(WindowID(raw: 3))])
        XCTAssertEqual(feed("%unlinked-window-close @3\n"), [.windowClose(WindowID(raw: 3))])
    }
    func testWindowRenamedKeepsSpaces() {
        XCTAssertEqual(feed("%window-renamed @1 my long name\n"),
                       [.windowRenamed(WindowID(raw: 1), name: "my long name")])
    }
    func testWindowPaneChanged() {
        XCTAssertEqual(feed("%window-pane-changed @1 %5\n"),
                       [.windowPaneChanged(WindowID(raw: 1), active: PaneID(raw: 5))])
    }
    func testSessionEvents() {
        XCTAssertEqual(feed("%session-changed $0 main\n"),
                       [.sessionChanged(SessionID(raw: 0), name: "main")])
        XCTAssertEqual(feed("%session-window-changed $0 @2\n"),
                       [.sessionWindowChanged(SessionID(raw: 0), active: WindowID(raw: 2))])
        XCTAssertEqual(feed("%sessions-changed\n"), [.sessionsChanged])
    }
    func testExitWithAndWithoutReason() {
        XCTAssertEqual(feed("%exit\n"), [.exit(reason: nil)])
        XCTAssertEqual(feed("%exit server exited unexpectedly\n"),
                       [.exit(reason: "server exited unexpectedly")])
    }
    func testUnknownVerbIsTolerated() {
        XCTAssertEqual(feed("%pause %0\n"), [.unknown(verb: "pause", raw: "%pause %0")])
    }
    func testNonNotificationLineIsMalformed() {
        XCTAssertEqual(feed("garbage line\n"),
                       [.malformed(raw: "garbage line", reason: "line does not start with %")])
    }
    func testMissingArgumentIsMalformed() {
        // %window-add with no @id
        if case .malformed = feed("%window-add\n").first {} else {
            XCTFail("expected .malformed for argument-less %window-add")
        }
    }
    func testCarriageReturnsAreStripped() {
        XCTAssertEqual(feed("%sessions-changed\r\n"), [.sessionsChanged])
    }
    func testPartialLineBuffersUntilNewline() {
        let parser = ControlModeParser()
        XCTAssertEqual(parser.feed(Array("%window-".utf8)), [])
        XCTAssertEqual(parser.feed(Array("add @9\n".utf8)), [.windowAdd(WindowID(raw: 9))])
    }
    func testMultipleEventsInOneFeed() {
        XCTAssertEqual(feed("%sessions-changed\n%window-add @1\n"),
                       [.sessionsChanged, .windowAdd(WindowID(raw: 1))])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose run --rm dev swift test --filter ControlModeParserTests`
Expected: FAIL — `cannot find 'ControlModeParser' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/NeotildeKit/Tmux/ControlModeEvent.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public enum CommandOutcome: Equatable, Sendable {
    case ok([String])
    case error([String])
}

public enum ControlModeEvent: Equatable, Sendable {
    case output(pane: PaneID, data: [UInt8])
    case commandResult(number: Int, outcome: CommandOutcome)
    case windowAdd(WindowID)
    case windowClose(WindowID)
    case windowRenamed(WindowID, name: String)
    case windowPaneChanged(WindowID, active: PaneID)
    case layoutChange(WindowID, layout: PaneLayout, visible: PaneLayout, flags: String)
    case sessionChanged(SessionID, name: String)
    case sessionWindowChanged(SessionID, active: WindowID)
    case sessionsChanged
    case exit(reason: String?)
    case unknown(verb: String, raw: String)
    case malformed(raw: String, reason: String)
}
```

```swift
// Sources/NeotildeKit/Tmux/ControlModeParser.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Streaming, never-throwing parser for the tmux `-CC` control-mode line
/// protocol. Feed it raw channel bytes; it buffers partial lines and returns the
/// typed events parsed from each complete line.
public final class ControlModeParser {
    private var buffer: [UInt8] = []

    public init() {}

    public func feed(_ bytes: [UInt8]) -> [ControlModeEvent] {
        buffer.append(contentsOf: bytes)
        var events: [ControlModeEvent] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            var lineBytes = Array(buffer[buffer.startIndex..<nl])
            buffer.removeSubrange(buffer.startIndex...nl)
            if lineBytes.last == 0x0D { lineBytes.removeLast() }
            let line = String(decoding: lineBytes, as: UTF8.self)
            events.append(contentsOf: parseLine(line))
        }
        return events
    }

    // MARK: - Line handling

    private func parseLine(_ line: String) -> [ControlModeEvent] {
        if let event = dispatch(line) { return [event] }
        return []
    }

    /// Dispatch a complete line to its handler. Returns nil only when the line is
    /// consumed without producing an event (none in this task; used by %begin
    /// once block handling lands in Task 6).
    private func dispatch(_ line: String) -> ControlModeEvent? {
        guard line.first == "%" else {
            return .malformed(raw: line, reason: "line does not start with %")
        }
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        let verb = parts[0]
        switch verb {
        case "%window-add":
            return single(line, parts) { WindowID(token: $0).map(ControlModeEvent.windowAdd) }
        case "%window-close", "%unlinked-window-close":
            return single(line, parts) { WindowID(token: $0).map(ControlModeEvent.windowClose) }
        case "%window-pane-changed":
            guard parts.count >= 3, let w = WindowID(token: parts[1]),
                  let p = PaneID(token: parts[2]) else {
                return .malformed(raw: line, reason: "bad %window-pane-changed")
            }
            return .windowPaneChanged(w, active: p)
        case "%window-renamed":
            guard parts.count >= 2, let w = WindowID(token: parts[1]) else {
                return .malformed(raw: line, reason: "bad %window-renamed")
            }
            return .windowRenamed(w, name: rest(line, after: parts[0], parts[1]))
        case "%session-changed":
            guard parts.count >= 2, let s = SessionID(token: parts[1]) else {
                return .malformed(raw: line, reason: "bad %session-changed")
            }
            return .sessionChanged(s, name: rest(line, after: parts[0], parts[1]))
        case "%session-window-changed":
            guard parts.count >= 3, let s = SessionID(token: parts[1]),
                  let w = WindowID(token: parts[2]) else {
                return .malformed(raw: line, reason: "bad %session-window-changed")
            }
            return .sessionWindowChanged(s, active: w)
        case "%sessions-changed":
            return .sessionsChanged
        case "%exit":
            let reason = line == "%exit" ? nil : String(line.dropFirst("%exit ".count))
            return .exit(reason: reason)
        default:
            return .unknown(verb: String(verb.dropFirst()), raw: line)
        }
    }

    // MARK: - Helpers

    /// A one-argument notification: `verb <token>`. Calls `make` with the token;
    /// a nil result (bad/missing token) becomes `.malformed`.
    private func single(_ line: String, _ parts: [Substring],
                        _ make: (Substring) -> ControlModeEvent?) -> ControlModeEvent {
        guard parts.count >= 2, let event = make(parts[1]) else {
            return .malformed(raw: line, reason: "bad \(parts[0])")
        }
        return event
    }

    /// Everything after `verb token ` — the free-form remainder (may be empty,
    /// may contain spaces). Used for window/session names.
    private func rest(_ line: String, after verb: Substring, _ token: Substring) -> String {
        let prefix = "\(verb) \(token) "
        guard line.count >= prefix.count else { return "" }
        return String(line.dropFirst(prefix.count))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `docker compose run --rm dev swift test --filter ControlModeParserTests`
Expected: PASS (11 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/NeotildeKit/Tmux/ControlModeEvent.swift Sources/NeotildeKit/Tmux/ControlModeParser.swift Tests/NeotildeKitTests/ControlModeParserTests.swift
git commit -m "feat: add tmux control-mode parser core (framing + notifications)"
```

---

### Task 5: `%output` handling

**Files:**
- Modify: `Sources/NeotildeKit/Tmux/ControlModeParser.swift` (add a `%output` case in `dispatch`)
- Test: `Tests/NeotildeKitTests/ControlModeOutputTests.swift`

**Interfaces:**
- Consumes: `unescapeTmuxOutput` (Task 2), `PaneID` (Task 1).
- Produces: `%output %<pane> <data>` → `.output(pane:data:)`; bad pane token or bad escape → `.malformed`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/NeotildeKitTests/ControlModeOutputTests.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

final class ControlModeOutputTests: XCTestCase {
    private func feed(_ s: String) -> [ControlModeEvent] {
        ControlModeParser().feed(Array(s.utf8))
    }

    func testOutputDecodesEscapedData() {
        // %output %1 hi\033[0m
        XCTAssertEqual(feed("%output %1 hi\\033[0m\n"),
                       [.output(pane: PaneID(raw: 1), data: Array("hi".utf8) + [0x1B, 0x5B, 0x30, 0x6D])])
    }
    func testOutputWithSpacesInData() {
        XCTAssertEqual(feed("%output %2 a b c\n"),
                       [.output(pane: PaneID(raw: 2), data: Array("a b c".utf8))])
    }
    func testOutputWithEmptyData() {
        XCTAssertEqual(feed("%output %2 \n"),
                       [.output(pane: PaneID(raw: 2), data: [])])
    }
    func testOutputBadEscapeIsMalformed() {
        if case .malformed = feed("%output %1 bad\\\n").first {} else {
            XCTFail("expected .malformed for a dangling backslash escape")
        }
    }
    func testOutputBadPaneIsMalformed() {
        if case .malformed = feed("%output @1 data\n").first {} else {
            XCTFail("expected .malformed for a non-pane id")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose run --rm dev swift test --filter ControlModeOutputTests`
Expected: FAIL — `%output` currently routes to `.unknown`, so equality assertions fail.

- [ ] **Step 3: Write minimal implementation**

In `dispatch(_:)`, add this case before `default:`:

```swift
        case "%output":
            // %output %<pane> <data> — data is the remainder and may contain spaces.
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, let pane = PaneID(token: fields[1]) else {
                return .malformed(raw: line, reason: "bad %output header")
            }
            guard let data = unescapeTmuxOutput(fields[2]) else {
                return .malformed(raw: line, reason: "bad %output escape")
            }
            return .output(pane: pane, data: data)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `docker compose run --rm dev swift test --filter ControlModeOutputTests`
Expected: PASS (5 tests). Also re-run `--filter ControlModeParserTests` → still PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/NeotildeKit/Tmux/ControlModeParser.swift Tests/NeotildeKitTests/ControlModeOutputTests.swift
git commit -m "feat: parse tmux %output into decoded pane bytes"
```

---

### Task 6: `%begin`/`%end`/`%error` block coalescing

**Files:**
- Modify: `Sources/NeotildeKit/Tmux/ControlModeParser.swift` (add open-block state + handling)
- Test: `Tests/NeotildeKitTests/ControlModeBlockTests.swift`

**Interfaces:**
- Produces: a `%begin N` … `%end N` block → one `.commandResult(N, .ok(bodyLines))`; `%error N` terminator → `.error`. While a block is open, every non-terminator line is a verbatim body line and emits no event. A terminator whose number ≠ the open block, or a terminator with no block open, → `.malformed`, and the parser resets to no-open-block.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/NeotildeKitTests/ControlModeBlockTests.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

final class ControlModeBlockTests: XCTestCase {
    private func feed(_ s: String) -> [ControlModeEvent] {
        ControlModeParser().feed(Array(s.utf8))
    }

    func testOkBlockCoalescesBodyLines() {
        let s = "%begin 1700000000 7 0\nline one\nline two\n%end 1700000000 7 0\n"
        XCTAssertEqual(feed(s), [.commandResult(number: 7, outcome: .ok(["line one", "line two"]))])
    }
    func testEmptyOkBlock() {
        let s = "%begin 1 4 0\n%end 1 4 0\n"
        XCTAssertEqual(feed(s), [.commandResult(number: 4, outcome: .ok([]))])
    }
    func testErrorBlock() {
        let s = "%begin 1 9 0\nno server running\n%error 1 9 0\n"
        XCTAssertEqual(feed(s), [.commandResult(number: 9, outcome: .error(["no server running"]))])
    }
    func testNotificationsSuppressedInsideBlock() {
        // A body line that itself looks like a notification stays a body line.
        let s = "%begin 1 2 0\n%window-add @4\n%end 1 2 0\n"
        XCTAssertEqual(feed(s), [.commandResult(number: 2, outcome: .ok(["%window-add @4"]))])
    }
    func testNumberMismatchIsMalformedAndResets() {
        let s = "%begin 1 2 0\nbody\n%end 1 3 0\n%sessions-changed\n"
        let events = feed(s)
        guard case .malformed = events.first else {
            return XCTFail("expected .malformed on number mismatch, got \(events)")
        }
        // After reset, the following notification parses normally.
        XCTAssertEqual(events.last, .sessionsChanged)
    }
    func testTerminatorWithNoOpenBlockIsMalformed() {
        if case .malformed = feed("%end 1 1 0\n").first {} else {
            XCTFail("expected .malformed for %end with no open block")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose run --rm dev swift test --filter ControlModeBlockTests`
Expected: FAIL — `%begin` currently routes to `.unknown`; no coalescing.

- [ ] **Step 3: Write minimal implementation**

Add the open-block state and rework `parseLine`. In `ControlModeParser`, add a stored property and a nested type:

```swift
    private var openBlock: OpenBlock?

    private struct OpenBlock {
        let number: Int
        var body: [String]
    }

    private enum BlockKind { case end, error }
```

Replace `parseLine(_:)` with:

```swift
    private func parseLine(_ line: String) -> [ControlModeEvent] {
        if openBlock != nil {
            return handleInsideBlock(line)
        }
        if line.hasPrefix("%begin ") {
            let parts = line.split(separator: " ")
            guard parts.count >= 3, let number = Int(parts[2]) else {
                return [.malformed(raw: line, reason: "bad %begin")]
            }
            openBlock = OpenBlock(number: number, body: [])
            return []
        }
        if let event = dispatch(line) { return [event] }
        return []
    }

    /// A line received while a command block is open. Only the matching
    /// terminator closes it; everything else is a verbatim body line.
    private func handleInsideBlock(_ line: String) -> [ControlModeEvent] {
        guard var block = openBlock else { return [] }
        if let (kind, number) = blockTerminator(line) {
            openBlock = nil
            guard number == block.number else {
                return [.malformed(raw: line, reason: "block number mismatch")]
            }
            let outcome: CommandOutcome = (kind == .end) ? .ok(block.body) : .error(block.body)
            return [.commandResult(number: number, outcome: outcome)]
        }
        block.body.append(line)
        openBlock = block
        return []
    }

    /// Recognise a `%end`/`%error` terminator line and pull its block number.
    private func blockTerminator(_ line: String) -> (BlockKind, Int)? {
        let parts = line.split(separator: " ")
        guard let verb = parts.first else { return nil }
        let kind: BlockKind
        if verb == "%end" { kind = .end }
        else if verb == "%error" { kind = .error }
        else { return nil }
        guard parts.count >= 3, let number = Int(parts[2]) else { return nil }
        return (kind, number)
    }
```

Also remove the now-unreachable `%end`/`%error` handling from `dispatch` if present (there is none in Task 4 — they fall to `.unknown` only when no block is open; with this change a bare terminator reaches `dispatch` and must be `.malformed`). Add to `dispatch(_:)` before `default:`:

```swift
        case "%end", "%error":
            return .malformed(raw: line, reason: "\(verb) with no open block")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `docker compose run --rm dev swift test --filter ControlModeBlockTests`
Expected: PASS (6 tests). Re-run `--filter ControlModeParserTests` and `--filter ControlModeOutputTests` → still PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/NeotildeKit/Tmux/ControlModeParser.swift Tests/NeotildeKitTests/ControlModeBlockTests.swift
git commit -m "feat: coalesce tmux %begin/%end/%error blocks into command results"
```

---

### Task 7: `%layout-change` handling

**Files:**
- Modify: `Sources/NeotildeKit/Tmux/ControlModeParser.swift` (add a `%layout-change` case)
- Test: `Tests/NeotildeKitTests/ControlModeLayoutTests.swift`

**Interfaces:**
- Consumes: `PaneLayout.parse` (Task 3), `WindowID` (Task 1).
- Produces: `%layout-change @<win> <layout> <visible-layout> <flags>` → `.layoutChange(win, layout:, visible:, flags:)`; a bad window id, missing field, or unparseable layout string → `.malformed`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/NeotildeKitTests/ControlModeLayoutTests.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

final class ControlModeLayoutTests: XCTestCase {
    private func feed(_ s: String) -> [ControlModeEvent] {
        ControlModeParser().feed(Array(s.utf8))
    }

    func testLayoutChangeParsesBothLayouts() {
        let s = "%layout-change @1 bc62,80x24,0,0,1 bc62,80x24,0,0,1 *\n"
        let leaf = PaneLayout.leaf(PaneID(raw: 1), Geometry(w: 80, h: 24, x: 0, y: 0))
        XCTAssertEqual(feed(s),
                       [.layoutChange(WindowID(raw: 1), layout: leaf, visible: leaf, flags: "*")])
    }
    func testLayoutChangeWithZoomedVisibleLayout() {
        // visible layout differs (a single zoomed pane)
        let s = "%layout-change @2 e5e4,80x24,0,0{40x24,0,0,1,39x24,41,0,2} bc62,80x24,0,0,1 Z\n"
        let split = PaneLayout.columns([
            .leaf(PaneID(raw: 1), Geometry(w: 40, h: 24, x: 0, y: 0)),
            .leaf(PaneID(raw: 2), Geometry(w: 39, h: 24, x: 41, y: 0)),
        ], Geometry(w: 80, h: 24, x: 0, y: 0))
        let zoomed = PaneLayout.leaf(PaneID(raw: 1), Geometry(w: 80, h: 24, x: 0, y: 0))
        XCTAssertEqual(feed(s),
                       [.layoutChange(WindowID(raw: 2), layout: split, visible: zoomed, flags: "Z")])
    }
    func testBadWindowIsMalformed() {
        if case .malformed = feed("%layout-change %1 bc62,80x24,0,0,1 bc62,80x24,0,0,1 *\n").first {} else {
            XCTFail("expected .malformed for non-window id")
        }
    }
    func testBadLayoutStringIsMalformed() {
        if case .malformed = feed("%layout-change @1 bc62,80x24,0,0{1 bc62,80x24,0,0,1 *\n").first {} else {
            XCTFail("expected .malformed for unparseable layout")
        }
    }
    func testMissingFieldIsMalformed() {
        if case .malformed = feed("%layout-change @1 bc62,80x24,0,0,1\n").first {} else {
            XCTFail("expected .malformed for missing visible-layout/flags")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose run --rm dev swift test --filter ControlModeLayoutTests`
Expected: FAIL — `%layout-change` currently routes to `.unknown`.

- [ ] **Step 3: Write minimal implementation**

In `dispatch(_:)`, add this case before `default:`:

```swift
        case "%layout-change":
            // %layout-change @<win> <layout> <visible-layout> <flags>
            let f = line.split(separator: " ", omittingEmptySubsequences: false)
            guard f.count >= 5, let win = WindowID(token: f[1]),
                  let layout = PaneLayout.parse(f[2]),
                  let visible = PaneLayout.parse(f[3]) else {
                return .malformed(raw: line, reason: "bad %layout-change")
            }
            return .layoutChange(win, layout: layout, visible: visible, flags: String(f[4]))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `docker compose run --rm dev swift test --filter ControlModeLayoutTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/NeotildeKit/Tmux/ControlModeParser.swift Tests/NeotildeKitTests/ControlModeLayoutTests.swift
git commit -m "feat: parse tmux %layout-change into a pane geometry tree"
```

---

### Task 8: Full-suite verification + merge

- [ ] **Step 1: Run the entire Swift suite**

Run: `docker compose run --rm dev swift test`
Expected: PASS — all NeotildeKit suites green (the original 20 Swift tests plus the new tmux tests).

- [ ] **Step 2: Confirm no regressions in the Rust crate is unnecessary (no Rust touched); skip.**

- [ ] **Step 3: Squash-merge to master**

```bash
git checkout master
git merge --squash feat/phase-3a-tmux-parser
git commit -m "Merge feat/phase-3a-tmux-parser: tmux -CC control-mode parser"
git branch -D feat/phase-3a-tmux-parser
```

- [ ] **Step 4: Update docs**

Mark this plan **Complete** in its header, and update the README status line to note Phase 3a (tmux control-mode parser) is done with its test count. Commit as `docs: sync project docs`.

---

## Self-review notes

- **Spec coverage:** placement (Task 1–7 in `Tmux/`), `feed` streaming + line buffering (Task 4), all message verbs (Tasks 4–7), block coalescing + mismatch/no-block malformed (Task 6), `%output` octal decode (Tasks 2, 5), layout tree incl. `{}`/`[]`/nested/checksum-ignored (Task 3), zoomed visible layout (Task 7), unknown-tolerant + never-throw (Task 4), Critical-tier exact-payload tests (every task). All spec sections map to a task.
- **Type consistency:** `ControlModeEvent`, `CommandOutcome`, `PaneID/WindowID/SessionID`, `Geometry`, `PaneLayout` and `PaneLayout.parse` / `unescapeTmuxOutput` signatures are used identically across tasks.
- **Deferred (per spec):** command-encoder/controller, SwiftTerm/SwiftUI, `%pause`/`%continue`/`%extended-output`/`%subscription-change`/`%client-*` (tolerated as `.unknown`).
