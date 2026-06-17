# Design tokens — color theming plumbing

**Date:** 2026-06-17
**Status:** Locked

## Goal

Establish color-theming plumbing now so v1 can ship the Bell Bronze palette while remaining ready to add alternative palettes later (Pro perk, accessibility variant, future light mode) without touching consumer code.

The infrastructure exists in v1; the picker UI does not. Adding a second theme later is a content addition, not a refactor.

## Public API

UI code references colors **only** through semantic tokens, never as hex values or palette constants. Tokens are accessed via a nested namespace:

```swift
Color.theme.surface.bg
Color.theme.bell.edge
Color.theme.state.success
Color.theme.keybar.slotBgPromoted
```

The active `Theme` is held in a SwiftUI environment value. Changing themes propagates through the view tree without rebuilds.

## Theme file shape

Each theme lives in one Swift file. The file defines `private let` palette constants with human-readable names (`bronze500`, `coolDarkAnchor`, `patina500`) and maps them into a single `Theme(...)` value of semantic tokens. **Palette constants are file-private**; only the semantic `Theme` is exported.

```swift
// BellBronzeTheme.swift
private let bronze500       = "#D49A5C"
private let bronze300       = "#F2C58A"
private let coolDarkAnchor  = "#0E1116"
private let coolDarkPanel   = "#161A22"
private let coolDarkPanelHi = "#1F2530"
private let coolDarkLine    = "#2A323F"
private let patina500       = "#5FA89C"
private let amber500        = "#F5A524"
private let red500          = "#E06B6B"
private let textPrimary     = "#E8EBF0"
private let textMuted       = "#8A93A3"

extension Theme {
    static let bellBronze = Theme(
        surface: .init(
            bg:        coolDarkAnchor,
            panel:     coolDarkPanel,
            panelHigh: coolDarkPanelHi,
            line:      coolDarkLine
        ),
        text: .init(
            primary:   textPrimary,
            secondary: textMuted,
            muted:     textMuted,
            inverse:   coolDarkAnchor
        ),
        accent: .init(
            primary:   bronze500,
            highlight: bronze300
        ),
        state: .init(
            success:  patina500,
            degraded: amber500,
            broken:   red500,
            warning:  amber500
        ),
        bell: .init(
            edge: bronze500
        ),
        focus: .init(
            paneBorder:         bronze500,
            paneBorderInactive: coolDarkLine
        ),
        keybar: .init(
            slotBg:         coolDarkPanel,
            slotBgPromoted: bronze500.alpha(0.12),
            slotBgArmed:    bronze500.alpha(0.20),
            slotBgLocked:   bronze500.alpha(0.30)
        ),
        predictor: .init(
            stripBg:        coolDarkPanel,
            suggestionBg:   coolDarkPanelHi,
            suggestionText: textPrimary
        ),
        banner: .init(
            amberBg:   amber500.alpha(0.15),
            redBg:     red500.alpha(0.15),
            neutralBg: coolDarkPanel
        ),
        terminal: .init(
            bg: "#0A0C10",
            fg: "#CFD6E4"
        )
    )
}
```

Two semantic tokens that should share a color reference the same private constant — drift-proof within a theme.

## Token registry (v1 starter set)

The categories and their tokens. Add new tokens as mockups demand them; never inline a hex value in consumer code.

| Category | Tokens |
|---|---|
| `surface` | `bg`, `panel`, `panelHigh`, `line` |
| `text` | `primary`, `secondary`, `muted`, `inverse` |
| `accent` | `primary`, `highlight` |
| `state` | `success`, `degraded`, `broken`, `warning` |
| `bell` | `edge` |
| `focus` | `paneBorder`, `paneBorderInactive` |
| `keybar` | `slotBg`, `slotBgPromoted`, `slotBgArmed`, `slotBgLocked` |
| `predictor` | `stripBg`, `suggestionBg`, `suggestionText` |
| `banner` | `amberBg`, `redBg`, `neutralBg` |
| `terminal` | `bg`, `fg` (chrome around the pane only; the ANSI palette is a separate axis, see Out of scope) |

The canonical token list lives here. `mockups/specs/design-system.html` becomes a rendered visualization (one swatch per token, resolved against the active theme).

## Theme switching

- Active theme held in `EnvironmentValues.theme`.
- Theme registry exposed as `Theme.all: [Theme]` (v1 contains only `bellBronze`).
- Picker UI lives in **App preferences → Appearance** as a row that opens a half-sheet of available themes. **Gated by Pro entitlement** — the row is shown only when more than one theme is registered AND the user has Pro, or shown disabled with an upgrade affordance when more than one theme is registered without Pro. In v1 the row is hidden entirely (only one theme exists; nothing to pick).
- No persistence outside iCloud sync (App preferences → iCloud sync covers the theme selection alongside other preferences).
- Theme change animates with a 200ms cross-fade; switching is a non-destructive operation.

## Existing mockup HTML

Existing mockup CSS variables (`--accent`, `--bg`, etc.) stay at palette level — they are reference artifacts, not consumer code. New mockups going forward use semantic CSS variable names that mirror the registry (`--accent-primary`, `--bell-edge`). No retrofit pass on the existing files.

## Out of scope (v1)

- **ANSI 16-color terminal palette** (and the 256-color cube). Strong user opinions (Solarized, Dracula, Gruvbox). Deferred — likely another Pro perk when alternative ANSI palettes are designed. The v1 ANSI palette is a single curated set tuned to Bell Bronze.
- **Light mode.** Bell Bronze is dark-only in v1. Light mode would be a sibling theme defined later — same plumbing.
- **User-authored themes.** Themes are app-shipped curated artifacts, not user-editable.
- **Per-host theme overrides.** Out of scope; could come back as a v1.5+ knob.

## Cross-spec consequences

- [[2026-06-16-pro-paid-scope-design]] — "alternative color themes when a second palette exists" now has clear plumbing. Pro entry gates the picker; the theme system itself is content-agnostic.
- [[2026-06-16-settings-sub-screens-design]] — App preferences gains an **Appearance** sub-section. In v1 it contains nothing visible (or "Theme: Bell Bronze" as a read-only row, designer's call). It becomes a real row when a second theme ships.
- [[2026-06-17-terminal-feedback-design]] — bell halo color references `bell.edge`.

## Related

- [[2026-06-16-pro-paid-scope-design]]
- [[2026-06-16-settings-sub-screens-design]]
- [[2026-06-17-terminal-feedback-design]]
