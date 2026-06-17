# Terminal feedback — bell handling

**Date:** 2026-06-17
**Status:** Locked
**Resolves:** sub-item (b) of punch-list item #1 (terminal emulator scope) in `docs/final-review-punchlist.md`.

## Scope

Defines how Glymr responds when the remote terminal emits a bell (`\x07`, BEL). Forward-looking: this spec is the home for other "terminal feedback" decisions (visual / haptic / audio) as they come up. Bell is the only entry in v1.

**Audio bell is explicitly rejected.** No sound option, ever. iOS users expect notifications to come from notifications, not the SSH connection; a remote `\x07` playing a "ding" reads as alien and conflicts with the iOS mute-switch convention. Visual + haptic only.

## Visual bell — halo pulse

A soft bronze glow outlining the active pane's edge.

- **Color:** `Color.theme.bell.edge` (Bell Bronze maps this to `bronze500`).
- **Shape:** outline-only — no interior fill; ~3–4pt blur radius outward from the pane border.
- **Animation:** single ease-in/out pulse, ~700ms total (250ms in / 200ms hold / 250ms out).
- **Peak opacity:** 30–35%. Visible peripherally, ignorable centrally.
- **No traveling sweep.** This is a held perimeter glow that breathes once, not an Apple-Intelligence-style rotating gradient. Sweep reads as "I'm thinking" — wrong semantic for an instant bell event, and harder to rate-limit.

### Rapid-bell behavior

A spammy `tput bel` loop must not produce a strobing pulse.

- If another bell arrives while the halo is still visible, the halo **does not** re-trigger from zero.
- The halo holds at peak opacity until the bell stream goes quiet for ~400ms, then plays its 250ms fade-out.
- Net effect of a busy loop: one held glow that releases when the loop stops.

### Multi-pane / unfocused pane behavior

- The halo appears on **the pane that rang**, not always the focused pane.
- Lets the user see which pane rang while focused elsewhere (background-task pattern: build finished on pane 2 while user is editing on pane 1).
- Same halo treatment, same `bell.edge` color. No additional indicator.

### Interaction with the existing active-pane border

The active pane already has a subtle bronze border in [[2026-06-15-keybar-customization-design]] / `mockups/specs/features.html`. The halo bell layers on top as a transient amplification of that existing border, not a new visual element. On unfocused panes (where the border is inactive / muted), the halo briefly takes over the border treatment for the pulse duration, then releases.

## Haptic bell

A soft impact, also opt-in.

- **Generator:** `UIImpactFeedbackGenerator(style: .soft)` — Apple's gentlest impact style.
- **Rate limit:** at most one fire per ~500ms regardless of how many bells arrive. A busy `\x07` stream produces one haptic, not a buzz.
- **Master Haptics toggle respect:** if the App preferences → Haptics master toggle is **off**, the bell haptic is off regardless of its own setting. The bell haptic is layered *under* the master.

## Settings surface

New sub-section in **App preferences → Terminal feedback** with two toggles:

| Toggle | Default | Notes |
|---|---|---|
| Visual bell | **ON** | The halo pulse on the pane that rang. |
| Bell haptic | **OFF** | A soft impact on the pane that rang. Requires the master Haptics toggle to be on. |

No sound option appears anywhere.

### Rationale for defaults

- **Visual bell ON:** bells carry real signal (job done, error, attention). Defaulting silent would surprise users who rely on them. The corner-glow treatment is subtle enough to be ignorable for users who don't.
- **Bell haptic OFF:** even a soft impact adds intrusiveness, and the global Haptics toggle is already opt-in territory. Power users who want it can turn it on; everyone else stays peaceful.

## Out of scope (v1)

- **Per-host bell behavior.** All hosts share the same setting in v1.
- **"Notify on command done"** style cross-pane notifications. Already deferred in [[2026-06-15-multi-connection-switching-design]].
- **System notifications driven by `\x07`** (Notification Center banner / Lock Screen). No — that's a separate, much larger surface.
- **Audio bell.** Rejected with prejudice; never to be added.

## Related

- [[2026-06-17-design-tokens-design]] — provides the `bell.edge` semantic token.
- [[2026-06-16-settings-sub-screens-design]] — App preferences host; gains the Terminal feedback sub-section.
- [[2026-06-15-keybar-customization-design]] — defines the active-pane border the halo layers over.
