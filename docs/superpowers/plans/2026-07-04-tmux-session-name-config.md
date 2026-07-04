# Configurable tmux session name — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user set the tmux `-CC` session name at the Defaults level and per-host, resolved host→Defaults→builtin `"semicolyn"`, replacing the opaque `semicolyn-<hash>` name.

**Architecture:** One optional `sessionName` leaf on `TmuxConfig`; a pure `resolveTmuxSessionName` resolver (reusing the `resolveLeaf` helper) + a pure `isValidTmuxSessionName`/`normalizedTmuxSessionName` validation pair, all Linux-tested in SemicolynKit. The host editor and Defaults editor gain a text field; `ConnectionViewModel.attachTmux` swaps the device-seed hash for the resolved name. `tmuxSessionName(seed:)` stays (other callers) but is no longer used by the launch path.

**Tech Stack:** Swift 6 (SemicolynKit, Linux-tested via `swift test` in the `semicolyn-dev` Docker image; App tier macOS-CI-only), SwiftUI editors, XCTest.

## Global Constraints

- **Two-tier rule:** pure logic (resolver, validation, model) lives in `Sources/SemicolynKit/` and is Linux-tested; App/SwiftUI wiring is macOS-CI-only. No `import UIKit`/`SwiftUI`/bare `CryptoKit` in Kit.
- **SPDX header** on every new source file: `// SPDX-FileCopyrightText: 2026 True Positive LLC` + `// SPDX-License-Identifier: GPL-3.0-only`.
- **Builtin default session name:** the literal `"semicolyn"`.
- **Allowed session-name charset:** ASCII letters, digits, `-`, `_`. Reject `.`, `:`, whitespace, control chars, shell metacharacters, and empty-after-trim.
- **`-A` (attach-or-create) is kept** — `tmux -CC new-session -A -s <name>` is unchanged.
- **Kit test command:** `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter <TestClass>` (no Swift toolchain on the host).
- **Conventional commits**; commit after each task. Branch: `feat/tmux-session-name` (already created; the spec + two UI fixes are already committed on it).

---

### Task 1: `TmuxConfig.sessionName` model leaf

**Files:**
- Modify: `Sources/SemicolynKit/Model/HostExtensions.swift` (the `TmuxConfig` struct, ~lines 54-61)
- Test: `Tests/SemicolynKitTests/HostSchemaTests.swift` (Codable round-trip)

**Interfaces:**
- Produces: `TmuxConfig.sessionName: String?` (optional, defaults `nil`); `TmuxConfig.init(attemptControlMode:sessionName:)`.

- [ ] **Step 1: Write the failing test** — add to `HostSchemaTests.swift`:

```swift
func testTmuxConfigSessionNameRoundTrips() {
    let cfg = TmuxConfig(attemptControlMode: true, sessionName: "work")
    let data = try! JSONEncoder().encode(cfg)
    let back = try! JSONDecoder().decode(TmuxConfig.self, from: data)
    XCTAssertEqual(back.sessionName, "work")
    XCTAssertEqual(back.attemptControlMode, true)
}

func testTmuxConfigDecodesLegacyRecordWithoutSessionName() {
    // A record written before this field existed must decode with sessionName nil.
    let json = Data(#"{"attemptControlMode":true}"#.utf8)
    let back = try! JSONDecoder().decode(TmuxConfig.self, from: json)
    XCTAssertNil(back.sessionName)
    XCTAssertEqual(back.attemptControlMode, true)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter HostSchemaTests`
Expected: FAIL — `TmuxConfig` has no `sessionName` parameter/member.

- [ ] **Step 3: Add the leaf** — in `HostExtensions.swift`, replace the `TmuxConfig` struct:

```swift
/// `semicolyn.tmux.*` — per-host tmux controls.
public struct TmuxConfig: Codable, Equatable, Sendable {
    public var attemptControlMode: Bool?
    /// User-chosen tmux -CC session name; nil = inherit (→ Defaults → "semicolyn").
    public var sessionName: String?

    public init(attemptControlMode: Bool? = nil, sessionName: String? = nil) {
        self.attemptControlMode = attemptControlMode
        self.sessionName = sessionName
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter HostSchemaTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Model/HostExtensions.swift Tests/SemicolynKitTests/HostSchemaTests.swift
git commit -m "feat(model): add TmuxConfig.sessionName leaf (Codable back-compatible)"
```

