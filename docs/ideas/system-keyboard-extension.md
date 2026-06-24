# System-wide iOS custom keyboard extension powered by Neotilde's predictor

**Status:** Idea — parked for future research / brainstorming. Not on the roadmap.
**Logged:** 2026-06-14

## Premise

Extract the on-device predictor engine (CMS + Bloom sketches, per-prefix gating, seed deference) from Neotilde and ship it as a standalone iOS keyboard extension. Users get Neotilde's "learns my vocabulary, never silently rewrites it" suggestion behavior in any app — Messages, Notes, email, code editors.

## Why it's interesting

- The predictor is already general-purpose. It doesn't know it's typing into a terminal — it observes input/output streams and suggests from learned + seeded vocabulary. Strip the terminal-specific seed and the engine works anywhere.
- iOS keyboard extensions are a known surface. Apple permits them; Gboard, SwiftKey, Fleksy, and others ship them.
- Differentiator vs. the big keyboards: **explicit-only suggestions (no silent autocorrect), local-only learning, transparency screen + wipe button.** That's a real privacy story for users who don't trust Google or Microsoft keyboards.
- Could be a separate paid app or a Neotilde Pro perk — natural expansion of the same engine investment.

## Open questions for the eventual brainstorm

- **iOS keyboard extension constraints:** "Full Access" requirement, sandbox limits, memory ceiling (extensions are killed harder than apps), what API surface the predictor actually needs.
- **Data isolation:** does the system keyboard share its sketch with the Neotilde app (App Group container), or are they independent vocabularies? Shared = better suggestions in the terminal too; independent = cleaner privacy story.
- **Seed choice:** the terminal-flavored seed (carapace + tldr + dotfiles) is wrong here. Need a general English / code-flavored seed.
- **Settings surface:** how the user configures it from outside the parent Neotilde app — extensions can't show arbitrary UI.
- **Monetization:** standalone app, in-app purchase, bundled with Neotilde, "Neotilde Pro" tier.
- **Privacy review:** keyboard extensions are scrutinized — the transparency story has to be airtight from day one.

## Relationship to Neotilde v1

This is **not** v1 scope. It's a "if the predictor engine proves out in Neotilde, here's a natural way to ship it more broadly" idea. Revisit after v1 ships and there's real predictor performance data.

## Related

- [[2026-06-13-predictor-design]] — the engine this would extract.
