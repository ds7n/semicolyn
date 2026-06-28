# Naming decision — neotilde → fosfyre

> ⚠️ **SUPERSEDED (2026-06-28, same day).** `fosfyre` was chosen and its rename was even
> executed on the parked branch `refactor/rename-fosfyre` (not merged), but the name was
> reconsidered further. **Current frontrunner: `semicolyn`** (a respell of *semicolon* — the
> shell command separator; owns the full namespace, trademark-clear), with `lumenhir` as
> backup. Neither is committed (pending a wife-test + manual TESS check). This doc is kept
> as the historical record of the fosfyre exploration; the live naming status lives in the
> agent memory `naming-and-trademark`.

**Date:** 2026-06-28
**Status:** **Superseded** — see the banner above. (Originally: "Decided + first-pass cleared"; the rename branch exists but was never merged.)
**Decision (at the time):** Rename the product from **neotilde** to **fosfyre**.

## Why we moved off "neotilde"

"neotilde" shipped on 2026-06-24 as the forced replacement for the trademark-blocked **Glymr** (see `docs/2026-06-24-naming-decision-neotilde.md`). It was *ownable* but never *loved*:

- **It mis-hears as "Matilda."** The dominant phonetic neighbor is a woman's first name — exactly the kind of personal-name collision the brand should avoid.
- **`neo-` is a tired prefix** (acknowledged as a cosmetic knock even when it was chosen).
- We **never filed the `NEOTILDE` mark**, so nothing is sunk — pre-launch is still the cheapest moment to change.

## Why "fosfyre"

A mangling of **phosphor** — the glowing coating that *is* a CRT terminal's light — bent toward **fyre**. It reads **"fos-FIRE": the glow of the screen, the fire in the tube.**

It was chosen after a wide brainstorm across seven flavor-realms (Old English, Irish, Scottish Gaelic, Welsh, Old Norse, German, Italian, plus sci-fi/cyber and pure coinage) and a clearance sweep of ~30 candidates. It hits the target formula we reverse-engineered from **glymr** (the name the user always liked):

- **Looks and sounds interesting; ghosts a real word** (phosphor) without being literal.
- **Carries genuine product meaning** — the terminal's phosphor glow — the way great terminal names own one facet (Blink=cursor, Warp=speed). fosfyre owns **the glow**.
- **Not a personal name.** No "Matilda" trap.
- **Maximally ownable** — the rarest property in 2026 (see below).

### The clearance result — fosfyre is a "unicorn"

Every facet is free, including `.com` (which neither neotilde's runner-ups nor Glymr could ever own):

| Facet | Status |
|---|---|
| `fosfyre.com` · `.dev` · `.sh` · `.app` · `.io` | **all free** (DNS-NS check, 2026-06-28) |
| npm `fosfyre` | free |
| App Store (iTunes Search API) | no exact/prefix app |
| GitHub `/fosfyre` | free (404) |
| USPTO exact `fosfyre` (+ `fosfyr`, `phosfyre`) | **no mark found** (Justia index; TSDR not bot-accessible) |
| Connotation | clean — light/glow/fire; "fosfor" = phosphorus in Scandinavian (neutral) |

**Sole soft caveat:** **Phosphyre Interactive**, a small early-stage *games* studio, is spelled `ph…phyre` but is **phonetically identical** ("FOS-fire"). Different spelling, different niche, tiny entity → low risk, but sound-alike is a real factor in USPTO §2(d) analysis. **Action: a 5-minute attorney knockout on the live register (and a check for any Phosphyre filing) before we file our own Class 9/42 mark.**

### Why this spelling (`fosfyre`) over its siblings

The whole `phosphor` family is wide open; the choice was taste, since three variants own even `.com`:

| Spelling | Reads | Why not chosen |
|---|---|---|
| **fosfyre** ✅ | fos-**FIRE** | **chosen** — the `-fyre` adds the *fire/glow* warmth, on-brand for a CRT-glow identity |
| fosfyr | FOS-fer | cleaner/sleeker but loses the fire reading |
| phosfyr | FOS-fer | keeps the `ph` etymology cue, reads more "chemistry" |
| phosfr / phsphyr | — | consonant-dense / unreadable |

### Domains to secure (NOT yet purchased)
Grab at minimum **`fosfyre.sh`** (`.sh` = shell, the apt TLD) and **`fosfyre.dev`**, plus **`fosfyre.com`** while it's free. Canonical site: `fosfyre.com` (or `.app`); redirect the rest. **This is the one time-sensitive action — a unicorn this clean won't stay free.**

## Runners-up (documented, in case we revisit)

| Name | Concept | Why not |
|---|---|---|
| **gwyll** | Welsh "dusk/gloom" | cleanest availability of all, but Welsh `ll` is unsayable for English speakers + *Y Gwyll* (Hinterland) TV association |
| **glyfr** | ghosts *glyph* (the chars a terminal draws); keeps the glymr formula | user-loved, viable, but sits in a crowded *Glyph/Glyde/Glide* software field; `.com` gone |
| **deckr** | *cyberdeck* — a terminal client literally is one | trademark-clear and `deckr.sh` is perfect, but domains/npm tight |
| **varkr / straumr / hougr / lyoma** | Norse `-r` / OE coinages (crossing / stream / mind / radiance) | all trademark-clear; lost to fosfyre on meaning + `.com` |
| **glymr** | the original beloved name | the *Glymr* KM company (`glymr.com`, Jeff Greenhouse) is **still live** (re-confirmed 2026-06-28); coexistence-only even though we own `glymr.dev` |

## Key lessons (carried from the Glymr search, reconfirmed)

- **Index-clean ≠ register-clean.** Do the authoritative USPTO/TSDR pull before *filing*.
- **Brandable `.com` is exhausted (2026)** — a name that owns `.com` (fosfyre) is the real prize.
- **Own one facet.** fosfyre owns the **phosphor glow** as a *concept*. We explored turning that into a color theme (warm ember, cold blue-flame, and a Neon-Midnight-plus-phosphor-hint — mockups under `mockups/drafts/2026-06-28-theme-*`) but **decided to keep the existing Neon Midnight as the default theme**; the rebrand does not require a new theme.

## Migration scope (NOT started)

`neotilde → fosfyre` is a mechanical-but-broad sweep, mostly in the **macOS-only Apple tier** (so CI is the only validation):

- Swift module/package: `NeotildeKit` → `FosfyreKit`; targets in `Package.swift` + `project.yml`.
- Bundle ID, app display name, scheme names, `xcodegen` config.
- UniFFI namespace + the generated XCFramework name (`scripts/build-xcframework.sh`).
- Rust crate `neotilde-ssh-core` → `fosfyre-ssh-core` (Cargo + `docker-compose.yml` test invocations).
- Dev image `neotilde-dev`, docs (README, ARCHITECTURE, TODO, specs), SPDX headers reference, on-disk dir, and the `github`/`origin` remotes + repo names.

To be done as a written plan (see writing-plans) **after** domains are grabbed and the spelling is final.

## Related
- Prior name + the Glymr conflict: `docs/2026-06-24-naming-decision-neotilde.md`, memory `naming-and-trademark`.
- Theme exploration (decided to keep Neon Midnight): `mockups/drafts/2026-06-28-theme-*.html`.
