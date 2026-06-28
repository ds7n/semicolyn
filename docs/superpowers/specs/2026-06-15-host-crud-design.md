# Host CRUD flow — design

> **Scope.** Create / edit / delete screens for host records and the Defaults record. Includes form layout, validation, conditional-field behavior, the inline identity sub-flow (pick / create / import), and delete behavior including the refused-if-referenced case.
>
> **Out of scope** (separate brainstorm sessions): import from `~/.ssh/config`, export to `~/.ssh/config`, multi-connection switching semantics, the management surface for Identities & Keys outside of the inline sub-flow, and the ssh-copy-id auto-install flow.
>
> Assumes the host config schema (`docs/superpowers/specs/2026-06-15-host-config-model-design.md`) and the host-management entry point (`docs/brainstorming-decisions.md` → "Host management & settings access").
>
> **Mockup:** `mockups/specs/host-crud.html` (form layout, conditional disabling, identity sub-flow, validation banners, defaults editor).

## Design principles

1. **Single scrollable form, same for create and edit.** No wizard, no tabs. Power users get a fast path; new users get aggressive default-collapse so they see Basics + Auth and nothing else.
2. **Sections own their own conditional behavior.** Mosh and Tailscale are named sections, not buried under Advanced — that's how users mentally model them ("does this host use mosh?" is a yes/no thought).
3. **Show + explain, never silently hide.** When a field is contextually irrelevant (e.g., `serverAliveInterval` under mosh), it stays visible, disabled, with a one-line tooltip explaining why. Conditional caveats surface as inline banners under their section header.
4. **Same form, different presentation, for both entry points.** Quick-edit (swipe from picker → Edit) and deep-edit (Settings → Hosts → tap) use the same fields, the same validation, the same default-expansion logic — but quick-edit presents as a half-sheet, deep-edit as full-screen push.
5. **Inline identity sub-flow.** The user never has to leave the host form to pick, create, or import a key.

## Form layout

### Section list (top-to-bottom)

| # | Section | Default state on new host | Notes |
|---|---|---|---|
| 1 | **Basics** | Expanded | `label` (required), `hostName` (required), `user`, `port` |
| 2 | **Auth** | Expanded | `identities[]` as pill row + `+` button; `passwordRef` row ("Use password instead" toggle that reveals the linked password row) |
| 3 | **Connection** | Collapsed | Tier 2 SSH options: `serverAliveInterval`, `serverAliveCountMax`, `compression`, `strictHostKeyChecking`, `forwardAgent`, `preferredAuthentications` |
| 4 | **Jump chain** | Collapsed | `proxyJump[]`; each row is a hop with two modes (Pick host / Inline `user@host:port`) |
| 5 | **Port forwarding** | Collapsed | `localForwards[]`, `remoteForwards[]`, `dynamicForwards[]` — three sub-lists with `+` per list |
| 6 | **Mosh** | Collapsed | `mosh.enabled` master toggle; reveals `serverPath`, `udpPortRange`, `predictionMode` when on |
| 7 | **Tailscale** | Collapsed | `tailscale.required` toggle; `tailnet` row appears when required is on (rare multi-tailnet case) |
| 8 | **Semicolyn behavior** | Collapsed | `semicolyn.predictor.incognito` toggle; `semicolyn.tmux.attemptControlMode` toggle |
| 9 | **Delete host** | (edit mode only) | Red destructive row; opens the delete confirmation sheet |

### Expansion rules

- **New host:** sections 1–2 expanded; sections 3–8 collapsed.
- **Edit host:** for sections 3–8, a section auto-expands on screen open iff at least one of its fields carries a non-default value. (If the user has set `compression: true`, Connection opens; if not, it stays collapsed.)
- **Save with validation errors:** any section containing a flagged field auto-expands and scrolls into view; the banner at the top of the form summarizes the errors.
- Expansion state is **per-session, not persisted.** Closing and reopening the form re-applies the rules above; there is no "last expansion state" memory.

### Header chrome

- Title shows `New host` or the host's `label`.
- Subtitle shows `unsaved` (until first save), `up to date` (after save, no changes), or `unsaved changes` (after a field is touched post-save).
- Left button: **Cancel** (with discard-confirmation if changes exist).
- Right button: **Save** (disabled while required fields are empty; primary-styled when changes exist and required fields satisfied).

## Conditional visibility & caveats

Every field stays present in the DOM regardless of context — visibility is controlled only by section collapse. **Disabled state** and **inline caveat banners** carry the conditional UX.

