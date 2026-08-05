<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Eternal Terminal IDPASSKEY Parse Fix + Transport Diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the Eternal Terminal connect bug (`.malformedIDPASSKEY` on a valid server response) by matching upstream's tolerant fixed-window parse, and add an opt-in `transport` diagnostics category that logs the raw bootstrap payload with the credential masked, so this class of handshake bug is diagnosable without leaking the secret.

**Architecture:** Two pure Linux-tested Kit changes (the `parseETIDPASSKEY` fix + a `maskBootstrapPayload` helper) carry all the logic; the App tier adds a `transport` `LogCategory` (default off, auto-rendered toggle) and three `.transport` log calls in `ConnectionViewModel`. No new UI code (the Diagnostics screen renders categories from `LogCategory.allCases`).

**Tech Stack:** Swift 6 (SemicolynKit, strict-concurrency, Sendable, no UIKit/CryptoKit), the slice-1b `ETBootstrapError`/`ETCredential`/`sanitizeEndReason`, `DebugLog`/`LogCategory`, XCTest.

## Global Constraints

- **Every source file: two-line SPDX header** (`// SPDX-FileCopyrightText: 2026 True Positive LLC` / `// SPDX-License-Identifier: GPL-3.0-only`; `<!-- -->` for Markdown). REUSE-compliant.
- **No em-dash (U+2014) / en-dash (U+2013)** anywhere (code, comments, docs, commits).
- **`Sources/SemicolynKit/` is Linux-tested, Swift 6 strict-concurrency, `Sendable`:** no `import UIKit`/`SwiftUI`/`CryptoKit`. The parser fix + mask helper live here.
- **`App/` is Apple-only, macOS-CI-verified.** The `LogCategory` case + the `.transport` log calls do not compile on Linux.
- **THE CREDENTIAL IS A SECRET.** `maskBootstrapPayload` must NEVER emit the actual id/passkey characters. The fixed parser still handles a secret; do not add any log of the raw id/passkey.
- **The parser fix must still reject genuinely malformed input:** validate the fixed 49-char window's structure (slash at index 16) + charset (id/passkey alphanumeric) + length. It only becomes tolerant of content BEFORE/AFTER the 49-char window, not of a malformed window.
- **Upstream reference (authoritative):** `extern/eternaltermlib/extern/eternalterminal/src/terminal/SshSetupHandler.cpp:105` does `sshBuffer.substr(passKeyIndex + 10, 16 + 1 + 32)` then `split('/')`. Match this window semantics.
- **Tests real** (`docs/superpowers/specs/2026-06-18-testing-standards-design.md`): EP + BVA + adversarial. Both units are Critical tier (one parses a secret, one must not leak it). Assert exact values / the specific failure case; the mask tests assert the credential is ABSENT from the output.
- **Conventional commits**; commit after each green step; end every commit message with `Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt`.
- **Build/test:** Kit tests via `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter <Class>`. If Docker hits a `.build` permission error, fix once with `docker compose run --rm --user root dev bash -c "chown -R $(id -u):$(id -g) /work/.build"`. App tier is macOS-CI-only.
- **Spec:** `docs/superpowers/specs/2026-08-05-et-parse-fix-transport-diagnostics-design.md`. Read it first.
- **`LogCategory` note:** cases are in `App/LogCategory.swift`; each case must be added to (1) the enum, (2) the exhaustive `summary` `switch self`. `defaultEnabled` is a `Set` (do NOT add `transport` to it, it defaults OFF). The Diagnostics screen auto-renders every case via `ForEach(LogCategory.allCases)` at `DiagnosticsSettingsView.swift:144`, so no UI code is needed.

---

## File Structure

**Pure Kit (Linux-tested):**
- Modify `Sources/SemicolynKit/ET/ETBootstrap.swift`, replace `parseETIDPASSKEY` body with the fixed-window parse.
- Create `Sources/SemicolynKit/ET/ETBootstrapMask.swift`, `maskBootstrapPayload`.
- Modify `Tests/SemicolynKitTests/ETIDPASSKEYParseTests.swift`, add the tolerant + boundary cases.
- Create `Tests/SemicolynKitTests/ETBootstrapMaskTests.swift`.

