<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Theme Picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user switch between the Neon Midnight (free) and Bell Bronze (Pro-gated) themes from a new top-level Settings screen, with the choice persisted and applied live across the app.

**Architecture:** A small pure catalog layer in `SemicolynKit` (`ThemeID`, `ThemeDescriptor`, `Theme.catalog`, and a pure `resolveTheme`/`resolveDescriptor` gate function) is the single source of truth for theme identity and Pro-gating. The App tier adds two `ObservableObject` stores (`ThemeSettingsStore` for the persisted selection, `ProStore` as a stub entitlement seam), a root view that resolves the active theme and injects it into `\.theme`, and the Settings → Appearance → Theme picker UI plus a placeholder upgrade screen.

**Tech Stack:** Swift 6 (SemicolynKit, strict concurrency, Linux-tested) · SwiftUI (App tier, macOS-CI + Simulator-verified) · XCTest · UserDefaults persistence · XcodeGen.

## Global Constraints

- **Two tiers, two test surfaces.** `Sources/SemicolynKit/` is pure, Linux-tested, no `import SwiftUI`/`UIKit`/`CryptoKit`. `App/` is Apple-only, validated by macOS CI + a manual Simulator pass — it does NOT compile on Linux and is invisible to `swift test`. Keep gate/identity logic in `SemicolynKit`; keep `App/` a thin wiring layer.
- **Every source file carries an SPDX header:** `// SPDX-FileCopyrightText: 2026 True Positive LLC` then `// SPDX-License-Identifier: GPL-3.0-only` (REUSE-compliant).
- **Pro-gate is enforced in pure code.** `resolveTheme` must fall back to the free default when a Pro theme is selected while `isPro == false`, or the id is unknown. The UI must not be able to leak a locked theme.
- **Free default = Neon Midnight** (`Theme.catalog[0]`, `isPro: false`). **Bell Bronze** is `isPro: true`. Stable `ThemeID` raw values: `"neonMidnight"`, `"bellBronze"`.
- **No real StoreKit in this slice.** `ProStore` is a UserDefaults-backed stub (default not-Pro) with a `#if DEBUG` flip; the upgrade screen's purchase CTA is stubbed.
- **Tests must be real** (`2026-06-18-testing-standards-design.md`): assert specific resolved values, not "non-nil"; the gate-fallback case is the security-relevant negative test.
- **Conventional commits**, feature branch `feat/theme-picker` (already created), squash-merge to `main`.
- **Build/test commands** (no host Swift toolchain): `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter <Suite>` for SemicolynKit; App-tier changes verify on the macOS CI job + a Simulator pass.
- **New files need no `project.yml` edit** — the App target globs `sources: - App` and the SwiftPM package globs `Sources/`; just `xcodegen generate` (CI does this).

---

### Task 1: Pure theme catalog + Pro-gate resolution

**Files:**
- Create: `Sources/SemicolynKit/Theme/ThemeCatalog.swift`
- Modify: `Sources/SemicolynKit/Theme/BellBronzeTheme.swift:42` (re-derive `Theme.all` from the catalog)
- Test: `Tests/SemicolynKitTests/ThemeCatalogTests.swift`

**Interfaces:**
- Consumes: existing `Theme`, `Theme.neonMidnight`, `Theme.bellBronze`.
- Produces:
  - `public struct ThemeID: Hashable, Sendable, Codable { public let raw: String; public init(_ raw: String) }`
  - `public struct ThemeDescriptor: Equatable, Sendable { public let id: ThemeID; public let displayName: String; public let isPro: Bool; public let theme: Theme }`
  - `public static let Theme.catalog: [ThemeDescriptor]`
  - `public static var Theme.defaultDescriptor: ThemeDescriptor`
  - `public func resolveDescriptor(selectedID: ThemeID, isPro: Bool, catalog: [ThemeDescriptor] = Theme.catalog) -> ThemeDescriptor`
  - `public func resolveTheme(selectedID: ThemeID, isPro: Bool, catalog: [ThemeDescriptor] = Theme.catalog) -> Theme`

