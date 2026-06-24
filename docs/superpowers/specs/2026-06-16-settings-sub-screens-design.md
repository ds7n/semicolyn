# Settings sub-screens — Security · App preferences · About & Help

**Date:** 2026-06-16
**Status:** Locked
**Replaces:** README "Unresolved" bullet — *Settings sub-screen layouts*

## Goal

Lay out the three Settings sub-screens whose tree positions were already
locked but whose contents were not: **Security**, **App preferences**, and
**About & Help**. The other two top-level entries (**Hosts**, **Identities
& Keys**) are already specced.

## Principle

Keep every sub-screen narrow. Power-user knobs (predictor pattern-exclude,
retention windows, incognito review, theme picker) defer to v1.5+ unless
their absence makes v1 visibly incomplete. Match the cuts the rest of the
app has made — three clearly-named rows beat a screen of toggles no one
touches.

## Revision to a previously locked decision

The locked Security framing in `docs/brainstorming-decisions.md` said:

> The user-facing biometric gate is **app-level** (Face ID once per
> session).

This spec **revises** that: the user-facing gate is the **device unlock**.
App-level Face ID is an **opt-in extra layer**, off by default. Rationale:
on an unlocked phone, Notes / Mail / Messages do not gate themselves; a
second prompt for Neotilde by default would be inconsistent with iOS norms
and friction-heavy for solo-device users. Users who share devices or want
defense-in-depth can opt in.

The `anyUse` per-identity policy continues to exist as the per-operation
escape hatch for high-value keys.

## Settings tree (recap)

```
Settings
├── Hosts                 (specced 2026-06-15-host-crud-design.md)
├── Identities & Keys     (specced 2026-06-15-identities-keys-management-design.md)
├── Security              ← this spec
├── App preferences       ← this spec
└── About & Help          ← this spec
```

## Security

Three rows under Security. Read top-to-bottom, decreasing in how often a
user touches them.

### App lock

```
App lock                            [○─●]   ← off by default
    Re-lock timeout       5 minutes   >    ← appears only when toggle is on
```

- **Toggle, off by default.** When off, Neotilde opens directly after device
  unlock. When on, Neotilde shows a Face ID prompt before revealing the
  picker, identities, or any session.
- **Re-lock timeout** sub-row appears only when the toggle is on. Options:
  *Immediately*, *1 minute*, *5 minutes*, *15 minutes*. Default *5
  minutes*. The timeout is measured from the moment the app is backgrounded
  or idle.
- **Active sessions on re-lock** are **hidden, not killed.** Live SSH and
  mosh sessions persist behind the lock view; unlock returns the user to
  the same terminal state. Killing a mosh on re-lock would defeat the
  point of mosh.
- The lock view itself is a full-screen sheet with the Neotilde mark, a
  *Unlock* button that re-invokes Face ID, and nothing else.
- **No grace period for failed Face ID.** Fall through to the device
  passcode automatically (standard `LAContext` behaviour). A user who
  cancels stays on the lock view — Neotilde does not back out of itself.

### Predictor

```
Predictive input                    [●─○]   ← on by default
    Sketches stay on device until wiped.
    ─────────────────────────────────────
Wipe all learning                            ← destructive row
```

- **Predictive input toggle** is the master switch. On = learn and
  suggest. Off = stop learning and stop suggesting. **Sketches persist on
  disk and in iCloud sync when off.** Turning back on resumes from the
  preserved state. The dim caption under the toggle calls this out
  explicitly so no one is surprised on re-toggle.
- **Wipe all learning** is the only path that destroys sketch data. Action
  sheet confirm. Wipes `today`, all rolling sketches, all sealed dailies.
  **The bundled seed survives** — confirm sheet body copy mentions this.
- Cut from v1 (defer to v1.5+): pattern-exclude list editor, retention
  window slider, incognito hosts review. The defaults in the predictor
  spec (pattern-exclude built-ins for secret-shaped strings, 90-day
  retention) carry v1.

