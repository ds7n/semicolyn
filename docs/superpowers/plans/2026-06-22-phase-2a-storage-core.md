# Phase 2a — Storage Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **First execution step:** copy this file to `docs/superpowers/plans/2026-06-22-phase-2a-storage-core.md` (the canonical plan location) and commit it on the feature branch.

## Context

Phase 0 locked the data model *schema primitives* (`Host`/`Identity`/`Defaults`/`Inherited<T>`, `RecordEnvelope` AES-256-GCM seal) but deliberately deferred the **remaining host fields** and the **storage/CRUD layer** to Phase 2 (see `docs/superpowers/plans/2026-06-17-phase-0-foundation.md:933`). The roadmap's Phase 2 (`...-neotilde-implementation-roadmap.md:85`) is *Storage & sync*: Keychain identity store, `known_hosts`, CloudKit records wrapped in the AES envelope, per-category sync toggles.

The dev environment is Linux/Docker (no Apple SDKs; `swift test` runs in `neotilde-dev`). The roadmap's cross-cutting constraint requires keeping the Apple-only layer thin and maximizing the Linux-testable surface. So this plan builds the **platform-agnostic storage core** — everything that compiles and is fully tested on Linux today — and defers the Apple concrete backends (Keychain/SE via `SecAccessControl`, CloudKit Private DB) to a later sub-phase (2b, macOS CI).

**Outcome:** a complete host/identity schema, the full resolution/fallback table, and a layered storage stack (`BlobStore` → `EncryptedRecordStore`; `SecretStore` → `HostKeyStore`) with in-memory + file Linux backends and a repository facade enforcing the spec's invariants (cycle prevention, soft-unique label warning, refuse-delete-if-referenced). The Apple backends in 2b implement the same two protocols (`BlobStore`, `SecretStore`) — no core rewrite.

**Specs of record:**
- `docs/superpowers/specs/2026-06-15-host-config-model-design.md` (schema, resolution table, invariants, storage backbone)
- `docs/superpowers/specs/2026-06-15-identities-keys-management-design.md` (Identity store layer, delete/used-by semantics)
- `docs/superpowers/specs/2026-06-16-icloud-sync-scope-design.md` (sync taxonomy, audit-log stub reservation)

## Architecture

Two independent storage stacks behind protocols, mirroring the spec's storage backbone:

```
CloudKit-bound (metadata, AES-sealed)        Keychain-bound (secrets, E2EE by Apple)
  BlobStore (protocol) ............ swap →      SecretStore (protocol) ........ swap →
    InMemoryBlobStore / FileBlobStore             InMemorySecretStore
  EncryptedRecordStore (seals via RecordEnvelope)  HostKeyStore (known_hosts over SecretStore)
            \                                      /
             \____ HostStore (repository facade) _/
                   cycle / dup-label / refuse-delete invariants
```

The two `protocol`s (`BlobStore`, `SecretStore`) are the only seams the Apple backends (2b) must fill. Everything above them is pure, value-type, Linux-tested Swift. Record sealing reuses the existing `RecordEnvelope` (`Sources/NeotildeKit/Crypto/RecordEnvelope.swift`); cycle detection reuses the existing `hasCycle` (`Sources/NeotildeKit/Model/Resolution.swift:18`).

## Tech Stack

Swift 6 (`NeotildeKit`, platform-agnostic), XCTest. Crypto via `CryptoKit` on Apple / `Crypto` (swift-crypto) on Linux behind `#if canImport(CryptoKit)` (pattern already in `RecordEnvelope.swift`). Run on Linux: `docker compose run --rm dev swift test`.

## Global Constraints

- Every source/test file begins with `// SPDX-FileCopyrightText: 2026 True Positive LLC` then `// SPDX-License-Identifier: GPL-3.0-only`.
- Placement: Swift in `Sources/NeotildeKit/Model/` (schema, resolution) and a new `Sources/NeotildeKit/Storage/` (stores); tests in `Tests/NeotildeKitTests/`.
- **No Apple-only APIs** in this plan — every file compiles and tests on Linux. Keychain/SE/CloudKit are out of scope (Phase 2b).
- Public model/store types are `Equatable, Sendable` where they hold value state; `Codable` for anything persisted.
- `Inherited<T>` semantics are load-bearing: `.inherit` (absent → inherit), `.explicit(value)` (set), `.explicit(nil)` (explicitly "none"). Never collapse the three.
- UUIDs internal, `label` for humans — references use UUID and survive label edits.
- Secrets (private key material, passwords, passphrases, `known_hosts`, the AES record key) live only in `SecretStore` — **never** in `BlobStore`/`EncryptedRecordStore`. Identity metadata records reference private material by UUID only.
- Testing tier: **Core** for stores/resolution (EP + BVA, good AND bad cases, exact-value assertions); **Critical** for the `EncryptedRecordStore` confidentiality property (adversarial: wrong key, tampered blob, plaintext-not-readable-from-backend).
- Conventional commits; commit after every green step. Branch `feat/phase-2a-storage-core`; squash-merge at the end.
- Test command: `docker compose run --rm dev swift test --filter <TestClassName>`.

---

### Task 0: Branch + plan doc

- [ ] **Step 1: Create the feature branch**

```bash
git checkout -b feat/phase-2a-storage-core
```

- [ ] **Step 2: Place the plan doc and commit**

Copy this plan to `docs/superpowers/plans/2026-06-22-phase-2a-storage-core.md`, then:

```bash
git add docs/superpowers/plans/2026-06-22-phase-2a-storage-core.md
git commit -m "docs: Phase 2a storage-core plan"
```

---

### Task 1: Complete the host schema (Tier 1 + Tier 2 + Neotilde extensions)

Phase 0 modeled only `user/port/identities/proxyJump`. Add every remaining field from the spec's entity model (`host-config-model-design.md:33-73`), all as `Inherited<T>`, plus the nested config value types. `Defaults` must carry the *same* optional fields (it is `Partial<Host>`).