- [ ] **Step 1: Write the failing tests**

Create `Tests/SemicolynKitTests/ThemeCatalogTests.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ThemeCatalogTests: XCTestCase {
    func testCatalogOrderAndFlags() {
        XCTAssertEqual(Theme.catalog.count, 2)
        XCTAssertEqual(Theme.catalog[0].id, ThemeID("neonMidnight"))
        XCTAssertFalse(Theme.catalog[0].isPro)
        XCTAssertEqual(Theme.catalog[0].theme, .neonMidnight)
        XCTAssertEqual(Theme.catalog[1].id, ThemeID("bellBronze"))
        XCTAssertTrue(Theme.catalog[1].isPro)
        XCTAssertEqual(Theme.catalog[1].theme, .bellBronze)
    }

    func testCatalogIDsAreUnique() {
        let ids = Theme.catalog.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testDefaultDescriptorIsFirstAndFree() {
        XCTAssertEqual(Theme.defaultDescriptor.id, ThemeID("neonMidnight"))
        XCTAssertFalse(Theme.defaultDescriptor.isPro)
    }

    func testAllDerivesFromCatalog() {
        XCTAssertEqual(Theme.all, Theme.catalog.map(\.theme))
    }

    // Gate: free theme always applies.
    func testResolveFreeThemeAlwaysApplies() {
        XCTAssertEqual(resolveTheme(selectedID: ThemeID("neonMidnight"), isPro: false), .neonMidnight)
        XCTAssertEqual(resolveTheme(selectedID: ThemeID("neonMidnight"), isPro: true), .neonMidnight)
    }

    // Gate: pro theme applies only with Pro.
    func testResolveProThemeWithProApplies() {
        XCTAssertEqual(resolveTheme(selectedID: ThemeID("bellBronze"), isPro: true), .bellBronze)
    }

    // Gate negative (security-relevant): pro theme without Pro falls back to default.
    func testResolveProThemeWithoutProFallsBackToDefault() {
        XCTAssertEqual(resolveTheme(selectedID: ThemeID("bellBronze"), isPro: false), .neonMidnight)
    }

    // Gate negative: unknown id falls back to default.
    func testResolveUnknownIDFallsBackToDefault() {
        XCTAssertEqual(resolveTheme(selectedID: ThemeID("does-not-exist"), isPro: true), .neonMidnight)
    }

    // resolveDescriptor reports the *applied* identity (not the raw selection).
    func testResolveDescriptorReportsAppliedIdentityOnLockedTheme() {
        let applied = resolveDescriptor(selectedID: ThemeID("bellBronze"), isPro: false)
        XCTAssertEqual(applied.id, ThemeID("neonMidnight"))
    }

    func testThemeIDCodableRoundTrip() throws {
        let original = ThemeID("bellBronze")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ThemeID.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ThemeCatalogTests`
Expected: FAIL — compile error, `ThemeID` / `ThemeDescriptor` / `Theme.catalog` / `resolveTheme` are undefined.

- [ ] **Step 3: Create the catalog source**

