# Identities & Keys management surface — design spec

> **Scope.** The standalone management surface for SSH identities: the `Settings → Identities & Keys` list, the per-identity detail screen, the create/import sub-flow (shared with host CRUD), the delete action sheet (including the refused-if-referenced case), and entry points.
>
> **Out of scope.** Key rotation flows (deferred to v1.5 once `ssh-copy-id` auto-install lands), QR / Share / AirDrop public-key export, the host CRUD form itself, multi-connection switching semantics.
>
> The `Identity` data schema is already locked in `docs/superpowers/specs/2026-06-15-host-config-model-design.md`. This spec is pure UI over that schema.

## Design principles

1. **Inventory, not console.** Users come here to act on a specific identity (rename, change auth policy, delete, see usage), not to drive a multi-step workflow. The screen is read-mostly, edit-occasionally.
2. **No fake rotation.** A rotation "wizard" without `ssh-copy-id` is a checklist with a hand-wave in the middle. Defer the whole concept until the auto-install primitive exists; provide only the parts that actually work today (mint, copy public key, edit references, delete).
3. **Reuse, don't reinvent.** The create/import sub-flow is the same half-sheet as the host CRUD inline create. The "Used by N hosts" drill-down is the same component as `Settings → Hosts`, filtered.
4. **App unlock is the security gate.** No per-toggle biometric on settings edits — that's not the convention in comparable apps (Blink, Termius, Secretive, 1Password, Bitwarden, iOS Passwords) and adds friction without raising the bar.
5. **Destructive actions are deliberate, not double-tappable.** Delete lives only on the detail screen, behind an action sheet whose geometry guards against muscle-memory confirmation.

## Architecture

Two screens plus one shared sub-flow:

| Surface | Presentation | Reached from |
|---|---|---|
| **Identities list** | Full-screen push | `Settings → Identities & Keys` |
| **Identity detail** | Full-screen push | List row tap · identity ref tap inside host CRUD |
| **Create/Import sub-flow** | Half-sheet from bottom | `+` button on list (standalone) · `+ Add identity` inside host CRUD (attached) |

The `Identity` entity itself is unchanged. The "Used by" relationship is computed on demand by scanning host records — at the scale of identities per user (single-digit to low-double-digit) there is no need for a persisted reverse index in v1.

## List screen

### Nav bar

- **Left:** back chevron (`‹ Settings`)
- **Center:** title "Identities & Keys"
- **Right:** `+` button — launches the create/import half-sheet in **standalone mode**

### List

- **Sort:** alphabetical by `displayName`, locale-aware.
- **No search, no filter, no sort toggle.** The list is small enough that any of these would be more chrome than payload.
- **No swipe-actions.** Delete is intentionally unreachable from the list; only the detail screen exposes it.

### Row anatomy

```
┌─────────────────────────────────────────────────┐
│  personal-github                  [iCloud]      │
│  ed25519 · SHA256:R9mNxJpVqB…    Used by 1   › │
└─────────────────────────────────────────────────┘
```

| Element | Source | Treatment |
|---|---|---|
| Display name (line 1) | `Identity.displayName` | 13pt semibold, truncates with ellipsis |
| Algorithm + fingerprint preview (line 2) | `Identity.algorithm` + first 12 chars of `Identity.fingerprint` after `SHA256:` | 11pt monospace, muted color |
| Flavor chip (top right) | `Identity.flavor` | `iCloud` chip (muted gray) or `SE` chip (bronze accent — Enhanced tier gets brand color) |
| Usage indicator (bottom right) | Computed: count of hosts referencing this identity | `Used by N` (muted) or `Unused` (further muted, italic) |
| Chevron | — | Tap target: entire row → push detail |

### Empty state

Common on first install. Centered glyph + one-line copy + a single CTA button:

- Glyph: simple key icon in bronze tint
- Copy: "No keys yet" (semibold) · "SSH identities you create or import will appear here." (muted)
- CTA: "Create or import a key" — opens the same half-sheet as the `+` button

## Identity detail screen

Push from a list row tap, or from a host CRUD identity ref tap. Single scrollable screen.

### Nav bar

