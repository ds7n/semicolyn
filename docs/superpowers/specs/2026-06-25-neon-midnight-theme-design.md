# Neon Midnight — default theme design

**Date:** 2026-06-25
**Status:** Designed (pending implementation plan)
**Type:** Visual / design-token design. Replaces the default palette; introduces no new token *structure* (the existing `Theme` semantic-token set is unchanged) — only new values + a glow rule + a theme-registry change.

## Context — why

The product renamed **Glymr → neotilde** (2026-06-24). The shipped palette, **"Bell bronze,"** was grounded entirely in the *Glymr = "bell / glimmer"* etymology (struck-bell → bronze, glimmer → lit-on-dark). That story is now dead, leaving the bronze accent **unmoored** — it read as "the color that happened to be there," and in review the bronze accent itself read as yellow-gold rather than true bronze. Rather than tune an arbitrary hue, we re-derived the accent from **neotilde's own** semantics.

**The grounded story — "Neon on a midnight terminal":**
- **neo → neon.** Neon gas (element 10) literally emits a warm **orange-red** glow when electrified — the iconic "neon" color. That physically grounds a warm coral/orange-red accent in the name.
- **The deep blue-near-black background = the night** the neon glows against. (The dark-blue base was the one element the user consistently liked across every exploration.)
- **The prompt `~` = the lit sign** glowing in the dark.
- This single story anchors the name, the physics, the dark base, and the warm accent at once — and gives a clean reason the error-red is a *separate, cooler, "unlit"* red.

## Design principles (explicitly anti-cyberpunk)

The neon-on-dark direction risks reading like *Cyberpunk 2077*. The concept is kept; the "costume" is shed by rule:

1. **Bell-only glow.** The accent is **solid at rest** — no persistent bloom on prompt, cursor, focus border, or keybar. A glow appears **only as a transient moment when the bell rings** (the `BellHaloView` halo already built in Phase 3c), then fades to flat. Persistent neon-sign bloom is the primary cyberpunk tell; we don't use it.
2. **Warm, approachable hue** — coral-lean `#FF6F5E`, *not* the acid-yellow / electric-cyan / magenta that form CP2077's fingerprint.
3. **Blue-tinted dark, not pure black.** `#07090E`, not near-black — cyberpunk leans on pure black + max-saturation neon; a blue-leaning dark reads "modern app."
4. **One restrained accent** + a **muted** verdigris success (`#5FB0A2`, not electric cyan). No competing neons.
5. **No** glitch, chromatic aberration, or scanlines — ever.

The "neon" therefore lives in the **story + the warm hue + the bell pulse**, not in the resting rendering.

## The palette — `Theme.neonMidnight`

Same semantic-token structure as today (`Sources/NeotildeKit/Theme/Theme.swift`); only values change. Opacities written as `@NN%`.

| Group · token | Value |
|---|---|
| **surface** · bg / panel / panelHigh / line | `#07090E` / `#0E1118` / `#161A24` / `#232A3A` |
| **text** · primary / secondary / muted / inverse | `#E8EBF0` / `#8A93A3` / `#8A93A3` / `#05070B` |
| **accent** · primary / highlight | `#FF6F5E` / `#FFB7A6` |
| **state** · success / degraded / broken / warning | `#5FB0A2` / `#F5A524` / `#E5455E` / `#F5A524` |
| **bell** · edge | `#FF6F5E` |
| **focus** · paneBorder / paneBorderInactive | `#FF6F5E` / `#232A3A` |
| **keybar** · slotBg / slotBgPromoted / slotBgArmed / slotBgLocked | `#0E1118` / `#FF6F5E @12%` / `#FF6F5E @20%` / `#FF6F5E @30%` |
| **predictor** · stripBg / suggestionBg / suggestionText | `#0E1118` / `#161A24` / `#E8EBF0` |
| **banner** · amberBg / redBg / neutralBg | `#F5A524 @15%` / `#E5455E @15%` / `#0E1118` |
| **terminal** · bg / fg | `#05070B` / `#CFD6E4` |

