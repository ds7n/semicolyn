# Naming decision — neotilde → semicolyn

**Date:** 2026-06-28
**Status:** **Decided + rename executed.** The product is **semicolyn**. The code/build/infra
rename from `neotilde` landed on branch `refactor/rename-semicolyn` (this is the live name; the
earlier `fosfyre` exploration on `refactor/rename-fosfyre` was never merged and is superseded).
**Decision:** Rename the product from **neotilde** to **semicolyn**.

## The naming journey

1. **Glymr** — the name the user always liked, but it collided with a **LIVE registered GLYMR
   trademark**, forcing a change (see `docs/2026-06-24-naming-decision-neotilde.md`).
2. **neotilde** (2026-06-24) — the forced replacement. *Ownable but never loved:* it mis-hears as
   "Matilda," `neo-` is a tired prefix, and the `NEOTILDE` mark was never filed (so nothing sunk).
3. **fosfyre** (2026-06-28) — a phosphor-glow coinage, chosen and even rename-executed on the parked
   branch `refactor/rename-fosfyre`, then reconsidered. Kept as the historical record in
   `docs/2026-06-28-naming-decision-fosfyre.md`.
4. **semicolyn** (2026-06-28) — the chosen name.

## Why "semicolyn"

A respell of **semicolon** — the `;` that **chains one shell command into the next**. It owns a real,
everyday piece of command-line punctuation the way the best terminal names own one facet
(Blink = cursor, Warp = speed); semicolyn owns **the separator**, the rhythm of stringing commands
together. The `-yn` respelling makes it a distinctive proper noun rather than the literal word.

Selection criteria it cleared, where neotilde and the alternates did not:

- **Cleanest namespace of the whole search** — owns the full namespace and is **trademark-clear**
  (zero collisions found), the deciding factor over `lumenhir` (the backup).
- **Ghosts a real word** (semicolon) with genuine product meaning, without being literal.
- **No personal-name collision** (the "Matilda" failure mode that sank neotilde).

`lumenhir` was the runner-up. A SEMICOLYN trademark is **not yet filed** — pre-launch is the cheapest
moment to still change, so filing waits until the name is fully settled.

## Casing convention

Lowercase **`semicolyn`** in path / code / identifier contexts (`SemicolynKit`, `semicolyn-ssh-core`,
`SEMICOLYN_TEST_SSHD`); capitalized **`Semicolyn`** only as the proper noun (sentence start, the app
name, the Xcode target).

## What the rename touched

Mechanical three-case token sweep (`neotilde→semicolyn`, `Neotilde→Semicolyn`, `NEOTILDE→SEMICOLYN`)
plus `git mv` of `SemicolynKit` / `SemicolynKitTests` / `semicolyn-ssh-core` / `semicolyn-seedbuild` /
`SemicolynApp.swift`, the UniFFI bridge (`SemicolynSSHCoreFFI` + `SemicolynSSHCore.xcframework`), the
dev image (`semicolyn-dev`), sshd fixtures + `SEMICOLYN_TEST_SSHD` env, the iOS bundle id
(`com.truepositive.semicolyn`), and the docs. The three historical naming docs
(`2026-06-24-naming-decision-neotilde.md`, `2026-06-24-naming-research.md`,
`2026-06-28-naming-decision-fosfyre.md`) are left verbatim as the decision record.
