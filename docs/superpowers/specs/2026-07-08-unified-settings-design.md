<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Unified Settings — one screen, context-aware (topics B + C + D)

**Date:** 2026-07-08
**Status:** Approved (brainstorming), pending implementation plan
**Related:** `App/SettingsView.swift`, `App/HostListView.swift`, `App/Keybar/KeybarEditorView.swift`
(`KeybarSettingsSheet`), `App/DefaultsEditorView.swift`.

## Problem

The app has **four disconnected settings surfaces**, which confuses users (topics B, C, D):

1. **Defaults** — host-list toolbar `slider.horizontal.3` → `DefaultsEditorView` (global
   per-connection SSH/terminal/Mosh/Tailscale config every host inherits).
2. **Settings** — host-list toolbar `gearshape` → `SettingsView` (Appearance, Terminal,
   Privacy, Diagnostics).
3. **Long-press-Esc menu** — `KeybarSettingsSheet` (Keybar editor + Launcher/Macros),
   in-session only.
4. In-session command shortcuts (out of scope here).

Two toolbar icons that both look like "settings" open unrelated domains (topic C), and the
Esc menu is a *different* set of options from the pre-connect menus (topic D).

## Goal

**One unified `SettingsView`** that hosts every section, reachable from both the pre-connect
host list and in-session (long-press Esc). Sections that don't apply in the current context
are **dimmed/disabled** rather than hidden. The two host-list icons merge into one.

## Decisions (locked during brainstorming)

- **One unified screen, all sections.** Connection Defaults becomes a normal section/row
  alongside the others (not visually segregated).
- **Context-aware dimming:** `Keybar` and `Launcher/Macros` edit the LIVE session's input
  surface, so they are **dimmed + disabled pre-connect** and **enabled in-session**. Every
  other section is always enabled.
- **Long-press Esc opens the SAME unified `SettingsView`** (at its root — top-level list, not
  deep-linked), making the Esc menu and the host-list gear literally identical.
- **Both entry points open the top-level list** (no deep-link, no last-section memory).
- **Merge the two host-list icons into one** (`gearshape` only); Defaults moves inside
  Settings.
- **The enablement rule is a pure `SemicolynKit` function with Linux tests** (mirrors the
  `tmuxLaunchDecision`-pure pattern).

## Non-goals (YAGNI)

- Reworking any leaf screen (`ThemePickerView`, `TerminalSettingsView`, `DefaultsEditorView`,
  `KeybarEditorView`, `MacroLibraryView`, `PrivacySettingsView`, `DiagnosticsSettingsView`) —
  all reused unchanged.