- **Left:** `‹ Identities` (or `‹ Edit host` when entered from host CRUD)
- **Center:** display name (truncates)
- **Right:** empty — all edits commit inline; there is no Save button

### Header card

A single panel-tinted card at the top sets context:

- Large flavor chip: `iCloud Keychain` (muted) or `Secure Enclave` (bronze)
- `Identity.algorithm` in bold
- `Created <date>` formatted in the user's locale

### Secure Enclave advisory (SE only)

Immediately under the header card, a constant low-contrast row with a small lock glyph:

> This key is bound to this device. It will not appear on your other Apple devices.

iCloud Keychain identities omit this row.

### Identity section

| Field | Behavior |
|---|---|
| `Display name` | Inline-editable. Tap → text field opens with current value. Commit on blur / return. Empty name is disallowed; on empty-blur, revert to prior value. Soft-uniqueness only (warn but allow duplicates, matching host label rules from `host-config-model-design.md`). |

### Public key section

A monospace block showing the public key in full OpenSSH format. A `Copy` action on the right places the public key on the clipboard. No QR, no share-sheet, no AirDrop in v1 — clipboard is the universal path and matches the host-crud spec which already says public-key Copy is the primary action.

The block expands by default to its full multi-line height (the public key is the most useful artifact on this screen; making the user expand it adds friction without payoff).

### Fingerprint section

The full `SHA256:…` fingerprint in monospace, with a `Copy` action. Read-only (derived from key material).

### Security section

A three-segment control labeled in plain language, mapping to the schema's auth-policy values:

| Label | Schema value | Explainer (rendered under control when selected) |
|---|---|---|
| `Never` | `never` | "Key usable any time the device is unlocked." |
| `Per-unlock` (default) | `afterUnlock` | "Biometric required once per device unlock; usable thereafter for the session." |
| `Per-use` | `anyUse` | "Biometric (Face ID / Touch ID) required on every use of the key." |

Changes commit immediately, no biometric, no confirmation. The app-level unlock is the security gate.

### Usage section

A single tappable row: `Used by N hosts` with chevron.

- Pushes to a filtered host list (the same component as `Settings → Hosts`, filtered to hosts referencing this identity).
- If N = 0, the row reads `Unused` in a muted tone and still pushes — to an empty state ("No hosts use this identity") rather than no-op, so the back-reference contract is symmetric.

### Delete button

Anchored at the bottom of the scrollable content:

- Style: full-width row, red text on a faint red tint background, generous top padding to keep it away from accidental scroll-taps.
- Label: "Delete identity"
- Behavior: launches the delete action sheet (see below). Disabled / converted to the refused-if-referenced sheet if `usedBy > 0`.

## Delete confirmation

iOS action sheet from the bottom. No biometric.

### Unreferenced case (`usedBy = 0`)

The sheet has two groups:

**Top group (deliberate-action surface):**

1. Title row: `Delete <displayName>?` (small caps, muted)
2. Body row: copy varies by flavor (see below)
3. Destructive row: `Delete key` in red, semibold

**Bottom group (escape):**

1. `Cancel` in normal weight

The destructive row sits in the top group and the cancel row sits in the bottom group, separated by a visible gap. The user's thumb just tapped the `Delete identity` button at the bottom of the detail screen; the new tap target for `Delete key` is visually offset upward, while `Cancel` is the bottom-most option. A muscle-memory double-tap lands on Cancel.

### Body copy by flavor

| Flavor | Copy |
|---|---|
| `iCloudKeychain` | "This will remove the key from **all your devices**. Hosts that use this key will lose access until you assign them another." |
| `secureEnclave` | "This key was never backed up. **It cannot be recovered.**" |