**App tier (macOS-CI-only):**
- Modify `App/LogCategory.swift`, add `case transport` + its `summary`.
- Modify `App/ConnectionViewModel.swift`, three `.transport` log calls (parse success, parse failure, capture).

---

### Task 1: Fix `parseETIDPASSKEY` (fixed 49-char window, upstream-matching)

**Files:**
- Modify: `Sources/SemicolynKit/ET/ETBootstrap.swift`
- Test: `Tests/SemicolynKitTests/ETIDPASSKEYParseTests.swift`

**Interfaces:**
- Consumes: `ETCredential`, `ETBootstrapError`, `sanitizeEndReason` (existing).
- Produces: same signature `parseETIDPASSKEY(_ stdout: String) -> Result<ETCredential, ETBootstrapError>`, new tolerant behavior.

- [ ] **Step 1: Write the failing tests (append to the existing ETIDPASSKEYParseTests class)**

The existing tests already cover: valid line, embedded-in-noise, no-line, short-id, short-passkey, missing-slash, injection-sanitized. ADD these tolerant + boundary cases inside the existing `final class ETIDPASSKEYParseTests` (do not create a new class):

```swift
private let id16b = "abcdef0123456789"                     // 16
private let key32b = "0123456789abcdef0123456789abcdef"    // 32

// The credential is followed by trailing content on the same line (a CR from the
// SSH PTY, or a status token). Upstream takes a fixed 49-char window and ignores
// this; we must too. THIS is the device bug.
func testTrailingCarriageReturnAfterCredentialSucceeds() {
    let out = "IDPASSKEY:\(id16b)/\(key32b)\r\n"
    guard case .success(let cred) = parseETIDPASSKEY(out) else { return XCTFail("expected success") }
    XCTAssertEqual(cred.id, id16b)
    XCTAssertEqual(cred.passkey, key32b)
}

func testTrailingJunkOnCredentialLineSucceeds() {
    let out = "IDPASSKEY:\(id16b)/\(key32b) extra=1 more junk\n"
    guard case .success(let cred) = parseETIDPASSKEY(out) else { return XCTFail("expected success") }
    XCTAssertEqual(cred.id, id16b)
    XCTAssertEqual(cred.passkey, key32b)
}

// A shell banner printed before the marker must not break extraction.
func testLeadingBannerBeforeMarkerSucceeds() {
    let out = "bash: cannot set terminal process group\nIDPASSKEY:\(id16b)/\(key32b)\n"
    guard case .success(let cred) = parseETIDPASSKEY(out) else { return XCTFail("expected success") }
    XCTAssertEqual(cred.id, id16b)
    XCTAssertEqual(cred.passkey, key32b)
}

// Boundary: fewer than 49 chars after the marker -> malformed.
func testTruncatedWindowIsMalformed() {
    let out = "IDPASSKEY:\(id16b)/short"
    guard case .failure(let e) = parseETIDPASSKEY(out) else { return XCTFail("expected failure") }
    XCTAssertEqual(e, .malformedIDPASSKEY)
}

// Slash not at index 16 (window landed on wrong content) -> malformed.
func testSlashNotAtIndex16IsMalformed() {
    let out = "IDPASSKEY:abcd/efghijklmnopqrstuvwxyz0123456789ABCDEF\n"   // slash at 4
    guard case .failure(let e) = parseETIDPASSKEY(out) else { return XCTFail("expected failure") }
    XCTAssertEqual(e, .malformedIDPASSKEY)
}

// Non-alphanumeric inside the id/passkey window -> malformed (garbage rejected).
func testNonAlphanumericWindowIsMalformed() {
    // 16 chars, slash, then 32 chars but with a space inside the passkey window.
    let out = "IDPASSKEY:\(id16b)/0123456789abcdef 123456789abcdef\n"
    guard case .failure(let e) = parseETIDPASSKEY(out) else { return XCTFail("expected failure") }
    XCTAssertEqual(e, .malformedIDPASSKEY)
}
```

