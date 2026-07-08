<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Nerd Font support in the terminal — design

**Date:** 2026-07-08
**Status:** Approved (brainstorming), pending implementation plan
**Related:** [Nerd Fonts TODO memory], Phase-4 Terminal Settings (deferred), `docs/superpowers/specs/*` Plan C terminal-UX.

## Goal

Let the terminal render Nerd Font glyphs — powerline separators (), Devicons,
file-type/Git icons, Font Awesome — instead of tofu (□). Ship a small curated set
of full (icon-patched) Nerd Fonts, default to one out of the box, let the user pick
a face, and let the user import their own `.ttf`/`.otf`.

## Decisions (locked during brainstorming)

- **Icon model: full patched fonts only.** Every bundled/imported face is expected to
  be a *full* Nerd Font with icons baked in. No symbols-only cascade / fallback layer.
  A plain (non-patched) font simply shows no icons — that is acceptable and expected.
- **Bundled curated set (2 fonts):** Hack Nerd Font, JetBrainsMono Nerd Font — both
  OFL/MIT-class, redistributable. Plus the current **system monospace** offered as a
  selectable no-icon face. (FiraCode was dropped — see "Mobile-first font selection".)
- **Default terminal face:** **Hack Nerd Font.**
- **Mobile-first font selection:** defaults are chosen for on-glass rendering, not
  desktop-monitor habits. Retina AA thins delicate strokes, the viewport is small, and
  code ligatures are *harder* to parse at small physical sizes — so the default is Hack
  (wide, sturdy strokes, strong `0/O/1/l/I` disambiguation, no ligatures). FiraCode was
  dropped specifically because its ligatures-on-by-default is a worse mobile first
  impression; dropping it also removes the ligature-rendering question entirely.
  One default everywhere — no per-device (iPhone vs iPad) branching.
- **User import:** document picker → register → persist an imported face.

## Non-goals (YAGNI)

- Per-host font overrides.
- Font weight/style selection, bold/italic Nerd variants.
- Symbols-only cascade / fallback layer (superseded by "full patched fonts only").
- Rebuilding the whole deferred Terminal Settings tree — we add only the minimal screen
  this feature needs.

## Two-tier split

Per repo rule: pure/testable logic → `Sources/SemicolynKit/` (Linux XCTest);
Apple/UIKit/font-registration/picker → `App/` (macOS-CI + manual verify).

## 1. Data model (SemicolynKit — Linux-tested)

Add a pure value type and a field on `TerminalSettings`:

```swift
public struct TerminalFont: Equatable, Sendable, Codable {
    public enum Kind: Equatable, Sendable, Codable {
        case system                 // SF Mono, no icons
        case bundled(String)        // PostScript name of a shipped Nerd Font
        case imported(String)       // PostScript name registered from user's .ttf/.otf
    }
    public var kind: Kind
    public var displayName: String  // shown in the picker row
}
```

- `TerminalSettings` gains `public var fontFace: TerminalFont`, defaulting to the
  **Hack** bundled case.
- **`BundledFont` registry** — plain data array of records
  `{ displayName, postScriptName, fileName, license }`, one per curated font. Lives in
  Kit so its shape is unit-testable. The default face MUST reference a registry entry.
- **Resolve-with-fallback (the real branching logic, in Kit):** given a `TerminalFont`
  and the registry, return the PostScript name to render with. For `.system` return a
  system sentinel. For `.bundled`/`.imported`, return the name; but if an `.imported`
  name is unknown/unresolvable at resolve time, **fall back to the default face's name**
  — never propagate an unrenderable name that would tofu the entire terminal. This is
  the unit under EP + boundary test.

Note: whether a `UIFont(name:)` actually exists is an Apple-tier concern (§2); Kit's
resolve is purely over the settings + registry (string-level), so it stays Linux-testable.

## 2. Font loading & registration (App tier — Apple-only)

New `App/TerminalFontProvider.swift` (a small singleton service):

- **Launch registration:** register the 3 bundled font files via
  `CTFontManagerRegisterFontsForURL`. Fonts ship as app resources; `project.yml`
  (XcodeGen) adds the resource files and the `UIAppFonts` Info.plist array.
- **`font(for: TerminalFont, size: CGFloat) -> UIFont` — the single resolver:**
  - `.system` → `UIFont.monospacedSystemFont(ofSize:weight:.regular)`.
  - `.bundled(name)` / `.imported(name)` → `UIFont(name: name, size:)`; if that returns
    nil, fall back to the Kit-resolved default's `UIFont`, and if *that* is somehow nil,
    to `monospacedSystemFont`. Never returns tofu-everything.
- **Import flow:** `UIDocumentPicker` (UTIs: `.ttf`, `.otf`) → copy the file into
  Application Support → `CTFontManagerRegisterFontsForURL` → read the PostScript name
  back from the registered graphic → persist a `.imported(postScriptName)` face with a
  human display name. All imported files are re-registered at each launch.

**Call-site change:** replace the 4 hardcoded
`UIFont.monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)` sites in
`App/TerminalScreen.swift` (2) and `App/TmuxPaneContainer.swift` (2) with
`TerminalFontProvider.shared.font(for: settings.fontFace, size: CGFloat(size))`.

