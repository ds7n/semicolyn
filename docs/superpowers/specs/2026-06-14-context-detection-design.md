# Context Detection — Design Spec

**Date:** 2026-06-14
**Status:** Locked direction, ready for implementation plan
**Scope:** Per-pane foreground-process detection driving context-aware keybar promotions

---

## North star

The keybar has 10 fixed slots competing for thumb real estate. A static layout is a compromise: `Esc` is gold inside vim and dead weight in a shell; `:` is essential in vim and pointless in a top-level shell. Context detection makes the bar **more useful per moment than any fixed layout could be** — without forcing the user to think about it.

Detection earns its complexity by removing friction at rapid context-switch moments (the most common kind in terminal work). The user should not have to think "I'm in vim now, swap layout."

---

## Non-goals (v1)

- **Modal sub-state inside an app** (vim insert vs normal vs visual; less paging vs search prompt). Requires per-app cooperation (e.g. a vim plugin emitting OSC escapes) or fragile content scraping. Deferred to v2.
- **Detecting the shell command line being typed** (e.g. promoting Kubernetes keys when the user starts typing `kubectl`). Requires a shell-side hook (`preexec` / `DEBUG` trap) or prompt-line scraping. Deferred to v2.
- **Predictor or launcher behavior changes.** The context signal is wired through (see §9) but those subsystems are not consumers in v1.

---

## What counts as a context

The foreground process per pane — including nested shells and REPLs. Bundled v1 promotion sets cover `vim`, `nvim`, `less`, `more`, `man`, `python`, `python3`, `ipython`, `node`, `psql`, `mysql`, `sqlite3`, `redis-cli`. Final list in §11.

Anything else (the top-level shell, `awk`, `ssh`, `git`, an unknown custom binary) falls through to "no promotions, defaults shown" — silently, with no nag.

---

## Signal source

`pane_current_command` from tmux control mode (`tmux -CC`). This is already locked as Glymr's session engine; the field is first-class tmux state, maintained by tmux itself via the pty's foreground-process-group tracking.

**Properties:**

- **Zero host cooperation required.** Works on any host the user can SSH to. No PROMPT_COMMAND, no shell helper, no installed package on the remote.
- **Already-tracked.** tmux maintains this regardless of what we do; we are reading existing state.
- **Survives nesting transparently.** If vim runs inside tmux inside ssh inside tmux, the outer tmux reports `vim`. We don't model the nesting; we just read the value.

**Acquisition:** preferred path is tmux control-mode subscription notifications (event-driven). Fallback path is low-cadence polling. Either is acceptable — the per-pane state machine debounces afterward, so polling jitter is absorbed.

---

## Per-pane state machine

Each pane maintains its own context state. The machine has three pieces:

| Field | Meaning |
|---|---|
| `currentProcess` | Latest `pane_current_command` reading |
| `engagedContext` | The process whose promotion set is currently driving the UI for this pane (or `null`) |
| dwell timers | One for entry (250ms), one for exit (1500ms) |

### Transitions

- **Process changes to a known bundled name.** Start engage timer. If `currentProcess` stays unchanged for ≥250ms, set `engagedContext = currentProcess` and notify the UI. If it changes again before the timer fires, restart with the new value.
- **Process changes away from `engagedContext`.** Start disengage timer. If the process stays away from `engagedContext` for ≥1500ms, set `engagedContext = null` and notify the UI. If the process returns to `engagedContext` before the timer fires, cancel the disengage — bar never reflowed.
- **Process changes to an unknown name (no bundled set, no user override).** Equivalent to "not in `engagedContext`" — starts the disengage timer if a context was engaged; otherwise no-op.

### Why asymmetric

Entering an app is intentional — you typed `vim file.txt`. A short engage threshold (250ms) is fine and gets the layout up fast. Leaving an app is often transient — `:!ls`, `:sh`, the app momentarily exec'd a subprocess. A long disengage threshold (1500ms) absorbs these excursions without flapping the layout back to shell defaults.

These numbers are starting points. Once Glymr ships with opt-in telemetry (predictor-style), tune from real session traces.

### Pane focus changes

When the focused pane changes (via the pane pill, terminal-area tap, or any other mechanism), the keybar updates to the new pane's `engagedContext` **immediately** — no re-debounce. Each pane already independently debounced on entry; the user is making a deliberate switch, and the bar should reflect reality on arrival.

### Global signal change