Also VERIFY the pre-existing negative tests still make sense under the new logic and keep them (short-id / short-passkey become "truncated window or non-alphanumeric" cases; if an existing test's exact input now takes a different-but-still-`.malformedIDPASSKEY` path, that is fine, the assertion is on `.malformedIDPASSKEY`; do NOT weaken any assertion. If an existing test asserted `.malformedIDPASSKEY` for `"IDPASSKEY:short/<32>"`, it still yields `.malformedIDPASSKEY` under the window logic (slash not at index 16), so it stays green.)

- [ ] **Step 2: Run tests to verify the NEW ones fail**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ETIDPASSKEYParseTests`
Expected: the new trailing/banner cases FAIL (current parser rejects them with `.malformedIDPASSKEY`), proving the bug.

- [ ] **Step 3: Replace the parser body with the fixed-window logic**

Replace the current `parseETIDPASSKEY` body (keep the signature + doc comment, update the doc to describe the window):

```swift
public func parseETIDPASSKEY(_ stdout: String) -> Result<ETCredential, ETBootstrapError> {
    let marker = "IDPASSKEY:"
    guard let range = stdout.range(of: marker) else {
        return .failure(.noIDPASSKEY(serverOutput: sanitizeEndReason(stdout)))
    }
    // Match upstream ET (SshSetupHandler.cpp): take the fixed 16 + 1 + 32 = 49
    // character window immediately after the marker, ignoring anything before or
    // after it (a trailing CR / status token / shell banner must not break parsing).
    let after = Array(stdout[range.upperBound...].unicodeScalars)
    guard after.count >= 49 else { return .failure(.malformedIDPASSKEY) }
    let window = Array(after[0..<49])
    guard window[16] == "/" else { return .failure(.malformedIDPASSKEY) }
    let idScalars = window[0..<16]
    let keyScalars = window[17..<49]
    func isAlnum(_ s: Unicode.Scalar) -> Bool {
        (s >= "0" && s <= "9") || (s >= "A" && s <= "Z") || (s >= "a" && s <= "z")
    }
    guard idScalars.allSatisfy(isAlnum), keyScalars.allSatisfy(isAlnum) else {
        return .failure(.malformedIDPASSKEY)
    }
    let id = String(String.UnicodeScalarView(idScalars))
    let passkey = String(String.UnicodeScalarView(keyScalars))
    return .success(ETCredential(id: id, passkey: passkey))
}
```

- [ ] **Step 4: Run tests to verify all pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ETIDPASSKEYParseTests`
Expected: PASS (all existing + new cases). Then run the ET bootstrap tests to confirm no cross-breakage:
`HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ETBootstrap`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/ET/ETBootstrap.swift Tests/SemicolynKitTests/ETIDPASSKEYParseTests.swift
git commit -m "fix(et): parse IDPASSKEY via upstream fixed 49-char window (tolerate trailing content)

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
```

---

### Task 2: `maskBootstrapPayload` (mask credential, keep structure + junk)

**Files:**
- Create: `Sources/SemicolynKit/ET/ETBootstrapMask.swift`
- Test: `Tests/SemicolynKitTests/ETBootstrapMaskTests.swift`

**Interfaces:**
- Consumes: `sanitizeEndReason` (existing).
- Produces: `public func maskBootstrapPayload(_ raw: String) -> String`.

Behavior:
- If `IDPASSKEY:` present: emit `IDPASSKEY:<id:N>/<key:M>[len=T leading="…" trailing="…"]` where N = count of the id window (up to 16), M = count of the passkey window (up to 32), T = total scalars after the marker, `leading` = repr of bytes before the marker (empty → omit), `trailing` = repr of bytes after the 49-char window (empty → omit). Control chars shown as `\r`, `\n`, `\xNN`. The actual id/passkey characters are NEVER emitted.
- If no marker: emit `no-marker len=<n> content="<repr of sanitizeEndReason(raw)>"`.

- [ ] **Step 1: Write the failing test**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ETBootstrapMaskTests: XCTestCase {
    private let id16 = "abcdef0123456789"
    private let key32 = "0123456789abcdef0123456789abcdef"

    // The actual credential characters must NEVER appear in the masked output.
    func testCredentialValuesAreAbsent() {
        let out = maskBootstrapPayload("IDPASSKEY:\(id16)/\(key32)\n")
        XCTAssertFalse(out.contains(id16), "id leaked into masked output")
        XCTAssertFalse(out.contains(key32), "passkey leaked into masked output")
    }

    // Structure (marker, lengths, slash) is shown.
    func testStructureShown() {
        let out = maskBootstrapPayload("IDPASSKEY:\(id16)/\(key32)\n")
        XCTAssertTrue(out.contains("IDPASSKEY:"))
        XCTAssertTrue(out.contains("<id:16>"))
        XCTAssertTrue(out.contains("<key:32>"))
    }

    // Trailing junk (the bug signature) is visible, control chars as repr.
    func testTrailingJunkVisible() {
        let out = maskBootstrapPayload("IDPASSKEY:\(id16)/\(key32)\r extra=1")
        XCTAssertTrue(out.contains("trailing="), "trailing content not surfaced")
        XCTAssertTrue(out.contains("\\r"), "CR not shown as repr")
        XCTAssertTrue(out.contains("extra=1"))
    }

    // Leading banner before the marker is visible.
    func testLeadingBannerVisible() {
        let out = maskBootstrapPayload("bash: no tty\nIDPASSKEY:\(id16)/\(key32)\n")
        XCTAssertTrue(out.contains("leading="))
        XCTAssertTrue(out.contains("bash: no tty"))
    }

    // No marker: content repr, no crash, no credential (there is none).
    func testNoMarker() {
        let out = maskBootstrapPayload("command not found: etterminal\n")
        XCTAssertTrue(out.contains("no-marker"))
        XCTAssertTrue(out.contains("command not found"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ETBootstrapMaskTests`
Expected: FAIL to compile / "cannot find 'maskBootstrapPayload' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Mask a raw transport bootstrap payload for the `transport` diagnostics log:
/// the credential VALUES are replaced with <id:N>/<key:M>, but the structure
/// (marker, lengths, slash) and any surrounding/trailing content stay visible so
/// a parse malformation (a trailing CR, a status token, a shell banner) is
/// diagnosable WITHOUT logging the live secret. The id/passkey characters are
/// never emitted.
public func maskBootstrapPayload(_ raw: String) -> String {
    let marker = "IDPASSKEY:"
    guard let range = raw.range(of: marker) else {
        let content = sanitizeEndReason(raw)
        return "no-marker len=\(raw.unicodeScalars.count) content=\"\(content)\""
    }
    let leading = String(raw[..<range.lowerBound])
    let after = Array(raw[range.upperBound...].unicodeScalars)
    let total = after.count
    // id window [0..16), slash at 16, key window [17..49) when present.
    let idLen = min(16, after.count)
    let hasSlash = after.count > 16 && after[16] == "/"
    let keyLen = after.count > 17 ? min(32, after.count - 17) : 0
    let slash = hasSlash ? "/" : "?"
    let trailing = after.count > 49 ? reprScalars(Array(after[49...])) : ""
    var out = "\(marker)<id:\(idLen)>\(slash)<key:\(keyLen)>[len=\(total)"
    if !leading.isEmpty { out += " leading=\"\(reprScalars(Array(leading.unicodeScalars)))\"" }
    if !trailing.isEmpty { out += " trailing=\"\(trailing)\"" }
    out += "]"
    return out
}

/// Control-char-safe repr: printable ASCII kept, CR/LF/TAB shown as escapes,
/// other control/non-ASCII as \xNN. Never used on credential windows.
private func reprScalars(_ scalars: [Unicode.Scalar]) -> String {
    var s = ""
    for u in scalars {
        switch u {
        case "\r": s += "\\r"
        case "\n": s += "\\n"
        case "\t": s += "\\t"
        default:
            if u.value >= 0x20 && u.value < 0x7F { s.unicodeScalars.append(u) }
            else { s += String(format: "\\x%02X", u.value) }
        }
    }
    return s
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ETBootstrapMaskTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/ET/ETBootstrapMask.swift Tests/SemicolynKitTests/ETBootstrapMaskTests.swift
git commit -m "feat(et): maskBootstrapPayload for the transport diagnostics log (mask values, keep structure)

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
```

---

### Task 3: `transport` LogCategory + wire the `.transport` logs (App, macOS-CI-only)

**Files:**
- Modify: `App/LogCategory.swift`
- Modify: `App/ConnectionViewModel.swift`

**Interfaces:**
- Consumes: `maskBootstrapPayload` (Task 2), `parseETIDPASSKEY` (Task 1), `DebugLog` (existing).
- Produces: a new `LogCategory.transport` (default off) + three `.transport` log calls.

Apple-tier (no Linux compile, macOS-CI-verified). Keep it wiring only.

- [ ] **Step 1: Add the `transport` LogCategory case**

In `App/LogCategory.swift`:
1. Add `case transport   // raw transport handshake structure (masked credential)` to the enum (after `geometry` is fine).
2. Add its arm to the exhaustive `summary` `switch self`:
   ```swift
   case .transport: return "Raw transport handshake structure (Eternal Terminal IDPASSKEY, Mosh connect). Credential values are masked. Verbose, off by default."
   ```
3. Do NOT add `.transport` to `defaultEnabled` (it stays off).

- [ ] **Step 2: Add the three `.transport` log calls in `ConnectionViewModel`**

READ the `attachET` parse site + `captureETBootstrap` first, then:

a) In `captureETBootstrap`, after the stdout is captured (right before returning it), add:
```swift
DebugLog.shared.log(.transport, "et: bootstrap payload " + maskBootstrapPayload(captured))
```
(use the actual captured-string variable name in that method, likely the `String(decoding: captured, as: UTF8.self)` value; log the masked form).

b) At the `attachET` parse site, log the masked payload on BOTH branches. The current code is:
```swift
switch parseETIDPASSKEY(stdout) {
case .success(let cred):
    serverCred = cred
case .failure(let e):
    DebugLog.shared.log(.connect, "et: IDPASSKEY parse FAILED (\(String(describing: e)))")
    return .failure(e)
}
DebugLog.shared.log(.connect, "et: IDPASSKEY parsed ok")
```
Add a `.transport` line covering both outcomes (place it right after `let stdout = ...` capture, before the switch, so it logs regardless of parse result):
```swift
DebugLog.shared.log(.transport, "et: parse input " + maskBootstrapPayload(stdout))
```
Keep the existing `.connect` lines unchanged (they never carried the secret).