| Condition | Effect |
|---|---|
| `mosh.enabled = true` | `serverAliveInterval` and `serverAliveCountMax` rows render grayed out with inline tooltip: *"Mosh has its own keepalive."* The values remain editable in the data sense (user can change them), but the UI signals they have no effect. |
| `mosh.enabled = true` and any port-forward list non-empty | Port forwarding section header shows a one-line caveat: *"Forwards exist only during the SSH bootstrap window when mosh is enabled."* |
| `mosh.enabled = true` and `forwardAgent = true` | Connection section header shows: *"Agent forwarding applies to the SSH bootstrap session only."* |
| `tailscale.required = true` | Tailscale section shows: *"Connection refused with a 'Tailscale required' banner when Tailscale is disconnected."* |

**No field is hidden by conditional rules.** A strict-subset philosophy means every field that exists is reachable; conditional hiding breeds "where did that go?" confusion.

## Identity sub-flow

Trigger: tap `+` at the end of the identities pill row in the Auth section.

**Presentation:** half-sheet from the bottom. Host form stays partially visible behind the sheet so the user retains context ("I'm mid-host-create").

**Three tabs** at the top of the sheet:

### Tab 1 — Pick existing

List of every stored Identity. Each row:
- Display name
- Fingerprint (truncated, full on tap)
- Flavor badge (`iCloud Keychain` in bronze · `Secure Enclave (Enhanced)` in verdigris with a ⚡ icon)
- Biometric-policy icon (`never` — none, `anyUse` — fingerprint glyph, `afterUnlock` — half-fingerprint)

Tap to select → returns to host form with the identity added to the pill row.

### Tab 2 — Create new

Fields:
- **Display name** (text, required, soft-unique)
- **Algorithm** (segmented: `ed25519` (default) · `ecdsa-p256` · `ecdsa-p384` · `rsa`)
- **Storage flavor** (segmented: `iCloud Keychain` (default, syncs E2EE) · `Secure Enclave` (Enhanced — device-bound, never syncs))
- **Biometric policy** (segmented: `never` · `any use` · `after unlock`)

On **Create**:
1. The key is generated in the chosen flavor with the chosen policy applied via `SecAccessControl`.
2. The sheet transitions to a **post-create view** showing the **public key** as monospaced text, with **Copy** / **Share** / **AirDrop** buttons. User installs it on the host's `~/.ssh/authorized_keys` manually. (Auto-install via ssh-copy-id is deferred to v1.5.)
3. **Done** dismisses the sheet; the new identity is added to the host form's pill row.

### Tab 3 — Import existing

Fields:
- **Display name** (text, required)
- **Private key** (multi-line text — paste a PEM, OpenSSH, or RSA block; can also use the iOS share sheet or document picker)
- **Passphrase** (only revealed if the parsed key is encrypted)
- **Storage flavor** (segmented, same as Create)
- **Biometric policy** (segmented, same as Create)

On **Import**:
1. Semicolyn parses the blob; if parsing fails, inline error: *"Unrecognized key format. Supported: OpenSSH, PEM, RFC 4716."*
2. If encrypted, the passphrase field unlocks; on wrong passphrase, inline error.
3. On success, the key material is written to the chosen flavor with the chosen policy; the sheet transitions to the same post-create view (public key + Copy/Share). User installs it on the host manually.

## Validation

### Live (as user types / blurs a field)

- **Required-field markers**: bronze `•` after `label` and `hostName` labels. Renders red if the field is empty after the user has touched it once.
- **Save button enablement**: enabled iff `label` and `hostName` are non-empty.
- No other live validation. The form does not interrupt a typing user with red marks on inferential errors.

### On Save tap (content validation)

| Check | Behavior on fail |
|---|---|
| Jump chain has a cycle | **Hard-block.** Banner at top of form: *"Jump chain contains a cycle: A → B → A."* Jump chain section auto-expands. Save refused. |
| Label duplicates another host's label | **Soft-block.** Sheet appears: *"A host named 'prod' already exists. Save anyway? / Rename."* If user chooses Save anyway, save proceeds. |
| No `user` set on host or Defaults | **Soft-block on save, hard-block on connect.** Banner: *"No user set here or in Defaults. Save anyway? Connecting will require setting a user."* If user saves, the host is stored; connection attempts later show a clear refuse-to-connect error. |
| Inline jumphost has empty `hostName` | **Hard-block.** Inline error on the offending hop row. |
| Port forward has missing `bindPort` or (for local/remote) missing `hostAddress`/`hostPort` | **Hard-block.** Inline error on the offending forward row. |
| `passwordRef` set but the linked password no longer exists in Keychain (stale ref after key deletion elsewhere) | **Hard-block.** Inline error on the Password row: *"Linked password missing. Re-pick or remove."* |

