# Host-Key Trust Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the MVP's `AutoTrustVerifier` with real trust-on-first-use host-key verification (first-trust + mismatch modals), persist trusted keys and host records in the iOS Keychain so they survive relaunch and sync across devices, and remember connected hosts as `Host` records.

**Architecture:** The trust *decision* (trusted / first-trust / mismatch) is a pure, Linux-tested `HostKeyTrustEvaluator` over the already-built `HostKeyStore`. The app supplies a real `SecretStore` backed by the iOS Keychain (`KeychainSecretStore`), composes the storage stack in one `AppStores` root, and bridges the Rust `HostKeyVerifier` callback to SwiftUI first-trust/mismatch modals via `TofuHostKeyVerifier`. The existing connect form persists the typed host as a `Host` record so its UUID keys the known-hosts store and reconnects are remembered.

**Tech Stack:** Swift 6 (`GlymrKit`, platform-agnostic logic + the Keychain backend behind `#if canImport(Security)`), Swift 5 app target (SwiftUI + UniFFI bridge), XCTest, the Rust `glymr-ssh-core` UniFFI `HostKeyVerifier`/`HostKeyInfo` contract (already shipped). Linux test loop: `docker compose run --rm dev swift test`.

## Global Constraints

- Every source/test file begins with `// SPDX-FileCopyrightText: 2026 True Positive LLC` then `// SPDX-License-Identifier: GPL-3.0-only`.
- Placement: platform-agnostic logic + the Keychain backend in `Sources/GlymrKit/Storage/`; Linux-runnable tests in `Tests/GlymrKitTests/`; app code in `App/`.
- **GlymrKit must keep compiling and testing on Linux.** Anything Apple-only (`Security`, `Keychain`) is guarded by `#if canImport(Security)`; the parts that gate trust (decision logic, the `SecretRef`→account mapping) stay platform-agnostic and Linux-tested. App SwiftUI code (`App/`) compiles only in the macOS CI job (the `Glymr` iOS-simulator build).
- Default policy is `strictHostKeyChecking = ask` (explicit confirm on first trust AND on key change) — `2026-06-17-host-key-trust-design.md` §"Default policy".
- Each `(host, key type)` is trusted independently; a key change on one algorithm never invalidates another — same spec §"When the modal fires".
- `HostKey.source` for a TOFU-accepted key is `.trustOnFirstUse`; `algorithm` is stored verbatim as the wire name from `HostKeyInfo.keyType` (e.g. `"ssh-ed25519"`).
- Fingerprints are SHA256/base64, displayed truncated as `SHA256:s4xL+m2…WYzZ` (first 5 chars after the `SHA256:` prefix + `…` + last 4) but always expandable to full — spec §"Cross-modal interaction".
- No biometric gate on either trust action (the device-unlock gate already covers authority) — spec §"Behavior".
- Storage write happens **after** the user's trust action, not on modal dismiss — spec §"Cross-modal interaction".
- Testing tiers: **Critical** for `HostKeyTrustEvaluator` (EP + BVA + adversarial: wrong key must read as `.mismatch`, never `.trusted`) and the `SecretRef`→account injectivity; **Core** for `Fingerprint` formatting.
- Conventional commits; commit after every green step. Branch `feat/host-key-trust-foundation`; squash-merge at the end.
- Linux test command: `docker compose run --rm dev swift test --filter <TestClassName>`.

---

### Task 0: Branch + plan doc

- [ ] **Step 1: Create the feature branch**

```bash
git checkout -b feat/host-key-trust-foundation
```

- [ ] **Step 2: Commit the plan doc**

```bash
git add docs/superpowers/plans/2026-06-22-host-key-trust-foundation.md
git commit -m "docs: host-key trust foundation plan"
```

---

### Task 1: `Fingerprint` formatting (Core tier, Linux)

A pure value type that normalizes and truncates SHA256 fingerprints for the modals, with the exact format the spec mandates. No SwiftUI.

**Files:**
- Create: `Sources/GlymrKit/Storage/Fingerprint.swift`
- Test: `Tests/GlymrKitTests/FingerprintTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct Fingerprint: Equatable, Sendable {
      public let full: String            // canonical "SHA256:<base64>"
      public init(_ raw: String)         // stores raw verbatim as `full`
      public var truncated: String       // "SHA256:s4xL+m2…WYzZ"; full if too short to truncate
  }
  ```
  Truncation rule: strip a leading `"SHA256:"` prefix → `body`. If `body.count <= 9` (5 + 4, the chars truncation would show) return `full` unchanged. Else return `"SHA256:" + body.prefix(5) + "…" + body.suffix(4)`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/GlymrKitTests/FingerprintTests.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import GlymrKit