- [ ] **Step 3: Commit** (macOS-CI-verified; no Linux build)

```bash
git add App/LogCategory.swift App/ConnectionViewModel.swift
git commit -m "feat(diagnostics): transport LogCategory (default off) + masked bootstrap payload logging

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
```

---

### Task 4: Push, verify CI, TestFlight, update TODO

**Files:**
- Modify: `TODO.md`

**Interfaces:**
- Consumes: all prior tasks.
- Produces: a green CI run + a TestFlight build for the device retest + updated resume pointer.

- [ ] **Step 1: Branch + push**

```bash
git checkout -b fix/et-parse-transport-diagnostics 2>/dev/null || git checkout fix/et-parse-transport-diagnostics
git push -u github fix/et-parse-transport-diagnostics
```

- [ ] **Step 2: Open the PR**

```bash
gh pr create --repo ds7n/semicolyn --base main --head fix/et-parse-transport-diagnostics \
  --title "fix(et): Eternal Terminal IDPASSKEY parse (fixed window) + transport diagnostics" \
  --body "$(cat <<'BODY'
Design: docs/superpowers/specs/2026-08-05-et-parse-fix-transport-diagnostics-design.md.

Fixes the on-device Eternal Terminal connect failure ("the server sent a malformed credential").

- Root cause (measured vs real etserver v7.0.0 + upstream source): parseETIDPASSKEY required the WHOLE marker line to be exactly <16>/<32>; upstream takes a fixed 49-char window after the marker and ignores trailing content. A trailing CR / status token / shell banner tripped our line-exact parse. Fix = match upstream's fixed window (still validates length + slash-at-16 + alphanumeric charset, so garbage still rejects).
- New `transport` LogCategory (default OFF) + maskBootstrapPayload: logs the raw bootstrap payload with the credential VALUES masked (<id:16>/<key:32>) but structure + trailing junk visible, so this class of handshake bug is diagnosable without leaking the secret.

Enables the on-device Eternal Terminal retest (should now connect).

https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt
BODY
)"
```