### Host fingerprints

```
Host fingerprints                       >
```

- Drill-down. Flat list of hostnames that have stored fingerprints
  (TOFU). Per row: hostname + count of stored keys ("ed25519 + rsa" or
  "2 keys").
- Tap a row → detail view showing the stored fingerprints, each with
  algorithm, base64 prefix, and date added. Swipe-to-forget per
  fingerprint.
- **No forget-all button.** Destructive, low-value, and the per-row swipe
  covers the realistic workflow ("I rotated the key and want to clear the
  old one before reconnecting").
- **No search, no sort toggle** for v1. Alphabetical by hostname.
- Title uses **"Host fingerprints"** to avoid the `known_hosts` jargon.

## App preferences

Three rows. The Keybar drill-down is a passthrough to an existing spec;
iCloud sync is a small toggle group; Haptics is one toggle.

### Keybar

```
Keybar                                  >
```

Drill-down to the existing editable list specced in
`docs/superpowers/specs/2026-06-15-keybar-customization-design.md`
(single editable list with locked vs scroll divider, custom slot
bindings, reverse-bar toggle, etc.). No new UI in this spec.

### iCloud sync

```
iCloud sync
─────────────────────────────────────
  Macros                          [●─○]
  Keybar customizations           [●─○]
  Predictor sketches              [●─○]

  All sync uses CloudKit with on-device encryption.
```

- Three toggles, **all default ON**, all locked in
  `docs/superpowers/specs/2026-06-16-icloud-sync-scope-design.md`.
- Toggling a category off **stops the device from contributing future
  changes to that data type and stops it from pulling remote changes for
  that type.** Existing local data is untouched. Toggling back on resumes
  bidirectional sync; conflicts resolve last-write-wins per the sync spec.
- The footer caption telegraphs the encryption story so users do not
  worry the toggles imply plaintext-in-the-cloud.
- **Per-macro "don't sync" flag** (from the iCloud sync scope spec) lives
  on the individual macro, not here. This is the global cut line.

### Haptics

```
Haptics                             [●─○]
```

- Single global toggle, **default ON.**
- Off disables: cursor engage/lift tick, window-switch wrap tick,
  long-press feedback on Esc pill and Pad, modifier-engage feedback.
- No per-event tuning in v1.

### Cut from App preferences

- **Appearance** — Neotilde ships with one palette (cool-dark + bell-bronze).
  No light mode, no theme picker, no follow-system. An inert one-option
  section is filler; revisit when a second theme actually exists.
- **Connection defaults** — covered by the Defaults editor reached from
  `Settings → Hosts`. No duplicate entry.
- **Predictor display tuning** (confidence floor, suggestion row
  position) — defaults from the predictor spec carry v1.

## About & Help

Six rows. Static-feeling reference content.

```
✦  Neotilde Pro                            >       ← amended; see Pro spec
─────────────────────────────────────
?  Tips & Gestures                      >
─────────────────────────────────────
Privacy statement                       >
Open source                             >
─────────────────────────────────────
Send feedback                           ↗
─────────────────────────────────────
Neotilde 1.0.0 (1234)                              ← tap to copy
                                  (Supporter ✦ when Pro is active)
```

### Neotilde Pro

Top row. Added in
`docs/superpowers/specs/2026-06-16-pro-paid-scope-design.md`. Reads
**"Neotilde Pro"** when the user is free, **"Neotilde Pro — thanks!"** when
Pro is active. Pushes to the upgrade screen specced there.

### Tips & Gestures

Link row, `?` icon. Opens the same scrollable reference screen the
Esc-pill picker opens. Same content. Secondary path; the picker remains
the primary entry. Specced in
`docs/superpowers/specs/2026-06-16-first-host-onboarding-design.md`.

### Privacy statement

Drill-down. Short page in plain English (no legal boilerplate). Covers:

- Storage-is-the-security framing — what lives in iCloud Keychain, what
  lives in Secure Enclave, what is encrypted-then-stored in CloudKit.
- What syncs (macros, keybar customizations, predictor sketches by
  default) and what does not (recent connections, live session state,
  audit log).
- No telemetry, no third-party analytics, no ads, no cross-device
  tracking beyond the user's own iCloud account.
- Link to the public privacy page on neotilde's site (URL TBD before
  shipping; placeholder string until then).

