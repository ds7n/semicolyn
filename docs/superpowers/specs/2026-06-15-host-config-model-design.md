# Host config model — design

> **Scope.** This spec defines the **data schema** for a Neotilde host record: fields, types, defaults inheritance, identity references, jump chains, port forwards, mosh/Tailscale extensions, `known_hosts` storage, and the storage backbone the schema lives on.
>
> **Out of scope** (separate brainstorm sessions): the host **CRUD UI flow** (create/edit/delete screens, validation, import from `~/.ssh/config`, export, error states) and the **multi-connection switching semantics** (foreground/background lifecycle, mosh heartbeating in iOS background, SSH background grace, when "Live" picker rows demote to "Recent").
>
> The host-management entry point (long-press Esc → picker sheet) and the settings tree (Hosts / Identities & Keys / Security / App preferences / About) are already locked in `docs/brainstorming-decisions.md`. This spec assumes them.

## Design principles

1. **`ssh_config(5)`-faithful naming and semantics.** Every field that has an OpenSSH analog uses the OpenSSH name and means what OpenSSH means by it. Neotilde extensions live under clearly namespaced fields (`mosh.*`, `tailscale.*`, `neotilde.*`) so they cannot be confused with SSH-derived options.
2. **Strict subset of OpenSSH's expressive power.** v1 ships Tier 1 (always visible) and Tier 2 ("Advanced") field sets, typed. No raw-option escape hatch in v1.
3. **Lossless import/export between Neotilde schema and `~/.ssh/config`** is a design goal for the SSH-derived fields. An imported host round-trips through export → import without losing information for any field we model. Neotilde extensions are skipped or emitted as comments on export.
4. **UUIDs internally, label for humans.** Stable internal references survive label edits; sync conflicts at the ID level are effectively impossible (UUID v4 collision: ~10⁻³⁷).
5. **iCloud-portable by default; Secure Enclave as an opt-in upgrade.** Users get device portability for free; hardware-binding is available for users who explicitly want it and accept the single-device constraint.
6. **End-to-end encryption everywhere, regardless of whether the user has Apple's "Advanced Data Protection" enabled.** Neotilde applies client-side AES-GCM to CloudKit records so Apple sees only ciphertext.

## Storage backbone

| Lives in | Contents | Encryption / trust model |
|---|---|---|
| **iCloud Keychain** | SSH keys (default flavor), passwords, passphrases, `known_hosts` entries, the AES key used to encrypt CloudKit records | End-to-end encrypted by Apple; syncs across the user's Apple-ID devices |
| **Secure Enclave** | "Enhanced" device-bound identities (opt-in at key creation) | Hardware-bound; cannot leave the device; does not sync |
| **CloudKit Private DB + client-side AES-256-GCM** | Host records, the singleton Defaults record, Identity *metadata* (display name, fingerprint, flags) | Records are AES-256-GCM ciphertext when written; the 32-byte key lives in iCloud Keychain → effective E2EE regardless of ADP setting |
| **Local only (never sync)** | Recent-connections list, live session state | Local file storage + standard iOS data protection. (Audit log originally listed here; dropped from v1 in `2026-06-16-icloud-sync-scope-design.md`. Code-level stub reserved for a future Pro feature.) |

Identity *private key material* always lives in Keychain or SE — never in CloudKit. Identity metadata in CloudKit only references private material by UUID.

## Entity model

### `Host`

```
Host {
  // Identity & display (required)
  id:        UUID                  // immutable, internal; never user-visible except in diagnostics
  label:     string                // user-facing; soft-unique (warn on duplicate, allow save)
  hostName:  string                // OpenSSH HostName (DNS name or IP)

  // OpenSSH Tier 1 — all optional, inherit from Defaults if undefined
  user?:                string
  port?:                number
  identities?:          IdentityRef[]       // ordered; tried in order, like OpenSSH IdentityFile
  passwordRef?:         string              // UUID of a stored password in Keychain
  proxyJump?:           JumpHop[]           // ordered hops; ref-or-inline per hop
  localForwards?:       LocalForward[]
  remoteForwards?:      RemoteForward[]
  dynamicForwards?:     DynamicForward[]

  // OpenSSH Tier 2 — all optional
  serverAliveInterval?:      number          // seconds
  serverAliveCountMax?:      number
  compression?:              boolean
  strictHostKeyChecking?:    "yes" | "accept-new" | "ask" | "no"
  forwardAgent?:             boolean         // default false (security-conservative)
  preferredAuthentications?: ("publickey" | "password" | "keyboard-interactive")[]

  // Neotilde extensions — all optional, namespaced
  mosh?: {
    enabled:          boolean
    serverPath?:      string                  // path to mosh-server on the host, if non-default
    udpPortRange?:    [number, number]        // default [60000, 61000]
    predictionMode?:  "adaptive" | "always" | "never" | "experimental"
  }
  tailscale?: {
    required:  boolean                        // if true: refuse connect & show "Tailscale required" banner when Tailscale is down
    tailnet?:  string                         // for the rare multi-tailnet case
  }
  neotilde?: {
    predictor?: { incognito?: boolean }       // when true, predictor does not learn from this host's keystrokes
    tmux?:      { attemptControlMode?: boolean } // when false, skip `tmux -V` probe; go straight to raw PTY
  }
}
```