## Cancel

If no changes since last save: dismiss silently.

If changes exist: **Action sheet from the bottom** — *"You have unsaved changes."*
- *Discard changes* (destructive)
- *Keep editing* (default, top)

There is **no auto-draft persistence** in v1. Backgrounding the app with an unsaved form retains in-memory state for the OS's normal lifecycle window, but a force-quit or system memory pressure event discards. This is acceptable for v1; auto-draft is a v1.5 candidate.

## Quick-edit vs deep-edit

**Same form. Different presentation.**

| | Quick-edit | Deep-edit |
|---|---|---|
| Entry point | Picker row swipe → Edit | Settings → Hosts → tap row |
| Presentation | Half-sheet from bottom, partial-screen | Full-screen push from a navigation stack |
| Dismiss | Swipe down on sheet (with discard confirm if changes exist) | Back button + standard nav stack |
| Fields | All sections | All sections |
| Validation | Identical | Identical |
| Default expansion | Identical (Basics + Auth; rest auto-expand if customized) | Identical |

Maintaining two forms would double the surface and the bug count. The user's mental model is "edit this host" regardless of entry point.

## Delete

### Entry points

- Picker row swipe → Delete (rightmost red action; already locked in the host-management entry-point decision).
- Form bottom row (edit mode only) → Delete.

Both paths flow to the same confirmation sheet.

### Confirmation sheet

- Title: *"Delete '\<label\>'?"*
- Body: *"This removes the host config from your library. The action cannot be undone."*
- Primary action: **Delete** (destructive).
- Secondary action: **Cancel**.

### Refused-if-referenced

If the host is in any other host's `proxyJump` chain (any hop with `kind: "ref"` pointing at this host's UUID), the delete is refused. Instead of the confirmation sheet:

- Banner: *"Cannot delete '\<label\>'."*
- Body: *"Used as jumphost by:*
  - *prod-db*
  - *staging-api*
  *Remove these references first."*
- Each listed host name is **tappable** — taps navigate into that host's deep-edit screen with the Jump chain section pre-expanded.

This protects against silent breakage of jump chains. No cascade, no copy-to-inline.

### Post-delete

Host record is removed from CloudKit. Identity references on the host are dropped, but **the Identity records themselves are not deleted** — they remain in Keychain/SE; the user manages them through the Identities & Keys surface. Saved snippets pinned to this host (v1.5) and audit log entries for this host (separate spec) keep their references by UUID, and the UI surfaces them as "host no longer in library."

## Defaults editor

Same form shell with the following differences:

- No `label`, `hostName`, or Delete host row.
- All sections collapsed by default (no notion of "this is the active host's settings"); user opens what they need.
- Each row shows two states:
  - **Inherit unset** — value is what the system-fallback table provides; row reads `inherit · 22` (for `port`), `inherit · false` (for `compression`), etc.
  - **Set** — value is explicitly stored on Defaults; row reads the value plain.
- **Swipe-left on a set row** = *Clear override* (revert to system fallback, returns the row to inherit state).
- No required fields → Save is always enabled.

Entry points:
- Top row of Settings → Hosts list: a dedicated **"Defaults"** row, distinct from individual host rows.
- Tappable "Defaults · 22" inheritance labels in any host's editor (Basics → Port row, etc.) — navigates to the Defaults editor with the relevant field scrolled into view.

## Out of scope / deferred

### Deferred to separate brainstorm sessions

- **Import from `~/.ssh/config`** — file picker / paste / share extension; mapping rules; conflict resolution with existing hosts; what to do with `Match` blocks, Tier-3 options, and `Include` directives; the post-import review screen.
- **Export to `~/.ssh/config`** — slug generation, label-to-alias resolution, what to emit for Semicolyn extensions (mosh, Tailscale, semicolyn.*), fingerprint comments, identity export (public-key only).
- **Identities & Keys management surface** outside the inline sub-flow — the standalone list, the per-identity detail screen ("which hosts use this key"), rotation flows, deletion flows, "regenerate" semantics.
- **Multi-connection switching semantics** — what happens to live sessions when the user opens a different host's edit screen from the picker.

### Deferred to v1.5+

- **ssh-copy-id auto-install** — after create, offer to install the public key on the host via a one-time password-auth connection.
- **Auto-draft persistence** for unsaved forms — survive force-quit / memory pressure.
- **Bulk operations** — multi-select in Settings → Hosts for bulk delete / bulk edit (e.g., reassign identity across many hosts).
- **Field-level edit history / undo** — track recent changes per host, surface a per-field undo.
- **Per-row long-press preview** in Settings → Hosts (peek at host details without opening the editor).