If `pane_current_command` is unavailable (tmux out of sync, control-mode hiccup), the state machine times out and `engagedContext` decays to `null`. No alarm — bar falls back to defaults.

---

## Keybar integration

The keybar is now structured as **locked left section + horizontally scrollable right section**.

### Locked region (never moves, never scrolls)

| Slot | Item |
|---|---|
| 1 | window pill |
| 2 | pane pill |
| 3 | arrow-pad (Blink-style drag) |
| 4 | Esc |

The "you'll lose your mind if these aren't always visible" set. Pills carry their existing locked gestures; arrows and Esc are the highest-frequency standalone keys.

### Scrollable region (horizontal pan)

Order, left to right:

1. **Ctrl/Alt/Shift** (combined modifier slot, sticky-for-one-keystroke)
2. **Tab**
3. **Promotions** — zero or more bronze-tinted slots from the engaged context's promotion set, in the order the set declares them
4. **Defaults** — `/`, `\|`, `~`, `-`, `(`, `)` (or whatever the user has customized for convenience defaults)

Promotions land directly after Tab. Defaults push right; they remain reachable via horizontal pan. The right edge of the bar carries a faint fade indicating scrollability.

### Promoted slot visual

**Treatment A+C:** bronze-tint fill + thin top-edge accent.

- Fill: `#D49A5C` at ~12% opacity over the default slot background. Warm cast, distinguishable in peripheral vision.
- Top-edge accent: 1–2pt bronze line along the top edge of the slot, like a tab indicator.
- Glyph contrast unchanged — full readability.

**State reservations (no collision):**

| State | Visual |
|---|---|
| Default convenience slot | Neutral fill, no accent |
| **Promoted slot** | Bronze tint + top-edge accent |
| Pressed | Brighter fill (applies on top of either default or promoted) |
| Modifier armed (sticky-for-one) | Existing full-bronze modifier indicator |
| Focus halo | Reserved for cursor halo on the terminal area |
| Connection state | Verdigris / amber, separate banner surface |

### Engage / disengage animation

- **Engage:** promoted slots slide in from the left over ~180ms. The top-edge accent on each new slot does a brief one-cycle brighten (one ~120ms pulse) so the change registers in peripheral vision.
- **Disengage:** promoted slots slide out to the left over ~180ms. Defaults reflow left to fill. No pulse.

No flashing, no jumpy reflow, no haptics on promotion change. The keybar is a quiet surface.

### Vertical real estate

Unchanged. The promotion mechanism is purely horizontal; the keybar height is identical with or without an engaged context.

---

## Authoring model

### v1 ships bundled defaults

A curated list (§11) for ~8 common processes covers the most-used apps. Promotion sets are stored as a bundled JSON resource shipped with the app.

### Promotion set shape

```json
{
  "vim": {
    "promote": [
      { "tap": ":", "up": ";" },
      { "tap": "*", "up": "#" },
      { "tap": "%", "up": "^", "down": "$" }
    ]
  },
  "python": {
    "promote": [
      { "tap": ":" },
      { "tap": "[", "up": "{" },
      { "tap": "]", "up": "}" },
      { "tap": "=", "up": "+" }
    ]
  }
}
```

Each promotion entry follows the existing keybar slot model (tap primary, optional swipe-up secondary, optional swipe-down tertiary). The same per-slot interaction rules apply.

### User customization in v1

Editing happens in a hidden JSON settings file at a stable on-device path. Advanced users can:

- Edit promotion sets for any bundled process (add, remove, reorder, set swipe chars).
- Register new processes with their own promotion sets (e.g. add `awk`, `jq`, `kubectl` — keeping in mind that `kubectl` as a foreground process is rare; this is for binaries that hang around).

Casual users never see this surface.

### v1.5 — in-app editor

Long-press any promoted slot → "Edit promotion set for *vim*." Surface the JSON's user-visible shape (ordered list of symbols + swipe chars) as a small editor. Defer until we see what users actually want to change.

---

## Override and unknowns

### Per-pane pin

Long-press the pane pill → menu offers "Pin keybar to defaults" or "Pin keybar to *current context*" (e.g. "Pin to vim layout"). Pinning:

- Freezes the bar for that pane.
- Decouples rendering from the state machine for that pane only; the state machine keeps running (cheap, useful for instrumentation).
- Visible affordance: small bronze dot on the pane pill while pinned.
- Persists per-pane for the session; not stored across reconnects.