Create `Sources/SemicolynKit/Theme/ThemeCatalog.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Stable identifier for a theme in the catalog. A thin `String` wrapper (matching
/// `MacroID` / `CustomSlotID`) so the pure tier stays deterministic and the App can
/// persist the raw value directly.
public struct ThemeID: Hashable, Sendable, Codable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}

/// A `Theme` plus the catalog metadata the picker and Pro-gate need. Keeps
/// presentation/commerce concerns off the pure `Theme` token set.
public struct ThemeDescriptor: Equatable, Sendable {
    public let id: ThemeID
    public let displayName: String
    public let isPro: Bool
    public let theme: Theme

    public init(id: ThemeID, displayName: String, isPro: Bool, theme: Theme) {
        self.id = id
        self.displayName = displayName
        self.isPro = isPro
        self.theme = theme
    }
}

extension Theme {
    /// Ordered theme catalog — the free default first. Single source of truth for
    /// both the picker's order and `Theme.all`.
    public static let catalog: [ThemeDescriptor] = [
        ThemeDescriptor(id: ThemeID("neonMidnight"), displayName: "Neon Midnight",
                        isPro: false, theme: .neonMidnight),
        ThemeDescriptor(id: ThemeID("bellBronze"), displayName: "Bell Bronze",
                        isPro: true, theme: .bellBronze),
    ]

    /// The free default descriptor (first in the catalog).
    public static var defaultDescriptor: ThemeDescriptor { catalog[0] }
}

/// Resolves the descriptor that should actually be applied, enforcing the
/// Pro-gate: a Pro theme requires `isPro`, otherwise it falls back to the free
/// default; an unknown id also falls back. This is the single gate decision — the
/// UI cannot leak a locked theme even with a stale persisted id.
public func resolveDescriptor(
    selectedID: ThemeID,
    isPro: Bool,
    catalog: [ThemeDescriptor] = Theme.catalog
) -> ThemeDescriptor {
    guard let descriptor = catalog.first(where: { $0.id == selectedID }) else {
        return Theme.defaultDescriptor
    }
    if descriptor.isPro && !isPro {
        return Theme.defaultDescriptor
    }
    return descriptor
}

/// Convenience: the resolved `Theme` to apply (see `resolveDescriptor`).
public func resolveTheme(
    selectedID: ThemeID,
    isPro: Bool,
    catalog: [ThemeDescriptor] = Theme.catalog
) -> Theme {
    resolveDescriptor(selectedID: selectedID, isPro: isPro, catalog: catalog).theme
}
```

- [ ] **Step 4: Re-derive `Theme.all` from the catalog**

In `Sources/SemicolynKit/Theme/BellBronzeTheme.swift`, replace line 42:

```swift
    public static let all: [Theme] = [.neonMidnight, .bellBronze]
```

with:

```swift
    public static let all: [Theme] = catalog.map(\.theme)
```

