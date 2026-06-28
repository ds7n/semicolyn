# iCloud sync scope — design

**Status:** locked
**Date:** 2026-06-16
**Supersedes (partially):** the predictor's "On-device, encrypted at rest, no cloud" promise from `2026-06-13-predictor-design.md` (revised — see below). Removes audit-log references from `2026-06-15-host-config-model-design.md` and `2026-06-15-multi-connection-switching-design.md`.
**Related specs:** host-config-model (2026-06-15), predictor-design (2026-06-13), keybar-customization (2026-06-15), multi-connection-switching (2026-06-15), identities-keys-management (2026-06-15)

## Summary

Defines which user data syncs across the user's Apple devices via iCloud and which stays local. The host-config-model spec already locked the storage backbone (iCloud Keychain for keys/secrets, CloudKit Private DB + client-side AES for host records, Secure Enclave for device-bound keys, local for audit/recents/live state). This spec extends the sync table to cover the items that were deferred at that point: snippets, keybar customizations, audit log, and predictor sketches.

It also revises two previously-locked decisions:

1. The predictor's "no cloud" promise is replaced with **synced default ON**, justified by the structural privacy of CMS/Bloom (lossy aggregate, not recoverable text) plus E2EE storage.
2. The audit log is **dropped from v1 entirely**. A code-level stub is reserved for a future Pro-tier compliance log; no v1 user-facing surface.

## Scope

In scope:
- Sync decision for snippet/macro library
- Sync decision for keybar customizations
- Audit log status (dropped) and stub reservation
- Sync decision for predictor sketches (revises predictor spec)
- New-device restoration behavior
- Per-macro "don't sync" flag