### Open source

Drill-down. Flat alphabetical list of bundled OSS, each with name,
version, license name, and a tappable row that pushes to the full license
text. Initial inventory (subject to actual implementation choices):

- `carapace` (predictor seed source)
- `tldr-pages` (predictor seed source)
- `libssh2` *or* `Citadel/SwiftSSH` *or* whichever SSH stack ships v1
- `mosh` (server-side, bundled rendering of license)
- `cmark` / similar (if any documentation rendering)
- Bundled fonts, if any are not Apple-system

Build process generates this list at archive time from the dependency
manifest; this spec only fixes the format and entry point.

### Send feedback

Tappable row. Opens `MFMailComposeViewController` (or equivalent
`MailKit`/`MessageUI` path) with:

- **To:** the support address (TBD before shipping; placeholder until
  then).
- **Subject:** `Neotilde feedback — 1.0.0 (1234)` (version pre-filled).
- **Body:** a small pre-filled diagnostic header (app version, build,
  iOS version, device model) above a blank space for the user message.
  Nothing host-specific or user-data-specific is pre-filled.

If the user has not configured Mail, fall back to a sheet with the
support email shown + a Copy button — no third-party mail handoff.

### Version + build

Read-only row at the bottom. Format `Neotilde <semver> (<build>)`. **Tap to
copy** the full string to the clipboard (handy for bug reports). Light
haptic on copy, no visible toast.

### Cut from About & Help

- **Terms of service** — Neotilde has no user account, no service contract.
  Apple's App Store terms cover what is needed.
- **Rate the app** — friction-y; the kind of prompt users click past.
  Revisit only if App Store reviews demand stars.
- **Changelog / What's new** — defer until there is a v1.5 worth
  describing.

## Cross-cutting conventions

- **Row idiom.** All sub-screen rows follow the iOS settings pattern:
  title + optional value + chevron (drill-down) or toggle (binary) or
  destructive-tinted text (action).
- **Destructive actions** (Wipe all learning, swipe-to-forget on Host
  fingerprints, Delete on Identity detail) all use the same action-sheet
  confirm pattern locked in
  `docs/superpowers/specs/2026-06-15-identities-keys-management-design.md`:
  destructive row in top group, Cancel in bottom group.
- **Footer captions** — used sparingly. Predictor toggle, iCloud sync
  group, App lock when on. Nowhere else.
- **No badges, no "new" pips.** Settings is reference, not promotion.

## Out of scope (explicit)

- **Pattern-exclude / retention / incognito review** — power-user
  predictor knobs deferred to v1.5+.
- **Theme picker / light mode** — single palette in v1.
- **Forget-all-fingerprints** — destructive blunt instrument; per-row
  swipe is the precise tool.
- **Search inside any settings sub-screen** — none of them are long
  enough to need it. Re-evaluate when a list grows past ~40 rows.
- **iPad / Stage Manager layout adaptations** — covered when iPad nav is
  brainstormed.
- **Localisation** — English only for v1.

## Related specs and mockups

- `docs/superpowers/specs/2026-06-15-host-config-model-design.md`
- `docs/superpowers/specs/2026-06-15-host-crud-design.md`
- `docs/superpowers/specs/2026-06-15-identities-keys-management-design.md`
- `docs/superpowers/specs/2026-06-15-keybar-customization-design.md`
- `docs/superpowers/specs/2026-06-16-icloud-sync-scope-design.md`
- `docs/superpowers/specs/2026-06-16-first-host-onboarding-design.md`
- `mockups/specs/settings-sub-screens.html` — added alongside this spec.