- [ ] **Step 3: Verify all CI jobs green**

Run: `gh run watch --repo ds7n/semicolyn $(gh run list --repo ds7n/semicolyn --branch fix/et-parse-transport-diagnostics --limit 1 --json databaseId --jq '.[0].databaseId')`
Expected: `linux-swift`, `linux-rust`, `lint`, `macos` all pass. If `linux-rust` flakes ("sshd fixtures not reachable"), rerun that job only.

- [ ] **Step 4: Trigger a TestFlight build (gate on macos green)**

```bash
gh workflow run "Release to TestFlight" --repo ds7n/semicolyn --ref fix/et-parse-transport-diagnostics
```
Confirm the run STARTS, then watch it to completion and confirm the upload step prints `UPLOAD SUCCEEDED` (the lane reports green even on a failed upload, so check the log, per the `testflight-lane-live` memory). The ET framework build step is now in this lane (fixed in `922cd10`).

- [ ] **Step 5: Update TODO + commit**

Edit `TODO.md`: record the parse fix + transport diagnostics slice (PR #<n>, CI green, TestFlight build N uploaded), and that the NEXT step is the on-device Eternal Terminal retest (should now connect; if it fails, flip Settings → Diagnostics → transport ON and read the masked payload). Keep the protocol-6-vs-7 watch-item noted (a `.handshakeFailed` after a successful parse = that separate issue).

```bash
git add TODO.md
git commit -m "docs: record Eternal Terminal parse fix + transport diagnostics; next = device retest

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
git push
```

---

## Self-Review

**Spec coverage:**
- §In 1 (parser fix, fixed-window, tolerant) → Task 1.
- §In 2 (`transport` category default off) → Task 3 Step 1.
- §In 3 (`maskBootstrapPayload`, mask values keep structure) → Task 2.
- §In 4 (wire `.transport` logs at parse + capture, success + failure) → Task 3 Step 2.
- §The parser fix detail (49-char window, slash at 16, alphanumeric, reject short/garbage) → Task 1 Step 3 + its tests.
- §Masking detail (values absent, structure + leading/trailing repr) → Task 2 + its tests (incl. the credential-absent assertion).
- §Testing Linux table → Tasks 1-2 tests. §macOS CI compile → Task 4 Step 3. §Device retest → Task 4 Step 4-5.
- §Non-goals (no unmasked logging, no Mosh wiring, no protocol-mismatch handling, no new UI) → respected.

**Placeholder scan:** No "TBD"/"add error handling"/"similar to Task N". Every code step has concrete content. Task 3 says "READ the parse site first + use the actual captured-var name", a precise instruction against the live file, not a blank.

**Type consistency:** `parseETIDPASSKEY(_:) -> Result<ETCredential, ETBootstrapError>` (unchanged signature), `maskBootstrapPayload(_:) -> String`, `ETCredential(id:passkey:)`, `sanitizeEndReason`, `ETBootstrapError.{malformedIDPASSKEY,noIDPASSKEY}` all match slice-1b's shipped API. `LogCategory` gains `.transport` in the enum + the `summary` switch (both required for exhaustiveness); `defaultEnabled` unchanged. `DebugLog.shared.log(_:_:)` matches existing call sites.
