# Host CRUD + Saved-Host Library Implementation Plan (Plan 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the host records Plan 1 persists into a usable library: an empty-state onboarding screen, a saved-host list (connect / edit / delete), the single-scrollable host editor (create + edit), the Defaults editor, and an inline "pick an existing identity" sub-flow — all backed by the `HostStore`/`HostKeyStore` wired in Plan 1.

**Architecture:** The spec's save-time validation rules become a pure, Linux-tested `HostFormValidation` over a `HostDraft` value type in `SemicolynKit` (cycle, duplicate-label, required fields, no-user, inline-jumphost, port-forward, stale passwordRef). The SwiftUI editor binds to that validator; the list and editor read/write through `AppStores` (Plan 1). Connect-from-saved resolves the host's effective config via the Phase-2a resolution table and reuses Plan 1's `TofuHostKeyVerifier`.

**Tech Stack:** Swift 6 (`SemicolynKit`, the validation core — Linux-tested), Swift 5 app target (SwiftUI), XCTest, the Phase-2a storage core + Plan-1 trust wiring. Linux loop: `docker compose run --rm dev swift test`. App target compiles only in the macOS CI job.

## Global Constraints

- Every source/test file begins with `// SPDX-FileCopyrightText: 2026 True Positive LLC` then `// SPDX-License-Identifier: GPL-3.0-only`.
- Placement: validation logic in `Sources/SemicolynKit/Model/`, Linux tests in `Tests/SemicolynKitTests/`; app UI in `App/`.
- **SemicolynKit stays Linux-clean.** The validation core has no SwiftUI/Apple deps and is fully Linux-tested. SwiftUI (`App/`) compiles only in macOS CI; absence of XCTest for views is expected, not a defect.
- **Spec of record:** `docs/superpowers/specs/2026-06-15-host-crud-design.md` (form, validation, delete, identity sub-flow, Defaults editor) + `docs/superpowers/specs/2026-06-15-host-config-model-design.md` (schema, resolution, invariants) + `docs/superpowers/specs/2026-06-16-first-host-onboarding-design.md` (empty state). Mock-up: `mockups/specs/host-crud.html`.
- Validation severities are **load-bearing** (host-crud-design §Validation): **hard-block** = cycle, inline-jumphost empty hostName, port-forward missing field, stale passwordRef; **soft-block** (warn, allow save) = duplicate label, no user set. Required (Save disabled) = `label`, `hostName` non-empty.
- Reuse existing logic — do NOT reimplement: `hasCycle` (`Resolution.swift`), the `resolve*` table (`Resolution.swift`), `HostStore.saveHost/deleteHost/hostsUsing` invariants (`HostStore.swift`). The validator runs the spec's checks *before* `saveHost`; `HostStore` remains the backstop.
- UUIDs internal, `label` for humans. `Inherited<T>`'s three states (`.inherit` / `.explicit(nil)` / `.explicit(value)`) must never collapse in the editor bindings.
- Theme: SwiftUI reads `@Environment(\.theme)` (defaults `.bellBronze`); `Color(themeColor)` bridges. Use `accent.primary` for primary actions, `state.broken` for destructive/error, `text.secondary` for dim.
- Conventional commits; commit after every green step. Branch `feat/host-crud-saved-hosts`; squash-merge at the end.
- Linux test command: `docker compose run --rm dev swift test --filter <TestClassName>`.

## Scope boundary (explicit deferrals)