#### Inheritance semantics

- `undefined` = **inherit** from `Defaults`, then fall back to the built-in default.
- `null` (or `[]` for list fields) = **explicit override to "none."**

This distinction is baked in from day one so a future move to per-group or per-pattern defaults (Q1's deferred options C/D) does not require a schema migration to disambiguate "blank means inherit" from "blank means I cleared it."

### `JumpHop` (discriminated union)

Matches OpenSSH `ProxyJump` semantics, which allow either an alias (reference to another `Host`) or an inline `user@host:port` per hop.

```
JumpHop =
  | { kind: "ref",    hostId: UUID }
  | { kind: "inline", hostName: string, port?: number, user?: string, identities?: IdentityRef[] }
```

**Cycle prevention:** at save time, walk the chain from the host being saved; refuse to save if it loops back through any host already in the chain.

**Deletion of a referenced jumphost:** **refuse delete** with a clear message ("Used as jumphost by: prod-db, staging-api. Remove references first."). No silent cascade. No copy-to-inline magic.

### Port-forward records

OpenSSH-faithful shapes:

```
LocalForward   = { bindAddress?: string, bindPort: number, hostAddress: string, hostPort: number }
RemoteForward  = { bindAddress?: string, bindPort: number, hostAddress: string, hostPort: number }
DynamicForward = { bindAddress?: string, bindPort: number }   // SOCKS proxy
```

`bindAddress` optional (defaults to localhost). Lossless round-trip with OpenSSH text form (`LocalForward 8080 db.internal:5432` → `{bindPort: 8080, hostAddress: "db.internal", hostPort: 5432}`).

### `HostKey` (known_hosts entries)

Stored in iCloud Keychain (synced, E2EE), queried by host UUID. Multiple entries per host supported (key rotation: old key + new key both valid for a window).

```
HostKey = {
  algorithm:   string             // "ssh-ed25519", "ecdsa-sha2-nistp256", "ssh-rsa", …
  fingerprint: string             // SHA256:base64
  addedAt:     Date
  source:      "manual" | "trust-on-first-use" | "imported"
}
```

**Trust-on-first-use propagation:** because entries live in iCloud Keychain, accepting a host key on iPhone propagates to iPad automatically — no re-verification per device.

**Mismatch handling** (UI behavior, not schema): connection-status banner + modal showing old fingerprint, new fingerprint, host label, and when each was added. Actions: *Trust new key* / *Trust new key only on this device* / *Cancel connection*. The "only on this device" path writes a non-synced entry to local-only storage; design of that fallback path is deferred to the CRUD/UI spec.

### `Defaults` (singleton)

```
Defaults = Partial<Host>          // minus the required fields { id, label, hostName }
                                  // same field names, same types, same semantics as Host
                                  // exactly one record per user (synced via CloudKit + client-side AES)
```

The Defaults record carries any field that is optional on `Host`. Resolution: per-host `undefined` → Defaults' value → built-in fallback.

### `Identity` (first-class entity)

Identities are separate first-class records because the iOS storage model forces it:

- Secure Enclave private keys cannot leave the SE; you can only reference them by UUID handle.
- iCloud Keychain SSH keys outlive any specific host (deleting a host should not destroy a key that other hosts might still use).
- A single identity may be referenced by many hosts.

```
Identity {
  id:                UUID
  displayName:       string                                    // user-facing
  flavor:            "iCloudKeychain" | "secureEnclave"
  algorithm:         "ed25519" | "ecdsa-p256" | "ecdsa-p384" | "rsa"
  publicKey:         string                                    // for display, copy, audit
  fingerprint:       string                                    // SHA256:base64
  createdAt:         Date
  biometricPolicy:   "never" | "anyUse" | "afterUnlock"        // enforced by iOS via SecAccessControl
  // private key material accessed via Keychain query (flavor=iCloudKeychain)
  // or SE query (flavor=secureEnclave) keyed by this UUID
}

IdentityRef = UUID                                              // points at an Identity record
```

#### Identity flavors

| Flavor | Where the private key lives | Syncs? | Threat model |
|---|---|---|---|
| `iCloudKeychain` (default) | iCloud Keychain | Yes — across all Apple-ID devices | Strong (E2EE); compromise requires Apple ID + recovery factor, **or** device + passcode |
| `secureEnclave` (opt-in "Enhanced") | Secure Enclave | No — single device, never extractable | Strongest; compromise requires this physical device + biometric/passcode |

Flavor is chosen at key creation. The UI is explicit about the trade at the moment of choice.

#### Auth policy

Auth policy is **identity-level** in v1, enforced by iOS via `SecAccessControl`:
- `never`: key usable any time the device is unlocked
- `anyUse`: biometric (Face ID / Touch ID) required on every use of the key
- `afterUnlock`: biometric required once per device unlock; usable thereafter for that session

Host-level confirmation ("always prompt before connecting to this host even if the key is unlocked") is deferred to v1.5.

#### Inline create during host creation

The host create flow can create a new `Identity` inline — the user does not need to visit "Identities & Keys" first. The identity still lands in the central Identity store and is referenced by UUID; the host record carries only the reference. "Identities & Keys" becomes the management surface (rotation, audit "which hosts use this key?", deletion), not the daily path.

## Resolution & fallbacks

Resolution order for any optional field on `Host`:

1. Per-host value, if not `undefined`
2. `Defaults` record value, if not `undefined`
3. Built-in fallback

### Built-in fallback table

| Field | Fallback |
|---|---|
| `port` | 22 |
| `user` | **No fallback.** If unset on both host and Defaults, refuse to connect with a clear error: *"Set a user for this host or in Defaults to connect."* (iOS has no OS-level "current user" concept to fall back to.) |
| `compression` | `false` |
| `forwardAgent` | `false` (security-conservative) |
| `strictHostKeyChecking` | `"accept-new"` (TOFU for new hosts, strict for known) |
| `serverAliveInterval` | `30` (seconds) |
| `serverAliveCountMax` | `3` |
| `preferredAuthentications` | `["publickey", "keyboard-interactive", "password"]` (this order also determines whether keys from `identities` or `passwordRef` are attempted first) |
| `mosh.enabled` | `false` |
| `tailscale.required` | `false` |
| `neotilde.predictor.incognito` | `false` |
| `neotilde.tmux.attemptControlMode` | `true` |
| `identities` | `[]` (empty — passwordRef or interactive auth will be attempted) |
| `passwordRef` | unset |
| `proxyJump` | `[]` (direct connection) |
| `localForwards`, `remoteForwards`, `dynamicForwards` | `[]` |

## Naming conventions

- Schema field names use Swift-style lowercase camelCase: `hostName`, `proxyJump`, `serverAliveInterval`.
- Word stems match `ssh_config(5)` exactly: `HostName` → `hostName`, `ProxyJump` → `proxyJump`, `IdentityFile` → `identities` (renamed plural because we always model an ordered list; OpenSSH allows the option to repeat to the same effect).
- Neotilde extensions are namespaced: `mosh.*`, `tailscale.*`, `neotilde.*` — never intermixed with OpenSSH-derived fields at the top level.
- `label` is **not** an OpenSSH concept; it's a human display name. On export to `~/.ssh/config`, `label` is sanitized to an OpenSSH-valid alias (collisions resolved with `-2`, `-3` suffixes at export time). Internal references always use the immutable UUID.

## Threat model summary

- **At rest in iCloud:** Apple sees CloudKit record count, sizes, modification timestamps. Record contents are AES-GCM ciphertext (Neotilde's client-side encryption). The encryption key lives in iCloud Keychain (E2EE; Apple cannot read).
- **iCloud Keychain contents** (keys, passwords, known_hosts, the host-config encryption key): end-to-end encrypted by Apple. Apple cannot decrypt server-side.
- **Secure Enclave private keys** (opt-in flavor): hardware-bound; never leave the device; even with full account compromise, an attacker cannot exfiltrate them.
- **Compromise of Apple's CloudKit infrastructure alone:** yields ciphertext only.
- **Loss of all devices + iCloud recovery factor:** data is unrecoverable. Apple cannot restore it. This is the right trade for "secure."

## Out of scope / deferred

### Out of scope for *this* spec (separate brainstorm sessions to come)

- **Host CRUD flow** — create/edit/delete UI, validation rules, import from `~/.ssh/config`, export, error states, the duplicate-label warning UX, the jumphost-in-use deletion message UX, the inline-create-an-identity wizard.
- **Multi-connection switching semantics** — what happens to a foreground SSH/mosh connection when the user switches to another host: tmux session lifecycle, mosh heartbeat budget in iOS background, SSH background-grace duration, when "Live" rows demote to "Recent" automatically.

### Deferred to v1.5+ (additive schema changes, do not break v1 records)

- **Groups / tags with per-group defaults** (Q1's option C). Adding a `groupId?: string` field on `Host` and a `groups` collection is forward-compatible.
- **Pattern matching** à la `Host *.internal` (Q1's option D). Adding a `patternRules` collection is forward-compatible.
- **Tier 3 OpenSSH options** — `Ciphers`, `MACs`, `KexAlgorithms`, `HostKeyAlgorithms`, `GSSAPI*`, `ForwardX11`, `AddressFamily`, `BindInterface`, `CanonicalDomains`, etc. Most modern OpenSSH defaults are sane; surface only on user demand.
- **Raw OpenSSH escape hatch** — `extraOptions: [string, string][]` for power users who hand-edit; not in v1.
- **Tailscale SSH support** — `tailscale up --ssh` flow where authentication uses the tailnet identity instead of an SSH key. Different auth path; defer.
- **Pinned snippets per host** — currently global.
- **Keybar slot overrides per host** — currently global.
- **Context-detection process overrides per host** — currently global (e.g., "my custom-named vim binary").
- **Predictor pattern-exclude additions per host** — currently global + a per-host `incognito` toggle.
- **Host-level confirmation policy** — "always prompt before connecting to this host" as an orthogonal auth-policy field on `Host`.