final class FingerprintTests: XCTestCase {
    func testTruncationMatchesSpecFormat() {
        let fp = Fingerprint("SHA256:s4xLm2abcdefghijklWYzZ")
        XCTAssertEqual(fp.full, "SHA256:s4xLm2abcdefghijklWYzZ")
        XCTAssertEqual(fp.truncated, "SHA256:s4xLm…WYzZ")   // first 5 of body + … + last 4
    }

    func testShortFingerprintIsNotTruncated() {
        // body "abc" (3 chars) ≤ 9 → returned whole, no ellipsis.
        let fp = Fingerprint("SHA256:abc")
        XCTAssertEqual(fp.truncated, "SHA256:abc")
        XCTAssertFalse(fp.truncated.contains("…"))
    }

    func testBoundaryBodyOfNineIsNotTruncatedTenIs() {
        XCTAssertEqual(Fingerprint("SHA256:123456789").truncated, "SHA256:123456789")     // 9 → whole
        XCTAssertEqual(Fingerprint("SHA256:1234567890").truncated, "SHA256:12345…7890")   // 10 → truncated
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `docker compose run --rm dev swift test --filter FingerprintTests` → FAIL (no such type).
- [ ] **Step 3: Implement** `Fingerprint.swift` per the truncation rule above.
- [ ] **Step 4: Run to verify it passes.**
- [ ] **Step 5: Commit** — `feat: Fingerprint SHA256 truncation formatting`

---

### Task 2: `HostKeyTrustEvaluator` (Critical tier, Linux)

The trust-decision core over `HostKeyStore`. Decides — without mutating — whether an offered key is already trusted, brand-new (first-trust), or a mismatch; and provides the persist-on-accept (`trust`) and replace-on-mismatch (`replace`) mutations. Each `(host, algorithm)` is evaluated independently.

**Files:**
- Create: `Sources/GlymrKit/Storage/HostKeyTrustEvaluator.swift`
- Test: `Tests/GlymrKitTests/HostKeyTrustEvaluatorTests.swift`

**Interfaces:**
- Consumes: `HostKeyStore` (`entries(forHost:)`, `add(_:forHost:)`, `remove(fingerprint:forHost:)`), `HostKey`, `HostKeySource.trustOnFirstUse`.
- Produces:
  ```swift
  public enum HostKeyDecision: Equatable, Sendable {
      case trusted                       // offered fp matches a stored entry of this algorithm
      case firstTrust                    // no stored entry of this algorithm
      case mismatch(stored: [HostKey])   // entries of this algorithm exist; none match the offered fp
  }

  public struct HostKeyTrustEvaluator {
      public init(store: HostKeyStore)
      /// Pure decision; never mutates storage.
      public func evaluate(hostID: UUID, algorithm: String, fingerprint: String) throws -> HostKeyDecision
      /// First-trust accept: append a `.trustOnFirstUse` entry for (host, algorithm, fingerprint).
      public func trust(hostID: UUID, algorithm: String, fingerprint: String, at now: Date) throws
      /// Mismatch replace: drop every stored entry of `algorithm` for this host, then add the new one.
      public func replace(hostID: UUID, algorithm: String, fingerprint: String, at now: Date) throws
  }
  ```
  Semantics:
  - `evaluate`: let `matching = entries(forHost:).filter { $0.algorithm == algorithm }`. If `matching.isEmpty` → `.firstTrust`. If `matching.contains(where: { $0.fingerprint == fingerprint })` → `.trusted`. Else → `.mismatch(stored: matching)`.
  - `trust`: `store.add(HostKey(algorithm:, fingerprint:, addedAt: now, source: .trustOnFirstUse), forHost:)`.
  - `replace`: for each `e` in `entries(forHost:)` where `e.algorithm == algorithm`, `store.remove(fingerprint: e.fingerprint, forHost:)`; then `store.add(HostKey(..., source: .trustOnFirstUse), forHost:)`. (Entries of *other* algorithms are untouched.)

- [ ] **Step 1: Write the failing test** (Critical: EP, BVA-by-algorithm, adversarial wrong-key, rotation, persistence)

```swift
// Tests/GlymrKitTests/HostKeyTrustEvaluatorTests.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import GlymrKit

final class HostKeyTrustEvaluatorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 0)
    private func evaluator() -> (HostKeyTrustEvaluator, HostKeyStore) {
        let store = HostKeyStore(secrets: InMemorySecretStore())
        return (HostKeyTrustEvaluator(store: store), store)
    }

    func testEmptyHostIsFirstTrust() throws {
        let (ev, _) = evaluator()
        XCTAssertEqual(try ev.evaluate(hostID: UUID(), algorithm: "ssh-ed25519",
                                       fingerprint: "SHA256:AAA"), .firstTrust)
    }

    func testTrustThenSameKeyReadsTrusted() throws {
        let (ev, _) = evaluator()
        let h = UUID()
        try ev.trust(hostID: h, algorithm: "ssh-ed25519", fingerprint: "SHA256:AAA", at: t0)
        XCTAssertEqual(try ev.evaluate(hostID: h, algorithm: "ssh-ed25519",
                                       fingerprint: "SHA256:AAA"), .trusted)
    }

    func testDifferentFingerprintSameAlgorithmIsMismatchNotTrusted() throws {
        let (ev, _) = evaluator()
        let h = UUID()
        try ev.trust(hostID: h, algorithm: "ssh-ed25519", fingerprint: "SHA256:AAA", at: t0)
        let decision = try ev.evaluate(hostID: h, algorithm: "ssh-ed25519", fingerprint: "SHA256:BBB")
        guard case let .mismatch(stored) = decision else {
            return XCTFail("expected mismatch, got \(decision)")
        }
        XCTAssertEqual(stored.map(\.fingerprint), ["SHA256:AAA"])   // surfaces the stored key for the modal
    }

    func testNewAlgorithmIsFirstTrustEvenWhenAnotherAlgorithmTrusted() throws {
        let (ev, _) = evaluator()
        let h = UUID()
        try ev.trust(hostID: h, algorithm: "ssh-ed25519", fingerprint: "SHA256:AAA", at: t0)
        // A different key type negotiated → independent first-trust, not a mismatch.
        XCTAssertEqual(try ev.evaluate(hostID: h, algorithm: "rsa-sha2-512",
                                       fingerprint: "SHA256:CCC"), .firstTrust)
    }

    func testRotationWindowBothKeysTrusted() throws {
        let (ev, _) = evaluator()
        let h = UUID()
        try ev.trust(hostID: h, algorithm: "ssh-ed25519", fingerprint: "SHA256:AAA", at: t0)
        try ev.trust(hostID: h, algorithm: "ssh-ed25519", fingerprint: "SHA256:BBB", at: t0)
        XCTAssertEqual(try ev.evaluate(hostID: h, algorithm: "ssh-ed25519", fingerprint: "SHA256:AAA"), .trusted)
        XCTAssertEqual(try ev.evaluate(hostID: h, algorithm: "ssh-ed25519", fingerprint: "SHA256:BBB"), .trusted)
    }

    func testReplaceDropsOldKeyAndKeepsOtherAlgorithms() throws {
        let (ev, store) = evaluator()
        let h = UUID()
        try ev.trust(hostID: h, algorithm: "ssh-ed25519", fingerprint: "SHA256:AAA", at: t0)
        try ev.trust(hostID: h, algorithm: "rsa-sha2-512", fingerprint: "SHA256:RRR", at: t0)
        try ev.replace(hostID: h, algorithm: "ssh-ed25519", fingerprint: "SHA256:NEW", at: t0)
        XCTAssertEqual(try ev.evaluate(hostID: h, algorithm: "ssh-ed25519", fingerprint: "SHA256:NEW"), .trusted)
        // The old ed25519 key is gone…
        guard case .mismatch = try ev.evaluate(hostID: h, algorithm: "ssh-ed25519", fingerprint: "SHA256:AAA") else {
            return XCTFail("old key should no longer be trusted")
        }
        // …and the untouched rsa key remains.
        XCTAssertEqual(try ev.evaluate(hostID: h, algorithm: "rsa-sha2-512", fingerprint: "SHA256:RRR"), .trusted)
        XCTAssertEqual(Set(try store.entries(forHost: h).map(\.fingerprint)), ["SHA256:NEW", "SHA256:RRR"])
    }
}
```

- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Implement** `HostKeyTrustEvaluator.swift` per the semantics above.
- [ ] **Step 4: Run to verify it passes.**
- [ ] **Step 5: Commit** — `feat: HostKeyTrustEvaluator (TOFU decision + trust/replace)`

---

### Task 3: `KeychainSecretStore` + `SecretRef` account mapping

A `SecretStore` backed by the iOS/macOS Keychain (`Security`), with `kSecAttrSynchronizable` so secrets ride iCloud Keychain (synced, E2EE) per the storage backbone. The `SecretRef`→account mapping is a **pure, Linux-tested** function (injectivity is security-relevant: two distinct refs must never collide onto one Keychain item); the Keychain calls themselves are `#if canImport(Security)` and verified on the simulator.

**Files:**
- Create: `Sources/GlymrKit/Storage/KeychainSecretStore.swift`
- Test: `Tests/GlymrKitTests/KeychainAccountTests.swift` (Linux — the mapping only)

**Interfaces:**
- Consumes: `SecretRef`, `SecretStore`.
- Produces:
  ```swift
  // Pure, platform-agnostic — the Keychain `kSecAttrAccount` for a ref. Injective.
  public func keychainAccount(for ref: SecretRef) -> String

  #if canImport(Security)
  public final class KeychainSecretStore: SecretStore {
      public init(service: String = "com.truepositive.glymr.secrets", synchronizable: Bool = true)
      public func setSecret(_ data: Data, for ref: SecretRef) throws
      public func getSecret(_ ref: SecretRef) throws -> Data?
      public func deleteSecret(_ ref: SecretRef) throws
  }
  public enum KeychainError: Error, Equatable { case unexpectedStatus(OSStatus) }
  #endif
  ```
  Account mapping (stable strings, one namespace prefix per kind so kinds can't collide):
  - `.recordKey` → `"recordKey"`
  - `.privateKey(identityID: id)` → `"privateKey/\(id.uuidString)"`
  - `.password(id)` → `"password/\(id.uuidString)"`
  - `.passphrase(identityID: id)` → `"passphrase/\(id.uuidString)"`
  - `.hostKeys(hostID: id)` → `"hostKeys/\(id.uuidString)"`

  Keychain item attributes (all items): `kSecClass = kSecClassGenericPassword`, `kSecAttrService = service`, `kSecAttrAccount = keychainAccount(for: ref)`, `kSecAttrSynchronizable = synchronizable`, `kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlock`.
  - `setSecret`: build a query of (class, service, account, synchronizable); `SecItemCopyMatching` to test existence → if found, `SecItemUpdate` setting `kSecValueData`; else `SecItemAdd` with `kSecValueData`. Map any non-`errSecSuccess` status to `KeychainError.unexpectedStatus`.
  - `getSecret`: query + `kSecReturnData = true`, `kSecMatchLimit = kSecMatchLimitOne`; `errSecItemNotFound` → `nil`; `errSecSuccess` → the `Data`; else throw.
  - `deleteSecret`: `SecItemDelete`; `errSecSuccess` or `errSecItemNotFound` → ok (idempotent); else throw.

- [ ] **Step 1: Write the failing test** (Linux — mapping injectivity + format)

```swift
// Tests/GlymrKitTests/KeychainAccountTests.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import GlymrKit

final class KeychainAccountTests: XCTestCase {
    func testRecordKeyAccountIsStable() {
        XCTAssertEqual(keychainAccount(for: .recordKey), "recordKey")
    }

    func testKindsWithSameUUIDDoNotCollide() {
        let id = UUID()
        let accounts = [
            keychainAccount(for: .privateKey(identityID: id)),
            keychainAccount(for: .password(id: id)),
            keychainAccount(for: .passphrase(identityID: id)),
            keychainAccount(for: .hostKeys(hostID: id)),
        ]
        XCTAssertEqual(Set(accounts).count, 4)   // distinct kinds → distinct accounts
        XCTAssertTrue(keychainAccount(for: .hostKeys(hostID: id)).hasPrefix("hostKeys/"))
    }

    func testDifferentUUIDsDoNotCollide() {
        let a = UUID(), b = UUID()
        XCTAssertNotEqual(keychainAccount(for: .hostKeys(hostID: a)),
                          keychainAccount(for: .hostKeys(hostID: b)))
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `docker compose run --rm dev swift test --filter KeychainAccountTests`.
- [ ] **Step 3: Implement** `KeychainSecretStore.swift` — the pure `keychainAccount(for:)` first (no guard), then the `#if canImport(Security)` class.
- [ ] **Step 4: Run to verify the Linux mapping test passes.**
- [ ] **Step 5: Commit** — `feat: KeychainSecretStore + SecretRef account mapping`

> **Verification note (honest):** the `keychainAccount` mapping is fully Linux-tested. The Keychain `set/get/delete` paths are Apple-only and are **not** exercised by a headless test (generic-password access in a macOS CI runner needs a provisioned keychain and would be flaky). They compile in the macOS CI job and are verified manually on the iOS Simulator in Task 6 (connect → trust → relaunch → reconnect is silent ⇒ the round-trip works).

---

### Task 4: `AppStores` composition root (App, iOS)

One place that builds the live storage stack the app uses: `FileBlobStore` (host records on disk) → `EncryptedRecordStore` (AES-sealed via the Keychain-held record key) → `HostStore`, plus `HostKeyStore` over `KeychainSecretStore`. Adds the `GlymrKit` product as an app dependency.

**Files:**
- Modify: `project.yml` (add `GlymrKit` to the `Glymr` target's `dependencies`)
- Create: `App/AppStores.swift`

**Interfaces:**
- Consumes: `KeychainSecretStore`, `recordKey(in:)`, `FileBlobStore`, `EncryptedRecordStore`, `HostStore`, `HostKeyStore`, `HostKeyTrustEvaluator`.
- Produces:
  ```swift
  @MainActor
  final class AppStores {
      static let shared = try! AppStores()       // app-lifetime singleton
      let hosts: HostStore
      let hostKeys: HostKeyStore
      let trust: HostKeyTrustEvaluator
      init() throws
  }
  ```
  `init`: `dir = FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("glymr", isDirectory: true)`; `secrets = KeychainSecretStore()`; `let key = try recordKey(in: secrets)`; `let blobs = FileBlobStore(directory: dir.appendingPathComponent("records"))`; `hosts = HostStore(records: EncryptedRecordStore(backend: blobs, key: key))`; `hostKeys = HostKeyStore(secrets: secrets)`; `trust = HostKeyTrustEvaluator(store: hostKeys)`.

- [ ] **Step 1: Add the dependency** — in `project.yml`, under `targets.Glymr.dependencies`, add:
  ```yaml
      - package: GlymrPackage
        product: GlymrKit
  ```
- [ ] **Step 2: Write `App/AppStores.swift`** per the interface above (`import Foundation`, `import GlymrKit`).
- [ ] **Step 3: Commit** — `feat: AppStores composition root (Keychain + FileBlob storage stack)`

> No unit test here — it's wiring of already-tested units, and it depends on Apple-only `KeychainSecretStore`. The macOS CI `xcodegen generate && xcodebuild` simulator build is the compile gate; the behavioral gate is Task 6's manual run.

---

### Task 5: First-trust & mismatch modals (App, iOS)

The two SwiftUI surfaces from the spec, driven by a single `HostKeyPrompt` value and resolved through an `async` continuation so the off-main Rust verifier can `await` a user decision.

**Files:**
- Create: `App/HostKeyPrompt.swift` (the prompt model + the modal views)

**Interfaces:**
- Consumes: `Fingerprint`, `HostKey`, `GlymrKit.Theme` tokens (`accent.primary`, `state.broken`, `text.secondary`).
- Produces:
  ```swift
  enum HostKeyPrompt: Identifiable, Equatable {
      case firstTrust(hostLabel: String, keyType: String, offered: String)
      case mismatch(hostLabel: String, keyType: String, stored: String, offered: String)
      var id: String { ... }   // stable per case+content
  }
  struct FirstTrustModal: View {                  // "Trust this host?" — Trust & Connect / Cancel
      let hostLabel: String; let keyType: String; let offered: String
      let onDecision: (Bool) -> Void
  }
  struct MismatchModal: View {                    // "⚠ Host key changed" — Cancel / Replace key & connect (2-step)
      let hostLabel: String; let keyType: String; let stored: String; let offered: String
      let onDecision: (Bool) -> Void
  }
  ```
  Behavior per `2026-06-17-host-key-trust-design.md`:
  - First-trust: neutral header; host label (large), `keyType` (dim), `Fingerprint(offered).truncated` in monospace, tappable to toggle full; body copy verbatim from spec §"First-trust modal"; **Trust & Connect** (`accent.primary`) → `onDecision(true)`; **Cancel** → `onDecision(false)`. Fingerprint is `.textSelection(.enabled)`.
  - Mismatch: red header strip (`state.broken`); shows `Last seen:` `Fingerprint(stored).truncated` (dim) and `Now offering:` `Fingerprint(offered).truncated` (bright); **Cancel** → `onDecision(false)`; **Replace key & connect** opens a destructive `.confirmationDialog` ("Replace stored key?") whose confirm → `onDecision(true)`, cancel dismisses the dialog only.
  - No biometric prompt in either path.

- [ ] **Step 1: Write `App/HostKeyPrompt.swift`** with the prompt enum and both modal views, using `Fingerprint` for display and Theme tokens for color. (UI-only; verified by the macOS CI compile + Task 6 manual run — no XCTest.)
- [ ] **Step 2: Commit** — `feat: first-trust & mismatch host-key modals`

---

### Task 6: `TofuHostKeyVerifier` + connect-flow wiring (App, iOS)

Bridge the Rust `HostKeyVerifier` callback to the evaluator and the modals; persist the typed host as a `Host` record so its UUID keys known-hosts and the connection is remembered; replace `AutoTrustVerifier`.

**Files:**
- Modify: `App/Bridges.swift` (remove `AutoTrustVerifier`; add `TofuHostKeyVerifier`)
- Modify: `App/ConnectionViewModel.swift` (find-or-create the host record; build the verifier with its UUID; surface the pending prompt)
- Modify: `App/ConnectView.swift` (present the modal sheet bound to the VM's pending prompt)

**Interfaces:**
- Consumes: `HostKeyVerifier`, `HostKeyInfo` (FFI), `HostKeyTrustEvaluator`, `HostKeyPrompt`, `AppStores`, `GlymrKit.Host`.
- Produces:
  ```swift
  final class TofuHostKeyVerifier: HostKeyVerifier {
      init(hostID: UUID,
           trust: HostKeyTrustEvaluator,
           present: @escaping @MainActor (HostKeyPrompt) async -> Bool)
      func verify(info: HostKeyInfo) async -> Bool
  }
  ```
  `verify`: `let decision = (try? trust.evaluate(hostID:, algorithm: info.keyType, fingerprint: info.fingerprint)) ?? .firstTrust`. On `.trusted` → return `true` with no prompt. On `.firstTrust` → `let ok = await present(.firstTrust(hostLabel: info.hostLabel, keyType: info.keyType, offered: info.fingerprint))`; if `ok`, `try? trust.trust(hostID:, algorithm:, fingerprint:, at: Date())`; return `ok`. On `.mismatch(let stored)` → `let ok = await present(.mismatch(hostLabel: info.hostLabel, keyType: info.keyType, stored: stored.first?.fingerprint ?? "", offered: info.fingerprint))`; if `ok`, `try? trust.replace(hostID:, algorithm:, fingerprint:, at: Date())`; return `ok`.

  `ConnectionViewModel` changes:
  - Add `@Published var pendingPrompt: HostKeyPrompt?` and a `private var promptContinuation: CheckedContinuation<Bool, Never>?`.
  - `present(_:)` (a `@MainActor` method): store the continuation, set `pendingPrompt`; returns when the view calls `resolvePrompt(_:)`.
  - `resolvePrompt(_ trusted: Bool)`: clear `pendingPrompt`, resume the continuation with `trusted`.
  - In `connect(...)`: before connecting, `let host = try findOrCreateHost(hostName: host, port: port, user: user)` against `AppStores.shared.hosts` — match an existing host by (`hostName`, resolved `port`, resolved `user`); if none, `saveHost(Host(id: UUID(), label: host, hostName: host, user: .explicit(user), port: .explicit(Int(port) ?? 22)))`. Build `TofuHostKeyVerifier(hostID: host.id, trust: AppStores.shared.trust, present: { [weak self] p in await self?.present(p) ?? false })` and pass it to `GlymrSSHCoreFFI.connect`.
  - On `ConnectError.hostKeyRejected`, set `state = .failed("Host key not trusted")`.

  `ConnectView` change: add `.sheet(item: $vm.pendingPrompt) { prompt in ... }` rendering `FirstTrustModal`/`MismatchModal`, each `onDecision: { vm.resolvePrompt($0) }`.

- [ ] **Step 1: Replace `AutoTrustVerifier`** in `App/Bridges.swift` with `TofuHostKeyVerifier` (delete the auto-trust stub).
- [ ] **Step 2: Wire `ConnectionViewModel`** — add the prompt continuation plumbing, the find-or-create-host step, and build the real verifier.
- [ ] **Step 3: Present the sheet** in `ConnectView`.
- [ ] **Step 4: macOS CI compile gate** — push triggers the `macos` job (`xcodegen generate` + simulator `xcodebuild`); confirm the app target builds.
- [ ] **Step 5: Manual simulator verification** (the behavioral gate; record the result):
  - First connect to a host → **first-trust modal** appears; tap Trust & Connect → shell opens.
  - Disconnect, relaunch the app, connect again → **no modal** (key trusted, persisted in Keychain across launch).
  - Point the same label at a server with a different host key → **mismatch modal**; Cancel aborts; Replace key & connect (after the 2-step confirm) proceeds and silences subsequent connects.
- [ ] **Step 6: Commit** — `feat: real TOFU host-key verification wired into connect`

---

### Task 7: Verification + docs sync

- [ ] **Step 1: Full Linux suite** — `docker compose run --rm dev swift test`. Expected: all prior suites green + new `FingerprintTests`, `HostKeyTrustEvaluatorTests`, `KeychainAccountTests`.
- [ ] **Step 2: Code review** — invoke the project review loop (`superpowers:requesting-code-review` / `/code-review`) over the branch diff; address findings.
- [ ] **Step 3: Squash-merge** the branch to `master`.
- [ ] **Step 4: Sync docs** — run the `sync` skill so `SPEC.md`/`README.md` reflect: real host-key trust + Keychain-backed `SecretStore` now live; the MVP `AutoTrustVerifier` stub is gone; note **Plan 2 (full host CRUD editor + saved-host library UI + Defaults editor + identity sub-flow)** as the remaining host-management work.

---

## Deferred to Plan 2 (Host CRUD + saved-host library) — explicitly out of scope here

- The full single-scrollable host editor (Basics / Auth / Connection / Jump chain / Port forwarding / Mosh / Tailscale / Glymr / Delete) per `2026-06-15-host-crud-design.md`, with conditional disabling, validation banners, and quick-edit vs deep-edit presentation.
- The saved-host **list UI** (picker, swipe-to-edit/delete, refused-delete-if-referenced message), the **Defaults editor**, and the **inline identity sub-flow** (pick/create/import). Note: identity **create/import** additionally needs the Apple key-minting layer that Phase 2a deferred to 2b (`SecKeyCreateRandomKey` / Secure Enclave) — a prerequisite for that sub-tab.
- **Settings → Security → Host fingerprints** forget-and-retry swipe (`2026-06-17-host-key-trust-design.md` §"Forget-and-retry path"). The store path already exists (`HostKeyStore.remove`); only the UI is deferred.
- Ad-hoc (non-saved) connection identity: Plan 1 persists every typed host as a `Host` record, so there is always a UUID. Plan 2 decides whether to offer an explicit "don't save this host" path.

## Verification

- **Per task:** `docker compose run --rm dev swift test --filter <TestClassName>` green (Tasks 1–3).
- **Apple-only units (Tasks 4–6):** macOS CI simulator build green + the Task 6 manual run (connect → trust → relaunch → silent reconnect; key-change → mismatch modal).
- **Security property:** `HostKeyTrustEvaluatorTests.testDifferentFingerprintSameAlgorithmIsMismatchNotTrusted` proves a changed key never silently reads as trusted — the core MITM guard.

## Self-Review (spec coverage — `2026-06-17-host-key-trust-design.md`)

- Default `ask` policy (confirm on first trust + on change): Tasks 2 + 6.
- First-trust modal (layout, copy, Trust & Connect / Cancel, copyable fingerprint, no biometric, write-after-action): Tasks 5 + 6.
- Mismatch modal (red header, last-seen vs now-offering, Cancel / Replace-with-2-step-confirm, no biometric): Tasks 5 + 6.
- Per-`(host, key type)` independence; new-algorithm re-prompt: Task 2 (`testNewAlgorithmIsFirstTrust…`).
- Storage in Keychain (synced, E2EE), multi-device propagation: Task 3 (`kSecAttrSynchronizable`) over the existing `HostKeyStore`.
- Fingerprint format consistency (truncate + expand): Task 1, used in Task 5.
- Forget-and-retry: store support exists; UI explicitly deferred to Plan 2 (noted above).
