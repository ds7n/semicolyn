# Predictor Suggestion Hygiene — Design Spec

**Date:** 2026-07-07
**Status:** Locked direction, ready for implementation plan
**Scope:** Fix four device-observed predictor defects + related smells found in a logic review: prompt tokens leaking into suggestions, suggestions on empty/short input, suggestions after Enter, stale chips lingering, and a timing-fragile input dispatch cascade.

---

## Bugs & root causes (from the 2026-07-07 predictor logic review)

| # | Symptom | Root cause |
|---|---------|------------|
| 2 | Starship **prompt** appears in suggestions (plain prompt only, not prompt+command) | ALL terminal output is harvested wholesale as suggestion candidates (`output.onHarvestBytes → predictor.harvest`). The prompt is output redrawn every line, so its tokens enter the ephemeral harvest set and surface newest-first. |
| 3 | Suggestions appear with **no input** (empty prefix) | No minimum-prefix gate anywhere. `OutputHarvest.candidates(forPrefix: "")` treats empty prefix as "match all" → returns everything. |
| 4 | Suggestions appear **after Enter** | The coalesced refresh is scheduled on *every* chunk including a bare Enter; Enter has already reset `tracker.current` to `""`, so the refresh runs with an empty prefix (→ bug 3's mechanism). |
| A | Stale chips linger on reset/accept | The only `setSuggestions([])` is the no-predictor branch. Nothing clears chips on Enter, line-reset, or after accept. |
| C/D | Fragile 40/45/50ms wall-clock dispatch cascade; coalescer mutated across async hops | Three main-queue hops keyed off one deadline, time-ordered not sequenced. (All on `@MainActor`, so no data race — but brittle under stall.) |

---

## Fixes

### Fix 1 — Harvest only typed-command echo, not free output (bug 2)

Remove the output→harvest→suggest path entirely. The predictor already tracks what the
user typed (`pendingLineTokens`, committed per line). Suggestions will source from the
**learned vocabulary + seed corpus + the user's own typed tokens** — never from raw
terminal output. The prompt is output, so it can no longer be harvested. This also
retires additional finding **#F** (powerline-glyph token fusion) since we stop tokenizing
output.

**Changes:**
- `App/ConnectionViewModel.swift`: delete the two `predictor?.harvest(output:)` calls (raw-shell `output.onHarvestBytes` ~line 505–511; tmux pane path ~line 756). Remove `onHarvestBytes` wiring that exists solely to feed harvest. (Keep `passwordDetector.noteOutput` — that is the password-prompt gate, unrelated.)
- The typed tokens already flow to the engine via `predictor.record(...)` on line-commit (the L1/L4/L7 learning path). No new learning path is needed; we are *removing* a source, not adding one.
- `OutputHarvest` and `PredictorEngine.harvest(output:)` become unused for the live path. Leave the types in place (seed ingestion / tests may reference them) but the App no longer calls `harvest`. If nothing references `harvest` after this, mark it clearly as seed-only or remove — decided at implementation time by a usage grep.

> **Trade-off (accepted):** loses "complete a filename you just saw in `ls` output." That same mechanism is what leaked the prompt; the user chose robustness over that feature.

### Fix 2 — Minimum-prefix gate (bugs 3, 4)

Authoritative gate inside the engine so every caller is protected:

- `PredictorEngine.suggestions(forPrefix:after:)`: `guard prefix.count >= minPrefix else { return [] }` at the top. `minPrefix` is a `SuggestionConfig` knob, default **2** (matches the "1–2 characters" intent; 2 chosen so a single stray char doesn't trigger).
- This alone makes an empty-prefix (post-Enter) refresh return `[]`.

### Fix 3 — Don't schedule a refresh for input-less chunks (bug 4, belt-and-suspenders)

- `App/ConnectionViewModel.swift observePredictorInput`: guard the coalesced-refresh scheduling block on `!scalars.isEmpty` (mirroring the echo-settle guard already there). An Enter/control-only chunk (empty `scalars`) neither settles echo nor requests a refresh.

### Fix 4 — Clear stale chips on line reset & accept (finding A, and B/E follow)

- On **Enter/line-commit** (the `0x0d/0x0a` branch in `observePredictorInput`) and on **ESC/control line reset**: call `predictorVM.setSuggestions([])` so chips clear immediately with the line.
- `refreshPredictorSuggestions`: when the gate yields `[]` (short/empty prefix), it already calls `setSuggestions([])` — make that explicit so a short prefix actively clears rather than leaving old chips.
- `acceptSuggestion`: clear chips synchronously at accept time (`setSuggestions([])`) instead of waiting for the async echo round-trip. The subsequent refresh repopulates from the new prefix. This closes findings **B** (stale-until-roundtrip) and **E** (tap-a-stale-chip no-op), since a chip is cleared the instant it's accepted.

### Fix 5 — Sequence the dispatch cascade explicitly (findings C, D)

The current cascade fires three main-queue blocks at `deadline` (echo-settle, +40ms),
`deadline+5ms` (refresh), `deadline+10ms` (learn-commit) — correct only by wall-clock
ordering. Replace the wall-clock ordering with **explicit sequencing** so refresh always
observes post-settle state and learn-commit always precedes the next line's refresh,
regardless of main-thread stalls:

- Keep a single `40ms` echo-settle debounce hop. Inside it (after `settleLine`), perform
  the ordered steps in sequence on the main actor: (1) settle echo, (2) if this chunk was
  a line-commit, run the learn-commit + clear chips, (3) run the coalesced suggestion
  refresh. Because these now execute in one main-actor continuation in program order, the
  fragile inter-hop offsets (+5ms/+10ms) are removed.
- Confirm (assert in a comment) that `observePredictorInput` and the coalescer mutations
  are `@MainActor` (they are — the VM is `@MainActor` and the only caller is
  `sendTerminalInput`), so **#D needs no lock** — document the isolation rather than add
  synchronization.

> This is the most invasive change; it touches the sacred keystroke path. It must preserve
> the existing L1 echo-settle timing (the 40ms window) and the coalescer's trailing-debounce
> semantics exactly — only the *ordering mechanism* changes, not the windows.

---

## Testing

| Unit | Where | Cases | Tier |
|---|---|---|---|
| `PredictorEngine.suggestions` min-prefix gate | Linux XCTest | prefix `""`→`[]`; 1 char→`[]` (minPrefix=2); 2 chars→normal results; boundary at exactly `minPrefix`. Assert exact returned arrays. | Core |
| Harvest-source change | Linux XCTest | after Fix 1, a token present ONLY in "output" (never typed) is NOT suggested; a typed+committed token IS suggested (via the existing record path). Pins the leak fix. | Core |
| `SuggestionConfig.minPrefix` default | Linux XCTest | default == 2. | Trivial |
| App pipeline (clear-on-reset, Enter-no-refresh, accept-clears, cascade ordering) | macOS CI / device | App-tier — verified by macOS CI compile + device pass. Behavioral checks are manual. | Core (manual) |

The engine-level gate + harvest-source change carry the real Linux coverage; the App-tier
wiring (Fixes 3, 4, 5) is macOS-CI-verified per repo convention.

---

## Non-goals / deferred

- OSC 133 shell-integration prompt markers (would enable safe output harvesting later; not needed once we harvest only typed echo).
- Heuristic Starship-prompt pattern matching (brittle; not pursued).
- Re-adding output-completion via a safe channel — revisit only if users miss "complete what I saw."
- `SuggestionConfig` per-host tuning of `minPrefix` (fixed default 2).
