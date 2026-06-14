# Function Keys — Design Spec

**Date:** 2026-06-14
**Status:** Locked direction, ready for implementation plan
**Scope:** Surfacing F1–F12 on a keyboard that has none, without polluting the keybar for users who never need them

---

## North star

iPhone has no native F-key access at all. Apps that depend on F-keys — `htop`, `top`, `mc`, various TUI debuggers, occasional vim mappings, custom user setups — are otherwise unusable from Glymr. The design must surface F-keys cleanly for users who need them while staying out of the way for the much larger set of users who never touch them.

The pattern every iOS terminal (Blink, Termius, a-Shell, Prompt 3) has converged on is a *layer toggle on the same row*, not a separate row or popup. We follow that convention.

---

## Non-goals (v1)

- **App-aware F-key labels.** Showing "F2 Setup" inside htop by scraping htop's status bar or shipping per-app label maps. Real win, but enough surface to defer to v1.5+.
- **F13–F24.** Vanishingly rare even on physical keyboards. Not surfaced.
- **F-keys via custom inputView.** Folds into the deferred v2 keyboard work.
- **F-key chord macros** (e.g. user maps Fn+1 to a custom sequence). Belongs to the snippet/macro system, not here.
- **External-keyboard F-key passthrough.** Folds into the deferred external-keyboard work.

---

## Surface model: Fn mode

A single keybar slot, `Fn`. Tapping it puts the keybar into **F-key mode**: the scrollable region's contents transform to show F1–F12 in place of the usual `[Ctrl/Alt/Shift, Tab, promotions, defaults]`. The locked region (window pill, pane pill, arrow-pad, Esc) is unchanged.

**Layout while in F-key mode:**

| Locked region (no scroll) | Scrollable region (F-key mode) |
|---|---|
| window · pane · arrow-pad · Esc | Ctrl/Alt/Shift · Tab · F1 · F2 · F3 · F4 · F5 · F6 · F7 · F8 · F9 · F10 *(F11, F12 reachable via pan)* |

Ctrl/Alt/Shift and Tab remain at the front of the scroll region in F-key mode, so **Shift+F-key combos work directly**: arm Shift, then tap the F-key.

**Why a layer toggle and not a popup or a separate row:**

- Popup (tap Fn → grid floats above) doubles the action cost for repeated F-key use — bad for htop where users hammer F2/F5/F6 in sequence.
- Separate row introduces a second design philosophy ("sometimes the keybar morphs, sometimes a row appears above") for the same conceptual surface.
- The layer toggle matches every other iOS terminal, is one mechanism, and the visible transformation of the scroll region is itself the state indicator.

---

## Fn slot location

**End of the scrollable region by default, not always visible at rest** — the user must pan to find Fn in normal mode.

Rationale:

- Heavy F-key users live in htop/top/mc. Those contexts **auto-engage** Fn (see §4), so manual access to the slot is irrelevant for them.
- For everyone else, Fn is rare. Front-of-bar real estate goes to higher-frequency items (modifiers, Tab, promotions, defaults).
- **State awareness is handled by the scroll-region transformation, not by seeing the Fn slot.** When F-keys are showing, the user knows they're in F-key mode regardless of whether the Fn slot itself is visible.
- Customization is first-class — users who want Fn forward can move it. The default placement matches the actual frequency curve, not a worst-case demand.

---

## Fn state machine

Caps-lock semantics — universally understood from physical keyboards.

| State | Visual | Enter | Exit |
|---|---|---|---|
| Off | Default slot | (default) | — |
| Armed (one-shot) | Bronze fill (matches modifier-armed) | Single tap from Off | Any F-key fires → returns to Off |
| Locked | Bronze fill + brighter glyph + small lock-indicator dot (4pt, top-right, bronze) | Double-tap from Off; or Armed → second tap; or context auto-engages | Single tap → Off (firing F-keys does **not** exit) |

---

## Auto-engage via context detection

Reuses the per-pane state machine from `2026-06-14-context-detection-design.md`. When `pane_current_command` matches a bundled auto-Fn process and clears the 250ms engage threshold, Fn auto-enters **Locked** for that pane. When the context disengages (1500ms threshold), Fn returns to Off.

### Bundled v1 auto-Fn contexts

| Process | Rationale |
|---|---|
| `htop` | F1–F10 are the primary UI |
| `top` | F-keys for help/setup |
| `mc` (midnight commander) | F-keys are the entire bottom menu |

**Deliberately excluded** despite occasional F-key use: `vim`, `nvim`, `nano`, `pico`, `lazygit`. Their F-key usage is sparse and varies per user; auto-arming for everyone would be wrong.

### User override is respected per episode

Per pane, per context-engagement *episode*, track a `fnUserOverride` flag.

- If `fnUserOverride == false` when a context engages: auto-lock Fn as normal.
- If the user single-taps Fn to turn it off while context has it locked: set `fnUserOverride = true`. Fn stays Off for the rest of this episode — auto-engage will **not** re-lock it.
- `fnUserOverride` resets when:
  - The context disengages and later re-engages (new episode), or
  - The pane is switched away and back, or
  - The user manually re-locks Fn.