Long-press pane pill → "Unpin" restores normal behavior.

### Global kill switch

Settings → "Context-aware keybar" toggle.

- Off: bar shows defaults everywhere, always. State machine still runs (no cost to leave it running), it just doesn't drive the UI.
- On: default. Reversible without restart.

### Unknown processes

When `pane_current_command` returns a process that is neither in the bundled list nor in user overrides:

- `engagedContext` becomes `null`.
- Bar shows defaults.
- **No hint, no nag, no "set up promotions for *foo*?" prompt.** Silent fallback. If a user keeps ending up in some process, they will customize. Until then, silence beats noise.

### Nested contexts

`pane_current_command` already returns the deepest foreground process (tmux tracks the pty's foreground process group). We use it as-is. No special handling for ssh-in-tmux-in-vim chains.

---

## Shared signal

Detection exposes a per-pane observable on the session model:

```
PaneState.currentContext: ProcessName | null
```

The keybar is the only v1 subscriber. The predictor, snippet launcher, and window pill activity badge are explicit *non-consumers* in v1 — they could subscribe later without re-architecting.

Decoupling rationale: the state machine is the same code either way, and exposing the observable now preserves future optionality (e.g. predictor ranking conditioned on context, launcher sorting macros relevant to the current process, pill badges showing `vim ●`). Designing those behaviors is out of scope here; the wire is the only commitment.

---

## Failure modes

| Failure | Result |
|---|---|
| tmux loses sync; `pane_current_command` stops updating | State machine times out, `engagedContext` decays to `null`, bar falls back to defaults |
| Promotion set in JSON references a non-printable or unsupported key | Render best-effort — any printable char works; reject at JSON load only on syntax errors |
| User pins a pane to a context they never enter | Pin remains valid; first time that context engages on another (non-pinned) pane, behavior is normal |
| User's JSON override file is malformed | Fall back to bundled defaults entirely; surface a one-time inline warning in settings; never crash |
| Two promotion entries from different sources collide (bundled vs user) | User entry wins. Always |

---

## Bundled v1 promotion list

| Process names | Promotions | Rationale |
|---|---|---|
| `vim`, `nvim` | `:` `*` `%` | ex commands; search-under-cursor; brace match |
| `less`, `more`, `man` | `?` `<` `>` | search-back; jump-to-start/end |
| `python`, `python3`, `ipython` | `:` `[` `]` `=` | block colon; collection literals; assignment |
| `node` | `:` `[` `]` `=` | same shape as python |
| `psql` | `\` `;` | meta-commands; statement terminator |
| `mysql` | `\` `;` | same shape as psql |
| `sqlite3` | `;` `.` | terminator; dot-commands |
| `redis-cli` | `:` `\` | key separators |

**Deferred until function-keys design lands:** `htop`, `top`. Their real win is F1–F10, which the keybar doesn't have a slot model for yet.

---

## Explicitly deferred

- **Modal sub-state detection** (vim insert mode, less prompts, tmux prefix-armed). Needs scraping or per-app helper. v2.
- **Shell-command-line aware promotions** (e.g. `kubectl`-typing detection). Needs a shell helper (preexec/DEBUG trap). v2.
- **In-app editor for promotion sets.** v1.5.
- **`htop` / `top` promotions.** Wait for the function-keys design.
- **Predictor consumption** of the context signal (per-context ranking). Wire is there; design when the predictor gets its next pass.
- **Launcher consumption** of the context signal (per-context macro sorting). Same.
- **Window pill activity badge** showing context (`vim ●`). Same.
- **Telemetry-driven tuning** of dwell thresholds (250ms / 1500ms). Needs predictor-style opt-in telemetry. v1.5.
- **Per-host or per-user promotion preferences synced via iCloud.** Folds into the broader iCloud sync scope, which is itself deferred.

---

## Open questions / known unknowns

- **Final tmux subscription mechanism.** Control-mode subscriptions vs polling cadence — implementation choice, validate against real `tmux -CC` behavior during build.
- **Visual treatment under low brightness / high ambient light.** Bronze tint at 12% may be too subtle outdoors. May need a brighter alternative tier in light/outdoor display modes; design when accessibility/display-modes pass happens.
- **Behavior when tmux is disabled per-host** (the "purist" tier from the session-engine decisions). Without tmux, `pane_current_command` is unavailable. Likely answer: detection is silently disabled for that host. Confirm during implementation.