---

### Task 2: `normalizedTmuxSessionName` + `isValidTmuxSessionName` (pure validation)

**Files:**
- Create: `Sources/SemicolynKit/Tmux/TmuxSessionName.swift`
- Test: `Tests/SemicolynKitTests/TmuxSessionNameTests.swift`

**Interfaces:**
- Produces:
  - `func normalizedTmuxSessionName(_ raw: String) -> String?` — trims; `nil` if empty after trim.
  - `func isValidTmuxSessionName(_ name: String) -> Bool` — true iff non-empty after trim AND every char is `[A-Za-z0-9_-]`.
  - `let builtInTmuxSessionName = "semicolyn"`

- [ ] **Step 1: Write the failing test** — `Tests/SemicolynKitTests/TmuxSessionNameTests.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class TmuxSessionNameTests: XCTestCase {
    // normalizedTmuxSessionName — trim + empty→nil
    func testNormalizeTrims() { XCTAssertEqual(normalizedTmuxSessionName("  x  "), "x") }
    func testNormalizeEmptyIsNil() { XCTAssertNil(normalizedTmuxSessionName("")) }
    func testNormalizeWhitespaceOnlyIsNil() { XCTAssertNil(normalizedTmuxSessionName("   ")) }
    func testNormalizeKeepsValidName() { XCTAssertEqual(normalizedTmuxSessionName("semicolyn"), "semicolyn") }

    // isValidTmuxSessionName — Critical tier (command-injection surface): EP + adversarial
    func testValidNames() {
        for n in ["semicolyn", "work", "my-session", "dev_2", "A1"] {
            XCTAssertTrue(isValidTmuxSessionName(n), "\(n) should be valid")
        }
    }
    func testRejectsDot() { XCTAssertFalse(isValidTmuxSessionName("a.b")) }        // tmux-forbidden
    func testRejectsColon() { XCTAssertFalse(isValidTmuxSessionName("a:b")) }      // tmux-forbidden
    func testRejectsSpace() { XCTAssertFalse(isValidTmuxSessionName("a b")) }
    func testRejectsShellMetachar() { XCTAssertFalse(isValidTmuxSessionName("a;rm -rf")) } // injection
    func testRejectsEmpty() { XCTAssertFalse(isValidTmuxSessionName("")) }
    func testRejectsWhitespaceOnly() { XCTAssertFalse(isValidTmuxSessionName("   ")) }
    func testRejectsControlChar() { XCTAssertFalse(isValidTmuxSessionName("a\u{0007}b")) }
    func testRejectsSlash() { XCTAssertFalse(isValidTmuxSessionName("a/b")) }
    func testRejectsLeadingTrailingSpaceButValidCore() {
        // "  work  " trims to a valid "work" → valid (editor trims on save).
        XCTAssertTrue(isValidTmuxSessionName("  work  "))
    }

    func testBuiltinDefaultIsSemicolyn() { XCTAssertEqual(builtInTmuxSessionName, "semicolyn") }
    func testBuiltinDefaultIsItselfValid() { XCTAssertTrue(isValidTmuxSessionName(builtInTmuxSessionName)) }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TmuxSessionNameTests`
Expected: FAIL — the functions don't exist (compile error).