**Files:**
- Create: `Sources/NeotildeKit/Model/HostExtensions.swift` (nested config types + auth/mode enums)
- Modify: `Sources/NeotildeKit/Model/Host.swift` (add fields to `Host` and `Defaults`)
- Test: `Tests/NeotildeKitTests/HostSchemaTests.swift`

**Interfaces:**
- Consumes: `Inherited<T>`, `IdentityRef`, `JumpHop`, `LocalForward`, `RemoteForward`, `DynamicForward`, `StrictHostKeyChecking` (all exist).
- Produces (new types in `HostExtensions.swift`):
  - `enum AuthMethod: String, Codable, Equatable, Sendable { case publicKey = "publickey", password, keyboardInteractive = "keyboard-interactive" }`
  - `enum MoshPredictionMode: String, Codable, Equatable, Sendable { case adaptive, always, never, experimental }`
  - `struct MoshConfig: Codable, Equatable, Sendable { var enabled: Bool; var serverPath: String?; var udpPortRange: [Int]?; var predictionMode: MoshPredictionMode? }` (use `[Int]?` of count 2 for the `[number,number]` range; round-trips losslessly)
  - `struct TailscaleConfig: Codable, Equatable, Sendable { var required: Bool; var tailnet: String? }`
  - `struct PredictorConfig: Codable, Equatable, Sendable { var incognito: Bool? }`
  - `struct TmuxConfig: Codable, Equatable, Sendable { var attemptControlMode: Bool? }`
  - `struct NeotildeConfig: Codable, Equatable, Sendable { var predictor: PredictorConfig?; var tmux: TmuxConfig? }`
- Produces (added to `Host`, each `Inherited<...>`, default `.inherit`, with matching `init` params): `passwordRef: Inherited<UUID>`, `localForwards: Inherited<[LocalForward]>`, `remoteForwards: Inherited<[RemoteForward]>`, `dynamicForwards: Inherited<[DynamicForward]>`, `serverAliveInterval: Inherited<Int>`, `serverAliveCountMax: Inherited<Int>`, `compression: Inherited<Bool>`, `strictHostKeyChecking: Inherited<StrictHostKeyChecking>`, `forwardAgent: Inherited<Bool>`, `preferredAuthentications: Inherited<[AuthMethod]>`, `mosh: Inherited<MoshConfig>`, `tailscale: Inherited<TailscaleConfig>`, `neotilde: Inherited<NeotildeConfig>`.
- Produces (added to `Defaults`): the identical optional field set (every field above plus the existing `identities`/`proxyJump`), same names/types/`.inherit` defaults. `Defaults` keeps no required fields.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/NeotildeKitTests/HostSchemaTests.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

final class HostSchemaTests: XCTestCase {
    func testFullyPopulatedHostRoundTripsThroughJSON() throws {
        let id = UUID()
        let host = Host(
            id: id, label: "prod", hostName: "db.internal",
            user: .explicit("deploy"), port: .explicit(2222),
            identities: .explicit([UUID()]),
            proxyJump: .explicit([.inline(hostName: "jump", port: 22, user: "j", identities: nil)]),
            passwordRef: .explicit(UUID()),
            localForwards: .explicit([LocalForward(bindAddress: nil, bindPort: 8080, hostAddress: "x", hostPort: 5432)]),
            remoteForwards: .inherit,
            dynamicForwards: .explicit([DynamicForward(bindAddress: nil, bindPort: 1080)]),
            serverAliveInterval: .explicit(15), serverAliveCountMax: .explicit(2),
            compression: .explicit(true),
            strictHostKeyChecking: .explicit(.acceptNew),
            forwardAgent: .explicit(false),
            preferredAuthentications: .explicit([.publicKey, .password]),
            mosh: .explicit(MoshConfig(enabled: true, serverPath: "/usr/bin/mosh-server",
                                       udpPortRange: [60000, 61000], predictionMode: .adaptive)),
            tailscale: .explicit(TailscaleConfig(required: true, tailnet: "corp.ts.net")),
            neotilde: .explicit(NeotildeConfig(predictor: PredictorConfig(incognito: true),
                                         tmux: TmuxConfig(attemptControlMode: false))))
        let data = try JSONEncoder().encode(host)
        let back = try JSONDecoder().decode(Host.self, from: data)
        XCTAssertEqual(back, host)
    }

    func testInheritExplicitNoneAndExplicitValueAreDistinctAfterRoundTrip() throws {
        // .inherit vs .explicit(nil) vs .explicit(value) must survive encoding.
        let h = Host(id: UUID(), label: "l", hostName: "h",
                     user: .inherit, port: .explicit(nil), compression: .explicit(true))
        let back = try JSONDecoder().decode(Host.self, from: JSONEncoder().encode(h))
        XCTAssertEqual(back.user, .inherit)
        XCTAssertEqual(back.port, .explicit(nil))
        XCTAssertEqual(back.compression, .explicit(true))
        XCTAssertNil(back.port.value)        // explicit-none reads as no value
    }

