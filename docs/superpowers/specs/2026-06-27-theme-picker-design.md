<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Theme picker — design

**Date:** 2026-06-27
**Status:** Designed (pending implementation plan)
**Type:** App-tier UI + a small pure catalog/resolution layer. Introduces no new
`Theme` token *structure*; adds theme identity, a Pro-gate seam, persistence, and
the root injection that makes themes user-switchable.

## Context — why now

Two palettes now exist: `Theme.neonMidnight` (default, free) and
`Theme.bellBronze` (alternate), with `Theme.all = [.neonMidnight, .bellBronze]`.
Three locked specs converge here:

- **`2026-06-25-neon-midnight-theme-design.md`** deferred the "theme-picker
  Settings UI and Pro-gating" to Phase 4 — explicitly the work this spec covers.
- **`2026-06-16-settings-sub-screens-design.md`** cut Appearance *because only one
  palette existed* ("An inert one-option section is filler; revisit when a second
  theme actually exists"). That precondition is now met.
- **`2026-06-16-pro-paid-scope-design.md`** designates alternate themes a Pro
  cosmetic: "Pro themes light up the moment a second palette exists." Bell Bronze
  is that theme.

Two gaps make the feature impossible today:

1. **`Theme` has no identity** (no `id`/`name`) — a selection can't be persisted.
2. **Nobody injects `\.theme`** — ~20 views read `@Environment(\.theme)` but the
   root never sets it, so everyone gets the `ThemeKey.defaultValue`. The theme is
   not user-switchable at all yet.

## Scope decisions (locked for this slice)

- **Pro-gating: picker + Pro-gate *seam*, real StoreKit deferred.** Build the
  picker, live switching, persistence, and a minimal `ProStore` entitlement
  abstraction now. Bell Bronze renders as Pro-locked; the real purchase flow
  (StoreKit, restore, Supporter badge, alternate app icons) is a separate Pro
  slice, partly enrollment-gated.
- **Entry point: a new top-level Settings screen from `HostListView`.** Settings
  currently only exists mid-session via the Esc-pill `KeybarSettingsSheet`; a
  theme must be changeable outside a session. This slice establishes the missing
  top-level Settings home (matching the `settings-sub-screens` tree) with one row
  — Appearance — as the anchor for future Settings rows.

## Architecture

### Pure tier — `Sources/SemicolynKit/Theme/` (Linux-tested)

Keep `Theme` as pure color tokens. Add a thin catalog layer beside it (plain
value types + one pure function — the "plain registry, no magic" idiom):

- **`ThemeID`** — a `String`-raw-value newtype, mirroring `MacroID` /
  `CustomSlotID`. `Sendable`, `Equatable`, `Codable`. Stable raw values:
  `"neonMidnight"`, `"bellBronze"`.
- **`ThemeDescriptor`** — `struct { let id: ThemeID; let displayName: String;
  let isPro: Bool; let theme: Theme }`. `Equatable`, `Sendable`. Pairs a `Theme`
  with the catalog metadata the picker and gate need, without putting
  presentation/commerce concerns on `Theme` itself.
- **`Theme.catalog: [ThemeDescriptor]`** — ordered list, default first:
  - `ThemeDescriptor(id: "neonMidnight", displayName: "Neon Midnight", isPro: false, theme: .neonMidnight)`
  - `ThemeDescriptor(id: "bellBronze",  displayName: "Bell Bronze",   isPro: true,  theme: .bellBronze)`
  - `Theme.all` is re-derived as `catalog.map(\.theme)` so there is one source of
    order and membership. The existing `Theme.all` order assertion stays valid.
  - **`Theme.defaultDescriptor`** = `catalog[0]` (Neon Midnight). The free
    fallback used everywhere below.
- **`resolveTheme(selectedID:isPro:catalog:) -> Theme`** — the single pure gate
  decision (the `tmuxLaunchDecision` pattern). Rules, in order:
  1. Unknown `selectedID` (not in catalog) → default theme.
  2. Selected descriptor `isPro == true` and `isPro` argument `false` → default
     theme (Pro lapsed/never-bought can't render a locked theme).
  3. Otherwise → the selected descriptor's theme.

  A `resolveDescriptor(...)` sibling returning the `ThemeDescriptor` (for the UI's
  "what is actually applied" state) may share the same logic.

This keeps the gate enforced in pure, tested code — the UI cannot leak a locked
theme even if a stale Pro id is persisted.

### App tier — `App/` (Apple, macOS-CI-only)

- **`ProStore: ObservableObject`** (`@MainActor`) — the entitlement seam.
  `@Published private(set) var isPro: Bool`, backed by a UserDefaults key
  (`semicolyn.pro.isActive`), **default `false`**. Exposes a debug
  `setProForDebug(_:)` (or a `#if DEBUG` toggle) so the Simulator pass and the
  upgrade-screen placeholder can flip it without StoreKit. The real Pro slice
  replaces the backing (StoreKit transaction listener) behind this same surface;
  consumers (`SemicolynApp`, `ThemePickerView`) are unchanged.
- **`ThemeSettingsStore: ObservableObject`** (`@MainActor`) — mirrors
  `KeybarSettingsStore`. `@Published var selectedThemeID: ThemeID { didSet { persist() } }`,
  persisted as the raw string under `semicolyn.appearance.themeID`. Loads with a
  decode-failure fallback to `Theme.defaultDescriptor.id` (a bad/old blob never
  bricks theming). `resetToDefault()` restores Neon Midnight.
- **`AppStores.shared`** gains `let pro = ProStore()` and
  `let appearance = ThemeSettingsStore()`.
- **Root injection — `SemicolynApp`.** Replace the bare `HostListView()` with a
  small root view that observes `appearance` + `pro`, computes
  `resolveTheme(selectedID: appearance.selectedThemeID, isPro: pro.isPro)`, and
  applies `.environment(\.theme, resolved)`. This is the wire that makes every
  existing `@Environment(\.theme)` consumer switch live.
- **Property-passed themes.** `TerminalScreen` (`var theme: Theme = .neonMidnight`)
  and `TmuxPaneContainer` take `theme` as a property, not from the environment.
  Their call sites in `SessionView` must pass the resolved theme (read from the
  environment or the stores) so the terminal surface recolors with the rest.

### UI

- **`SettingsView`** — new top-level screen. A gear `ToolbarItem` on
  `HostListView` presents it (sheet with an internal `NavigationStack`, matching
  `KeybarSettingsSheet`'s idiom; "Done" dismisses). One row for this slice:
  `NavigationLink("Appearance", systemImage: "paintpalette") → ThemePickerView`.
- **`ThemePickerView`** — a `List` over `Theme.catalog`:
  - Each row: a **swatch** (small composite of `accent.primary` / `surface.bg` /
    `terminal.fg`), the `displayName`, a trailing **checkmark** on the currently
    *applied* theme (per `resolveDescriptor`), and a **✦Pro** badge on locked
    rows (`isPro && !pro.isPro`).
  - Tapping an **unlocked** row sets `appearance.selectedThemeID` → root recolors
    live.
  - Tapping a **locked** row does **not** change selection; it pushes
    `ProUpgradeView`.
- **`ProUpgradeView`** (placeholder) — the "Semicolyn Pro" screen shape from the
  Pro spec: the "free stays free" framing line, the exact perks list
  (Alternative app icons / Alternative color themes / Supporter badge), and a
  **stubbed** CTA (disabled "Unlock Semicolyn Pro — coming soon"). Under `#if
  DEBUG`, an "Unlock (debug)" button flips `ProStore` so the gate path is
  testable end-to-end on the Simulator. The real StoreKit CTA, Restore, Family
  Sharing note, and Supporter badge land in the Pro slice.

## Data flow

```
ThemeSettingsStore.selectedThemeID ─┐
                                    ├─► resolveTheme(id, isPro) ─► .environment(\.theme)
ProStore.isPro ─────────────────────┘            (pure)              │
                                                                     ▼
                                            ~20 @Environment(\.theme) consumers
                                            + SessionView → TerminalScreen/TmuxPaneContainer (property)
```

Selecting a theme mutates `selectedThemeID` → persisted → root recomputes
`resolveTheme` → environment value changes → SwiftUI re-renders all consumers.

## Error / edge handling

- **Stale Pro id, Pro inactive:** `resolveTheme` returns the default; the picker
  still shows the row selected-but-locked is *not* applied (checkmark sits on the
  default). Selection persists so re-purchasing Pro re-applies it without the user
  re-picking. (The picker shows the persisted choice's lock state; the checkmark
  follows `resolveDescriptor`, i.e. what's actually rendered.)
- **Unknown/old persisted id:** decode/lookup fallback → default theme.
- **Decode failure of the UserDefaults blob:** fallback to default id; never
  crash.

## Flagged risk — SwiftTerm live recolor

Chrome, keybar, panes, and banners recolor live via `@Environment`. The terminal
**content** colors (`theme.terminal.bg/fg`) flow into SwiftTerm, which may cache
its color attributes and not repaint on a pure SwiftUI value change. The
implementation must verify on the Simulator pass whether SwiftTerm picks up new
bg/fg; if not, apply a SwiftTerm reconfigure (e.g. re-set its color attributes on
theme change) or, worst case, document that terminal colors apply on next
render/reconnect while chrome updates immediately. This is a verification item,
not a blocker on the picker itself.

## Testing

**Pure (Linux, `swift test --filter ThemeTests` / a new `ThemePickerTests`):**
- Catalog invariants: ids unique; `catalog[0].id == "neonMidnight"` and
  `isPro == false`; `bellBronze` present with `isPro == true`; `Theme.all ==
  catalog.map(\.theme)`.
- `resolveTheme` equivalence partitions (assert the *specific* resolved theme,
  not just "non-nil"):
  - (`neonMidnight`, isPro: false) → `.neonMidnight`
  - (`neonMidnight`, isPro: true)  → `.neonMidnight`
  - (`bellBronze`,   isPro: true)  → `.bellBronze`
  - (`bellBronze`,   isPro: false) → `.neonMidnight`  *(gate fallback — the
    security-relevant case)*
  - (unknown id,     isPro: true)  → `.neonMidnight`  *(fallback)*
- `ThemeID` Codable round-trip; raw values are the stable strings.

**App (macOS CI compile + Simulator interaction pass):**
- Gear → Settings → Appearance → picker renders both rows with swatches.
- Selecting Neon Midnight vs Bell Bronze (with debug-Pro on) recolors chrome
  live; with debug-Pro off, Bell Bronze shows ✦Pro and routes to the upgrade
  placeholder without changing selection.
- The SwiftTerm live-recolor check above.
- `ThemeSettingsStore` selection survives relaunch.

## Out of scope (own slices)

- **Real StoreKit Pro** — purchase, restore, Family Sharing, Supporter badge,
  alternate app icons. Tracked in `2026-06-16-pro-paid-scope-design.md`.
- **Rest of the Settings tree** — Security, the other App-preferences rows
  (Keybar passthrough already exists mid-session, iCloud sync, Haptics), About &
  Help. Each per `2026-06-16-settings-sub-screens-design.md`; this slice adds only
  the Settings shell + Appearance.
- **Light mode / follow-system appearance.** Both palettes are dark; no light
  variant exists.
- **Per-host / per-session theme overrides.** Single app-wide theme.
- **New palettes** beyond the two that exist.

## Implementation surface (summary)

- **Create** `Sources/SemicolynKit/Theme/ThemeCatalog.swift` — `ThemeID`,
  `ThemeDescriptor`, `Theme.catalog`, `Theme.defaultDescriptor`, `resolveTheme` /
  `resolveDescriptor`. Re-derive `Theme.all` from `catalog`.
- **Create** `App/ProStore.swift`, `App/ThemeSettingsStore.swift`.
- **Create** `App/SettingsView.swift`, `App/ThemePickerView.swift`,
  `App/ProUpgradeView.swift`.
- **Modify** `App/AppStores.swift` (add `pro`, `appearance`),
  `App/SemicolynApp.swift` (root view + environment injection),
  `App/HostListView.swift` (gear toolbar item), `App/SessionView.swift` (pass
  resolved theme to `TerminalScreen`/`TmuxPaneContainer`).
- **Tests** `Tests/SemicolynKitTests/` — catalog + `resolveTheme` + `ThemeID`
  round-trip (extend `ThemeTests` or add `ThemePickerTests`).

## References

- `Sources/SemicolynKit/Theme/Theme.swift`, `ThemeEnvironment.swift`,
  `NeonMidnightTheme.swift`, `BellBronzeTheme.swift`.
- `docs/superpowers/specs/2026-06-25-neon-midnight-theme-design.md`
- `docs/superpowers/specs/2026-06-16-settings-sub-screens-design.md`
- `docs/superpowers/specs/2026-06-16-pro-paid-scope-design.md`
- Settings-sheet idiom: `App/Keybar/KeybarEditorView.swift`
  (`KeybarSettingsSheet`). Store idiom: `App/KeybarSettingsStore.swift`.
