# First-host onboarding & Tips & Gestures — design

**Date:** 2026-06-16
**Status:** Locked
**Replaces:** README "Unresolved" bullet — *First-host onboarding flow*

## Goal

Get a brand-new user from app launch to a first working SSH session without
forced tutorials, while making Neotilde's distinctive gesture vocabulary
discoverable on demand — before, during, and after first connection.

## Principle

No forced walkthrough. No just-in-time tooltips. No coach marks, badges, or
spotlight overlays. The unfamiliar gestures (Esc-pill long-press, the Pad,
context-aware promotions, modifier stickiness, Fn keys) are documented in a
single reference screen the user opens when they want it.

This trades discoverability-on-encounter for discoverability-on-curiosity. The
bet: a user who is using a terminal client is comfortable poking around, and
the things that are novel enough to need explanation are reachable from two
prominent entry points (empty state and Esc-pill picker), plus two
secondary paths (About & Help → Tips & Gestures per
`docs/superpowers/specs/2026-06-16-settings-sub-screens-design.md`, and the
`⌘?` hardware shortcut per
`docs/superpowers/specs/2026-06-17-external-keyboard-design.md`).

## Entry points

### Empty state (no hosts configured)

First-launch screen. Layout:

```
                    [ centered Neotilde mark, small ]


              ┌────────────────────────────────┐
              │      Add your first host       │   ← bell-bronze fill, large tap target
              └────────────────────────────────┘

         You'll need a hostname, username, and either
                  a password or key.                    ← dim micro-copy, one line


                  Settings   ·   Tips & Gestures        ← dim secondary text links
```

- **Centered "Add your first host" CTA** — the only primary action. Tapping
  opens the existing host CRUD form (`mockups/specs/host-crud.html`) in
  create mode.
- **One-line micro-copy** below the CTA — sets expectations so the form does
  not feel surprising.
- **Two secondary links** below: `Settings` and `Tips & Gestures`. Plain text
  buttons separated by a dim middot. No icons.
- **Keybar is hidden.** It has nothing to act on without a session, and
  showing it inert looks broken. It appears with the first connection.
- **Predictor strip is also hidden** in the empty state, for the same reason —
  there is no input field to attach to. It appears with the first connection
  alongside the keybar.
- The empty state disappears the moment a host exists. It does not return
  when all hosts are later deleted (the host-picker handles the "no hosts"
  case in that flow — re-showing the empty state would erase user
  configuration state implied by deletion).

### Esc-pill picker (post-connection)

The existing long-press-Esc picker (`docs/superpowers/specs/2026-06-15-host-config-model-design.md`,
`mockups/drafts/host-management.html`) gains one new row:

```
  ● example.com                    (Live)
  ○ build-01                       (Live · Sleeping)
  ────────────────────────────────
  jumphost-01                      (Recent)
  ────────────────────────────────
  +  Connect…
  ⚙  Settings
  ?  Tips & Gestures               ← new
```

Anchored at the bottom of the picker, below Settings. Same target as the
empty-state link.

## The Tips & Gestures screen

Single scrollable screen. Same content from both entry points — no
"first-time vs returning" branching, no state tracking.

### Frame

- Top-anchored close button (X), top-right.
- Title: **Tips & Gestures**, bell-bronze.
- Cool-dark canvas, matches the rest of the design system.
- Scrollable body. No tabs, no pagination.

### Content sections (in order)

Each section: short prose paragraph + one small static SVG diagram showing
the gesture or visual.

1. **The keybar**
   Orientation paragraph: locked-left vs scroll region; tap = primary,
   swipe-up/down = secondaries shown as dim chars on each key; long-press
   on a custom slot = edit. (References `docs/superpowers/specs/2026-06-15-keybar-customization-design.md`.)

2. **The Esc pill**
   Tap sends Escape. Long-press opens the picker — hosts, settings, this
   screen. Diagram: finger-press with timing dot.

3. **The Pad**
   Drag for arrow keys (mouse-like delta, not joystick). Tap to zoom on
   the cursor. Long-press to arm split mode. Diagram: pad with three
   gesture annotations.

4. **Context-aware promotions**
   When the foreground process is something Neotilde recognises (vim, less,
   python, psql, etc.), relevant symbols promote into the scroll region
   with bronze tint and a top-edge accent. Diagram: before/after shell
   vs vim. (References `docs/superpowers/specs/2026-06-14-context-detection-design.md`.)

5. **Modifiers**
   Ctrl / Alt / Shift are sticky-for-one-keystroke. Double-tap Ctrl to
   lock; double-tap again to release. Alt and Shift are sticky-only,
   no lock. Diagram: state machine, three nodes.

6. **Fn keys**
   Fn slot toggles the scroll region to F1–F12. Caps-lock state machine
   (tap = armed one-shot, double-tap = locked). Auto-engages in htop /
   top / mc; user can override per episode. (References
   `docs/superpowers/specs/2026-06-14-function-keys-design.md`.)

### Visual treatment

- Static SVG inline per section. No animation, no autoplay, no looping
  clips. v1 ships with prose + diagrams.
- One diagram per section. Bronze accent strokes on cool-dark fill.
- Section headers: bell-bronze, ~18pt.
- Body text: ~14pt, regular weight, generous line-height.

### Persistence & state

- No "unread" badge.
- No "you have seen this" tracking. No CloudKit sync of read state.
- Entry points are always present (empty state link until first host is
  created; picker row forever).
- Re-opens are free — the user may return any number of times.

## Out of scope (explicit)

- **JIT tooltips on first encounter** — rejected in favour of voluntary
  reference. Coach marks, spotlight overlays, and animated callouts are
  out.
- **Demo PTY / sample session** — adds a whole subsystem (local PTY,
  demo content, exit path) for marginal first-impression value.
- **Prefilled example host** — creates a "what is this row?" confusion
  moment and pushes the user toward editing instead of creating.
- **Multi-page swipe tour** — paginated card flows feel like a forced
  walkthrough even when voluntary.
- **Read-state tracking** — no badge, no analytic, no sync.
- **Localisation** — English only for v1, matching the rest of the app.
- **Predictor row explainer, keybar swipe-up/down explainer** — judged
  self-explanatory; covered in the keybar section's orientation
  paragraph if at all.
- **Connection status banner / mosh roaming / identity flavours** —
  these surfaces explain themselves at point of use; not in the doc.

## Open questions deferred to a later spec

- iPad / Stage Manager layout of the empty state and the Tips & Gestures
  screen — covered when iPad layout is brainstormed.
- External keyboard interactions on the empty state — same.

## Related specs and mockups

- `mockups/specs/host-crud.html` — the form opened by the CTA.
- `mockups/drafts/host-management.html` — the picker that the new row
  joins.
- `docs/superpowers/specs/2026-06-14-context-detection-design.md`
- `docs/superpowers/specs/2026-06-14-function-keys-design.md`
- `docs/superpowers/specs/2026-06-15-keybar-customization-design.md`
- `docs/superpowers/specs/2026-06-15-host-config-model-design.md`
- `mockups/specs/first-host-onboarding.html` — added alongside
  this spec.
