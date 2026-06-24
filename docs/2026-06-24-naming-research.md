# Naming & trademark research — Glymr / neotilde

**Date:** 2026-06-24
**Purpose:** Full research log behind the [naming decision](2026-06-24-naming-decision-neotilde.md) (Glymr → neotilde). Serves as (1) good-faith-clearance evidence, (2) a record so this work is never repeated, (3) reference for the migration.
**Companion docs:** decision record `2026-06-24-naming-decision-neotilde.md`; memory `glymr-trademark-conflict`.

---

## Part 1 — Glymr trademark research

### The conflict (confirmed via USPTO)
- Wordmark **GLYMR** — **Reg. 7579030 · Serial 98373157** — **LIVE / REGISTERED**, Principal Register.
- Filed **2024-01-24**, registered **2024-11-26**.
- **Classes 035 + 041** (business/management consulting + education/training).
- Owner: **Glymr**, Westfield NJ (founder Jeff Greenhouse) — a knowledge-management / data-insights **consulting + training** firm (`glymr.com`). Founded 2022.
- **Not** registered in Class **009** (downloadable software) or **042** (SaaS/IT) — those lanes are open on the register.

### Likelihood-of-confusion analysis (§2(d) factors)
| Factor | Direction |
|---|---|
| Marks **identical** (GLYMR=GLYMR), now **registered** | ⚠️ against us — identical marks need *less* goods-relatedness to find confusion |
| Senior, nationwide priority (2024-01-24, predates our ~2026 use) | ⚠️ against us |
| Goods/services genuinely different (consulting/training vs. SSH software) | ✅ for us |
| Different buyers/channels (enterprises vs. developers) | ✅ for us |
| They did **not** claim software classes (009/042) | ✅ for us |
| "Glymr" is a real Old Norse word (≈ "clang/resound") | ✅ mildly for us (weakens "uniquely theirs") |
| KM-consulting ↔ KM-software adjacency | ⚠️ residual risk |

### Risk assessment
- **Forced-rename risk: low-moderate** (~10–25% lifetime chance of at least a C&D; actual forced rename lower). Different fields are a strong shield; the registration is their stronger sword.
- Our own Class 9/42 filing would be **contestable** — an examiner will likely cite GLYMR under §2(d).
- The downsides are **permanent**: `glymr.com` is theirs; we'd be permanently second in search; the mark doesn't improve with time.

### Critical lesson — index ≠ register
Initial knockout searches on Justia/Trademarkia indexes returned **no GLYMR record** → a **false negative** (the registration is recent, Nov 2024). Only the **authoritative `tmsearch.uspto.gov` search caught it.** Index-absence is NOT clearance.

### Glymr domain situation
- `glymr.com` — owned by the NJ consultancy (unavailable).
- We already own `glymr.app` + `glymr.dev`; `glymr.io` + `glymr.sh` were free.
- Considered but rejected: emailing the consultancy (waking the bear / non-binding / admission risk); `glymr+X` compounds (embed the registered mark — don't escape it).

---

## Part 2 — neotilde research (the chosen name)

### How we got there
The unlock was reframing: **a name should evoke *one facet* of a mobile terminal** (Blink=cursor, Warp=speed, Prompt=prompt). Glymr's facet was *glimmer* (aesthetic, not terminal). `~` (tilde) is the shell home symbol — deeply terminal-literate (`tilde.club`, `tildes.net` are unix-culture sites). **`neotilde`** = `neo` (new) + `tilde` → "the modern terminal."

### Why it won
- **Terminal-resonant** + clear, positive meaning.
- **Owns the entire namespace** — the only candidate in the whole search with `.com`+`.sh`+`.app`+`.io`+`.dev` all free.
- **Collision-clean** (no company/app/product/brand).
- Coined compound (decent mark strength). One knock: "neo-" is an overused prefix (accepted as cosmetic).

### Domains (all grabbed 2026-06-24)
`neotilde.com` · `.io` · `.dev` · `.sh` · `.app`. Optional unbought extra: `neotil.de` (domain-hack short link).

### Remaining gate
Authoritative `tmsearch.uspto.gov` check (Classes 9/42/35/41) — protocol in the decision record. Not yet run.

---

## Part 3 — Candidate exploration (the full trail)

Veins mined and their best *clean + available* survivors (all pending USPTO):

| Vein | Notable clean candidates | Verdict |
|---|---|---|
| Light/dusk/bronze (Glymr lineage) | duskrelyx, duskrel, arcrelyn, lumora, auryx, tildwave, duskr, tembr | none beat neotilde; "dusk" crowded |
| Connection / relay-echo | duskrelay (real word — rejected), hexrelay, sablerelay | "relay" too literal/real |
| Norse mythic `-nir` | **glymnir** (Glymr lineage), **vordnir** (warden = best *meaning*), gattnir, stafnir, dirnir | strong runners-up; glymnir shares `GLYM-` onset (proximity risk) |
| Norse gate/door | gattnir, dyrnir, dirnir | abstract |
| Pseudowords (short 4-6) | mostly `.com`-taken | short = collision-heavy |
| Pseudowords (long 7-10) | `.com` mostly taken too; `-eria` survivors read as Romance "shops" | not tech-feeling |
| **tilde + affix** | **neotilde** ✓, syntilde, exotilde, tildeon | **winner here** |

### Rejected with cause (key collisions found)
- `gleamr` (read-later app + others), `glyphr` (Glyphr Studio font tool), `glynt` (GLYNT.ai), `konch` (Konch.ai), `nyxl` (NYXL esports), `harbr` (AppHarbr), `kyndl` (KyndL IT firm), `vspyr` (VESPR Cardano wallet), `emberlux` (registered TM Reg. 5718682), `caelyx` (chemo drug), `auronyx` (AoroNyx cybersecurity), `dornir` (≈ **Dornier** — aerospace/medical brand family), `caelia` (real Roman name; pronunciation fork SEE-/KIE-).

### Runners-up if neotilde ever falls through
1. **glymnir** — keeps the Glymr lineage; verify GLYM-proximity at USPTO.
2. **vordnir** — strongest *meaning* (warden = what SSH does); standardize that one spelling.

---

## Part 4 — Methodology & tools
- **Domain availability:** Verisign RDAP (`rdap.verisign.com`) for `.com`; `whois` for `.sh`/`.io`/`.com`; `rdap.org` (with backoff) for `.dev`/`.app`; authoritative registry RDAP where aggregators rate-limited/misreported. (Early `whois`-absent run gave false "taken"s — corrected with RDAP.)
- **Trademark/collision:** web + registry-index search (Justia/Trademarkia indexes) for knockout; **authoritative `tmsearch.uspto.gov`** as the only decisive source.
- **Generation:** scripted Cartesian of morpheme sets + a pronounceability filter, then human curation for "sounds real."

## Part 5 — Lessons
1. **Index-clean ≠ register-clean** — always confirm at `tmsearch.uspto.gov`.
2. **Brandable `.com` is exhausted (2026)** — nice pseudowords (short or long) are ~universally taken; names that own `.com` are rare wins.
3. **Great terminal names own one facet**, not the whole concept.
4. **`X+tilde` / `X+nir`** were the two most fertile veins for available + on-theme names.

## Part 6 — Good-faith clearance trail (for the record)
On **2026-06-24** we: identified the GLYMR registration (Reg. 7579030); analyzed §2(d) risk; explored 12+ naming veins; vetted domain availability via RDAP/whois; ran web/index collision checks on all finalists; and documented the remaining authoritative-USPTO step. The decision to adopt **neotilde** was made in good faith with a clean web/index record, pending the authoritative USPTO confirmation.
