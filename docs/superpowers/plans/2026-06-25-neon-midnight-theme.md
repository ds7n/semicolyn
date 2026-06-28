# Neon Midnight Theme Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make **Neon Midnight** (`#FF6F5E` coral accent on a `#07090E` blue-near-black night) the default theme, keeping Bell-bronze as a switchable alternate in the registry.

**Architecture:** Add a new `Theme.neonMidnight` value (new file mirroring `BellBronzeTheme.swift`) in `SemicolynKit`, flip the registry order and the SwiftUI/App default to it, and keep `Theme.bellBronze`. No token *structure* changes — only values + a default switch. Glow stays confined to the existing `BellHaloView` (bell-only); no persistent bloom is added.

**Tech Stack:** Swift 6 (`SemicolynKit`, Linux-tested via Docker) / Swift 5 (App target, macOS-CI only), XCTest, the existing `Theme` semantic-token system.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-06-25-neon-midnight-theme-design.md` (token table is authoritative).
- **`SemicolynKit` is Swift-6 + Linux-clean**; theme value types are `Sendable`, no UIKit/SwiftUI in the palette file. Run tests via `docker compose run --rm dev swift test`.
- **App / SwiftUI-gated code is macOS-CI-verified only.** `Sources/SemicolynKit/Theme/ThemeEnvironment.swift` is wrapped in `#if canImport(SwiftUI)` → NOT compiled on Linux; `App/` is macOS-only. So `ThemeKey.defaultValue` and `App/TerminalScreen.swift` changes are validated by the macOS CI job, not Linux `swift test`. The **Linux proxy** for "neon is the default" is the `Theme.all` ordering test (Task 1).
- **Exact token values** (verbatim from the spec): accent `#FF6F5E` / hi `#FFB7A6`; surface bg/panel/panelHigh/line `#07090E`/`#0E1118`/`#161A24`/`#232A3A`; text `#E8EBF0`/`#8A93A3`/`#8A93A3`/`#05070B`; success `#5FB0A2`; warning/degraded `#F5A524`; broken `#E5455E`; bell.edge `#FF6F5E`; focus `#FF6F5E`/`#232A3A`; keybar slotBg `#0E1118`, promoted/armed/locked = accent @ `0.12`/`0.20`/`0.30`; predictor `#0E1118`/`#161A24`/`#E8EBF0`; banner amberBg `#F5A524@0.15`, redBg `#E5455E@0.15`, neutralBg `#0E1118`; terminal bg/fg `#05070B`/`#CFD6E4`.
- **error must not equal accent** (the coral-vs-red separation): `state.broken (#E5455E) ≠ accent.primary (#FF6F5E)`.
- Conventional commits; commit after each green step. Do NOT add glow tokens or bloom to focus/cursor/keybar.

## File Structure