- [ ] **Step 3: Write the implementation** — `Sources/SemicolynKit/Tmux/TmuxSessionName.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The built-in tmux -CC session name when neither the host nor Defaults sets one.
public let builtInTmuxSessionName = "semicolyn"

/// Trims surrounding whitespace; returns nil for an empty/whitespace-only string
/// so a "cleared to blank" leaf resolves as unset (inherit).
public func normalizedTmuxSessionName(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? nil : trimmed
}

/// A tmux session name is valid iff, after trimming, it is non-empty and every
/// character is an ASCII letter, digit, hyphen, or underscore. This rejects
/// tmux's forbidden `.`/`:`, whitespace, control chars, and every shell
/// metacharacter, so a validated name is always safe to interpolate into the
/// `-CC new-session -A -s <name>` command.
public func isValidTmuxSessionName(_ name: String) -> Bool {
    guard let n = normalizedTmuxSessionName(name) else { return false }
    return n.unicodeScalars.allSatisfy { s in
        (s >= "a" && s <= "z") || (s >= "A" && s <= "Z")
            || (s >= "0" && s <= "9") || s == "-" || s == "_"
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TmuxSessionNameTests`
Expected: PASS (all cases).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Tmux/TmuxSessionName.swift Tests/SemicolynKitTests/TmuxSessionNameTests.swift
git commit -m "feat(tmux): pure session-name validation + normalization (charset-safe)"
```

---

### Task 3: `resolveTmuxSessionName` resolver

**Files:**
- Modify: `Sources/SemicolynKit/Model/Resolution.swift` (add near the other nested-config leaf resolvers, ~after `resolveTmuxAttemptControlMode`)
- Test: `Tests/SemicolynKitTests/ResolutionTests.swift`

**Interfaces:**
- Consumes: `resolveLeaf` (private helper already in `Resolution.swift`), `normalizedTmuxSessionName`, `builtInTmuxSessionName` (Task 2).
- Produces: `func resolveTmuxSessionName(host: Host, defaults: Defaults) -> String`.

- [ ] **Step 1: Write the failing test** — add to `ResolutionTests.swift`:

```swift
func testTmuxSessionNameHostWins() {
    let h = host { $0.semicolyn = .explicit(SemicolynConfig(tmux: TmuxConfig(sessionName: "work"))) }
    let d = Defaults(semicolyn: .explicit(SemicolynConfig(tmux: TmuxConfig(sessionName: "shared"))))
    XCTAssertEqual(resolveTmuxSessionName(host: h, defaults: d), "work")
}

func testTmuxSessionNameInheritsDefaults() {
    let d = Defaults(semicolyn: .explicit(SemicolynConfig(tmux: TmuxConfig(sessionName: "shared"))))
    XCTAssertEqual(resolveTmuxSessionName(host: host(), defaults: d), "shared")
}

func testTmuxSessionNameBuiltinWhenUnset() {
    XCTAssertEqual(resolveTmuxSessionName(host: host(), defaults: Defaults()), "semicolyn")
}

func testTmuxSessionNameEmptyLeafFallsThrough() {
    // A host leaf set to "" (or whitespace) is treated as unset → Defaults → builtin.
    let h = host { $0.semicolyn = .explicit(SemicolynConfig(tmux: TmuxConfig(sessionName: "   "))) }
    XCTAssertEqual(resolveTmuxSessionName(host: h, defaults: Defaults()), "semicolyn")
    let h2 = host { $0.semicolyn = .explicit(SemicolynConfig(tmux: TmuxConfig(sessionName: ""))) }
    let d = Defaults(semicolyn: .explicit(SemicolynConfig(tmux: TmuxConfig(sessionName: "shared"))))
    XCTAssertEqual(resolveTmuxSessionName(host: h2, defaults: d), "shared")
}