## 3. Picker UI (App tier)

`App/TerminalFontPickerView.swift`, reachable from a minimal Terminal Settings screen:

- **Section: Bundled** — system + the 3 Nerd Fonts. Each row previews sample letters
  plus a couple of representative icons, drawn in that row's own face, so the user sees
  the letterforms and confirms icons render.
- **Section: Imported** — the user's imported faces (swipe-to-delete removes the face
  and its copied file) + an **"Import Font…"** button launching the document picker.
- Selecting a row writes `settings.fontFace`. The live terminal updates through the
  **existing** settings-change path that already re-applies `fontSize` on change (the
  `baseSize`/coordinator update in `TerminalScreen`/`TmuxPaneContainer`), extended to
  also re-resolve the face.

**Minimal Terminal Settings screen:** the broader Terminal Settings tree is deferred and
unbuilt. `App/SettingsView.swift` is a `List` of `NavigationLink` rows (Appearance →
`ThemePickerView`, Privacy, Diagnostics). We add a **"Terminal" row** (SF Symbol
`terminal`) pushing a new `App/TerminalSettingsView.swift`, which hosts the existing
font-size control + this font picker. Scoped to this feature, not the whole deferred tree;
follows the established row-pushes-detail-view pattern exactly.

## 4. Persistence

- **Correction:** `TerminalSettingsStore` is currently **in-memory only** — `fontSize`
  is not persisted today. This feature **adds persistence** to that store, mirroring
  `App/ThemeSettingsStore.swift` (a `@Published … { didSet { persist() } }` + a
  `UserDefaults` key loaded in `init`). We persist the whole `TerminalSettings` as a
  JSON-encoded `Codable` blob (so `fontSize` comes along for free), or minimally just the
  `fontFace`. `TerminalFont: Codable` serializes the face.
- Imported font files are copied into Application Support and survive relaunch; the
  persisted `.imported(name)` re-resolves after launch-time re-registration. If a
  previously-imported file is gone at launch, resolve-with-fallback (§1) quietly reverts
  that face to the default.

## 5. Testing

**Kit (Linux XCTest) — the real logic:**

- `TerminalFont` Codable round-trip for each `Kind` case (`.system`, `.bundled`,
  `.imported`) — assert the decoded value equals the original (round-trip, not tautology).
- **Resolve-with-fallback** (EP over the three Kinds + boundary):
  - `.system` → the system sentinel (exact).
  - `.bundled(known)` → that exact PostScript name.
  - `.imported(known)` → that exact name.
  - `.imported(unknown)` → **the default face's PostScript name** (assert the *specific*
    fallback name, not merely non-nil).
- `BundledFont` registry invariants: assert the exact expected count (3) and that the
  **default face's PostScript name is present in the registry** (guards "default points
  at a font we actually ship").

**Apple tier (macOS-CI + manual on build):** font file registration, provider resolution
against real registered fonts, picker selection, import round-trip, and — device only —
whether icons render (Hack default + JetBrainsMono).

## Ligatures — not applicable (FiraCode dropped)

FiraCode was the only ligature font under consideration; it was dropped in favor of Hack
(default) + JetBrainsMono, neither of which ships code ligatures. So there is no ligature
behavior to verify for this cut.

For the record, the SwiftTerm draw path *would* have supported ligatures: its default
CoreGraphics path (`Apple/AppleTerminalView.swift` `buildAttributedString` →
`CTLineCreateWithAttributedString`) batches consecutive same-attribute characters into one
`NSAttributedString` and never sets `kCTLigatureAttributeName = 0`, so CoreText's default
(ligatures on) applies. If a ligature font is ever re-introduced, ligatures are expected to
render (breaking only across attribute boundaries / `U+FE0E`-tagged symbols).

## Files touched

- `Sources/SemicolynKit/Terminal/TerminalSettings.swift` — add `TerminalFont`,
  `fontFace`, `BundledFont` registry, resolve-with-fallback.
- `Tests/SemicolynKitTests/…` — the Kit tests above.
- `App/TerminalFontProvider.swift` — new (registration + resolver + import).
- `App/TerminalFontPickerView.swift` — new (picker UI).
- `App/TerminalSettingsView.swift` — new (font-size + font picker); add a "Terminal"
  `NavigationLink` row to `App/SettingsView.swift`.
- `App/TerminalScreen.swift`, `App/TmuxPaneContainer.swift` — swap the 4 font call-sites.
- `App/TerminalSettingsStore.swift` — persist `fontFace`.
- `project.yml` — bundle the 2 font resources (Hack, JetBrainsMono) + `UIAppFonts`
  Info.plist entries.
- Font resource files (`.ttf`) + their license files (REUSE / per-font license).

## Licensing / REUSE

Each bundled font ships with its upstream license (OFL/MIT/Hack license) recorded per
REUSE requirements; the repo stays REUSE-compliant. Font files are third-party assets,
not GPL-3.0 source — license headers do not apply to the binaries; their own license
files travel with them.
