# Host-key trust UX — first-trust + mismatch

**Date:** 2026-06-17
**Status:** Locked
**Resolves:** punch-list item #2 in `docs/final-review-punchlist.md`. [[2026-06-15-host-config-model-design]] flagged the mismatch modal as "deferred to CRUD spec"; CRUD didn't pick it up. This spec fills both gaps.

## Default policy

`strictHostKeyChecking = ask` is the v1 default for every host. Explicit user confirm on first trust, explicit user confirm on key change. Tier 2 in the host-config schema lets a power user set `accept-new` or `no` per host; the default is the conservative one.

The advertised key algorithms and the order they're tried are governed by the v1 algorithm allowlist (separate punch-list item #3, separate spec). Once the remote selects an algorithm, this spec governs what happens with the resulting key.

## Storage

Per [[2026-06-15-host-config-model-design]] the `known_hosts`-equivalent entries live in iCloud Keychain. Each entry is a `(host-pattern, key-type, fingerprint, key-material)` tuple, syncing E2EE across the user's devices. This spec doesn't change storage; it specifies the UI surfaces that read and write those entries.

## First-trust modal

When connecting to a host with no stored key for the offered algorithm.

### Layout

```
┌─────────────────────────────────────────┐
│  Trust this host?                        │   ← neutral header (Bell-Bronze tinted)
├─────────────────────────────────────────┤
│  build-01.example.com                    │   ← label (large)
│  ed25519                                 │   ← key type (dim)
│                                          │
│  SHA256:                                 │
│  s4xL+m2…WYzZ                            │   ← fingerprint in monospace
│                                          │
│  Verify this matches what your           │   ← body, dim
│  administrator gave you, or the          │
│  fingerprint shown by the server when    │
│  you set it up.                          │
│                                          │
│  ┌──────────────────────┐  ┌──────────┐ │
│  │  Trust & Connect      │  │  Cancel  │ │   ← primary bronze / dim
│  └──────────────────────┘  └──────────┘ │
└─────────────────────────────────────────┘
```

### Behavior

- **Trust & Connect:** the entry is written to the iCloud-Keychain-backed `known_hosts` for this host pattern + key type, and the connection proceeds. No further prompt until the key changes.
- **Cancel:** the connection is aborted. No entry is written. The host stays in "first-trust will be re-prompted next attempt" state.
- **No biometric required** for either action. The user is already past the device-unlock gate; this is a trust decision, not a key-extraction one.
- **Fingerprint is selectable / copyable** via long-press magnifier (matches the rest of the design's monospace-copyable convention from identity management).

### When the modal fires

- First connection to a label that has no entry of the relevant key type.
- When a host config lists multiple `HostKeyAlgorithms` and a *new* algorithm is negotiated (e.g., the host previously offered ed25519 and now also offers rsa-sha2-512). Each (host, key type) is independently trusted.
- **Multi-device sync:** if device A has already trusted this host, the iCloud-synced `known_hosts` entry is on device B before its first connection; no modal fires on B.

## Mismatch modal

When the offered key for a host+algorithm does **not** match the stored entry.

### Layout

```
┌─────────────────────────────────────────┐
│  ⚠  Host key changed                     │   ← red header strip
├─────────────────────────────────────────┤
│  build-01.example.com                    │
│  ed25519                                 │
│                                          │
│  This may indicate a man-in-the-middle   │   ← body, slightly weighted
│  attack. Only continue if you know the   │
│  host key legitimately changed (server   │
│  reinstall, key rotation).               │
│                                          │
│  Last seen:                              │
│  SHA256:s4xL+m2…WYzZ                     │   ← stored fingerprint, dim
│                                          │
│  Now offering:                           │
│  SHA256:q9oN+x4…RkPp                     │   ← offered fingerprint, bright
│                                          │
│  ┌──────────┐ ┌─────────────┐ ┌──────────────────────┐ │
│  │  Cancel  │ │  Edit host  │ │  Replace key & connect│ │
│  └──────────┘ └─────────────┘ └──────────────────────┘ │
└─────────────────────────────────────────┘
```

### Actions

| Action | Role | Effect |
|---|---|---|
| **Cancel** | Primary, dim | Aborts the connection. Stored entry unchanged. |
| **Edit host** | Neutral | Opens the host's CRUD form. For the "wait, I think I aimed at the wrong server" case. Closes this modal; reopens on next connect attempt if the mismatch persists. |
| **Replace key & connect** | Destructive, requires secondary confirm | Opens the secondary confirm sheet below. Only on success does the stored entry get replaced. |

### Secondary confirm sheet

iOS action sheet (red destructive style):

> **Replace stored key?**
> The new key will replace the previous one for this host. If this change is unexpected, do not continue.
>
> [ Replace and connect ] ← red
> [ Cancel ]

The action-sheet pattern matches [[2026-06-15-identities-keys-management-design]]'s delete confirmation. No biometric — the device-unlock gate already covers the user's authority; this is a trust decision.

### When the modal fires

- Stored entry for (host pattern, key type) exists, offered key fingerprint differs.
- Per-algorithm: a key change on ed25519 doesn't invalidate the rsa-sha2-512 entry. Each is tracked independently.

## Cross-modal interaction

- **The fingerprint format is consistent everywhere**: SHA256, base64url, no trailing `=`, displayed with truncation as `SHA256:s4xL+m2…WYzZ` (first 5 chars + ellipsis + last 4 chars) but always **expandable on tap** to the full string for verification.
- **Always-copyable.** Long-press magnifier copies the full fingerprint regardless of truncation.
- **Storage write happens after the user action**, not after the modal closes. If the network drops between the action and the connection completing, the entry has already been written.

## Forget-and-retry path

Out of the modal. The user can also pre-clear a stored key from **Settings → Security → Host fingerprints → swipe-to-forget**, established in [[2026-06-16-settings-sub-screens-design]]. After a forget, the next connection to that host fires the first-trust modal as if it were brand new. This is the explicit path for "I want to start fresh."

## Out of scope (v1)

- **DNSSEC SSHFP record lookup.** Could short-circuit first-trust for hosts that publish their host key in DNS. Deferred — useful for org users but adds DNS infrastructure dependency that v1 doesn't need.
- **CA-signed host certificates.** Out of scope of this UX spec; will be covered by the SSH algorithm + cert-auth spec (punch-list item #4).
- **Per-host suppression of the first-trust modal** ("never ask me for this host"). Not designed; the existing per-host `strictHostKeyChecking` Tier 2 option already covers it.
- **Bulk import of `known_hosts`** from `~/.ssh/known_hosts`. Out of scope — matches the rejection of `~/.ssh/config` import from earlier brainstorming.

## Cross-spec consequences

- [[2026-06-15-host-config-model-design]] — the "modal exists, design deferred to CRUD spec" note now points here. No schema change.
- [[2026-06-15-host-crud-design]] — no change; the mismatch modal's "Edit host" action opens the existing CRUD form.
- [[2026-06-16-settings-sub-screens-design]] — host fingerprints drill-down already provides the forget-and-retry path; no change needed.
- [[2026-06-17-design-tokens-design]] — modals use `state.broken` (red header strip for mismatch) and `accent.primary` (Trust & Connect button).

## Related

- [[2026-06-15-host-config-model-design]]
- [[2026-06-16-settings-sub-screens-design]]
- [[2026-06-15-identities-keys-management-design]] — sets the action-sheet destructive-confirm pattern reused here.
- [[2026-06-17-design-tokens-design]]