(The existing `testRegistryHasNeonMidnightDefaultThenBellBronze` in `ThemeTests` still passes — count 2, first Neon Midnight, last Bell Bronze.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ThemeCatalogTests`
Expected: PASS (all 10 tests).

- [ ] **Step 6: Run the full SemicolynKit theme suite for regressions**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ThemeTests`
Expected: PASS (the existing `ThemeTests`, incl. the registry-order test, still green).

- [ ] **Step 7: Commit**

```bash
git add Sources/SemicolynKit/Theme/ThemeCatalog.swift Sources/SemicolynKit/Theme/BellBronzeTheme.swift Tests/SemicolynKitTests/ThemeCatalogTests.swift
git commit -m "feat(theme): pure theme catalog + Pro-gate resolution"
```

---

### Task 2: App-tier stores — selected theme + Pro entitlement seam

**Files:**
- Create: `App/ThemeSettingsStore.swift`
- Create: `App/ProStore.swift`
- Modify: `App/AppStores.swift:23-25` (register the two stores)

**Interfaces:**
- Consumes: `ThemeID`, `Theme.defaultDescriptor` (Task 1).
- Produces:
  - `@MainActor final class ThemeSettingsStore: ObservableObject { @Published var selectedThemeID: ThemeID; func resetToDefault() }`
  - `@MainActor final class ProStore: ObservableObject { @Published private(set) var isPro: Bool; #if DEBUG func setProForDebug(_:) #endif }`
  - `AppStores.shared.appearance: ThemeSettingsStore`, `AppStores.shared.pro: ProStore`

> **Note:** App-tier files do not compile on Linux and have no XCTest. Verification is the macOS CI build + the Simulator pass in Task 5. Each App task ends by committing; the build signal arrives on CI.

- [ ] **Step 1: Create `ProStore`**

Create `App/ProStore.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The Pro-entitlement seam. v1 is a stub backed by `UserDefaults` (default
/// not-active) with a `#if DEBUG` flip so the Simulator pass can exercise the gate
/// and the unlock path without StoreKit. The real StoreKit slice replaces the
/// backing behind this same surface; consumers (`RootView`, the picker, the
/// upgrade screen) do not change.
@MainActor final class ProStore: ObservableObject {
    private static let defaultsKey = "semicolyn.pro.isActive"

    @Published private(set) var isPro: Bool

    init() {
        self.isPro = UserDefaults.standard.bool(forKey: Self.defaultsKey)
    }

    #if DEBUG
    /// Debug-only: flip Pro state to test the gate end-to-end. Removed when real
    /// StoreKit lands.
    func setProForDebug(_ active: Bool) {
        isPro = active
        UserDefaults.standard.set(active, forKey: Self.defaultsKey)
    }
    #endif
}
```

- [ ] **Step 2: Create `ThemeSettingsStore`**

Create `App/ThemeSettingsStore.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SemicolynKit

/// App-lifetime holder for the user's selected theme id. Persists the raw id
/// string in `UserDefaults` (mirrors `KeybarSettingsStore`); the root view
/// resolves it through `resolveTheme(...)` against Pro state and injects the
/// result into the environment. A missing key falls back to the free default.
@MainActor final class ThemeSettingsStore: ObservableObject {
    private static let defaultsKey = "semicolyn.appearance.themeID"

    @Published var selectedThemeID: ThemeID {
        didSet { persist() }
    }

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.defaultsKey) {
            self.selectedThemeID = ThemeID(raw)
        } else {
            self.selectedThemeID = Theme.defaultDescriptor.id
        }
    }

    /// Restores the free default (Neon Midnight).
    func resetToDefault() {
        selectedThemeID = Theme.defaultDescriptor.id
    }

    private func persist() {
        UserDefaults.standard.set(selectedThemeID.raw, forKey: Self.defaultsKey)
    }
}
```

- [ ] **Step 3: Register both on `AppStores`**

In `App/AppStores.swift`, after the existing `keybarSettings` property (line 25), add:

```swift
    /// User-selected theme id (Appearance), persisted. The root view resolves it
    /// through the Pro-gate and injects the result into `\.theme`.
    let appearance = ThemeSettingsStore()
    /// Pro entitlement (stub seam; real StoreKit is a later slice).
    let pro = ProStore()
```

- [ ] **Step 4: Sanity-check the diff**

Run: `git diff --stat`
Expected: two new files under `App/`, one modified `App/AppStores.swift`. (No Linux build — these are App-tier; CI compiles them.)

- [ ] **Step 5: Commit**

```bash
git add App/ProStore.swift App/ThemeSettingsStore.swift App/AppStores.swift
git commit -m "feat(theme): app stores for theme selection + Pro entitlement seam"
```

---

### Task 3: Root injection — make the theme live and app-wide

**Files:**
- Modify: `App/SemicolynApp.swift` (root view that resolves + injects `\.theme`)
- Verify: `App/SessionView.swift:45,83` (terminal surface already reads env theme)

**Interfaces:**
- Consumes: `AppStores.shared.appearance`, `AppStores.shared.pro`, `resolveTheme(...)` (Tasks 1–2).
- Produces: a `RootView` that injects `.environment(\.theme, resolved)` so all `@Environment(\.theme)` consumers recolor live.

- [ ] **Step 1: Replace the app root with a resolving root view**

Replace the entire contents of `App/SemicolynApp.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

@main
struct SemicolynApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Observes the appearance + Pro stores, resolves the active theme through the
/// pure gate, and injects it into the environment so every `@Environment(\.theme)`
/// consumer recolors live. (Before this, nothing injected `\.theme`, so the app
/// was stuck on the default — this is the wire that makes themes switchable.)
private struct RootView: View {
    @ObservedObject private var appearance = AppStores.shared.appearance
    @ObservedObject private var pro = AppStores.shared.pro