Notes:
- **Error `#E5455E`** is deliberately a cooler, deeper crimson so the warm coral accent never reads as a failure (coral-lean is the accent hue closest to red; this buys the separation).
- The **keybar** alpha ladder (12/20/30%) mirrors Bell-bronze exactly, so the two themes stay structurally parallel.
- Contrast: light accents/text on a near-black ground yield comfortably high contrast. A formal WCAG pass is folded into the existing app-wide [[accessibility-review-todo]] (low-opacity overlays + the focus border are the items to audit there).

## Theme architecture & roles

- **`neonMidnight` becomes the default.** `Theme.all = [.neonMidnight, .bellBronze]` (default first); the environment default (`ThemeKey.defaultValue`) and the per-view defaults added in Phase 3c (`TerminalScreen` / `TmuxPaneContainer` `var theme: Theme = .bellBronze`) switch to `.neonMidnight`.
- **`bellBronze` is kept** in the registry as a **switchable alternate** — a candidate **Pro cosmetic** (consistent with the README's "Pro is cosmetic-only, no feature paywall").
- The **theme-picker UI and Pro-gating are deferred to Phase 4** (Settings). Shipping two registry entries now with the picker hidden is fine — the app simply renders the default.

## Implementation surface

- **Create** `Sources/NeotildeKit/Theme/NeonMidnightTheme.swift` — file-private palette constants + `extension Theme { public static let neonMidnight = Theme(...) }`, mirroring the shape of `BellBronzeTheme.swift`.
- **Modify** `BellBronzeTheme.swift` (or wherever `Theme.all` lives) — `Theme.all = [.neonMidnight, .bellBronze]`.
- **Modify** `Sources/NeotildeKit/Theme/ThemeEnvironment.swift` — `ThemeKey.defaultValue = .neonMidnight`.
- **Modify** `App/TerminalScreen.swift`, `App/TmuxPaneContainer.swift` — change the `var theme: Theme = .bellBronze` defaults (added in Phase 3c) to `.neonMidnight`.
- **Tests** `Tests/NeotildeKitTests/ThemeTests.swift` — add `neonMidnight` value assertions (e.g. `accent.primary == ThemeColor("#FF6F5E")`, `bell.edge == accent.primary`, error/success values) and assert the default + `Theme.all` order. Keep the existing bellBronze assertions.
- **Docs** — update `mockups/specs/design-system.html` (palette section) and the brand-palette row in `docs/brainstorming-decisions.md` to Neon Midnight; note Bell-bronze is retained as an alternate. Reference mockup: `mockups/drafts/2026-06-25-theme-neon-midnight-final.html`.
- **Glow:** no new persistent-glow tokens. Confirm the only glow in the app remains `App/BellHaloView.swift` (bell). Do **not** add bloom to the focus border, cursor, or keybar.

## Out of scope (deferred)

- **Theme-picker Settings UI** and **Pro-gating** of Bell-bronze → Phase 4 (see [[phase-3-tmux-app-integration]] Plan C is done; picker belongs with Phase-4 Settings/keybar work and the pro-paid scope).
- **Per-host / per-theme overrides** — not now.
- Formal WCAG audit → the existing [[accessibility-review-todo]].

## Verification

- **Linux:** `docker compose run --rm dev swift test --filter ThemeTests` (and the full `NeotildeKit` suite) green — token values + default + registry order.
- **macOS / CI:** the app builds and renders the new default; visual check on the Simulator that the accent is **solid at rest** and only the **bell** glows (fire `printf '\a'`), per the bell-only rule.
- **Sanity:** `git grep` shows no stray persistent-glow added to focus/cursor/keybar; `Theme.all.first == .neonMidnight`.

## References

- Final mockup: `mockups/drafts/2026-06-25-theme-neon-midnight-final.html` (+ exploration drafts `2026-06-25-theme-*.html`).
- Token structure: `Sources/NeotildeKit/Theme/Theme.swift`; current palette `BellBronzeTheme.swift`.
- Story/rename context: `docs/2026-06-24-naming-decision-neotilde.md`, memory [[naming-and-trademark]].
- Bell halo (the glow primitive): Phase 3c, `App/BellHaloView.swift`.