- Deep-linking / remembering last section.
- In-session command-shortcut consolidation (surface #4).
- Any new persistence or store.

## Architecture

### 1. Kit: the enablement rule (Linux-tested)

`Sources/SemicolynKit/Settings/SettingsSection.swift` (new), pure value types + rule:

```swift
public enum SettingsContext: Equatable, Sendable { case preConnect, inSession }

public enum SettingsSection: String, CaseIterable, Sendable {
    case appearance, terminal, keybar, launcher, defaults, privacy, diagnostics
}

public enum SettingsGate {
    /// Whether a section is interactive in the given context. Keybar + Launcher
    /// edit the live session input surface, so they are disabled pre-connect.
    public static func isEnabled(_ section: SettingsSection, in context: SettingsContext) -> Bool {
        switch section {
        case .keybar, .launcher: return context == .inSession
        default:                 return true
        }
    }
}
```

Linux XCTest: every `(section × context)` pair asserts the exact expected `Bool` (EP over
both partitions; the two session-only sections are the boundary). This is the one piece of
real branching logic.

### 2. App: the unified `SettingsView`

`App/SettingsView.swift` gains parameters and renders all seven rows:

```swift
struct SettingsView: View {
    let context: SettingsContext
    @ObservedObject var keybarSettings: KeybarSettingsStore
    // …existing @Environment(\.dismiss)…
}
```

Row set (order): Appearance → `ThemePickerView`; Terminal → `TerminalSettingsView`;
Keybar → `KeybarEditorView(store: keybarSettings)`; Launcher → `MacroLibraryView(store: keybarSettings)`;
Connection Defaults → `DefaultsEditorView`; Privacy → `PrivacySettingsView`;
Diagnostics → `DiagnosticsSettingsView`. Each row uses `SettingsGate.isEnabled(section, in: context)`
to drive `.disabled(!enabled)` + a dimmed (`.foregroundStyle(.secondary)` / reduced-opacity
label) style when disabled. `InputClickFeedback.play()` on the Done button (existing pattern).

### 3. App: merge the host-list icons

`App/HostListView.swift` — Defaults moves entirely inside Settings, so **remove ALL three of
its host-list shortcuts** (locked decision):
1. the toolbar `slider.horizontal.3` "Defaults" button,
2. the top-of-host-list "Defaults" row (`hostList` first row),
3. the empty-state "Edit defaults" button,

plus the now-unused `showingDefaults` state and its
`.sheet(isPresented: $showingDefaults) { DefaultsEditorView() }`. Keep the `gearshape` button;
its sheet presents
`SettingsView(context: .preConnect, keybarSettings: AppStores.shared.keybarSettings)`.
Defaults is reachable only via Settings → Connection Defaults (gear → row, 2 taps). This fully
resolves the "too many settings entry points" problem (topic C).

### 4. App: long-press Esc → unified Settings

`App/Keybar/KeybarView.swift` — its `showingSettings` sheet currently presents
`KeybarSettingsSheet(store: keybarSettings)`. Change it to
`SettingsView(context: .inSession, keybarSettings: keybarSettings)`. **Delete
`KeybarSettingsSheet`** (`App/Keybar/KeybarEditorView.swift:9-32`). The Esc menu is now the
same unified screen at its root, with Keybar + Launcher enabled (in-session).

## Data flow

`SettingsContext` (Kit) is passed by the presenter: `HostListView` passes `.preConnect`,
`KeybarView` passes `.inSession`. `SettingsView` asks `SettingsGate.isEnabled(...)` per row to
decide enabled/dimmed. All leaf destinations already exist and are reused. No new store or
persistence.

## What is deleted / simplified

- `KeybarSettingsSheet` struct (superseded by the unified `SettingsView`).
- ALL three `HostListView` Defaults shortcuts (toolbar icon, top-of-list row, empty-state
  button) + the `showingDefaults` state + its sheet. Defaults lives only inside Settings now.

## Error handling / edge cases

- Tapping a dimmed row does nothing (`.disabled`). No navigation, no crash.
- In-session, all rows enabled; the Keybar/Launcher leaves mutate the live keybar as they do
  today.
- The `SettingsView` `context`/`keybarSettings` are required (no defaults) so every call-site
  is explicit; the compiler enforces both presenters pass them.

## Testing

- **Kit (Linux XCTest):** `SettingsGate.isEnabled` — assert the exact `Bool` for every
  `SettingsSection × SettingsContext` pair (7 × 2 = 14 cases). Keybar/Launcher `.preConnect`
  → `false`; everything else → `true`; all `.inSession` → `true`. Real values, no tautology.
- **App tier (macOS CI + device/simulator):** both entry points open the same `SettingsView`;
  Keybar + Launcher dimmed + non-tappable pre-connect and enabled in-session; Connection
  Defaults reachable inside Settings; the second host-list icon is gone; long-press Esc opens
  the unified screen; no leaf screen regressed.

## Files touched (anticipated)

- `Sources/SemicolynKit/Settings/SettingsSection.swift` — new (context/section/gate).
- `Tests/SemicolynKitTests/SettingsGateTests.swift` — new (14-case table).
- `App/SettingsView.swift` — add `context` + `keybarSettings`; render all 7 rows with dimming.
- `App/HostListView.swift` — remove all 3 Defaults shortcuts (toolbar icon, list row,
  empty-state button) + `showingDefaults` state + sheet; gear opens
  `SettingsView(context: .preConnect, …)`.
- `App/Keybar/KeybarView.swift` — `showingSettings` sheet → `SettingsView(context: .inSession, …)`.
- `App/Keybar/KeybarEditorView.swift` — delete `KeybarSettingsSheet`.