    var body: some View {
        HostListView()
            .environment(\.theme,
                         resolveTheme(selectedID: appearance.selectedThemeID,
                                      isPro: pro.isPro))
    }
}
```

- [ ] **Step 2: Verify the terminal surface consumes the env theme**

`App/SessionView.swift` already declares `@Environment(\.theme) private var theme` (line 18) and passes `theme: theme` to `TmuxPaneContainer` (line 45). Confirm `TerminalScreen(...)` at line 83 is similarly fed the env `theme` (it takes `var theme: Theme`); if the call omits it, add `theme: theme,` to the `TerminalScreen(...)` initializer call so the raw-PTY terminal surface recolors with the rest.

Run: `grep -n "TerminalScreen(" App/SessionView.swift`
Expected: the `TerminalScreen(...)` call includes a `theme: theme` argument (add it if missing).

- [ ] **Step 3: Commit**

```bash
git add App/SemicolynApp.swift App/SessionView.swift
git commit -m "feat(theme): inject resolved theme at app root for live switching"
```

---

### Task 4: Settings shell + Appearance entry from the host list

**Files:**
- Create: `App/SettingsView.swift`
- Modify: `App/HostListView.swift` (gear toolbar button + sheet)

**Interfaces:**
- Consumes: `ThemePickerView` (Task 5 — forward reference; create a minimal stub here is NOT needed because Task 5 lands the view; if executing strictly in order, Task 5 follows immediately).
- Produces: `struct SettingsView: View` presented as a sheet; a gear button on `HostListView`.

> **Ordering note:** `SettingsView` references `ThemePickerView` (Task 5). Implement Task 4 and Task 5 back-to-back; the macOS CI build only needs both present. If a reviewer builds after Task 4 alone it will not compile — that is expected; the deliverable boundary is "Settings reachable with a working picker" across Tasks 4+5.

- [ ] **Step 1: Create `SettingsView`**

Create `App/SettingsView.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// Top-level Settings, presented as a sheet from the host list. v1 surfaces one
/// row — Appearance; it is the anchor for the future Settings tree (Security, App
/// preferences, About & Help — see the settings-sub-screens spec).
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    ThemePickerView()
                } label: {
                    Label("Appearance", systemImage: "paintpalette")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
```

- [ ] **Step 2: Add the gear button + sheet to `HostListView`**

In `App/HostListView.swift`, add a state flag with the other `@State` declarations (near line 19):

```swift
    /// Whether the top-level Settings sheet is presented.
    @State private var showingSettings = false
```

Add a gear `ToolbarItem` inside the `.toolbar { ... }` block, alongside the existing leading Defaults button (after the `slider.horizontal.3` `ToolbarItem`):

```swift
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
```

Add the sheet alongside the existing `.sheet(isPresented: $showingDefaults)` modifier:

```swift
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
```

- [ ] **Step 3: Commit (with Task 5 — see ordering note)**

```bash
git add App/SettingsView.swift App/HostListView.swift
git commit -m "feat(theme): top-level Settings shell + Appearance entry"
```

---

### Task 5: Theme picker + placeholder upgrade screen

**Files:**
- Create: `App/ThemePickerView.swift`
- Create: `App/ProUpgradeView.swift`

**Interfaces:**
- Consumes: `Theme.catalog`, `ThemeDescriptor`, `ThemeID`, `resolveDescriptor` (Task 1); `AppStores.shared.appearance`, `AppStores.shared.pro` (Task 2); `Color(_:)` from `ThemeEnvironment.swift`.
- Produces: `struct ThemePickerView: View`, `struct ProUpgradeView: View`.

- [ ] **Step 1: Create the upgrade placeholder**

Create `App/ProUpgradeView.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// Placeholder "Semicolyn Pro" screen — the Pro-gate seam's destination. Shows the
/// real perks copy from the pro-paid-scope spec; the purchase CTA is stubbed for
/// v1. The full StoreKit flow (purchase / restore / Family Sharing / Supporter
/// badge / alt icons) is a separate slice. A `#if DEBUG` unlock flips the stub
/// entitlement so the gate path is testable on the Simulator.
struct ProUpgradeView: View {
    @ObservedObject private var pro = AppStores.shared.pro

    var body: some View {
        List {
            Section {
                Text("Semicolyn is, and will stay, free to use in full. Pro is for people who want to support development. Buy it once; that's it.")
                    .font(.callout)
            }
            Section("What's included") {
                Label("Alternative app icons", systemImage: "app.badge")
                Label("Alternative color themes", systemImage: "paintpalette")
                Label("Supporter badge", systemImage: "sparkles")
            }
            Section {
                Button {
                    // Stub: real StoreKit purchase lands in the Pro slice.
                } label: {
                    Text("Unlock Semicolyn Pro — coming soon")
                        .frame(maxWidth: .infinity)
                }
                .disabled(true)
            }
            #if DEBUG
            Section("Debug") {
                Button(pro.isPro ? "Lock (debug)" : "Unlock (debug)") {
                    pro.setProForDebug(!pro.isPro)
                }
            }
            #endif
        }
        .navigationTitle("Semicolyn Pro")
    }
}
```

- [ ] **Step 2: Create the theme picker**

Create `App/ThemePickerView.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// Settings → Appearance → Theme. Lists the theme catalog with a palette swatch +
/// a checkmark on the currently *applied* theme. Pro themes show a ✦Pro badge when
/// Pro is inactive; tapping a locked theme routes to the upgrade screen instead of
/// applying. Selecting an unlocked theme mutates the store and the root recolors
/// live.
struct ThemePickerView: View {
    @ObservedObject private var appearance = AppStores.shared.appearance
    @ObservedObject private var pro = AppStores.shared.pro
    @State private var showingUpgrade = false

    /// The descriptor actually rendered right now (gate-resolved) — the checkmark
    /// follows this, not the raw selection, so a locked-but-selected theme shows
    /// the default as applied.
    private var appliedID: ThemeID {
        resolveDescriptor(selectedID: appearance.selectedThemeID, isPro: pro.isPro).id
    }

    var body: some View {
        List {
            ForEach(Theme.catalog, id: \.id.raw) { descriptor in
                row(for: descriptor)
            }
        }
        .navigationTitle("Theme")
        .navigationDestination(isPresented: $showingUpgrade) { ProUpgradeView() }
    }

    @ViewBuilder
    private func row(for descriptor: ThemeDescriptor) -> some View {
        let locked = descriptor.isPro && !pro.isPro
        Button {
            if locked {
                showingUpgrade = true
            } else {
                appearance.selectedThemeID = descriptor.id
            }
        } label: {
            HStack(spacing: 12) {
                ThemeSwatch(theme: descriptor.theme)
                Text(descriptor.displayName)
                Spacer()
                if locked {
                    Label("Pro", systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if descriptor.id == appliedID {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A small palette preview: accent + terminal-fg dots over the surface bg.
private struct ThemeSwatch: View {
    let theme: Theme
    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color(theme.surface.bg))
            .frame(width: 44, height: 28)
            .overlay(
                HStack(spacing: 3) {
                    Circle().fill(Color(theme.accent.primary)).frame(width: 10, height: 10)
                    Circle().fill(Color(theme.terminal.fg)).frame(width: 6, height: 6)
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(theme.surface.line))
            )
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add App/ThemePickerView.swift App/ProUpgradeView.swift
git commit -m "feat(theme): Appearance theme picker + placeholder Pro upgrade screen"
```

---

### Task 6: Docs sync + Simulator verification pass

**Files:**
- Modify: `TODO.md` (move "Theme picker + Pro-gating" out of Next; note the deferred real-StoreKit Pro slice + the SwiftTerm live-recolor check)

- [ ] **Step 1: Push the branch and let macOS CI build**

```bash
git push -u github feat/theme-picker
```
Expected: the `macos` CI job compiles the App target (new files auto-globbed; CI runs `xcodegen generate`). `linux-swift` runs the SemicolynKit suite incl. `ThemeCatalogTests`. If `linux-rust` flakes on sshd readiness, rerun that job — it is unrelated.

- [ ] **Step 2: Simulator pass (manual, macOS)**

Verify on the iOS Simulator:
- Host list → gear → **Settings → Appearance → Theme** renders both rows with swatches; a checkmark sits on Neon Midnight.
- With Pro **off**: Bell Bronze shows **✦Pro**; tapping it opens the upgrade placeholder and does **not** move the checkmark.
- In the upgrade screen, tap **Unlock (debug)**; back out → Bell Bronze no longer shows ✦Pro; tap it → chrome (host list, keybar, banners) recolors to bronze **live**; checkmark moves to Bell Bronze.
- **SwiftTerm live-recolor check (flagged risk):** open a session, switch theme, confirm the terminal *content* bg/fg repaints. If it does not, the terminal caches color attributes — file a follow-up to re-apply SwiftTerm colors on theme change (chrome already updates; this is the known risk from the spec, not a blocker on the picker).
- Relaunch the app → the selected theme persists.

- [ ] **Step 3: Update `TODO.md`**

In `TODO.md`, under **Next (unblocked dev work)**, replace the "Theme picker + Pro-gating" bullet with a Resolved entry noting: theme picker shipped (Settings → Appearance), Bell Bronze Pro-gated via a stub `ProStore` seam; **deferred** to its own slice — real StoreKit purchase/restore, Supporter badge, alternate app icons; **carry** the SwiftTerm live-recolor follow-up if the Simulator pass found it caches colors. Reference `docs/superpowers/specs/2026-06-27-theme-picker-design.md`.

- [ ] **Step 4: Commit**

```bash
git add TODO.md
git commit -m "docs: mark theme picker done; carry Pro-StoreKit + SwiftTerm recolor follow-ups"
```

---

## Self-Review

**Spec coverage:**
- Pure catalog (`ThemeID`/`ThemeDescriptor`/`catalog`/`defaultDescriptor`) → Task 1 ✓
- `resolveTheme`/`resolveDescriptor` gate (incl. fallback) → Task 1 ✓
- `Theme.all` re-derived → Task 1 ✓
- `ProStore` stub seam + debug flip → Task 2 ✓
- `ThemeSettingsStore` persistence + default fallback → Task 2 ✓
- `AppStores` registration → Task 2 ✓
- Root injection making themes live → Task 3 ✓
- Property-passed terminal theme wiring → Task 3 ✓
- Top-level Settings from HostListView → Task 4 ✓
- `ThemePickerView` (swatch, applied-checkmark, ✦Pro badge, locked-routes-to-upgrade) → Task 5 ✓
- `ProUpgradeView` placeholder with spec perks copy + debug unlock → Task 5 ✓
- Tests (catalog invariants, gate partitions incl. security-negative, ThemeID round-trip) → Task 1 ✓
- SwiftTerm live-recolor flagged-risk verification → Task 6 ✓
- Docs sync → Task 6 ✓

**Placeholder scan:** No TBD/TODO/"handle edge cases" — every code step shows complete code. (The one intentional stub — the disabled StoreKit CTA — is the explicit spec scope, with a code comment, not a plan placeholder.)

**Type consistency:** `ThemeID(_:)`, `ThemeDescriptor`, `resolveDescriptor`/`resolveTheme`, `selectedThemeID`, `isPro`, `setProForDebug`, `AppStores.shared.appearance`/`.pro`, `Theme.catalog`/`.defaultDescriptor` used identically across Tasks 1→5. `Color(_ themeColor:)` matches the existing `ThemeEnvironment.swift` extension.

**Known cross-task build boundary:** `SettingsView` (Task 4) references `ThemePickerView` (Task 5); Tasks 4+5 must land together for a green App build (noted in Task 4).