Out of scope (carried forward unchanged):
- Encryption backbone (locked in host-config-model)
- iCloud Keychain vs Secure Enclave identity flavors (locked)
- Conflict resolution at sync time (deferred to implementation — CloudKit's last-write-wins is acceptable default for v1)

Out of scope (deferred to v1.5+):
- Pro-tier audit log (depends on the upcoming Pro / monetization brainstorm)
- Predictor sketch snapshot time-travel (point-in-time rollback to a prior sealed daily)
- Per-device override flags for sync (e.g., "this snippet only on iPhone")
- Sync-status indicators in the UI (last-synced timestamp, sync-in-progress badge)

## Organizing principle

> **Configuration syncs. Behavior / history doesn't** — except predictor sketches, which sync because they're structurally lossy and the cross-device value is too high to bury.

The principle gives a clean default for future additions: when a new piece of user data is added to Semicolyn, classify it as configuration (user-authored choices) or behavior/history (runtime artifacts) and apply this rule. Exceptions like the predictor sketches need explicit justification (and an updated spec).

## Sync table

This is the authoritative v1 sync scope. Items below the line carry forward from prior specs.

### Newly locked in this spec

| Item | Storage backend | Sync | Notes |
|---|---|---|---|
| **Macro library** (formerly "snippets / macros" — unified concept) | CloudKit Private DB + client-side AES-256-GCM | yes (default ON) | Per-macro "don't sync" flag for sensitive macros. |
| **Keybar customizations** | CloudKit Private DB + client-side AES-256-GCM | yes | Custom slots and their bindings, slot order, divider position, reverse-bar toggle. |
| **Audit log** | — | — | **Dropped from v1.** Code-level stub reserved (see below). No user-facing surface in v1. |
| **Predictor sketches** | CloudKit Private DB + client-side AES-256-GCM | yes (default ON, opt-out) | Revises the predictor spec's "no cloud" promise. CMS/Bloom + E2EE = structurally lossy + encrypted in transit and at rest. New-device restore is automatic via sync. CloudKit (not iCloud Keychain) because sketch blobs are multi-MB and exceed Keychain item-size constraints. |

### Already locked elsewhere (carried forward for completeness)

| Item | Storage backend | Sync | Source spec |
|---|---|---|---|
| Identities (iCloud Keychain flavor) | iCloud Keychain | yes (E2EE) | host-config-model |
| Identities (Secure Enclave flavor) | Secure Enclave | no (device-bound) | host-config-model |
| Keys, passwords, passphrases | iCloud Keychain | yes | host-config-model |
| `known_hosts` entries | iCloud Keychain | yes | host-config-model |
| Host records + Defaults record | CloudKit + AES | yes | host-config-model |
| Identity metadata records | CloudKit + AES | yes | host-config-model |
| Recent connections (picker history) | Local only | no | host-config-model + multi-connection-switching |
| Live session state | Local only | no | multi-connection-switching |

## Per-macro "don't sync" flag

The macro/snippet model gains a per-record boolean: **sync across devices? (✓ / ✗)**, default ✓.

When **unchecked**, the macro is stored locally only on the device it was authored on. It does **not** appear on other signed-in devices. The flag is editable after creation (the macro editor in the launcher carries the toggle).

This is the macro-level equivalent of the per-host `semicolyn.predictor.incognito` flag from the host-config-model. Same mental model, same opt-out shape, same purpose: let users keep sensitive entries local without forcing them to disable the whole sync category.

The flag is **not** modifiable by viewing the macro on a non-authoring device. Cross-device editing of the flag is deferred — a v1.5 candidate if usage shows demand.

## Audit log — dropped in v1, stub reserved

### What's dropped

No user-facing audit log surface in v1. Settings → Security has no audit-log entry. No log of:

- Connection events (connect / disconnect timestamps)
- Identity uses
- `known_hosts` changes
- Auth failures
- Biometric prompts
- Settings changes

### What replaces it

Runtime errors / banners / picker row indicators already surface what the user needs for *immediate* debugging:

- Connection problems → top-of-screen banner (locked design)
- Background-connection health → picker-row dot (locked design from multi-connection-switching)
- Auth/identity failures → host detail screen + banner on attempted connect

The **recent connections** list in the picker (last N hosts connected to) covers the "what did I recently connect to?" use case at the precision an individual user actually needs.

### Why this matters for privacy posture

The original host-config-model and multi-connection-switching specs both casually referenced an audit log. Those references are removed. Semicolyn's "no telemetry, security-first" posture is stronger without a local behavioral log sitting on the device — that log would be a high-value target if the device were compromised.

### Code-level stub reservation

To keep the door open for a future Pro-tier compliance log without committing to one now:

- Reserve a namespace in CloudKit and local storage (e.g., `auditLog.*` keys/tables).
- Define event-emission hook points in the codebase at the obvious places (connect, disconnect, identity use, etc.).
- These hooks are **no-ops** in v1 — they don't write anywhere, they don't allocate memory, they're trivially compiled out if the language supports it.
- Future Pro feature toggles the hooks on, writes to the reserved namespace, surfaces the log in Settings → Security.

This costs almost nothing in v1 implementation and preserves clean evolution to a Pro feature without retroactive instrumentation work later.

## Predictor sketches — revised to sync

### What's changing

The predictor spec (`2026-06-13-predictor-design.md`) locked: "On-device, encrypted at rest, no cloud." This spec replaces that with:

> Predictor sketches sync via CloudKit Private DB with client-side AES-256-GCM. Default ON. Users can opt out per-device in Settings → App preferences → Predictor.

### Why the revision is sound

The original "no cloud" promise was over-conservative once the actual data structure is examined:

- **Count-Min Sketch** is a probabilistic counter. It cannot reconstruct the exact tokens or sequences that were counted — only approximate frequencies, with hash collisions causing systematic overestimation. Even with full read access, an attacker cannot recover "what the user typed."
- **Bloom filter** is membership-only. It can answer "have we seen this token?" with controlled false-positive rate, but cannot enumerate tokens or recover sequences.
- The combination is a **lossy aggregate fingerprint** of vocabulary, not a recoverable typing history.

Combined with **client-side AES-256-GCM** before upload to CloudKit (the same encryption model already used for host records), the data is encrypted in transit and at rest, and even if an attacker had the encrypted blob, the underlying structure is mathematically lossy.

### Why default ON

The predictor's whole purpose is to learn the user's vocabulary. If a user types `kubectl get pods` 100 times on iPhone and opens iPad to a fresh predictor, the value is *halved*. Cross-device sync is the substantial UX win that justifies the revision.

Burying the sync behind an opt-in toggle most users will never find means most users won't get the value. Default ON, with a clear disclosure on the predictor settings screen, gives the value while respecting user agency.

### Settings disclosure copy

The predictor settings screen carries this exact disclosure (or close paraphrase):

> Your typing vocabulary syncs across your iCloud devices, encrypted end-to-end. The synced data is a lossy aggregate (frequency fingerprint) — not your exact text. Toggle off to keep learning local-only on this device.

The toggle is in Settings → App preferences → Predictor → "Sync vocabulary across devices."

### What about existing privacy controls?

The locked predictor privacy controls are unchanged:

- **Master off** — disable learning entirely
- **Read-only mode** — use sketches for suggestions, don't add new learnings
- **Per-host incognito** — don't learn anything from sessions to flagged hosts
- **Pattern-exclude list** — prevent learning of tokens matching user-defined patterns + scrub matching tokens
- **Wipe** — nuke all sketches and start over
- **Retention window** — sealed dailies older than the configured window (default 90 days) are dropped

Adding sync does not weaken any of these. The pattern-exclude scrub, for instance, runs both locally and propagates via sync (next device receives the scrubbed sketches, not the original).

### What's NOT being added

The earlier brainstorm explored a **"Forget this exact string"** feature (best-effort CMS decrement + do-not-suggest override). **Not in v1.** The existing controls (master off, pattern-exclude, wipe) cover the typical privacy needs. A specific-string forget is small but not essential; revisit if real users ask.

## Sync frequency and triggers

Specified at the design level; implementation details are spec-deferred.

| Item | Sync triggers |
|---|---|
| Snippet / macro library | On macro create / edit / delete. Cheap; record-level diffs. |
| Keybar customizations | On Settings → Keybar save. Cheap; single record. |
| Predictor sketches | **End-of-day seal** — when today's sketch is sealed into the rolling structures. Optionally, opportunistic mid-day sync if backgrounding (low priority). Per-keystroke sync is not done. |
| Identities, host records | On create / edit / delete. Per the host-config-model spec. |
| `known_hosts` | On TOFU acceptance or rotation. Per the host-config-model spec. |

Conflict resolution defaults to **CloudKit's last-write-wins**. Acceptable for v1 because: most data is single-device-edited at any given moment, and the data shapes are either small (host record) or aggregate (sketches) where slight loss is recoverable through normal use.

## New-device restoration

There is no separate "restore from iCloud" UI. Restoration is implicit via sync:

1. User installs Semicolyn on a new device, signs into iCloud, opens the app.
2. CloudKit sync engages on first launch.
3. Synced items (hosts, identities, snippets, keybar customizations, predictor sketches) populate from the user's iCloud account.
4. Device-bound items (Secure Enclave identities, local-only data) do **not** restore — they're tied to the original device by design.
5. The user lands in a populated app, ready to use.

For the "I wiped local data on this device, please re-sync" case, the same flow applies — re-signing into iCloud / re-installing Semicolyn / re-launching pulls the current synced state. No explicit restore button.

**Snapshot time-travel** (roll back to last Tuesday's sketches) is **not** in v1. The sealed-daily structure could support it, but the UI design (which day? merge or replace? per-item or wholesale?) and the storage cost in iCloud make it a v1.5+ candidate at most.

## Sync status visibility

In v1, there is **no sync-status surface** (no last-synced timestamp, no sync-in-progress badge, no manual "Sync now" button). CloudKit handles sync transparently and the user shouldn't need to manage it.

If real usage shows confusion ("did my macro sync?"), we can add a simple status line in Settings → App preferences → Storage. Not in v1.

## Migration / supersession notes

This spec **supersedes** the following previously-locked items. The earlier specs will need housekeeping updates (rolled into the next `sync` task):

1. `2026-06-13-predictor-design.md`, "Engine" / "Privacy" sections — the "On-device, encrypted at rest, no cloud" line is replaced. The privacy story is rewritten: "Sketches sync via CloudKit + AES; structurally lossy (CMS/Bloom) + E2EE; toggle off to keep local-only."
2. `2026-06-15-host-config-model-design.md`, "Storage backbone" table — the "Local only = audit log, recent connections, live session state" row drops "audit log."
3. `2026-06-15-multi-connection-switching-design.md`, "Open / deferred" — the line "Audit log entries for state transitions … Concrete schema deferred until the audit-log surface itself is designed" is updated: "Audit log dropped in v1 (see iCloud sync scope spec); no schema needed."
4. `brainstorming-decisions.md` "Credentials & security" — confirm no audit-log references; if any exist, remove.
5. `brainstorming-decisions.md` "Predictive input" → "Engine" row — update from "On-device, encrypted at rest, no cloud" to reflect the synced default.

## Open / deferred

- **Pro-tier compliance audit log** — gated on the Pro / monetization brainstorm. Stub reservation in place.
- **Predictor snapshot time-travel** — point-in-time rollback to a prior sealed daily. v1.5+ if demand.
- **Per-device sync override** for individual items — e.g., "this snippet only on iPad." Cross-device edit of the don't-sync flag. v1.5+ if demand.
- **Sync status surface** — last-synced timestamps, sync-in-progress indicators, manual trigger. v1.5+ if usage shows confusion.
- **Per-device-name override for keybar customizations** — iPhone-specific vs iPad-specific layouts. Deferred along with the iPad navigation work (separate spec).
- **CloudKit conflict resolution policy** — last-write-wins is acceptable default; revisit if real conflicts surface.

## Acceptance summary

The user experience this spec defines:

- A user signing into Semicolyn on a second Apple device finds their hosts, identities (non-Secure-Enclave), snippets, keybar customizations, and predictor vocabulary already there — no restore action needed.
- A user worried about sensitive snippets can flag specific macros as "don't sync" without disabling the entire snippet sync.
- A user worried about predictor vocabulary syncing can opt out in one toggle without losing local predictor learning.
- A privacy-conscious user finds clear disclosures on the relevant settings screens explaining what syncs and what doesn't.
- A user wiping the device or buying a new one experiences "open Semicolyn → it's all there" rather than "open Semicolyn → empty → import → resolve → painful."
- No audit log lives on the device. Behavioral history that doesn't earn its keep is simply not collected.