The bolded irreversibility line for SE is rendered in red, not just bold — the worst outcome (destroying a key the user can't recover) deserves a visual cue, not just typographic emphasis.

### Referenced case (`usedBy > 0`)

The detail screen's `Delete identity` button is replaced by the same action sheet shape, but with refusal copy and no destructive option:

**Top group:**

1. Title: `Can't delete <displayName>`
2. Body: "This identity is referenced by **N hosts**. Remove or reassign them first."
3. Navigation row: `Show hosts using this key` in accent color → pushes the same filtered host list as the Usage section.

**Bottom group:**

1. `Cancel`

This mirrors the refused-if-referenced delete pattern from `host-crud-design.md` (jump host with dependents). No cascade option, no "force delete" — the user reroutes via the back-references.

### What gets deleted

On confirm:

1. The `Identity` metadata record (CloudKit) is removed.
2. The underlying private key material is destroyed:
   - **iCloud Keychain:** Keychain item deleted; propagates to other devices via iCloud sync.
   - **Secure Enclave:** key handle released; the SE-bound key is destroyed and cannot be recovered.
3. The public key is not retained anywhere after this point.

No orphaned key material. The user expectation when they tap "delete a key" is that the key is gone.

### App uninstall behavior

Documented here for completeness, since it's a deletion path the user can take outside the app:

- **iCloud Keychain identities** *survive* app uninstall + reinstall. iOS removes the local Keychain item on uninstall (iOS 10.3+ default), but the iCloud-Keychain-synced copy lives in iCloud and is restored when the user reinstalls Semicolyn and re-signs in. Effectively: uninstalling Semicolyn does not destroy iCloud-flavor identities; signing out of iCloud (or removing the device from the Apple ID) does.
- **Secure Enclave identities** are *destroyed* on app uninstall. The Keychain reference to the SE-bound key is deleted, the SE key material is no longer accessible, and there is no recovery path. Same outcome as tapping Delete inside the app. This is expected iOS behavior, not a Semicolyn quirk.

This contrast is surfaced in two places:

1. The **SE delete-confirm action sheet** already bolds the irreversibility (per the locked copy below). The same phrasing applies to uninstall: "irreversible" means uninstall too.
2. The **About & Help → Privacy** drill-down per [[2026-06-16-settings-sub-screens-design]] mentions the contrast in one sentence: *"iCloud Keychain identities survive reinstall via iCloud sync; Secure Enclave identities are tied to this device and this install."*

No in-app warning at uninstall (iOS doesn't surface uninstall to apps — the app is already gone before there's a chance to warn).

## Create / Import sub-flow

The same half-sheet locked in `host-crud-design.md`. This spec adds the standalone-entry parameterization.

### Sheet header

- **Left:** `Cancel` (muted)
- **Center:** title — `New identity` (standalone) or `Identity for <host>` (attached)
- **Right:** primary action — `Create` (when Create new tab active), `Save` (Import tab), `Attach` (Pick existing tab, attached mode only)

### Tabs

| Tab | Standalone entry | Attached entry (from host CRUD) |
|---|---|---|
| Pick existing | hidden | visible |
| Create new | visible (default) | visible (default if no identities exist; otherwise Pick is default) |
| Import existing | visible | visible |

The standalone entry skips Pick existing because picking an identity that's not being attached to anything is a no-op — the user is already on the management surface that lists every identity.

### Create new tab

Fields (vertical stack):

1. **Display name** — text, required, soft-unique.
2. **Algorithm** — default `ed25519`; expanding "More algorithms" discloses `ecdsa-p256`, `ecdsa-p384`, `rsa-4096`.
3. **Storage** — radio with two options, both labels expand the trade-off at the moment of choice:
   - `iCloud Keychain` — "Default. Syncs end-to-end encrypted across your Apple devices."
   - `Secure Enclave — Enhanced` (bronze accent tag) — "Hardware-bound. This device only. Cannot be backed up."
4. **Auth policy** — three-segment control, default `Per-unlock`. Same labels and explainers as the detail screen.

On `Create`:

1. Semicolyn generates the key via `SecKeyCreateRandomKey` (iCloud Keychain flavor) or `SecKeyCreateRandomKey` with `kSecAttrTokenIDSecureEnclave` (SE flavor), applying the chosen auth policy via `SecAccessControl`.
2. The `Identity` metadata record is written to CloudKit.
3. The sheet dismisses, returning to the entry context (list refreshes with the new identity in alphabetical position; or host form's identity pill row gets the new ref appended).

On generation failure (SE quota exhausted, OS denial, hardware error, etc.): inline error in the form, sheet stays open, no record created.

### Import existing tab

**Source row** at top: two side-by-side affordances:

- `📋 Paste` — opens a textarea modal for the private key blob
- `📁 Choose file…` — opens the iOS Files document picker (works with Files, iCloud Drive, Dropbox, and anything else the user has Files-integrated)

No Share Extension in v1.

**After a key is loaded**, the form populates:

1. **Detected** (read-only) — algorithm and fingerprint, parsed from the blob.
2. **Display name** — required, free-form. Pre-filled from a filename hint when available (e.g., `id_ed25519` → `id_ed25519`).
3. **Auth policy** — three-segment, default `Per-unlock`.
4. **Passphrase** (only shown if the parsed key is encrypted) — secure entry field with a `Decrypt` action. The passphrase is consumed when the key is rewritten into Keychain and **discarded immediately after decrypt**; it is not retained anywhere, not cached for the session, not re-prompted at use time. The Keychain-stored key material is itself encrypted at rest by iOS data protection; the iCloud Keychain copy is decrypted-equivalent only when the user's iCloud account is authenticated and the device is unlocked. No persistent passphrase state survives the import step.

**Storage flavor is absent.** Imported keys are always `iCloudKeychain` — Secure Enclave by definition cannot accept external key material. A muted explainer at the bottom of the form makes this explicit:

> Imported keys are always stored in iCloud Keychain. Secure Enclave cannot accept external key material.

On `Save`:

1. Semicolyn re-stores the key in iCloud Keychain with the chosen auth policy via `SecAccessControl`.
2. The `Identity` metadata record is written to CloudKit.
3. The sheet dismisses, same as Create new.

On parse failure: inline error, sheet stays open. Supported formats: OpenSSH (post-7.8 default), legacy PEM (RSA, ECDSA).

### Pick existing tab (attached entry only)

Unchanged from the host-crud spec. Scrollable list of existing identities using the same row anatomy as the management list (display name + algorithm + fingerprint preview + flavor chip). Tap to attach.

## Entry points

| Entry | Mode | Behavior |
|---|---|---|
| `Settings → Identities & Keys` | List | Standard navigation push. |
| Host CRUD identity pill (tap) | Detail | Push to detail screen for the tapped identity. Back returns to host CRUD. |
| Host CRUD `+ Add identity` | Sub-flow (attached) | Existing locked behavior. |
| List `+` button | Sub-flow (standalone) | New: opens the same half-sheet with `Pick existing` tab hidden. |
| List empty-state CTA | Sub-flow (standalone) | Same as `+` button. |

## Open questions / deferred

### Deferred to v1.5+

- **Rotation wizard.** Requires `ssh-copy-id` auto-install (already deferred to v1.5 in `host-crud-design.md`). At that point: a guided flow that mints a successor, re-points host records, auto-installs the new pubkey, and revokes the predecessor.
- **Share / AirDrop / QR public key.** Clipboard is enough for v1; expand to richer export channels once usage data justifies the surface.
- **Host-level auth policy overrides** ("always prompt before connecting to this host even if the key is unlocked"). Already noted as deferred in `host-config-model-design.md`.
- **"Last used" timestamp on detail screen.** Decided against showing on the list; could add a small "Last used Mar 14, 2026" row inside the detail's header card if a use case emerges. Doesn't change the schema (would derive from audit log).
- **Bulk delete / multi-select.** No use case at v1 scale; revisit if user libraries grow large enough.

### Not deferred — intentionally out of scope

- **ssh-agent emulation surface.** Semicolyn is the client; it does not expose its keys as an SSH agent to other apps. (iOS doesn't have an agent IPC primitive in any case.)
- **Password manager integration.** Locked out at the storage layer per `host-crud-design.md` — iCloud Keychain *is* the password manager backend for this app's primary use case; import covers the rest.
- **Key revocation tracking.** "Mark this key as compromised, refuse to use it anywhere" — a meaningful feature in an enterprise context, no clear user need at v1.

## Mockup

See `mockups/specs/identities-keys.html` for the visual record: list with mixed flavors, empty state, iCloud detail, SE detail (with advisory row), three delete-confirm sheets (iCloud, SE, refused-if-referenced), and three sub-flow phases (Create new, Import existing, Pick existing from host CRUD).