- `Sources/SemicolynKit/Theme/NeonMidnightTheme.swift` *(create)* — file-private palette constants + `extension Theme { public static let neonMidnight }`. Mirrors `BellBronzeTheme.swift`.
- `Sources/SemicolynKit/Theme/BellBronzeTheme.swift` *(modify)* — `Theme.all = [.neonMidnight, .bellBronze]` (line 41). Bell-bronze value kept unchanged.
- `Tests/SemicolynKitTests/ThemeTests.swift` *(modify)* — replace the v1 registry test; add `neonMidnight` value assertions. Keep the bellBronze assertions.
- `Sources/SemicolynKit/Theme/ThemeEnvironment.swift` *(modify, line 7)* — `ThemeKey.defaultValue = .neonMidnight` (SwiftUI-gated → macOS CI).
- `App/TerminalScreen.swift` *(modify, line 23)* — `var theme: Theme = Theme.neonMidnight` (App → macOS CI). `TmuxPaneContainer.swift` needs **no change** (its `theme` is a required param fed by `SessionView`'s `@Environment(\.theme)`).
- `mockups/specs/design-system.html` + `docs/brainstorming-decisions.md` *(modify)* — reflect Neon Midnight as default; note Bell-bronze retained.

---

### Task 1: `Theme.neonMidnight` value + registry + tests (Linux)

**Files:**
- Create: `Sources/SemicolynKit/Theme/NeonMidnightTheme.swift`
- Modify: `Sources/SemicolynKit/Theme/BellBronzeTheme.swift:41`
- Test: `Tests/SemicolynKitTests/ThemeTests.swift`

**Interfaces:**
- Consumes: `Theme`, `ThemeColor` (existing, `Sources/SemicolynKit/Theme/Theme.swift`); `ThemeColor.alpha(_:)`.
- Produces: `Theme.neonMidnight: Theme`; updated `Theme.all: [Theme] = [.neonMidnight, .bellBronze]`.

- [ ] **Step 1: Write the failing tests**

In `Tests/SemicolynKitTests/ThemeTests.swift`, **replace** `testRegistryContainsOnlyBellBronzeInV1` with the registry test below and **add** the `neonMidnight` tests. Keep every existing `bellBronze`/`rgba` test as-is.

```swift
func testRegistryHasNeonMidnightDefaultThenBellBronze() {
    XCTAssertEqual(Theme.all.count, 2)
    XCTAssertEqual(Theme.all.first, Theme.neonMidnight)   // default is first
    XCTAssertTrue(Theme.all.contains(Theme.bellBronze))   // bronze retained
}

func testNeonMidnightAccentIsCoral() {
    XCTAssertEqual(Theme.neonMidnight.accent.primary, ThemeColor("#FF6F5E"))
    XCTAssertEqual(Theme.neonMidnight.accent.highlight, ThemeColor("#FFB7A6"))
}

func testNeonMidnightBellEdgeMatchesAccent() {
    XCTAssertEqual(Theme.neonMidnight.bell.edge, Theme.neonMidnight.accent.primary)
}

func testNeonMidnightErrorIsDistinctFromAccent() {
    // The coral-vs-error separation: error must be its own cooler crimson.
    XCTAssertEqual(Theme.neonMidnight.state.broken, ThemeColor("#E5455E"))
    XCTAssertNotEqual(Theme.neonMidnight.state.broken, Theme.neonMidnight.accent.primary)
}

func testNeonMidnightSurfacesAreDarkerNight() {
    XCTAssertEqual(Theme.neonMidnight.surface.bg, ThemeColor("#07090E"))
    XCTAssertEqual(Theme.neonMidnight.terminal.bg, ThemeColor("#05070B"))
}

func testNeonMidnightSuccessIsVerdigris() {
    XCTAssertEqual(Theme.neonMidnight.state.success, ThemeColor("#5FB0A2"))
}

func testNeonMidnightKeybarLadder() {
    XCTAssertEqual(Theme.neonMidnight.keybar.slotBgPromoted, ThemeColor("#FF6F5E", opacity: 0.12))
    XCTAssertEqual(Theme.neonMidnight.keybar.slotBgArmed,    ThemeColor("#FF6F5E", opacity: 0.20))
    XCTAssertEqual(Theme.neonMidnight.keybar.slotBgLocked,   ThemeColor("#FF6F5E", opacity: 0.30))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ThemeTests`
Expected: FAIL — `type 'Theme' has no member 'neonMidnight'` (and the registry test fails on count/first).

- [ ] **Step 3: Create the theme value**

Create `Sources/SemicolynKit/Theme/NeonMidnightTheme.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

// Palette constants are file-private: only the semantic `Theme` is exported.
// Values verbatim from docs/superpowers/specs/2026-06-25-neon-midnight-theme-design.md.
// Story: neo → neon (neon gas glows orange-red) on a midnight blue-near-black
// night; the prompt `~` is the lit sign. Glow is bell-only (see BellHaloView) —
// no persistent bloom lives in these tokens.
private let coral500      = ThemeColor("#FF6F5E")   // neon accent (the glow's color)
private let coral300      = ThemeColor("#FFB7A6")   // highlight / hot core
private let night0        = ThemeColor("#07090E")   // ground — darker blue-night
private let nightPanel    = ThemeColor("#0E1118")
private let nightPanelHi  = ThemeColor("#161A24")
private let nightLine     = ThemeColor("#232A3A")
private let nightTerm     = ThemeColor("#05070B")   // terminal bg (deepest night)
private let patina500     = ThemeColor("#5FB0A2")   // verdigris success (cool complement)
private let amber500      = ThemeColor("#F5A524")
private let crimson500    = ThemeColor("#E5455E")   // unlit, cooler error red
private let textPrimary   = ThemeColor("#E8EBF0")
private let textMuted     = ThemeColor("#8A93A3")
private let termFg        = ThemeColor("#CFD6E4")

extension Theme {
    public static let neonMidnight = Theme(
        surface: .init(bg: night0, panel: nightPanel,
                       panelHigh: nightPanelHi, line: nightLine),
        text: .init(primary: textPrimary, secondary: textMuted,
                    muted: textMuted, inverse: nightTerm),
        accent: .init(primary: coral500, highlight: coral300),
        state: .init(success: patina500, degraded: amber500,
                     broken: crimson500, warning: amber500),
        bell: .init(edge: coral500),
        focus: .init(paneBorder: coral500, paneBorderInactive: nightLine),
        keybar: .init(slotBg: nightPanel,
                      slotBgPromoted: coral500.alpha(0.12),
                      slotBgArmed: coral500.alpha(0.20),
                      slotBgLocked: coral500.alpha(0.30)),
        predictor: .init(stripBg: nightPanel, suggestionBg: nightPanelHi,
                         suggestionText: textPrimary),
        banner: .init(amberBg: amber500.alpha(0.15), redBg: crimson500.alpha(0.15),
                      neutralBg: nightPanel),
        terminal: .init(bg: nightTerm, fg: termFg)
    )
}
```

- [ ] **Step 4: Flip the registry**

In `Sources/SemicolynKit/Theme/BellBronzeTheme.swift`, change line 41 from:

```swift
    public static let all: [Theme] = [.bellBronze]
```
to:
```swift
    // Neon Midnight is the default (first); Bell-bronze retained as a switchable
    // alternate (candidate Pro cosmetic). Picker UI is Phase 4.
    public static let all: [Theme] = [.neonMidnight, .bellBronze]
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ThemeTests`
Expected: PASS — all new `neonMidnight` tests + the registry test, and the retained bellBronze tests.

- [ ] **Step 6: Run the full suite (no regressions)**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS — full `SemicolynKit` suite green.

- [ ] **Step 7: Commit**

```bash
git add Sources/SemicolynKit/Theme/NeonMidnightTheme.swift Sources/SemicolynKit/Theme/BellBronzeTheme.swift Tests/SemicolynKitTests/ThemeTests.swift
git commit -m "feat(theme): add Neon Midnight palette; make it the default registry entry"
```

---

### Task 2: Flip the live default + refresh docs (macOS CI + docs)

**Files:**
- Modify: `Sources/SemicolynKit/Theme/ThemeEnvironment.swift:7`
- Modify: `App/TerminalScreen.swift:23`
- Modify: `mockups/specs/design-system.html`, `docs/brainstorming-decisions.md`

**Interfaces:**
- Consumes: `Theme.neonMidnight` (Task 1).

> No new Linux test: both code edits are SwiftUI/App-gated (invisible to Linux `swift test`). Task 1's `testRegistryHasNeonMidnightDefaultThenBellBronze` is the Linux proxy that neon is the default; these edits make the *live* environment default match, validated by macOS CI.

- [ ] **Step 1: Flip the SwiftUI environment default**

In `Sources/SemicolynKit/Theme/ThemeEnvironment.swift`, change line 7 from `static let defaultValue: Theme = .bellBronze` to:

```swift
    static let defaultValue: Theme = .neonMidnight
```

- [ ] **Step 2: Flip the raw-PTY view default**

In `App/TerminalScreen.swift`, change line 23 from `var theme: Theme = Theme.bellBronze` to:

```swift
    var theme: Theme = Theme.neonMidnight
```

(`App/TmuxPaneContainer.swift` needs no change — its `let theme: Theme` is supplied by `SessionView`'s `@Environment(\.theme)`, which now resolves to `.neonMidnight`.)

- [ ] **Step 3: Refresh the design-system mockup**

In `mockups/specs/design-system.html`, update the palette section (`<h2>Palette — "Bell bronze"</h2>` and the lede / swatch hexes) to present **Neon Midnight** as the default — accent `#FF6F5E`, night `#07090E`/`#05070B`, success `#5FB0A2`, error `#E5455E` — and add a one-line note that **Bell bronze is retained as a switchable alternate**. Keep the existing bronze swatches in a clearly-labelled "alternate" subsection rather than deleting them.

- [ ] **Step 4: Refresh the brand-palette decision row**

In `docs/brainstorming-decisions.md`, update the `Brand palette` row to: **"Neon Midnight"** — coral accent `#FF6F5E` (the orange-red glow of neon) on darker blue-near-black `#07090E`, verdigris `#5FB0A2`, bell-only glow (anti-CP2077). Note Bell-bronze kept as a Pro-cosmetic alternate. Reference `docs/superpowers/specs/2026-06-25-neon-midnight-theme-design.md`.

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Theme/ThemeEnvironment.swift App/TerminalScreen.swift mockups/specs/design-system.html docs/brainstorming-decisions.md
git commit -m "feat(theme): make Neon Midnight the live default; refresh design-system + brand docs"
```

- [ ] **Step 6: Push the branch and confirm macOS CI is green**

```bash
git push github feat/neon-midnight-theme
```
Open/refresh the PR; confirm the `macos` job is **success** — it's the only validation that the SwiftUI default (`ThemeKey.defaultValue`) and the App view default compile and render. Spot-check on the Simulator that the app comes up in Neon Midnight (coral accent, deep blue-black) and that the accent is **solid at rest** — only the bell glows (`printf '\a'`).

---

## Verification

- **Linux (primary, free/local):** `docker compose run --rm dev swift test` — full `SemicolynKit` suite green, including the new `neonMidnight` value + registry-order tests and the retained bellBronze tests. The `state.broken ≠ accent.primary` assertion guards the coral-vs-error separation.
- **macOS / CI:** the `macos` job builds + renders the app with Neon Midnight as the live default (validates the SwiftUI/App default flips that Linux can't compile). Simulator spot-check: coral-on-deep-blue at rest, bell-only glow.
- **Glow guardrail:** `git grep -n 'shadow' App/` shows glow/bloom only in `App/BellHaloView.swift` (the bell) — no bloom added to focus border, cursor, or keybar.
- **Registry sanity:** `Theme.all.first == .neonMidnight` and `.bellBronze` still present.

## Self-review notes (spec coverage)

Spec → tasks: the full `Theme.neonMidnight` token table + registry → Task 1 (with value tests, incl. error≠accent and bell.edge==accent); live default flip (`ThemeKey.defaultValue` + `TerminalScreen`) → Task 2; docs refresh → Task 2. Bell-bronze retained (Task 1 registry test asserts it). Glow-bell-only is a guardrail (verification), not new code — the only glow remains `BellHaloView` from Phase 3c. **Deferred per spec:** theme-picker Settings UI + Pro-gating of Bell-bronze (Phase 4); formal WCAG audit (existing accessibility-review TODO). No new persistent-glow tokens are introduced.