Net behavior: htop auto-arms once on entry; if you turn it off, it stays off until your next htop visit. The system does not nag.

---

## Interaction with symbol promotions

Symbol promotions (the context-detection spec's bronze-tint slots inserted after Tab) and F-key mode both transform the same surface — the scrollable region. They are **mutually exclusive on display.**

If a hypothetical context were to define both a promotion set and trigger auto-Fn, F-key mode wins (it's the more dramatic state and the use case is sharper). No such case exists in the v1 bundled lists — `htop`/`top`/`mc` have no symbol promotions; vim/python/etc. don't auto-Fn — so this is a theoretical conflict for now. Revisit if a real one emerges.

---

## Companion change: Ctrl gets double-tap-to-lock

A small revision to the previously-locked Ctrl/Alt/Shift modifier behavior. The combined modifier slot's state machine becomes:

| Action | Result |
|---|---|
| Tap | Arm Ctrl (one-shot) |
| **Double-tap** | **Lock Ctrl** |
| Tap while Ctrl locked | Unlock Ctrl |
| Swipe-up | Arm Alt (one-shot) — no lock |
| Swipe-down | Arm Shift (one-shot) — no lock |
| Long-press | Edit slot (global) |

**Why asymmetric:**

- Only Ctrl's gesture (tap) supports double-tap cleanly. Swipe-based double-arming for Alt/Shift would be awkward and hard to discover.
- iOS's native keyboard already provides caps-lock for Shift (double-tap Shift on the letter layer).
- Alt-lock is vanishingly rare in terminal work.
- Ctrl-lock has a real use case: Emacs-style chord sequences (`Ctrl-x Ctrl-s`, `Ctrl-x Ctrl-f`).

The asymmetry maps to actual use. This is a delta against the v0 keybar spec — `mockups/keybar-v1.html` and the locked-decisions doc should be updated to reflect Ctrl-lock.

---

## Visual

| Element | Treatment |
|---|---|
| Fn slot **Off** | Default slot styling |
| Fn slot **Armed** (one-shot) | Bronze fill — same as the modifier-armed visual already used for sticky Ctrl/Alt/Shift |
| Fn slot **Locked** | Bronze fill + brighter glyph + small lock-indicator dot (4pt, top-right corner, bronze) |
| F-keys in F-key mode | Standard slot styling; no special tint. They're temporary inhabitants of the scroll region. Differentiated from "promoted symbols" (bronze-tint + top-edge accent) by their content, not their chrome. |
| Mode transition | Scroll region content cross-fades ~180ms between normal contents and F-keys. No haptics. |

---

## F-key range

**F1–F12.** Standard, sufficient for every realistic TUI use case. F13–F24 not surfaced.

---

## Authoring model

The auto-Fn process list ships as a bundled JSON resource, in the same shape as the promotion-sets JSON from the context-detection spec:

```json
{
  "htop": { "autoFn": true },
  "top":  { "autoFn": true },
  "mc":   { "autoFn": true }
}
```

Users can edit this file to add their own auto-Fn processes (e.g. a custom TUI). The v1.5 in-app editor surfaces this alongside promotion-set editing.

---

## Failure modes

| Failure | Result |
|---|---|
| User pans away from Fn slot in normal mode and forgets it exists | Acceptable. Fn is rare for that user by definition. Discovery happens via context auto-engage or via customization. |
| User locks Fn manually, switches panes, forgets it's locked | The other pane's scroll region shows F-keys. The visible-state transformation surfaces the issue. |
| User single-taps Fn to exit, but `fnUserOverride` was unintentional | They tap Fn again to re-lock. Trivial recovery. |
| User registers a custom auto-Fn process | Supported via the same JSON shape as bundled defaults. |
| tmux loses sync; `pane_current_command` is stale | Same fallback as the context-detection spec — context disengages, Fn returns to Off. Bar shows defaults. |
| Bundled auto-Fn list expands later | Append to JSON. Backward compatible. No state-machine changes. |

---

## Explicitly deferred

- **Per-app F-key labels** (showing "F2 Setup" in htop). v1.5+. Requires curated label maps per app or scraping the app's status bar.
- **In-app editor** for the auto-Fn list and the promotion sets generally. v1.5.
- **Shift+F-key affordance polish** — works today (arm Shift, tap F-key) but no visual hint that Shift is armed against a coming F-key. May need a small affordance later.
- **F-key chord macros** — out of scope; belongs to the snippet/macro system.
- **External-keyboard F-key passthrough** — folds into the deferred external-keyboard work.
- **htop/top symbol promotions** — were noted as deferred in the context-detection spec specifically because F-keys are their real win. Now satisfied by this design via auto-Fn; no separate symbol-promotion set needed for those apps.

---

## Cross-spec consequences

This spec creates two follow-up edits:

1. **`mockups/keybar-v1.html` and locked-decisions doc**: Ctrl's behavior changes from "sticky-for-one only" to "sticky-for-one with double-tap-to-lock." Alt and Shift unchanged.
2. **`2026-06-14-context-detection-design.md` §11**: the bundled list's note about `htop`/`top` being deferred until function keys are designed can be retired — they're now covered here via auto-Fn (no symbol promotions needed for them).
