# Jump-host chain authentication

**Date:** 2026-06-17
**Status:** Locked
**Resolves:** punch-list item #5 in `docs/final-review-punchlist.md`.

## Goal

Define what the user sees when connecting through a `proxyJump` chain whose hops use identities with different auth policies, especially when multiple hops require fresh biometric (`anyUse`) authentication.

## Constraint from iOS

Secure Enclave keys with `anyUse` policy require a *fresh* biometric for *each* signing operation. Semicolyn cannot bank one Face ID for multiple `anyUse` operations — the SE enforces this at the hardware level. Any chain with two `anyUse` hops will, by necessity, prompt twice. The question is purely about UX framing around an unavoidable fact.

## Behavior

### Chain enumeration

Before initiating the connection, Semicolyn enumerates the auth chain: the final host and every `proxyJump` hop, each with its negotiated identity. It counts identities with `authPolicy: anyUse`.

### Single-prompt case (0 or 1 anyUse in chain)

**No summary modal.** The chain proceeds; if a single `anyUse` identity is used, its Face ID prompt fires at the moment that hop authenticates — expected behavior, same as a direct connection to an `anyUse` host. Zero `anyUse` = fully silent chain after the device-unlock gate.

### Multi-prompt case (≥2 anyUse in chain)

**Pre-flight summary modal** at connection start, before any socket is opened to any hop:

```
┌─────────────────────────────────────────┐
│  Multiple authentications required       │   ← neutral header
├─────────────────────────────────────────┤
│  Connecting to target.example.com        │
│  through 2 jump hosts.                   │
│                                          │
│  Face ID will be required twice:         │
│                                          │
│    hop 1   bastion1.example.com          │
│            (Personal SE)                 │
│                                          │
│    hop 2   bastion2.example.com          │
│            (Work SE)                     │
│                                          │
│  ┌──────────────┐  ┌──────────┐          │
│  │  Continue    │  │  Cancel  │          │
│  └──────────────┘  └──────────┘          │
└─────────────────────────────────────────┘
```

- Primary action **Continue** dismisses the modal and starts the chain. Face ID prompts fire serially as each `anyUse` hop authenticates.
- **Cancel** dismisses; no connection attempt is made; no state mutated.
- Body lists every `anyUse` hop in chain order with the identity label that will be used. Non-`anyUse` hops are not listed (no friction to call out).
- Final target is named in the lede so the user knows what they're trying to reach, but not enumerated as a hop unless its own identity is `anyUse`.

### Serial Face ID flow

After Continue (or in the 0/1 prompt case where the modal didn't fire), connection proceeds as normal. Each `anyUse` identity gets its Face ID prompt at the moment its hop is authenticated by the SSH stack. The existing connection-status banner shows in-progress state per [[2026-06-16-banner-expanded-design]] (reconnecting / connecting templates).

### Cancellation paths

The user can interrupt the chain in two places:

1. **Cancel the summary modal** — no sockets opened, nothing to clean up. Trivial.
2. **Cancel a mid-chain Face ID prompt** (iOS-native cancel on the biometric sheet) — Semicolyn aborts the in-flight connection: closes the SSH socket to the current hop, closes any sockets to earlier hops, marks the connection as failed in the picker, fires the existing connect-failed banner from [[2026-06-16-banner-expanded-design]] with the message *"Authentication cancelled at hop {n}."*

No partial-success state. A chain either fully establishes or fully fails.

## Edge cases

- **All `anyUse` identities point at the same key reference.** Each use is still a separate SE signing operation; each still prompts. No coalescing. (The SE doesn't expose a "this is the same key, batch these" affordance.)
- **`anyUse` plus `afterUnlock` mixed in the chain.** The summary modal counts only `anyUse`. An `afterUnlock` hop is silent.
- **Chain with no `anyUse` but the user has app-level App lock enabled** (per [[2026-06-16-settings-sub-screens-design]]). The App-lock biometric is a one-time gate at app foreground; not part of this spec.
- **Chain depth limit.** No spec'd cap on chain length in v1 — `host-config-model-design.md` allows arbitrary `proxyJump` depth. The summary modal scales by listing each `anyUse` hop on its own row; at very long chains the modal becomes scrollable.

## What this is *not*

- **Not a per-connection consent dialog.** Single-prompt connections stay silent. The modal exists only to set expectations when iOS is about to prompt the user multiple times in sequence.
- **Not a way to bypass `anyUse`.** `anyUse` is a deliberate user choice; the chain UX respects it absolutely. The summary modal is informational only.
- **Not a way to remember "I already approved this chain."** Each connection that hits ≥2 `anyUse` hops gets the modal again. No "don't ask again." The whole point of `anyUse` is no-caching.

## Cross-spec consequences

- [[2026-06-15-multi-connection-switching-design]] — the "auth-policy interaction on wake" section currently describes single-hop `anyUse` waking. The chain case is now grounded here; cross-link both directions.
- [[2026-06-16-banner-expanded-design]] — the connect-failed template gains a possible fault reason: "Authentication cancelled at hop {n}." Body grid: "Failed at hop {n}, host {bastion-label}, identity {label}." No new template, just a use case.
- [[2026-06-15-host-config-model-design]] — no schema change. The chain UX reads existing `proxyJump` and identity `authPolicy` fields.
- [[2026-06-15-host-crud-design]] — no change. The auth section already exposes identity selection per hop.

## Related

- [[2026-06-15-multi-connection-switching-design]]
- [[2026-06-15-host-config-model-design]]
- [[2026-06-16-banner-expanded-design]]
- [[2026-06-16-settings-sub-screens-design]]