func testTmuxSessionNameLeafIndependence() {
    // Host sets ONLY sessionName; Defaults sets ONLY attemptControlMode=false.
    // Each leaf resolves independently (regression for the #7 container-shadow bug).
    let h = host { $0.semicolyn = .explicit(SemicolynConfig(tmux: TmuxConfig(sessionName: "work"))) }
    let d = Defaults(semicolyn: .explicit(SemicolynConfig(tmux: TmuxConfig(attemptControlMode: false))))
    XCTAssertEqual(resolveTmuxSessionName(host: h, defaults: d), "work")
    XCTAssertFalse(resolveTmuxAttemptControlMode(host: h, defaults: d))
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ResolutionTests`
Expected: FAIL — `resolveTmuxSessionName` undefined.

- [ ] **Step 3: Add the resolver** — in `Resolution.swift`, after `resolveTmuxAttemptControlMode`:

```swift
/// Resolve the tmux -CC session name: host leaf → Defaults leaf → builtin.
/// Normalization runs inside the leaf accessor, so an empty/whitespace-only leaf
/// is seen as absent and falls through to the next level (ultimately "semicolyn").
public func resolveTmuxSessionName(host: Host, defaults: Defaults) -> String {
    resolveLeaf(host.semicolyn, defaults.semicolyn,
                { $0.tmux?.sessionName.flatMap(normalizedTmuxSessionName) },
                fallback: builtInTmuxSessionName)
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ResolutionTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Model/Resolution.swift Tests/SemicolynKitTests/ResolutionTests.swift
git commit -m "feat(resolution): resolveTmuxSessionName (host→Defaults→\"semicolyn\", leaf-independent)"
```

---

### Task 4: Validation issue — block Save on an invalid host session name

**Files:**
- Modify: `Sources/SemicolynKit/Model/HostFormValidation.swift` (add a `Kind` case + the check)
- Test: `Tests/SemicolynKitTests/HostFormValidationTests.swift`

**Interfaces:**
- Consumes: `isValidTmuxSessionName` (Task 2).
- Produces: `ValidationIssue.Kind.invalidTmuxSessionName` (hardBlock), emitted by `validateHostForm` when the host's `semicolyn.tmux.sessionName` is set-but-invalid.

- [ ] **Step 1: Write the failing test** — add to `HostFormValidationTests.swift`:

```swift
func testInvalidTmuxSessionNameHardBlocks() {
    var h = Host(id: UUID(), label: "l", hostName: "h")
    h.semicolyn = .explicit(SemicolynConfig(tmux: TmuxConfig(sessionName: "a.b")))   // dot → invalid
    let issues = validateHostForm(h, others: [], defaults: Defaults(), passwordRefResolves: true)
    XCTAssertTrue(issues.contains { $0.kind == .invalidTmuxSessionName && $0.severity == .hardBlock })
    XCTAssertFalse(canSave(issues))
}

func testValidTmuxSessionNameDoesNotBlock() {
    var h = Host(id: UUID(), label: "l", hostName: "h")
    h.semicolyn = .explicit(SemicolynConfig(tmux: TmuxConfig(sessionName: "work")))
    let issues = validateHostForm(h, others: [], defaults: Defaults(), passwordRefResolves: true)
    XCTAssertFalse(issues.contains { $0.kind == .invalidTmuxSessionName })
}

func testBlankTmuxSessionNameIsNotAnError() {
    // Blank = "inherit / use default", not a validation error.
    var h = Host(id: UUID(), label: "l", hostName: "h")
    h.semicolyn = .explicit(SemicolynConfig(tmux: TmuxConfig(sessionName: "   ")))
    let issues = validateHostForm(h, others: [], defaults: Defaults(), passwordRefResolves: true)
    XCTAssertFalse(issues.contains { $0.kind == .invalidTmuxSessionName })
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter HostFormValidationTests`
Expected: FAIL — `.invalidTmuxSessionName` is not a `Kind` case.

- [ ] **Step 3: Add the Kind case + the check.** In `HostFormValidation.swift`, add to the hard-block group of `ValidationIssue.Kind`:

```swift
        case invalidTmuxSessionName
```

Then in `validateHostForm`, after the existing required-field checks (anywhere in the hard-block section), add:

```swift
    // --- Hard: tmux session name, if set, must be command-safe ---
    // A blank/whitespace name means "inherit" (normalizedTmuxSessionName → nil) and
    // is NOT an error; only a set-but-invalid name blocks Save.
    if let raw = host.semicolyn.value?.tmux?.sessionName,
       normalizedTmuxSessionName(raw) != nil,           // not blank
       !isValidTmuxSessionName(raw) {
        issues.append(ValidationIssue(kind: .invalidTmuxSessionName, severity: .hardBlock))
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter HostFormValidationTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Model/HostFormValidation.swift Tests/SemicolynKitTests/HostFormValidationTests.swift
git commit -m "feat(validation): hard-block Save on an invalid tmux session name"
```

---

### Task 5: Wire the resolved name into the launch path

**Files:**
- Modify: `App/ConnectionViewModel.swift` (`attachTmux`, ~lines 580-582)

**Interfaces:**
- Consumes: `resolveTmuxSessionName(host:defaults:)` (Task 3).
- Note: App-tier — compiles/validates only on macOS CI. No Kit test.

- [ ] **Step 1: Confirm `host`/`defaults` are in scope in `attachTmux`.** Read `attachTmux`'s signature and callers. If `attachTmux` does not already receive `host`/`defaults`, thread them in from the two callers (`attachSSHShell`/the mosh fallback and the crash-recovery path both call `attachTmux(conn:)`). The connect path already resolves `defaults`; the saved/ad-hoc `host` (or `hostRecord`) is in scope at both call sites.

- [ ] **Step 2: Replace the seed-hash name.** In `attachTmux`, change:

```swift
        let seed = (try? AppStores.shared.deviceSeed()) ?? "semicolyn-local"
        let runtime = TmuxRuntime(sessionName: tmuxSessionName(seed: seed))
```

to:

```swift
        let name = resolveTmuxSessionName(host: host, defaults: defaults)
        let runtime = TmuxRuntime(sessionName: name)
```

where `host`/`defaults` are the resolved values threaded in (Step 1). Leave `tmuxSessionName(seed:)` and `deviceSeed` untouched — they retain other callers (`StubSessionNameProvider`, tests); only the launch path stops using the hash.

- [ ] **Step 3: Commit** (no local test — macOS CI is the gate):

```bash
git add App/ConnectionViewModel.swift
git commit -m "feat(tmux): launch -CC with the resolved session name, not the device-seed hash"
```

---

### Task 6: Host-editor session-name field

**Files:**
- Modify: `App/HostEditorSections.swift` (`semicolynSection`, after the `attemptControlMode` toggle ~line 604)

**Interfaces:**
- Consumes: `TmuxConfig.sessionName` (Task 1); the existing `vm.host.semicolyn` binding pattern; `vm.revalidate()`.
- Note: App-tier — macOS CI only.

- [ ] **Step 1: Add the field.** In `semicolynSection`, directly below the "Attempt tmux control mode" toggle block, add a `TextField` bound to the nested leaf, disabled when control mode is off, showing the resolved-inherited placeholder:

```swift
            // tmux session name — Inherited via the nested leaf. Blank = inherit
            // (→ Defaults → "semicolyn"). Disabled when control mode is off.
            let controlModeOn = (vm.host.semicolyn.value?.tmux?.attemptControlMode ?? true)
            LabeledContent {
                TextField(
                    "inherit · semicolyn",
                    text: Binding(
                        get: { vm.host.semicolyn.value?.tmux?.sessionName ?? "" },
                        set: { newName in
                            var cfg = vm.host.semicolyn.value ?? SemicolynConfig()
                            var tmux = cfg.tmux ?? TmuxConfig()
                            tmux.sessionName = newName.isEmpty ? nil : newName
                            cfg.tmux = tmux
                            vm.host.semicolyn = .explicit(cfg)
                        }
                    )
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: vm.host.semicolyn) { _, _ in vm.revalidate() }
            } label: {
                Text("tmux session name")
                    .foregroundStyle(Color(theme.text.primary))
            }
            .disabled(!controlModeOn)

            if vm.issues.contains(where: { $0.kind == .invalidTmuxSessionName }) {
                Text("Only letters, digits, - and _ (no spaces, dots, or colons).")
                    .font(.caption)
                    .foregroundStyle(Color(theme.state.broken))
            }
```

(Match the exact `theme`/`vm.issues` accessors already used in this file — confirm `vm.issues` exposes the validation array as used elsewhere in the editor; if the editor reads issues differently, use that accessor.)

- [ ] **Step 2: Commit** (macOS CI is the gate):

```bash
git add App/HostEditorSections.swift
git commit -m "feat(ui): host-editor tmux session-name field with inline validation"
```

---

### Task 7: Defaults-editor session-name field

**Files:**
- Modify: `App/DefaultsEditorView.swift` (the semicolyn/tmux section — near the existing `attemptControlMode`/`serverAlive` rows)

**Interfaces:**
- Consumes: `TmuxConfig.sessionName` (Task 1); the existing Defaults `semicolyn` binding + "Clear override" swipe pattern.
- Note: App-tier — macOS CI only.

- [ ] **Step 1: Add the field.** In the Defaults semicolyn/tmux section, add a `TextField` bound to `vm.defaults.semicolyn…tmux.sessionName`, mirroring the host field but with the Defaults "Clear override" swipe action used by the other Defaults rows:

```swift
            LabeledContent {
                TextField(
                    "inherit · semicolyn",
                    text: Binding(
                        get: { vm.defaults.semicolyn.value?.tmux?.sessionName ?? "" },
                        set: { newName in
                            var cfg = vm.defaults.semicolyn.value ?? SemicolynConfig()
                            var tmux = cfg.tmux ?? TmuxConfig()
                            tmux.sessionName = newName.isEmpty ? nil : newName
                            cfg.tmux = tmux
                            vm.defaults.semicolyn = .explicit(cfg)
                        }
                    )
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            } label: {
                Text("tmux session name")
                    .foregroundStyle(Color(theme.text.primary))
            }
            .swipeActions {
                if vm.defaults.semicolyn.value?.tmux?.sessionName != nil {
                    Button("Clear override") {
                        var cfg = vm.defaults.semicolyn.value ?? SemicolynConfig()
                        var tmux = cfg.tmux ?? TmuxConfig()
                        tmux.sessionName = nil
                        cfg.tmux = tmux
                        vm.defaults.semicolyn = .explicit(cfg)
                    }
                    .tint(Color(theme.accent.primary))
                }
            }
```

(Confirm the exact `vm.defaults` accessor + section placement against the existing `attemptControlMode` row in this file; match its structure.)

- [ ] **Step 2: Commit** (macOS CI is the gate):

```bash
git add App/DefaultsEditorView.swift
git commit -m "feat(ui): Defaults-editor tmux session-name field with clear-override"
```

---

### Task 8: Full Kit suite green + push for macOS CI

**Files:** none (verification task).

- [ ] **Step 1: Run the full Kit suite** to confirm no regression across the model/resolution/validation changes:

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS (all tests; new count = prior + the Task 1-4 additions).

- [ ] **Step 2: rustfmt/clippy are unaffected** (no Rust changed) — skip.

- [ ] **Step 3: Push the branch and open/refresh the PR** so macOS CI validates the App-tier tasks (5-7):

```bash
git push -u github feat/tmux-session-name
```

Then open a PR (or let the existing one build) and wait for the `macos` job — the only validator for the editor + launch-wiring changes. If `linux-rust` flakes on sshd readiness, rerun just that job (known flake).

- [ ] **Step 4: (Manual, user)** On the affected host, verify the ergonomic goal: set the Defaults session name to `semicolyn` (or a custom name), connect, and confirm `tmux ls` on the server shows that name and the app attaches to it. This also feeds the separate #2 crash-banner investigation.

---

## Self-Review

**1. Spec coverage:**
- Data model (`TmuxConfig.sessionName`) → Task 1 ✓
- Resolution (`resolveTmuxSessionName`, leaf-independent, builtin `"semicolyn"`, empty→fall-through) → Task 3 ✓
- Validation (`isValidTmuxSessionName`/`normalizedTmuxSessionName`, charset, editor hard-block) → Tasks 2 + 4 ✓
- Editor UI (host + Defaults fields, disabled-when-control-mode-off, red row, clear-override) → Tasks 6 + 7 ✓
- Launch wiring (swap hash for resolved name, keep `-A`, retire hash from this path only) → Task 5 ✓
- Testing (exact-value resolver asserts, adversarial validation negatives, Codable back-compat) → Tasks 1-4 ✓
- Out-of-scope items (attach-only, per-connection suffix, migration) → not built ✓

**2. Placeholder scan:** No TBD/TODO; every code step shows real code; test bodies are concrete. Two App-tier tasks (6, 7) say "confirm the exact accessor against the existing row" — that's a real instruction to match an established in-file pattern, not a placeholder, and the code shown is complete.

**3. Type consistency:** `TmuxConfig(attemptControlMode:sessionName:)`, `resolveTmuxSessionName(host:defaults:)`, `isValidTmuxSessionName(_:)`, `normalizedTmuxSessionName(_:)`, `builtInTmuxSessionName`, `ValidationIssue.Kind.invalidTmuxSessionName` — used identically across all tasks. The resolver reuses `resolveLeaf` (existing) exactly as `resolveTmuxAttemptControlMode` does.

Consistent. Ready to execute.