- **Identity create / import** (host-crud-design §Identity sub-flow tabs 2–3) needs Apple key-minting (`SecKeyCreateRandomKey` / Secure Enclave), which Phase 2a deferred to **2b**. Plan 2 ships the **Pick-existing** tab only; the Create/Import tabs are stubbed with a "coming soon" note pointing at the 2b minting work.
- **Connect auth from a saved host**: password + keyboard-interactive only (reusing Plan 1's path). Publickey/cert connect needs the same minting + a Keychain signing path → 2b. The Auth section can still *reference* identities (stored as `host.identities`) for later use.
- **Quick-edit half-sheet vs deep-edit push** (host-crud-design §Quick-edit): Plan 2 ships one presentation — full-screen push from the list. The half-sheet variant is a later polish item.
- **`~/.ssh/config` import/export, bulk ops, auto-draft, per-field undo** — out of scope per the spec's own deferral list.

---

### Task 0: Branch + plan doc

- [ ] **Step 1:** `git checkout -b feat/host-crud-saved-hosts`
- [ ] **Step 2:** `git add docs/superpowers/plans/2026-06-22-host-crud-saved-hosts.md && git commit -m "docs: host CRUD + saved-hosts plan (Plan 2)"`

---

### Task 1: `HostDraft` + `HostFormValidation` (Core tier, Linux)

The editable form state as a value type, plus the spec's save-time validation as a pure function. This is the Linux-testable heart; the SwiftUI form is a thin binding over it.

**Files:**
- Create: `Sources/SemicolynKit/Model/HostFormValidation.swift`
- Test: `Tests/SemicolynKitTests/HostFormValidationTests.swift`

**Interfaces:**
- Consumes: `Host`, `Defaults`, `JumpHop`, `LocalForward`/`RemoteForward`/`DynamicForward`, `hasCycle` (`Resolution.swift`), `HostStore`-shaped inputs (passed as plain arrays — the validator is store-agnostic).
- Produces:
  ```swift
  public enum ValidationSeverity: Equatable, Sendable { case hardBlock, softBlock }
  public struct ValidationIssue: Equatable, Sendable {
      public enum Kind: Equatable, Sendable {
          case missingLabel, missingHostName          // hard (Save disabled)
          case jumpChainCycle                          // hard
          case inlineJumpHostMissingHostName(index: Int) // hard
          case localForwardMissingField(index: Int)    // hard
          case remoteForwardMissingField(index: Int)   // hard
          case dynamicForwardMissingField(index: Int)  // hard
          case stalePasswordRef                        // hard
          case duplicateLabel(existing: [HostRef])     // soft
          case noUserSet                               // soft
      }
      public let kind: Kind
      public let severity: ValidationSeverity
  }

  // Pure: given the edited host, the other saved hosts, the Defaults, and whether
  // the host's passwordRef still resolves to a stored secret, return every issue.
  public func validateHostForm(
      _ host: Host, others: [Host], defaults: Defaults, passwordRefResolves: Bool
  ) -> [ValidationIssue]

  // Convenience: true iff no `.hardBlock` issue is present (Save allowed).
  public func canSave(_ issues: [ValidationIssue]) -> Bool
  ```
  Rules (host-crud-design §Validation, host-config-model §Cycle/invariants):
  - `label.isEmpty` → `.missingLabel` (hard). `hostName.isEmpty` → `.missingHostName` (hard).
  - Cycle: build `[UUID: Host]` from `others + [host]`; `hasCycle(savingHostId: host.id, chain: host.resolvedJumpChain, in:)` → `.jumpChainCycle` (hard).
  - For each inline `JumpHop.inline` in `host.resolvedJumpChain` with empty `hostName` → `.inlineJumpHostMissingHostName(index:)` (hard).
  - For each `host.localForwards.value`/`remoteForwards.value` entry missing `hostAddress` (empty) or with `bindPort`/`hostPort` ≤ 0 → `.localForwardMissingField`/`.remoteForwardMissingField` (hard); each `dynamicForwards.value` entry with `bindPort` ≤ 0 → `.dynamicForwardMissingField` (hard).
  - `host.passwordRef.value != nil && !passwordRefResolves` → `.stalePasswordRef` (hard).
  - `others.filter { $0.label == host.label }` non-empty → `.duplicateLabel(existing:)` (soft) with their `HostRef`s.
  - `host.user.value == nil && defaults.user.value == nil` → `.noUserSet` (soft).

- [ ] **Step 1: Write the failing test** (EP + BVA + each rule, good AND bad)

```swift
// Tests/SemicolynKitTests/HostFormValidationTests.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class HostFormValidationTests: XCTestCase {
    private func h(_ label: String = "prod", _ id: UUID = UUID(),
                   hostName: String = "h", user: Inherited<String> = .explicit("u"),
                   jump: [JumpHop] = []) -> Host {
        Host(id: id, label: label, hostName: hostName, user: user,
             proxyJump: jump.isEmpty ? .inherit : .explicit(jump))
    }

    func testValidHostHasNoIssues() {
        let issues = validateHostForm(h(), others: [], defaults: Defaults(), passwordRefResolves: true)
        XCTAssertEqual(issues, [])
        XCTAssertTrue(canSave(issues))
    }

    func testMissingRequiredFieldsAreHardBlocks() {
        let bad = h("", hostName: "")
        let issues = validateHostForm(bad, others: [], defaults: Defaults(), passwordRefResolves: true)
        XCTAssertTrue(issues.contains { $0.kind == .missingLabel && $0.severity == .hardBlock })
        XCTAssertTrue(issues.contains { $0.kind == .missingHostName && $0.severity == .hardBlock })
        XCTAssertFalse(canSave(issues))
    }

    func testDirectCycleIsHardBlock() {
        let id = UUID()
        let host = h("self", id, jump: [.ref(hostId: id)])
        let issues = validateHostForm(host, others: [], defaults: Defaults(), passwordRefResolves: true)
        XCTAssertTrue(issues.contains { $0.kind == .jumpChainCycle && $0.severity == .hardBlock })
        XCTAssertFalse(canSave(issues))
    }

    func testInlineJumpHostEmptyHostNameIsHardBlockWithIndex() {
        let host = h("p", jump: [.inline(hostName: "", port: 22, user: nil, identities: nil)])
        let issues = validateHostForm(host, others: [], defaults: Defaults(), passwordRefResolves: true)
        XCTAssertTrue(issues.contains { $0.kind == .inlineJumpHostMissingHostName(index: 0) })
    }

    func testDuplicateLabelIsSoftBlockAndStillSavable() {
        let existing = h("prod")
        let issues = validateHostForm(h("prod"), others: [existing], defaults: Defaults(),
                                      passwordRefResolves: true)
        XCTAssertTrue(issues.contains { if case .duplicateLabel = $0.kind { return $0.severity == .softBlock }; return false })
        XCTAssertTrue(canSave(issues))   // soft → still savable
    }

    func testNoUserSoftBlockUnlessDefaultsProvides() {
        let host = h(user: .inherit)
        XCTAssertTrue(validateHostForm(host, others: [], defaults: Defaults(), passwordRefResolves: true)
            .contains { $0.kind == .noUserSet && $0.severity == .softBlock })
        // Defaults supplies a user → no issue.
        XCTAssertFalse(validateHostForm(host, others: [], defaults: Defaults(user: .explicit("root")),
                                        passwordRefResolves: true)
            .contains { $0.kind == .noUserSet })
    }

    func testStalePasswordRefIsHardBlock() {
        var host = h()
        host.passwordRef = .explicit(UUID())
        let issues = validateHostForm(host, others: [], defaults: Defaults(), passwordRefResolves: false)
        XCTAssertTrue(issues.contains { $0.kind == .stalePasswordRef && $0.severity == .hardBlock })
        XCTAssertFalse(canSave(issues))
    }

    func testPortForwardMissingFieldIsHardBlock() {
        var host = h()
        host.localForwards = .explicit([LocalForward(bindAddress: nil, bindPort: 0, hostAddress: "", hostPort: 0)])
        let issues = validateHostForm(host, others: [], defaults: Defaults(), passwordRefResolves: true)
        XCTAssertTrue(issues.contains { $0.kind == .localForwardMissingField(index: 0) })
    }
}
```

- [ ] **Step 2:** Run → fails. `docker compose run --rm dev swift test --filter HostFormValidationTests`
- [ ] **Step 3:** Implement per the rules above (reuse `hasCycle`; do not duplicate it).
- [ ] **Step 4:** Run → passes.
- [ ] **Step 5:** Commit — `feat: HostFormValidation (save-time checks over a draft)`

---

### Task 2: Home screen — empty state + saved-host list (App)

Replace `ConnectView` as the app root with a host **library**: the first-host empty state when no hosts exist, else a list (tap → connect, swipe → Edit / Delete). Delete routes through `HostStore.deleteHost`, surfacing the refused-if-referenced message.

**Files:**
- Create: `App/HostListView.swift`, `App/HostListViewModel.swift`
- Modify: `App/SemicolynApp.swift` (root → `HostListView`)

**Interfaces:**
- Consumes: `AppStores.shared.hosts` (`allHosts`/`deleteHost`), `Host`, `StoreError.jumpHostInUse`, the connect flow (Task 8 wires connect-from-saved; until then the row's connect can reuse the existing `ConnectionViewModel`).
- Produces:
  ```swift
  @MainActor final class HostListViewModel: ObservableObject {
      @Published var hosts: [Host] = []
      @Published var deleteError: String?        // set on refuse-if-referenced
      func reload()                              // hosts = (try? AppStores.shared.hosts.allHosts()) ?? []
      func delete(_ host: Host)                  // try deleteHost; on StoreError.jumpHostInUse set deleteError with referrer labels
  }
  struct HostListView: View {                    // empty state vs List; .onAppear { vm.reload() }
      // Empty: centered "Add your first host" CTA (accent.primary) + one-line micro-copy → opens editor in create mode.
      // List: each row shows label + hostName; tap → connect; .swipeActions → Edit (opens editor), Delete (red).
  }
  ```
  Empty-state copy verbatim (first-host-onboarding §Empty state): CTA `Add your first host`; micro-copy `You'll need a hostname, username, and either a password or key.` Keybar/predictor are not present here (no session). The empty state does not return after all hosts are deleted — the list's own "no hosts" state handles that.
  Delete refusal message (host-crud-design §Refused-if-referenced): `Cannot delete '<label>'. Used as jumphost by: <labels>. Remove these references first.`

- [ ] **Step 1:** Write `HostListViewModel.swift` (reload, delete with `StoreError.jumpHostInUse` → `deleteError`).
- [ ] **Step 2:** Write `HostListView.swift` (empty state + list + swipe actions + a `.sheet`/navigation to the editor from Task 3).
- [ ] **Step 3:** Point `SemicolynApp` root at `HostListView`.
- [ ] **Step 4:** macOS CI compile gate (push). Manual: empty state shows on first launch; after creating a host it lists; swipe-delete a referenced jumphost shows the refusal.
- [ ] **Step 5:** Commit — `feat: host library — empty state + saved-host list`

---

### Task 3: Host editor — Basics + Auth + Save/Cancel (App)

The single scrollable editor (create + edit), starting with the always-expanded sections and the save/validation spine bound to `HostFormValidation`.

**Files:**
- Create: `App/HostEditorView.swift`, `App/HostEditorViewModel.swift`
- Test: `Tests/SemicolynKitTests/HostEditorBindingTests.swift` (only if a Linux-testable binding helper is extracted; otherwise none)

**Interfaces:**
- Consumes: `HostFormValidation` (Task 1), `AppStores.shared.hosts`, `Host`, `Inherited<T>`, `Identity` (for the Auth pill row).
- Produces:
  ```swift
  @MainActor final class HostEditorViewModel: ObservableObject {
      @Published var host: Host                 // the working draft
      @Published var issues: [ValidationIssue] = []
      let isNew: Bool
      init(creating: Bool)                       // new Host(id: UUID(), label:"", hostName:"")
      init(editing: Host)
      func revalidate()                          // issues = validateHostForm(host, others:, defaults:, passwordRefResolves:)
      var canSave: Bool                          // canSave(issues) && !label.isEmpty && !hostName.isEmpty
      func save() throws -> SaveOutcome          // revalidate; if hard issues, throw; else AppStores...saveHost(host)
  }
  struct HostEditorView: View {
      // Header: title "New host"/label; Cancel (discard-confirm if changed); Save (disabled unless canSave).
      // Section "Basics": label (required •), hostName (required •), user, port.
      // Section "Auth": identities as a pill row + "+" (opens Task 6 sub-flow); "Use password" toggle → password row.
      // Inline banners for soft issues (duplicate label, no user) shown but non-blocking.
  }
  ```
  Bindings must preserve `Inherited<T>` semantics: an empty text field for `user`/`port` means `.inherit` (show the resolved "Defaults · 22" hint), a typed value means `.explicit(value)`. Provide small `Binding` helpers mapping `Inherited<String>`/`Inherited<Int>` ↔ `String`.

- [ ] **Step 1:** Write `HostEditorViewModel.swift` (draft, revalidate via Task 1, save).
- [ ] **Step 2:** Write `HostEditorView.swift` Basics + Auth sections + header chrome + soft-issue banners.
- [ ] **Step 3:** Wire create/edit entry from `HostListView` (Task 2).
- [ ] **Step 4:** macOS CI compile + manual: create a host (label/hostName required to enable Save); duplicate label saves with a warning banner.
- [ ] **Step 5:** Commit — `feat: host editor — Basics + Auth + validation spine`

---

### Task 4: Host editor — Connection + Jump chain + Port forwarding (App)

Add the three collapsed Tier-2/list sections, each auto-expanding on edit iff it holds a non-default value (host-crud-design §Expansion rules).

**Files:** Modify `App/HostEditorView.swift`.

- Section **Connection**: `serverAliveInterval`, `serverAliveCountMax`, `compression`, `strictHostKeyChecking` (picker: yes/accept-new/ask/no), `forwardAgent`, `preferredAuthentications`.
- Section **Jump chain**: `proxyJump[]`; each row toggles Pick-host (from saved hosts → `.ref(hostId:)`) vs Inline (`user@host:port` → `.inline`). Inline empty-hostName surfaces the Task-1 hard issue inline.
- Section **Port forwarding**: three sub-lists (`localForwards`/`remoteForwards`/`dynamicForwards`) with `+` per list; missing-field hard issues shown inline.

- [ ] **Step 1:** Add the three sections with `.explicit/.inherit`-preserving bindings + per-row add/remove.
- [ ] **Step 2:** Wire the Task-1 hard issues (cycle, inline-jumphost, port-forward) to inline error styling + section auto-expand on a flagged field.
- [ ] **Step 3:** macOS CI compile + manual: add a cyclic jump ref → Save blocked with the cycle banner; add an inline hop with empty host → inline error.
- [ ] **Step 4:** Commit — `feat: host editor — Connection, Jump chain, Port forwarding`

---

### Task 5: Host editor — Mosh + Tailscale + Semicolyn + Delete (App)

The remaining namespaced-extension sections, the conditional caveats, and the edit-mode Delete row.

**Files:** Modify `App/HostEditorView.swift`; reuse `HostListViewModel.delete` semantics or call `HostStore.deleteHost` directly with the refusal sheet.

- Section **Mosh**: `mosh.enabled` master toggle reveals `serverPath`, `udpPortRange`, `predictionMode`. When `enabled`, Connection's `serverAliveInterval`/`serverAliveCountMax` render disabled with the caveat *"Mosh has its own keepalive."* (host-crud-design §Conditional visibility).
- Section **Tailscale**: `tailscale.required` toggle reveals `tailnet`; caveat banner when required.
- Section **Semicolyn behavior**: `semicolyn.predictor.incognito`, `semicolyn.tmux.attemptControlMode` toggles.
- **Delete host** row (edit mode only): destructive; confirmation sheet *"Delete '<label>'?"*; routes through `HostStore.deleteHost` → on `StoreError.jumpHostInUse` shows the refused-if-referenced banner with tappable referrer labels (host-crud-design §Delete).

- [ ] **Step 1:** Add the three sections + the conditional disabled/caveat behavior.
- [ ] **Step 2:** Add the Delete row + confirmation sheet + refusal handling.
- [ ] **Step 3:** macOS CI compile + manual: enabling Mosh greys the keepalive rows; deleting a referenced host is refused.
- [ ] **Step 4:** Commit — `feat: host editor — Mosh, Tailscale, Semicolyn sections + delete`

---

### Task 6: Inline identity sub-flow — Pick existing (App)

The half-sheet from the Auth `+`. Plan 2 ships the **Pick existing** tab; Create/Import are stubbed (need 2b key-minting).

**Files:** Create `App/IdentityPickerSheet.swift`. Modify `App/HostEditorView.swift` (present it from the Auth `+`).

**Interfaces:**
- Consumes: `AppStores.shared.hosts.allIdentities()`, `Identity`, `Fingerprint`.
- Produces: `IdentityPickerSheet` — three tabs; **Pick existing** lists each `Identity` (displayName, truncated fingerprint via `Fingerprint`, flavor badge `iCloud Keychain`/`Secure Enclave`, biometric-policy glyph). Tap → appends its `id` to `host.identities` and dismisses. **Create new** / **Import existing** tabs render a one-line note: *"Key generation arrives with Secure-Enclave support (Phase 2b)."*

- [ ] **Step 1:** Write `IdentityPickerSheet.swift` (Pick-existing list + the two stub tabs).
- [ ] **Step 2:** Present it from the Auth section `+`; selected identity shows in the pill row.
- [ ] **Step 3:** macOS CI compile + manual: pick an identity → appears as a pill; Create/Import show the 2b note.
- [ ] **Step 4:** Commit — `feat: inline identity picker (pick-existing; create/import stubbed for 2b)`

---

### Task 7: Defaults editor (App)

The Defaults singleton editor: the same section shell minus `label`/`hostName`/Delete, with inherit-vs-set row states and swipe-to-clear-override.

**Files:** Create `App/DefaultsEditorView.swift` (reusing the section views from the host editor where practical). Entry point: a "Defaults" row at the top of `HostListView`.

**Interfaces:**
- Consumes: `AppStores.shared.hosts.defaults()`/`saveDefaults(_:)`, `Defaults`, the resolution fallback table (for the `inherit · <fallback>` row labels).
- Produces: `DefaultsEditorView` — all sections collapsed by default; each row shows `inherit · <fallback>` when unset or the explicit value when set; **swipe-left on a set row = Clear override** (→ `.inherit`); Save always enabled (no required fields).

- [ ] **Step 1:** Write `DefaultsEditorView.swift` + the "Defaults" entry row in `HostListView`.
- [ ] **Step 2:** macOS CI compile + manual: set a Default (e.g. user `root`), reopen a host → its empty user field hints `Defaults · root`; clear-override reverts.
- [ ] **Step 3:** Commit — `feat: Defaults editor (inherit/set rows + clear-override)`

---

### Task 8: Connect-from-saved + verification + docs

Wire tapping a saved host to an actual connection using its resolved config, then verify and merge.

**Files:** Modify `App/HostListViewModel.swift` / the connect path (reuse `ConnectionViewModel` + Plan 1's `TofuHostKeyVerifier`).

- Resolve the tapped host's effective `user` (`resolveUser`), `port` (`resolvePort`) against `defaults()`; if `resolveUser` throws `.userUnset`, surface *"Set a user for this host or in Defaults to connect."* (host-config-model fallback table). Connect with `TofuHostKeyVerifier(hostID: host.id, …)`; auth = password (from the host's stored `passwordRef` secret if present, else prompt) or keyboard-interactive. Publickey/cert connect is deferred (2b) — note it in the auth UI.
- [ ] **Step 1:** Wire connect-from-saved (resolution + verifier + password auth).
- [ ] **Step 2: Full Linux suite** — `docker compose run --rm dev swift test` (all green incl. `HostFormValidationTests`).
- [ ] **Step 3: macOS CI** green (push) + manual: create a host → tap → first-trust modal → shell; no-user host shows the clear refuse message.
- [ ] **Step 4: Code review** — project review loop over the branch; address findings.
- [ ] **Step 5: Squash-merge** to `main`; **sync docs** (`sync` skill) — note remaining Phase 2b work (Apple key-minting → identity create/import + publickey connect; CloudKit sync).
- [ ] **Step 6: Commit/merge.**

---

## Deferred to Phase 2b (Apple key-minting + CloudKit)

- Identity **Create / Import** tabs (key generation via `SecKeyCreateRandomKey` / Secure Enclave); **publickey/cert connect** from a saved host.
- Quick-edit **half-sheet** presentation; `~/.ssh/config` import/export; bulk ops; auto-draft; per-field undo (spec's own deferral list).
- CloudKit sync backend + per-category sync toggles UI.

## Verification

- **Per task (Linux):** `docker compose run --rm dev swift test --filter HostFormValidationTests`.
- **App tasks:** macOS CI simulator build green + the per-task manual checks.
- **End-to-end:** create → list → connect (first-trust) → shell; delete-refused-if-referenced; Defaults inheritance hint; duplicate-label warning saves anyway.

## Self-Review (spec coverage — host-crud-design)

- Single scrollable form, create+edit (Task 3–5); expansion rules (Task 4); conditional caveats (Task 5); identity sub-flow pick-existing (Task 6, create/import deferred); validation hard/soft severities (Task 1 + surfaced 3–5); delete + refused-if-referenced (Task 5/2); Defaults editor (Task 7); empty-state onboarding (Task 2); connect-from-saved (Task 8).
