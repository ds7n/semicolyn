# Naming decision — Glymr → neotilde

**Date:** 2026-06-24
**Status:** **Decided** (pending authoritative USPTO clearance — see protocol below)
**Decision:** Rename the product from **Glymr** to **neotilde**.

## Why we moved off "Glymr"

A **LIVE, federally-registered identical trademark** exists for the wordmark **GLYMR**:

- **Reg. 7579030 · Serial 98373157 · Principal Register · Classes 035 + 041** (filed 2024-01-24, registered 2024-11-26).
- Owner: **Glymr** of Westfield NJ (Jeff Greenhouse) — a knowledge-management / data-insights **consulting + training** firm (`glymr.com`). They did **not** register Class **009** (downloadable software) or **042** (SaaS) — those lanes are open.

Our product is an iOS **SSH/terminal client** → Class 009/042, a genuinely different field. So the legal risk was **low-moderate** (different goods/buyers/channels), *not* severe. But the situation is **permanent and only gets more expensive to fix**:

- Identical *registered* mark → our own Class 9/42 filing would be **contestable** (a §2(d) refusal citing GLYMR is likely; identical marks need *less* goods-relatedness to refuse).
- `glymr.com` is theirs forever; we'd be **permanently second in search**.
- "Glymr" doesn't actually evoke a terminal (the *glimmer* facet is aesthetic).

We are **pre-launch** — the cheapest moment we will ever have to change. So we changed.

## Why "neotilde"

Chosen after a long, thorough exploration (12+ rounds). Rationale:

- **Terminal-resonant:** `~` (tilde) is the shell home symbol; `tilde.club`/`tildes.net` make it culturally *terminal*. "neo" = new → **"the modern terminal."**
- **Owns the entire namespace** — the only candidate in the whole search with `.com` + `.sh` + `.app` + `.io` + `.dev` all free (Glymr could never own its `.com`).
- **Collision-clean** in web/index search; a coined compound (decent trademark strength).
- **One honest knock:** "neo-" is an overused prefix. Accepted as cosmetic vs. Glymr's structural problems.

### Domains secured (2026-06-24)
`neotilde.com` · `neotilde.io` · `neotilde.dev` · `neotilde.sh` · `neotilde.app` — **all grabbed.**
Optional extra (not required): `neotil.de` (a `.de` domain-hack spelling "neotilde"; cute short-link, free as of this date; `.de` may need a German admin-c).
**Canonical site:** `neotilde.com` (or `.app`); redirect the rest.

## Runners-up (documented, in case we revisit)

| Name | Concept | Why not |
|---|---|---|
| **glymnir** | Glymr + Norse `-nir` (Gungnir/Draupnir family) — keeps the Glymr lineage | shares the `GLYM-` onset with the registered mark → most residual proximity risk |
| **vordnir** | Old Norse *vörðr* = warden/guardian (what an SSH client *does*) | strongest *meaning*, but spelling-fork (d/th, i/y) + generic-fantasy-Norse lean |
| **dirnir / gattnir** | Norse "door/gateway" + `-nir` | solid but more abstract |
| **duskrelyx** | dusk + fanciful relay-echo | "dusk" is crowded in tech; doesn't evoke terminal |

## Key lessons from the search (so we don't repeat the work)

- **Index-clean ≠ register-clean.** GLYMR looked clear on Justia/Trademarkia but is a LIVE registration — only the authoritative USPTO search caught it.
- **Brandable `.com` is exhausted (2026).** Nice-sounding made-up words — short *or* long — are ~universally `.com`-taken; the rare names that own `.com` (like neotilde) are the real prizes.
- **Great terminal names own one facet** (Blink=cursor, Warp=speed); neotilde owns the `~`.

## Remaining gate — authoritative USPTO clearance (DO THIS BEFORE COMMITTING CODE/BRAND)

The one step that can't be done from a script — run it at `tmsearch.uspto.gov`:

1. **Basic search**, one at a time: `neotilde`, then `tilde` (the dominant element, to see neighbors).
2. **Expert mode** wildcard sweep: `neotilde*`, `*tilde*`, plus phonetic `neotild*` / `neotyld*`.
3. For every hit, record three fields: **status** (must be DEAD/abandoned to ignore; flag any **LIVE**), **class** (watch **009 / 042 / 035 / 041**), **owner + goods/services**.
4. **Decision rule:** no LIVE mark for `neotilde` *or* a confusingly-similar mark in **Classes 9 / 42** → clear to proceed and file.
5. **Common-law sweep:** Google `neotilde`, plus App Store / Google Play / GitHub / npm.
6. **Recommended:** a flat-fee attorney clearance opinion (~$300–600) for the definitive read (phonetic + common-law) and to file the application.

### Filing our own mark (once cleared)
File `NEOTILDE` via USPTO **TEAS**:
- **Class 009** (core): *"Downloadable computer software for secure remote terminal access, SSH session management, and terminal emulation on mobile devices."*
- **Class 042** (if SaaS/cloud-sync features ship, e.g. CloudKit): *"Software as a service (SaaS) featuring software for secure remote terminal access and SSH session management."*

## Migration scope (deferred — pre-launch, cheap)
Repo, bundle ID, app name, design tokens, memory, README, specs still say "Glymr." Rename is a mechanical sweep to do **after** USPTO clearance confirms neotilde is safe. Not started yet.

## Related
- Trademark conflict detail + full vet trail: memory `glymr-trademark-conflict`.
- Apple enrollment / `truepositive.dev` branding context: memory `apple-enrollment-and-site`.