    func testDefaultsCarriesSameOptionalFields() throws {
        let d = Defaults(user: .explicit("root"), compression: .explicit(false),
                         strictHostKeyChecking: .explicit(.yes))
        let back = try JSONDecoder().decode(Defaults.self, from: JSONEncoder().encode(d))
        XCTAssertEqual(back, d)
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `docker compose run --rm dev swift test --filter HostSchemaTests` → FAIL (unknown init params / types).

- [ ] **Step 3: Implement** — add `HostExtensions.swift` with the nested types/enums; extend `Host` and `Defaults` with the new `Inherited<...>` fields and init params (default every new param to `.inherit`). Keep the existing `resolvedJumpChain` helper. Preserve the existing 4 fields and their order; append new ones.

- [ ] **Step 4: Run to verify it passes.**

- [ ] **Step 5: Commit** — `feat: complete host schema (Tier 1/2 + neotilde extensions)`

---

### Task 2: Full resolution & fallback table

Phase 0 shipped only `resolvePort`. Implement the entire resolution table (`host-config-model-design.md:193-210`): per-host value → Defaults value → built-in fallback, including the `user` **no-fallback** typed error and the nested-config leaf resolutions.

**Files:**
- Modify: `Sources/NeotildeKit/Model/Resolution.swift` (keep `resolvePort`, `hasCycle`; add the rest)
- Test: `Tests/NeotildeKitTests/ResolutionTests.swift`

**Interfaces:**
- Consumes: `Host`, `Defaults`, `Inherited<T>`, and the Task 1 types.
- Produces:
  - Generic core: `func resolve<T: Equatable & Codable>(_ host: Inherited<T>, _ defaults: Inherited<T>, fallback: T) -> T` (returns `host.value ?? defaults.value ?? fallback`).
  - `enum ResolutionError: Error, Equatable { case userUnset }`
  - `func resolveUser(host: Host, defaults: Defaults) throws -> String` — `host.user.value ?? defaults.user.value`, else `throw .userUnset`.
  - Typed wrappers (each returns the spec fallback): `resolveCompression`→`false`, `resolveForwardAgent`→`false`, `resolveStrictHostKeyChecking`→`.acceptNew`, `resolveServerAliveInterval`→`30`, `resolveServerAliveCountMax`→`3`, `resolvePreferredAuthentications`→`[.publicKey, .keyboardInteractive, .password]`, `resolveIdentities`→`[]`, `resolveProxyJump`→`[]`, `resolveLocalForwards`/`resolveRemoteForwards`/`resolveDynamicForwards`→`[]`.
  - Nested-config leaves (host config → defaults config → builtin): `resolveMoshEnabled`→`false`, `resolveTailscaleRequired`→`false`, `resolvePredictorIncognito`→`false`, `resolveTmuxAttemptControlMode`→`true`.

- [ ] **Step 1: Write the failing test** (one representative assertion per resolution layer + the `user` error path)

```swift
// Tests/NeotildeKitTests/ResolutionTests.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

final class ResolutionTests: XCTestCase {
    private func host(_ b: (inout Host) -> Void = { _ in }) -> Host {
        var h = Host(id: UUID(), label: "l", hostName: "h"); b(&h); return h
    }

    func testPortPrefersHostThenDefaultsThenBuiltin() {
        XCTAssertEqual(resolvePort(host: host { $0.port = .explicit(2222) },
                                   defaults: Defaults(port: .explicit(2022))), 2222)   // host wins
        XCTAssertEqual(resolvePort(host: host(), defaults: Defaults(port: .explicit(2022))), 2022) // defaults
        XCTAssertEqual(resolvePort(host: host(), defaults: Defaults()), 22)             // builtin
    }

    func testUserThrowsWhenUnsetOnBothHostAndDefaults() {
        XCTAssertThrowsError(try resolveUser(host: host(), defaults: Defaults())) {
            XCTAssertEqual($0 as? ResolutionError, .userUnset)
        }
        XCTAssertEqual(try? resolveUser(host: host { $0.user = .explicit("deploy") },
                                        defaults: Defaults()), "deploy")
    }

    func testSecurityConservativeFallbacks() {
        XCTAssertFalse(resolveForwardAgent(host: host(), defaults: Defaults()))   // false, not inherited-true
        XCTAssertEqual(resolveStrictHostKeyChecking(host: host(), defaults: Defaults()), .acceptNew)
        XCTAssertEqual(resolvePreferredAuthentications(host: host(), defaults: Defaults()),
                       [.publicKey, .keyboardInteractive, .password])
    }

    func testExplicitNoneOverridesDefaultsForListField() {
        // .explicit(nil) means "cleared to none" — must NOT fall through to Defaults.
        let h = host { $0.identities = .explicit(nil) }
        XCTAssertEqual(resolveIdentities(host: h, defaults: Defaults(identities: .explicit([UUID()]))), [])
    }

    func testNestedMoshEnabledResolves() {
        XCTAssertTrue(resolveMoshEnabled(host: host { $0.mosh = .explicit(MoshConfig(enabled: true, serverPath: nil, udpPortRange: nil, predictionMode: nil)) },
                                         defaults: Defaults()))
        XCTAssertFalse(resolveMoshEnabled(host: host(), defaults: Defaults()))  // builtin
    }
}
```

- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Implement** the generic `resolve`, the `user` error path, and every wrapper. Use `resolve(...)` internally for the simple `Inherited<T>` fields; reach into `.value?.<leaf>` for the nested configs.
- [ ] **Step 4: Run to verify it passes.**
- [ ] **Step 5: Commit** — `feat: full host resolution & fallback table`

---

### Task 3: `BlobStore` protocol + `InMemoryBlobStore`

The swappable backend seam for CloudKit-bound records. Stores opaque `Data` blobs keyed by `(type, id)`. CloudKit implements this on Apple (2b); the in-memory impl backs tests and previews.

**Files:**
- Create: `Sources/NeotildeKit/Storage/BlobStore.swift`
- Test: `Tests/NeotildeKitTests/InMemoryBlobStoreTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public protocol BlobStore {
      func putBlob(_ data: Data, type: String, id: UUID) throws
      func getBlob(type: String, id: UUID) throws -> Data?
      func deleteBlob(type: String, id: UUID) throws
      func listBlobs(type: String) throws -> [(id: UUID, data: Data)]   // unordered
  }
  public final class InMemoryBlobStore: BlobStore {
      public init()
      // backed by [String: [UUID: Data]]; missing get → nil; idempotent delete
  }
  ```

- [ ] **Step 1: Write the failing test** — put→get round-trip; overwrite replaces; `getBlob` for missing key → `nil`; `deleteBlob` removes and is idempotent; `listBlobs` returns all ids for a type and excludes other types.

```swift
// Tests/NeotildeKitTests/InMemoryBlobStoreTests.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

final class InMemoryBlobStoreTests: XCTestCase {
    func testPutGetOverwriteDeleteAndList() throws {
        let s = InMemoryBlobStore()
        let a = UUID(), b = UUID()
        try s.putBlob(Data([1]), type: "host", id: a)
        try s.putBlob(Data([2]), type: "host", id: b)
        try s.putBlob(Data([9]), type: "defaults", id: a)
        XCTAssertEqual(try s.getBlob(type: "host", id: a), Data([1]))
        try s.putBlob(Data([3]), type: "host", id: a)                 // overwrite
        XCTAssertEqual(try s.getBlob(type: "host", id: a), Data([3]))
        XCTAssertNil(try s.getBlob(type: "host", id: UUID()))         // missing → nil
        XCTAssertEqual(Set(try s.listBlobs(type: "host").map(\.id)), [a, b])  // excludes "defaults"
        try s.deleteBlob(type: "host", id: a)
        XCTAssertNil(try s.getBlob(type: "host", id: a))
        try s.deleteBlob(type: "host", id: a)                        // idempotent, no throw
    }
}
```

- [ ] **Step 2–4:** Run-fail → implement (`final class` with a `[String: [UUID: Data]]` dict) → run-pass.
- [ ] **Step 5: Commit** — `feat: BlobStore protocol + in-memory backend`

---

### Task 4: `FileBlobStore` (atomic, disk-backed)

A file-backed `BlobStore` for local persistence and Linux integration tests, mirroring `LearnedStore`'s atomic-write idiom (`Sources/NeotildeKit/Predictor/LearnedStore.swift:45-58`). Layout: one file per record at `<dir>/<type>/<uuid>.rec`.

**Files:**
- Modify: `Sources/NeotildeKit/Storage/BlobStore.swift` (append `FileBlobStore`)
- Test: `Tests/NeotildeKitTests/FileBlobStoreTests.swift`

**Interfaces:**
- Produces: `public struct FileBlobStore: BlobStore { public init(directory: URL) }` — `putBlob` writes atomically (`.atomic`; add `.completeFileProtection` under `#if os(iOS)`), creating `<dir>/<type>/` as needed; `getBlob` returns `nil` for a missing file; `listBlobs` enumerates `*.rec` in `<dir>/<type>/` and parses UUIDs from filenames (skips unparseable); `deleteBlob` removes the file, idempotent.

- [ ] **Step 1: Write the failing test** — round-trip survives a *new* `FileBlobStore` instance over the same dir (proves real persistence); missing → `nil`; `listBlobs` returns written ids; delete removes. Use a unique temp dir per test; clean up in `tearDown`.

```swift
// Tests/NeotildeKitTests/FileBlobStoreTests.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

final class FileBlobStoreTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testPersistsAcrossInstances() throws {
        let id = UUID()
        try FileBlobStore(directory: dir).putBlob(Data([7, 8, 9]), type: "host", id: id)
        // Fresh instance, same directory — must read what the first wrote.
        let reread = try FileBlobStore(directory: dir).getBlob(type: "host", id: id)
        XCTAssertEqual(reread, Data([7, 8, 9]))
    }

    func testMissingReturnsNilAndListAndDelete() throws {
        let s = FileBlobStore(directory: dir)
        XCTAssertNil(try s.getBlob(type: "host", id: UUID()))
        let id = UUID()
        try s.putBlob(Data([1]), type: "host", id: id)
        XCTAssertEqual(try s.listBlobs(type: "host").map(\.id), [id])
        try s.deleteBlob(type: "host", id: id)
        XCTAssertNil(try s.getBlob(type: "host", id: id))
        try s.deleteBlob(type: "host", id: id)   // idempotent
    }
}
```

- [ ] **Step 2–4:** Run-fail → implement → run-pass.
- [ ] **Step 5: Commit** — `feat: file-backed BlobStore`

---

### Task 5: `RecordType` taxonomy + `EncryptedRecordStore` (confidentiality — Critical tier)

Seals Codable records with `RecordEnvelope` over any `BlobStore`, so the backend (and CloudKit in 2b) sees only AES-GCM ciphertext. `RecordType` enumerates the CloudKit-bound record kinds and seeds the sync taxonomy.

**Files:**
- Create: `Sources/NeotildeKit/Storage/EncryptedRecordStore.swift`
- Test: `Tests/NeotildeKitTests/EncryptedRecordStoreTests.swift`

**Interfaces:**
- Consumes: `BlobStore`, `RecordEnvelope.seal/open` (`Sources/NeotildeKit/Crypto/RecordEnvelope.swift`), `SymmetricKey`.
- Produces:
  - `public enum RecordType: String, Codable, Sendable, CaseIterable { case host, defaults, identity }` (string = the `BlobStore` `type` namespace).
  - ```swift
    public struct EncryptedRecordStore {
        public init(backend: BlobStore, key: SymmetricKey)
        public func put<T: Encodable>(_ value: T, type: RecordType, id: UUID) throws
        public func get<T: Decodable>(_ type: RecordType, id: UUID, as: T.Type) throws -> T?  // nil if absent
        public func delete(_ type: RecordType, id: UUID) throws
        public func list<T: Decodable>(_ type: RecordType, as: T.Type) throws -> [(id: UUID, value: T)]
    }
    ```
  - `put` seals via `RecordEnvelope.seal` then `backend.putBlob`. `get` reads the blob (→ `nil` if absent) then `RecordEnvelope.open`; a present-but-undecryptable blob **throws** `RecordEnvelopeError.decryptionFailed` (do not swallow — tamper/wrong-key must surface, unlike `LearnedStore`'s fail-soft behavior).

- [ ] **Step 1: Write the failing test** (Critical: round-trip + confidentiality + tamper + wrong-key)

```swift
// Tests/NeotildeKitTests/EncryptedRecordStoreTests.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import NeotildeKit

final class EncryptedRecordStoreTests: XCTestCase {
    private let key = SymmetricKey(size: .bits256)

    private func host() -> Host { Host(id: UUID(), label: "prod", hostName: "db.internal",
                                       user: .explicit("deploy")) }

    func testRoundTripAndList() throws {
        let backend = InMemoryBlobStore()
        let store = EncryptedRecordStore(backend: backend, key: key)
        let h = host()
        try store.put(h, type: .host, id: h.id)
        XCTAssertEqual(try store.get(.host, id: h.id, as: Host.self), h)
        XCTAssertNil(try store.get(.host, id: UUID(), as: Host.self))    // absent → nil
        XCTAssertEqual(try store.list(.host, as: Host.self).map(\.value), [h])
        try store.delete(.host, id: h.id)
        XCTAssertNil(try store.get(.host, id: h.id, as: Host.self))
    }

    func testBackendHoldsCiphertextNotPlaintext() throws {
        let backend = InMemoryBlobStore()
        let h = host()
        try EncryptedRecordStore(backend: backend, key: key).put(h, type: .host, id: h.id)
        let raw = try XCTUnwrap(try backend.getBlob(type: "host", id: h.id))
        // The raw blob must NOT be the plaintext JSON, and must NOT decode as a Host.
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("db.internal"))
        XCTAssertThrowsError(try JSONDecoder().decode(Host.self, from: raw))
    }

    func testWrongKeyFails() throws {
        let backend = InMemoryBlobStore()
        let h = host()
        try EncryptedRecordStore(backend: backend, key: key).put(h, type: .host, id: h.id)
        let attacker = EncryptedRecordStore(backend: backend, key: SymmetricKey(size: .bits256))
        XCTAssertThrowsError(try attacker.get(.host, id: h.id, as: Host.self)) {
            XCTAssertEqual($0 as? RecordEnvelopeError, .decryptionFailed)
        }
    }

    func testTamperedBlobFails() throws {
        let backend = InMemoryBlobStore()
        let h = host()
        try EncryptedRecordStore(backend: backend, key: key).put(h, type: .host, id: h.id)
        var raw = try XCTUnwrap(try backend.getBlob(type: "host", id: h.id))
        raw[raw.count - 1] ^= 0xFF                                    // flip a tag byte
        try backend.putBlob(raw, type: "host", id: h.id)
        XCTAssertThrowsError(try EncryptedRecordStore(backend: backend, key: key)
            .get(.host, id: h.id, as: Host.self)) {
            XCTAssertEqual($0 as? RecordEnvelopeError, .decryptionFailed)
        }
    }
}
```

- [ ] **Step 2–4:** Run-fail → implement → run-pass.
- [ ] **Step 5: Commit** — `feat: EncryptedRecordStore over BlobStore (AES-sealed records)`

---

### Task 6: `SecretStore` protocol + `InMemorySecretStore` + record-key helper

The Keychain-bound seam: opaque secrets keyed by a typed `SecretRef`. On Apple (2b) this is iCloud Keychain / Secure Enclave via `SecAccessControl`; here, in-memory. Includes a get-or-generate helper for the 32-byte AES record key that `EncryptedRecordStore` consumes.

**Files:**
- Create: `Sources/NeotildeKit/Storage/SecretStore.swift`
- Test: `Tests/NeotildeKitTests/InMemorySecretStoreTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum SecretRef: Hashable, Sendable {
      case recordKey                      // the AES-256 key for EncryptedRecordStore
      case privateKey(identityID: UUID)   // SSH private key material (iCloudKeychain flavor)
      case password(id: UUID)             // host password (passwordRef target)
      case passphrase(identityID: UUID)   // key passphrase
      case hostKeys(hostID: UUID)         // serialized [HostKey] for a host (Task 7)
  }
  public protocol SecretStore {
      func setSecret(_ data: Data, for ref: SecretRef) throws
      func getSecret(_ ref: SecretRef) throws -> Data?     // nil if absent
      func deleteSecret(_ ref: SecretRef) throws           // idempotent
  }
  public final class InMemorySecretStore: SecretStore { public init() }
  ```
- Plus a free helper:
  ```swift
  // Returns the stored 32-byte record key, generating + persisting one on first call.
  public func recordKey(in store: SecretStore) throws -> SymmetricKey
  ```
  Implementation: `getSecret(.recordKey)` → if present build `SymmetricKey(data:)`; else `SymmetricKey(size: .bits256)`, persist its `withUnsafeBytes` Data via `setSecret`, return it.

- [ ] **Step 1: Write the failing test** — set/get/delete round-trip per ref kind; missing → nil; delete idempotent; `recordKey` is stable across calls (same bytes) and persists into the store.

```swift
// Tests/NeotildeKitTests/InMemorySecretStoreTests.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import NeotildeKit

final class InMemorySecretStoreTests: XCTestCase {
    func testSetGetDeleteByRef() throws {
        let s = InMemorySecretStore()
        let idA = UUID()
        try s.setSecret(Data([1, 2]), for: .privateKey(identityID: idA))
        XCTAssertEqual(try s.getSecret(.privateKey(identityID: idA)), Data([1, 2]))
        XCTAssertNil(try s.getSecret(.privateKey(identityID: UUID())))   // distinct ref → nil
        XCTAssertNil(try s.getSecret(.password(id: idA)))               // distinct kind, same UUID → nil
        try s.deleteSecret(.privateKey(identityID: idA))
        XCTAssertNil(try s.getSecret(.privateKey(identityID: idA)))
        try s.deleteSecret(.privateKey(identityID: idA))                // idempotent
    }

    func testRecordKeyIsGeneratedOnceAndStable() throws {
        let s = InMemorySecretStore()
        let k1 = try recordKey(in: s)
        let k2 = try recordKey(in: s)                                    // must not regenerate
        let d1 = k1.withUnsafeBytes { Data($0) }
        let d2 = k2.withUnsafeBytes { Data($0) }
        XCTAssertEqual(d1, d2)
        XCTAssertEqual(d1.count, 32)
        XCTAssertNotNil(try s.getSecret(.recordKey))                     // persisted
    }
}
```

- [ ] **Step 2–4:** Run-fail → implement (`final class` with `[SecretRef: Data]`) → run-pass.
- [ ] **Step 5: Commit** — `feat: SecretStore protocol + in-memory backend + record-key helper`

---

### Task 7: `HostKeyStore` (known_hosts over `SecretStore`)

`known_hosts` entries live in iCloud Keychain (synced, E2EE), queried by host UUID, **multiple entries per host** (rotation: old + new valid together) — `host-config-model-design.md:109-122`. Stored as JSON-encoded `[HostKey]` under `SecretRef.hostKeys(hostID:)`.

**Files:**
- Create: `Sources/NeotildeKit/Storage/HostKeyStore.swift`
- Test: `Tests/NeotildeKitTests/HostKeyStoreTests.swift`

**Interfaces:**
- Consumes: `SecretStore`, `HostKey`, `HostKeySource` (exist in `Host.swift`).
- Produces:
  ```swift
  public struct HostKeyStore {
      public init(secrets: SecretStore)
      public func entries(forHost hostID: UUID) throws -> [HostKey]      // [] if none
      public func add(_ key: HostKey, forHost hostID: UUID) throws       // appends; preserves existing
      public func remove(fingerprint: String, forHost hostID: UUID) throws  // removes matching; deletes the secret when empty
  }
  ```

- [ ] **Step 1: Write the failing test** — empty host → `[]`; `add` two distinct keys → both present (rotation); `add` preserves order/existing; `remove` by fingerprint drops only the match; removing the last entry leaves `entries` empty.

```swift
// Tests/NeotildeKitTests/HostKeyStoreTests.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

final class HostKeyStoreTests: XCTestCase {
    private func key(_ fp: String) -> HostKey {
        HostKey(algorithm: "ssh-ed25519", fingerprint: fp,
                addedAt: Date(timeIntervalSince1970: 0), source: .trustOnFirstUse)
    }

    func testRotationKeepsMultipleEntriesPerHost() throws {
        let store = HostKeyStore(secrets: InMemorySecretStore())
        let h = UUID()
        XCTAssertEqual(try store.entries(forHost: h), [])
        try store.add(key("SHA256:AAA"), forHost: h)
        try store.add(key("SHA256:BBB"), forHost: h)               // rotation window: both valid
        XCTAssertEqual(try store.entries(forHost: h).map(\.fingerprint), ["SHA256:AAA", "SHA256:BBB"])
    }

    func testRemoveByFingerprint() throws {
        let store = HostKeyStore(secrets: InMemorySecretStore())
        let h = UUID()
        try store.add(key("SHA256:AAA"), forHost: h)
        try store.add(key("SHA256:BBB"), forHost: h)
        try store.remove(fingerprint: "SHA256:AAA", forHost: h)
        XCTAssertEqual(try store.entries(forHost: h).map(\.fingerprint), ["SHA256:BBB"])
        try store.remove(fingerprint: "SHA256:BBB", forHost: h)
        XCTAssertEqual(try store.entries(forHost: h), [])           // last removed → empty
    }
}
```

- [ ] **Step 2–4:** Run-fail → implement (decode `[HostKey]` from the secret, mutate, re-encode; delete the secret when the array empties) → run-pass.
- [ ] **Step 5: Commit** — `feat: HostKeyStore (known_hosts over SecretStore)`

---

### Task 8: `HostStore` repository facade + invariants

Ties the record store together and enforces the spec's save/delete invariants: cycle prevention at save (`host-config-model-design.md:93`), soft-unique label *warning* (not a block — `:36`), refuse-delete-of-referenced-jumphost (`:95`), and Identity refuse-delete-if-referenced + used-by scan (`identities-keys-management-design.md:166-180`). Defaults is a singleton.

**Files:**
- Create: `Sources/NeotildeKit/Storage/HostStore.swift`
- Test: `Tests/NeotildeKitTests/HostStoreTests.swift`

**Interfaces:**
- Consumes: `EncryptedRecordStore`, `Host`, `Defaults`, `Identity`, `hasCycle` (`Resolution.swift:18`), `RecordType`.
- Produces:
  ```swift
  public struct HostRef: Equatable, Sendable { public let id: UUID; public let label: String }
  public enum StoreError: Error, Equatable {
      case jumpChainCycle
      case jumpHostInUse(by: [HostRef])
      case identityInUse(by: [HostRef])
  }
  public struct SaveOutcome: Equatable, Sendable { public let duplicateLabels: [HostRef] } // warning, not failure

  public struct HostStore {
      public init(records: EncryptedRecordStore)

      // Hosts
      @discardableResult public func saveHost(_ host: Host) throws -> SaveOutcome  // throws .jumpChainCycle
      public func host(id: UUID) throws -> Host?
      public func allHosts() throws -> [Host]
      public func deleteHost(id: UUID) throws                                       // throws .jumpHostInUse

      // Defaults singleton (fixed id Self.defaultsID)
      public func defaults() throws -> Defaults                                     // empty Defaults() if unset
      public func saveDefaults(_ d: Defaults) throws

      // Identities
      public func saveIdentity(_ identity: Identity) throws
      public func identity(id: UUID) throws -> Identity?
      public func allIdentities() throws -> [Identity]
      public func hostsUsing(identityID: UUID) throws -> [HostRef]                  // scans host.identities + inline jump hops
      public func deleteIdentity(id: UUID) throws                                   // throws .identityInUse
  }
  ```
- Semantics:
  - `saveHost`: build `[UUID: Host]` from `allHosts()` (excluding the one being saved), run `hasCycle(savingHostId: host.id, chain: host.resolvedJumpChain, in:)` → throw `.jumpChainCycle` if true. Compute `duplicateLabels` = other hosts whose `label == host.label`. Persist. Return `SaveOutcome(duplicateLabels:)` — duplicate labels never block the save.
  - `deleteHost`: scan all *other* hosts; collect any whose resolved jump chain contains `.ref(hostId: id)`. Non-empty → throw `.jumpHostInUse(by:)` with their `HostRef`s. Else delete.
  - `defaults`: read the singleton at `Self.defaultsID` (a fixed sentinel `UUID`); `nil` → `Defaults()`.
  - `hostsUsing`: a host references an identity if `host.identities.value` contains the id, OR any inline jump hop's `identities` contains it.
  - `deleteIdentity`: `hostsUsing` non-empty → throw `.identityInUse(by:)`; else delete.

- [ ] **Step 1: Write the failing test** (each invariant, good AND bad)

```swift
// Tests/NeotildeKitTests/HostStoreTests.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import NeotildeKit

final class HostStoreTests: XCTestCase {
    private func makeStore() -> HostStore {
        HostStore(records: EncryptedRecordStore(backend: InMemoryBlobStore(),
                                                key: SymmetricKey(size: .bits256)))
    }
    private func host(_ label: String, _ id: UUID = UUID(),
                      jump: [JumpHop] = [], ids: [IdentityRef] = []) -> Host {
        Host(id: id, label: label, hostName: "h",
             identities: ids.isEmpty ? .inherit : .explicit(ids),
             proxyJump: jump.isEmpty ? .inherit : .explicit(jump))
    }

    func testSaveHostRoundTripAndDuplicateLabelWarning() throws {
        let s = makeStore()
        let a = host("prod")
        XCTAssertEqual(try s.saveHost(a).duplicateLabels, [])           // first "prod": no dup
        XCTAssertEqual(try s.host(id: a.id), a)
        let outcome = try s.saveHost(host("prod"))                      // second "prod": warn, still saved
        XCTAssertEqual(outcome.duplicateLabels.map(\.id), [a.id])
        XCTAssertEqual(try s.allHosts().count, 2)
    }

    func testSaveHostRejectsDirectCycle() throws {
        let s = makeStore()
        let id = UUID()
        XCTAssertThrowsError(try s.saveHost(host("self", id, jump: [.ref(hostId: id)]))) {
            XCTAssertEqual($0 as? StoreError, .jumpChainCycle)
        }
    }

    func testDeleteHostRefusedWhenUsedAsJumpHost() throws {
        let s = makeStore()
        let jump = host("jump")
        try s.saveHost(jump)
        let user = host("prod", jump: [.ref(hostId: jump.id)])
        try s.saveHost(user)
        XCTAssertThrowsError(try s.deleteHost(id: jump.id)) {
            XCTAssertEqual($0 as? StoreError, .jumpHostInUse(by: [HostRef(id: user.id, label: "prod")]))
        }
        try s.deleteHost(id: user.id)                                   // remove the referrer first
        try s.deleteHost(id: jump.id)                                   // now allowed
        XCTAssertNil(try s.host(id: jump.id))
    }

    func testDefaultsSingletonRoundTrip() throws {
        let s = makeStore()
        XCTAssertEqual(try s.defaults(), Defaults())                    // unset → empty
        try s.saveDefaults(Defaults(user: .explicit("root")))
        XCTAssertEqual(try s.defaults().user, .explicit("root"))
    }

    func testIdentityUsedByScanAndRefusedDelete() throws {
        let s = makeStore()
        let kid = UUID()
        let ident = Identity(id: kid, displayName: "gh", flavor: .iCloudKeychain,
                             algorithm: .ed25519, publicKey: "ssh-ed25519 AAAA",
                             fingerprint: "SHA256:x", createdAt: Date(timeIntervalSince1970: 0),
                             biometricPolicy: .afterUnlock)
        try s.saveIdentity(ident)
        let user = host("prod", ids: [kid])
        try s.saveHost(user)
        XCTAssertEqual(try s.hostsUsing(identityID: kid), [HostRef(id: user.id, label: "prod")])
        XCTAssertThrowsError(try s.deleteIdentity(id: kid)) {
            XCTAssertEqual($0 as? StoreError, .identityInUse(by: [HostRef(id: user.id, label: "prod")]))
        }
        try s.deleteHost(id: user.id)
        XCTAssertEqual(try s.hostsUsing(identityID: kid), [])
        try s.deleteIdentity(id: kid)                                   // now allowed
        XCTAssertNil(try s.identity(id: kid))
    }
}
```

- [ ] **Step 2–4:** Run-fail → implement → run-pass.
- [ ] **Step 5: Commit** — `feat: HostStore repository facade + save/delete invariants`

---

### Task 9: Sync taxonomy + audit-log stub reservation

The icloud-sync-scope spec requires a code-level sync classification and a **no-op audit-log stub namespace** reserved for a future Pro feature (`icloud-sync-scope-design.md:108-116`, sync table `:50-68`). Encode the taxonomy as data (the per-item sync decision) and reserve the audit namespace as inert hooks.

**Files:**
- Create: `Sources/NeotildeKit/Storage/SyncScope.swift`
- Test: `Tests/NeotildeKitTests/SyncScopeTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum SyncBackend: Equatable, Sendable { case cloudKitAES, iCloudKeychain, secureEnclave, localOnly }
  // Authoritative v1 sync decision per stored item the storage core knows about.
  public enum SyncItem: CaseIterable, Sendable {
      case hostRecord, defaultsRecord, identityMetadata     // cloudKitAES
      case privateKeyICloud, password, passphrase, knownHosts // iCloudKeychain
      case privateKeySE                                       // secureEnclave
      case recentConnections, liveSessionState               // localOnly
      public var backend: SyncBackend { ... }
      public var syncs: Bool { ... }                          // true except secureEnclave/localOnly
  }
  // Reserved Pro-tier audit log — no-op in v1 (writes nowhere, allocates nothing).
  public enum AuditLog {
      public static let reservedNamespace = "auditLog"
      public static func record(_ event: @autoclosure () -> String) { /* intentionally empty in v1 */ }
  }
  ```

- [ ] **Step 1: Write the failing test** — assert each representative item maps to the spec's backend and `syncs` value; assert the SE/local items don't sync; assert `AuditLog.record` is a no-op (call it, assert nothing observable changes — and that the reserved namespace string is stable).

```swift
// Tests/NeotildeKitTests/SyncScopeTests.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

final class SyncScopeTests: XCTestCase {
    func testBackendsMatchSpec() {
        XCTAssertEqual(SyncItem.hostRecord.backend, .cloudKitAES)
        XCTAssertEqual(SyncItem.knownHosts.backend, .iCloudKeychain)
        XCTAssertEqual(SyncItem.privateKeySE.backend, .secureEnclave)
        XCTAssertEqual(SyncItem.recentConnections.backend, .localOnly)
    }
    func testSyncFlags() {
        XCTAssertTrue(SyncItem.hostRecord.syncs)
        XCTAssertTrue(SyncItem.password.syncs)        // iCloud Keychain syncs
        XCTAssertFalse(SyncItem.privateKeySE.syncs)   // device-bound
        XCTAssertFalse(SyncItem.liveSessionState.syncs)
    }
    func testAuditLogIsReservedNoOp() {
        XCTAssertEqual(AuditLog.reservedNamespace, "auditLog")
        AuditLog.record("connect")                    // must compile, do nothing, not crash
    }
}
```

- [ ] **Step 2–4:** Run-fail → implement → run-pass.
- [ ] **Step 5: Commit** — `feat: sync taxonomy + audit-log stub reservation`

---

### Task 10: Full-suite verification + sync docs

- [ ] **Step 1: Run the whole suite** — `docker compose run --rm dev swift test`. Expected: all prior suites still green + the new `HostSchemaTests`, `ResolutionTests`, `InMemoryBlobStoreTests`, `FileBlobStoreTests`, `EncryptedRecordStoreTests`, `InMemorySecretStoreTests`, `HostKeyStoreTests`, `HostStoreTests`, `SyncScopeTests` pass.
- [ ] **Step 2: Code review** — invoke the project review loop (`/code-review` or `superpowers:requesting-code-review`) over the branch diff; address findings.
- [ ] **Step 3: Squash-merge** the branch to `master` per the project convention.
- [ ] **Step 4: Sync docs** — run the `sync` skill so `SPEC.md`/`README.md` reflect the new storage core (and note Phase 2b — Apple Keychain/SE/CloudKit backends + per-category sync toggles UI — as the remaining Phase 2 work).

---

## Deferred to Phase 2b (Apple / macOS CI) — explicitly out of scope here

- `BlobStore` backed by **CloudKit Private DB**; `SecretStore` backed by **iCloud Keychain + Secure Enclave** via `SecAccessControl` (the `never`/`anyUse`/`afterUnlock` biometric policies).
- Key generation/import (`SecKeyCreateRandomKey`, `kSecAttrTokenIDSecureEnclave`) — schema/store seams exist; concrete minting is Apple-only.
- CloudKit sync engine, conflict resolution (last-write-wins), per-category sync toggles UI, new-device restoration.
- Macro library + keybar-customization records and predictor-sketch sync records (other phases own those models; they reuse `EncryptedRecordStore`).

### Follow-ups noted in the Phase-2a final review (resolve in 2b)

- **Corrupt-record recovery / repair path.** `EncryptedRecordStore.list` is fail-closed: a single undecryptable blob throws and blocks bulk reads (`allHosts()` → all save/delete). Deliberate for v1 security posture (a tampered record must not silently vanish); 2b should add a repair/quarantine path once CloudKit sync + recovery exists.
- **Key-material zeroing.** `recordKey(in:)` copies the 32-byte AES key into a non-scrubbed `Data`. In-memory only today; the 2b Keychain backend should keep key material in scrubbed/locked storage.
- **`FileBlobStore.getBlob` error conflation.** `try?` maps both "missing" and "unreadable" to `nil`; acceptable for the local backend in 2a, distinguish if it matters in 2b.

## Verification

- **Per task:** `docker compose run --rm dev swift test --filter <TestClassName>` green.
- **End-to-end (Task 10):** `docker compose run --rm dev swift test` — entire suite green, including the 9 new test classes.
- **Confidentiality property (manual sanity):** `EncryptedRecordStoreTests.testBackendHoldsCiphertextNotPlaintext` proves a CloudKit-bound record is unreadable from the backend without the key — the core's E2EE-against-Apple guarantee.

## Self-Review (spec coverage)

- host-config-model: full schema (Task 1), resolution/fallback table incl. `user` no-fallback (Task 2), cycle prevention (Task 8), jumphost-in-use refusal (Task 8), soft-unique label warning (Task 8), `known_hosts` multi-entry store (Task 7), AES-sealed CloudKit records + secrets-never-in-CloudKit split (Tasks 5/6), Defaults singleton (Task 8).
- identities-keys-management (store layer only): Identity persistence (Task 8), used-by scan (Task 8), refuse-delete-if-referenced (Task 8). UI screens are Phase 5.
- icloud-sync-scope: sync taxonomy + audit-log stub (Task 9). CloudKit sync engine + toggles UI are Phase 2b/later.
