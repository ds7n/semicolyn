<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Nerd Font Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the terminal render Nerd Font glyphs (powerline/dev/file-type icons) by shipping a curated set of full patched fonts, defaulting to FiraCode, with a picker and user-import.

**Architecture:** Pure font model + resolve-with-fallback live in `SemicolynKit` (Linux-tested). Font registration, the `UIFont` resolver, the picker, and import live in `App/` (Apple-only, macOS-CI + manual verify). The 4 hardcoded `monospacedSystemFont` call-sites route through one provider.

**Tech Stack:** Swift 6 (strict concurrency), XCTest (Linux), SwiftUI, CoreText (`CTFontManagerRegisterFontsForURL`), XcodeGen (`project.yml`), SwiftTerm.

**Spec:** `docs/superpowers/specs/2026-07-08-nerd-font-support-design.md`

## Global Constraints

- Every source file carries the SPDX header: `// SPDX-FileCopyrightText: 2026 True Positive LLC` / `// SPDX-License-Identifier: GPL-3.0-only`. Repo stays REUSE-compliant; each bundled font ships its upstream license file.
- **Two-tier rule:** `Sources/SemicolynKit/` = NO `import UIKit`/`SwiftUI`; Linux-tested with XCTest. `App/` = Apple-only, validated on the macOS CI job, not `swift test`.
- Swift 6 strict concurrency: Kit types are `Sendable`; `App/` stores are `@MainActor`.
- Tests are real (equivalence-partitioning + boundary; assert exact observable values; a negative test asserts the *specific* failure — no tautologies).
- **Icon model: full patched fonts only** — no symbols cascade.
- **Default terminal face: FiraCode Nerd Font.**
- Bundled set: FiraCode (default), JetBrainsMono, Hack — all full Nerd Fonts — plus the system monospace as a no-icon selectable face.
- Conventional commits; feature branch `feat/nerd-font-support`; squash-merge.
- Kit build/test: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter <name>`.

---

### Task 1: `TerminalFont` model + `fontFace` on `TerminalSettings` (Kit)

**Files:**
- Modify: `Sources/SemicolynKit/Terminal/TerminalSettings.swift`
- Test: `Tests/SemicolynKitTests/TerminalFontTests.swift` (create)

**Interfaces:**
- Consumes: nothing (foundational).
- Produces:
  - `public struct TerminalFont: Equatable, Sendable, Codable { public enum Kind: Equatable, Sendable, Codable { case system; case bundled(String); case imported(String) }; public var kind: Kind; public var displayName: String; public init(kind: Kind, displayName: String) }`
  - `TerminalSettings.fontFace: TerminalFont` (stored `var`), defaulting to `BundledFont.default.face` (defined in Task 2). **Until Task 2 lands**, default temporarily to `TerminalFont(kind: .system, displayName: "System")` — Task 2 flips it to FiraCode.

- [ ] **Step 1: Write the failing test**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class TerminalFontTests: XCTestCase {
    // Round-trip each Kind case (EP over the 3 partitions).
    func testCodableRoundTripSystem() throws {
        let f = TerminalFont(kind: .system, displayName: "System")
        let back = try JSONDecoder().decode(TerminalFont.self, from: JSONEncoder().encode(f))
        XCTAssertEqual(back, f)
    }
    func testCodableRoundTripBundled() throws {
        let f = TerminalFont(kind: .bundled("FiraCodeNF-Regular"), displayName: "FiraCode Nerd Font")
        let back = try JSONDecoder().decode(TerminalFont.self, from: JSONEncoder().encode(f))
        XCTAssertEqual(back, f)
    }
    func testCodableRoundTripImported() throws {
        let f = TerminalFont(kind: .imported("MyFont-Regular"), displayName: "My Font")
        let back = try JSONDecoder().decode(TerminalFont.self, from: JSONEncoder().encode(f))
        XCTAssertEqual(back, f)
    }
    func testSettingsDefaultFontFaceIsSystemForNow() {
        // Task 2 will change this expectation to FiraCode.
        XCTAssertEqual(TerminalSettings().fontFace.kind, .system)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TerminalFontTests`
Expected: FAIL — `TerminalFont` / `fontFace` undefined.

- [ ] **Step 3: Write minimal implementation**

Add to `TerminalSettings.swift` (above `TerminalSettings`):

```swift
/// A selectable terminal typeface. `.system` = SF Mono (no icons); `.bundled`
/// = a Nerd Font shipped in the app bundle; `.imported` = a user-registered
/// `.ttf`/`.otf`. The associated `String` is the font's PostScript name.
public struct TerminalFont: Equatable, Sendable, Codable {
    public enum Kind: Equatable, Sendable, Codable {
        case system
        case bundled(String)
        case imported(String)
    }
    public var kind: Kind
    public var displayName: String
    public init(kind: Kind, displayName: String) {
        self.kind = kind
        self.displayName = displayName
    }
}
```

Add the stored property + default to `TerminalSettings` (extend the memberwise init):

```swift
    public var fontFace: TerminalFont
```
In `init`, add parameter `fontFace: TerminalFont = TerminalFont(kind: .system, displayName: "System")` and `self.fontFace = fontFace`.

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TerminalFontTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Terminal/TerminalSettings.swift Tests/SemicolynKitTests/TerminalFontTests.swift
git commit -m "feat(kit): add TerminalFont model + fontFace on TerminalSettings"
```

---

### Task 2: `BundledFont` registry + resolve-with-fallback (Kit)

**Files:**
- Modify: `Sources/SemicolynKit/Terminal/TerminalSettings.swift`
- Test: `Tests/SemicolynKitTests/BundledFontTests.swift` (create)

**Interfaces:**
- Consumes: `TerminalFont` (Task 1).
- Produces:
  - `public struct BundledFont: Equatable, Sendable { public let displayName: String; public let postScriptName: String; public let fileName: String; public let license: String; public var face: TerminalFont { TerminalFont(kind: .bundled(postScriptName), displayName: displayName) } }`
  - `public enum FontCatalog { public static let bundled: [BundledFont]; public static let `default`: BundledFont }` — `default` is FiraCode; `bundled` = `[FiraCode, JetBrainsMono, Hack]`.
  - `public static func resolvePostScriptName(_ face: TerminalFont, registeredImported: Set<String>) -> String?` on `FontCatalog` — returns `nil` for `.system` (a sentinel meaning "use monospacedSystemFont"); the bundled/imported name if resolvable; and for an `.imported` name NOT in `registeredImported`, returns the **default bundled** font's PostScript name (fallback, never nil/tofu).

- [ ] **Step 1: Write the failing test**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class BundledFontTests: XCTestCase {
    func testCatalogHasThreeBundledFonts() {
        XCTAssertEqual(FontCatalog.bundled.count, 3)
    }
    func testDefaultIsFiraCodeAndIsInCatalog() {
        XCTAssertEqual(FontCatalog.default.displayName, "FiraCode Nerd Font")
        XCTAssertTrue(FontCatalog.bundled.contains(FontCatalog.default),
                      "default must be a font we actually ship")
    }
    func testSettingsDefaultFaceIsFiraCode() {
        XCTAssertEqual(TerminalSettings().fontFace, FontCatalog.default.face)
    }
    // resolve-with-fallback: EP over the 3 Kinds + the unknown-imported boundary.
    func testResolveSystemReturnsNilSentinel() {
        let face = TerminalFont(kind: .system, displayName: "System")
        XCTAssertNil(FontCatalog.resolvePostScriptName(face, registeredImported: []))
    }
    func testResolveBundledReturnsItsExactName() {
        let face = FontCatalog.default.face
        XCTAssertEqual(FontCatalog.resolvePostScriptName(face, registeredImported: []),
                       FontCatalog.default.postScriptName)
    }
    func testResolveKnownImportedReturnsItsExactName() {
        let face = TerminalFont(kind: .imported("MyFont-Regular"), displayName: "My Font")
        XCTAssertEqual(
            FontCatalog.resolvePostScriptName(face, registeredImported: ["MyFont-Regular"]),
            "MyFont-Regular")
    }
    func testResolveUnknownImportedFallsBackToDefaultName() {
        let face = TerminalFont(kind: .imported("Gone-Regular"), displayName: "Gone")
        XCTAssertEqual(
            FontCatalog.resolvePostScriptName(face, registeredImported: []),
            FontCatalog.default.postScriptName,   // specific fallback, not just non-nil
            "an unregistered imported face must fall back to the default, never tofu")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter BundledFontTests`
Expected: FAIL — `BundledFont`/`FontCatalog` undefined.

- [ ] **Step 3: Write minimal implementation**

Add to `TerminalSettings.swift`. PostScript names below are the standard Nerd Font names; Task 5 verifies them against the actual files and corrects if needed.

```swift
/// A font shipped inside the app bundle. `fileName` is the resource file
/// (without extension assumptions handled by the App tier); `postScriptName`
/// is what `UIFont(name:)` needs; `license` is the SPDX / upstream id.
public struct BundledFont: Equatable, Sendable {
    public let displayName: String
    public let postScriptName: String
    public let fileName: String
    public let license: String
    public var face: TerminalFont {
        TerminalFont(kind: .bundled(postScriptName), displayName: displayName)
    }
}

/// The curated font set + the resolve-with-fallback that keeps an unresolvable
/// face from tofu-ing the whole terminal.
public enum FontCatalog {
    public static let bundled: [BundledFont] = [
        BundledFont(displayName: "FiraCode Nerd Font",
                    postScriptName: "FiraCodeNerdFont-Regular",
                    fileName: "FiraCodeNerdFont-Regular",
                    license: "OFL-1.1"),
        BundledFont(displayName: "JetBrainsMono Nerd Font",
                    postScriptName: "JetBrainsMonoNerdFont-Regular",
                    fileName: "JetBrainsMonoNerdFont-Regular",
                    license: "OFL-1.1"),
        BundledFont(displayName: "Hack Nerd Font",
                    postScriptName: "HackNerdFont-Regular",
                    fileName: "HackNerdFont-Regular",
                    license: "MIT"),
    ]
    public static let `default`: BundledFont = bundled[0]

    /// Resolve a face to the PostScript name to render with.
    /// - Returns: `nil` for `.system` (caller uses `monospacedSystemFont`);
    ///   the exact name for bundled or a registered imported face; the default
    ///   bundled font's name for an imported face not in `registeredImported`.
    public static func resolvePostScriptName(
        _ face: TerminalFont, registeredImported: Set<String>) -> String? {
        switch face.kind {
        case .system:
            return nil
        case .bundled(let name):
            return name
        case .imported(let name):
            return registeredImported.contains(name) ? name : `default`.postScriptName
        }
    }
}
```

Flip the `TerminalSettings.init` default: `fontFace: TerminalFont = FontCatalog.default.face`. Update Task 1's `testSettingsDefaultFontFaceIsSystemForNow` — delete it (superseded by `testSettingsDefaultFaceIsFiraCode` here).

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter BundledFontTests`
Then full Kit sweep: `... swift test`
Expected: PASS; no regressions.

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Terminal/TerminalSettings.swift Tests/SemicolynKitTests/BundledFontTests.swift Tests/SemicolynKitTests/TerminalFontTests.swift
git commit -m "feat(kit): add BundledFont catalog + resolve-with-fallback; default to FiraCode"
```

---

### Task 3: Persist `TerminalSettings` in `TerminalSettingsStore` (App)

**Files:**
- Modify: `App/TerminalSettingsStore.swift`
- Reference pattern: `App/ThemeSettingsStore.swift`

**Interfaces:**
- Consumes: `TerminalSettings`, `TerminalFont` (Codable, Tasks 1–2).
- Produces: `TerminalSettingsStore.settings` now persists across launches (JSON blob in `UserDefaults` under `"semicolyn.terminal.settings"`); a `resetToDefaults()` method.

> App-tier: not covered by `swift test`. Verified by macOS CI compile + manual. No Linux test step; the "test" is the CI build.

- [ ] **Step 1: Rewrite the store to persist**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SemicolynKit

/// App-lifetime holder for terminal preferences. Persists the whole
/// `TerminalSettings` as a JSON blob in `UserDefaults` (mirrors
/// `ThemeSettingsStore`); a missing/corrupt key falls back to defaults.
@MainActor final class TerminalSettingsStore: ObservableObject {
    private static let defaultsKey = "semicolyn.terminal.settings"

    @Published var settings: TerminalSettings {
        didSet { persist() }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(TerminalSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = TerminalSettings()
        }
    }

    func resetToDefaults() {
        settings = TerminalSettings()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
```

This requires `TerminalSettings: Codable`. Add conformance in Kit if not already present:

- [ ] **Step 2: Make `TerminalSettings` Codable (Kit) + round-trip test**

In `Sources/SemicolynKit/Terminal/TerminalSettings.swift`, add `Codable` to `TerminalSettings` and to `CursorStyle` (`enum CursorStyle: Equatable, Sendable, Codable`). Add to `TerminalFontTests.swift`:

```swift
    func testTerminalSettingsCodableRoundTrip() throws {
        var s = TerminalSettings(fontSize: 15, cursorStyle: .bar, cursorBlink: true, scrollbackLines: 2000)
        s.fontFace = TerminalFont(kind: .bundled("HackNerdFont-Regular"), displayName: "Hack Nerd Font")
        let back = try JSONDecoder().decode(TerminalSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }
```

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TerminalFontTests`
Expected: PASS (adds 1 test).

- [ ] **Step 3: Commit**

```bash
git add Sources/SemicolynKit/Terminal/TerminalSettings.swift Tests/SemicolynKitTests/TerminalFontTests.swift App/TerminalSettingsStore.swift
git commit -m "feat(app): persist TerminalSettings; make settings Codable (kit)"
```

---

### Task 4: `TerminalFontProvider` — registration + `UIFont` resolver (App)

**Files:**
- Create: `App/TerminalFontProvider.swift`

**Interfaces:**
- Consumes: `TerminalFont`, `FontCatalog` (Kit).
- Produces (App-tier singleton, `@MainActor`):
  - `TerminalFontProvider.shared`
  - `func registerBundledFonts()` — idempotent; called once at launch.
  - `func registerImported(fileURL: URL) -> String?` — registers a user file, returns its PostScript name (or nil on failure).
  - `var registeredImportedNames: Set<String>` — imported names successfully registered this session.
  - `func font(for face: TerminalFont, size: CGFloat) -> UIFont` — the single resolver; never returns tofu.

> App-tier: macOS-CI compile + manual verification. No Linux unit test.

- [ ] **Step 1: Write the provider**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import CoreText
import SemicolynKit

/// Registers bundled + imported Nerd Fonts with CoreText and resolves a
/// `TerminalFont` to a concrete `UIFont`. The resolver always returns a real
/// font — an unresolvable name falls back through the Kit default to the
/// system monospace, never tofu.
@MainActor final class TerminalFontProvider {
    static let shared = TerminalFontProvider()

    private(set) var registeredImportedNames: Set<String> = []
    private var didRegisterBundled = false

    /// Register the curated bundled fonts. Idempotent; safe to call at launch.
    func registerBundledFonts() {
        guard !didRegisterBundled else { return }
        didRegisterBundled = true
        for f in FontCatalog.bundled {
            guard let url = Bundle.main.url(forResource: f.fileName, withExtension: "ttf")
                ?? Bundle.main.url(forResource: f.fileName, withExtension: "otf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// Register a user-imported font file. Returns its PostScript name on success.
    func registerImported(fileURL: URL) -> String? {
        guard CTFontManagerRegisterFontsForURL(fileURL as CFURL, .process, nil) else { return nil }
        guard let data = try? Data(contentsOf: fileURL),
              let provider = CGDataProvider(data: data as CFData),
              let cg = CGFont(provider),
              let ps = cg.postScriptName as String? else { return nil }
        registeredImportedNames.insert(ps)
        return ps
    }

    /// Resolve a face to a concrete UIFont. Never returns a tofu font.
    func font(for face: TerminalFont, size: CGFloat) -> UIFont {
        guard let name = FontCatalog.resolvePostScriptName(
            face, registeredImported: registeredImportedNames) else {
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        }
        if let font = UIFont(name: name, size: size) { return font }
        // name resolved by Kit but not actually available → default, then system.
        if let def = UIFont(name: FontCatalog.default.postScriptName, size: size) { return def }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
```

- [ ] **Step 2: Verify it compiles (macOS CI)**

This file can only compile on the macOS job. Locally, sanity-check syntax by eye; the real gate is CI in Task 8. No commit-blocking local run.

- [ ] **Step 3: Commit**

```bash
git add App/TerminalFontProvider.swift
git commit -m "feat(app): add TerminalFontProvider (register bundled/imported + resolve UIFont)"
```

---

### Task 5: Bundle the font files + wire `project.yml` (App/build)

**Files:**
- Create: `App/Resources/Fonts/FiraCodeNerdFont-Regular.ttf` (+ `.license`)
- Create: `App/Resources/Fonts/JetBrainsMonoNerdFont-Regular.ttf` (+ `.license`)
- Create: `App/Resources/Fonts/HackNerdFont-Regular.ttf` (+ `.license`)
- Modify: `project.yml` (resource group + `UIAppFonts`)
- Modify: `App/…AppEntry/RootView` — call `TerminalFontProvider.shared.registerBundledFonts()` at launch.

**Interfaces:**
- Consumes: `TerminalFontProvider.registerBundledFonts()` (Task 4).
- Produces: the three fonts present in the app bundle + registered at launch.

- [ ] **Step 1: Download the fonts and confirm exact PostScript names**

```bash
mkdir -p App/Resources/Fonts && cd App/Resources/Fonts
# Nerd Fonts release assets (v3+). Pin a release tag when running.
curl -fLO https://github.com/ryanoasis/nerd-fonts/releases/latest/download/FiraCode.zip
curl -fLO https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip
curl -fLO https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Hack.zip
# Extract only the Regular .ttf we need from each, rename to our fileName, delete the rest + zips.
```

For each extracted `.ttf`, read its real PostScript name and reconcile with the catalog:

```bash
python3 - <<'PY'
from fontTools.ttLib import TTFont
for p in ["FiraCodeNerdFont-Regular.ttf","JetBrainsMonoNerdFont-Regular.ttf","HackNerdFont-Regular.ttf"]:
    f=TTFont(p); name=f["name"].getDebugName(6); print(p, "->", name)
PY
```

If any printed PostScript name differs from `FontCatalog`'s `postScriptName`, **update the catalog string in `TerminalSettings.swift` to match exactly** and re-run `swift test --filter BundledFontTests`. (Kit tests assert names round-trip, not that they match the file — this manual reconcile is the guard that names match reality.)

- [ ] **Step 2: Add per-font license files (REUSE)**

Each font's upstream `LICENSE`/`OFL.txt` goes beside it as `<fileName>.ttf.license` or a `.reuse/dep5` entry. FiraCode + JetBrainsMono = OFL-1.1; Hack = MIT (Hack license). Confirm REUSE passes: `docker compose run --rm dev reuse lint` (if `reuse` present in the dev image) — else document the license mapping in `App/Resources/Fonts/README.md`.

- [ ] **Step 3: Wire `project.yml`**

Add the fonts as bundled resources of the App target and declare `UIAppFonts` in the target's Info plist section. Example fragment to merge into the App target:

```yaml
    sources:
      - path: App/Resources/Fonts
        buildPhase: resources
    info:
      properties:
        UIAppFonts:
          - FiraCodeNerdFont-Regular.ttf
          - JetBrainsMonoNerdFont-Regular.ttf
          - HackNerdFont-Regular.ttf
```

(Match the existing `project.yml` structure — merge into the current App target's `sources`/`info`, don't duplicate the target.)

- [ ] **Step 4: Register at launch**

Find the App entry point (the `@main` App struct / RootView `init` or `.onAppear`) and add:

```swift
TerminalFontProvider.shared.registerBundledFonts()
```

`UIAppFonts` auto-registers bundled fonts too; the explicit call is belt-and-suspenders and also the seam that re-registers imported fonts (Task 6). Keep it.

- [ ] **Step 5: Commit**

```bash
git add App/Resources/Fonts project.yml App/*  # entry point file
git commit -m "feat(app): bundle FiraCode/JetBrainsMono/Hack Nerd Fonts + register at launch"
```

---

### Task 6: Route the 4 terminal call-sites through the provider (App)

**Files:**
- Modify: `App/TerminalScreen.swift:54` and `:182`
- Modify: `App/TmuxPaneContainer.swift:192` and `:391`

**Interfaces:**
- Consumes: `TerminalFontProvider.shared.font(for:size:)` (Task 4), `settings.fontFace` (Task 1).
- Produces: the live terminal renders with the selected face; face changes apply through the existing settings-change path.

- [ ] **Step 1: Swap `TerminalScreen.swift` (initial apply, line ~54)**

Replace:
```swift
terminal.font = UIFont.monospacedSystemFont(ofSize: CGFloat(s.fontSize), weight: .regular)
```
with:
```swift
terminal.font = TerminalFontProvider.shared.font(for: s.fontFace, size: CGFloat(s.fontSize))
```

- [ ] **Step 2: Swap `TerminalScreen.swift` (size-change apply, line ~182)**

Replace:
```swift
terminal.font = UIFont.monospacedSystemFont(ofSize: CGFloat(newSize), weight: .regular)
```
with (use the coordinator's current face):
```swift
terminal.font = TerminalFontProvider.shared.font(for: settings.fontFace, size: CGFloat(newSize))
```
(If `settings` isn't in scope at that line, thread the stored `settings.fontFace` the same way `baseSize` is captured at line ~153.)

- [ ] **Step 3: Swap both `TmuxPaneContainer.swift` sites (lines ~192, ~391)**

Replace each:
```swift
UIFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
```
with:
```swift
TerminalFontProvider.shared.font(for: coordinator!.settings.fontFace, size: CGFloat(fontSize))
```
Match the exact `fontSize`/`newSize` variable and `settings`/`coordinator` access in scope at each site (line 391 already reads `coordinator?.settings.fontSize`; reuse that `coordinator?.settings.fontFace`).

- [ ] **Step 4: Grep-verify no hardcoded monospace font remains for the terminal**

Run: `rg -n "monospacedSystemFont" App/TerminalScreen.swift App/TmuxPaneContainer.swift`
Expected: no matches (all 4 routed through the provider).

- [ ] **Step 5: Commit**

```bash
git add App/TerminalScreen.swift App/TmuxPaneContainer.swift
git commit -m "feat(app): route terminal font through TerminalFontProvider (respects fontFace)"
```

---

### Task 7: Terminal Settings screen + font picker + import (App)

**Files:**
- Create: `App/TerminalSettingsView.swift`
- Create: `App/TerminalFontPickerView.swift`
- Modify: `App/SettingsView.swift` (add a "Terminal" row)

**Interfaces:**
- Consumes: `TerminalSettingsStore` (Task 3), `FontCatalog`, `TerminalFont` (Kit), `TerminalFontProvider` (Task 4), `InputClickFeedback` (existing).
- Produces: a reachable picker that mutates `store.settings.fontFace` and imports fonts.

- [ ] **Step 1: Add the "Terminal" row to `SettingsView.swift`**

Insert after the Appearance link (line ~18), following the exact `NavigationLink { … } label: { Label(…) }` pattern:

```swift
                NavigationLink {
                    TerminalSettingsView()
                } label: {
                    Label("Terminal", systemImage: "terminal")
                }
```

- [ ] **Step 2: Write `TerminalSettingsView.swift`**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// Minimal Terminal settings: font size + font face picker. Anchor for the
/// (otherwise deferred) Terminal settings tree.
struct TerminalSettingsView: View {
    @EnvironmentObject private var store: TerminalSettingsStore

    var body: some View {
        List {
            Section("Font Size") {
                Slider(value: $store.settings.fontSize,
                       in: TerminalSettings.fontRange, step: 1) {
                    Text("Font Size")
                }
                Text("\(Int(store.settings.fontSize)) pt")
                    .foregroundStyle(.secondary)
            }
            Section("Font") {
                NavigationLink {
                    TerminalFontPickerView()
                } label: {
                    HStack {
                        Text("Typeface")
                        Spacer()
                        Text(store.settings.fontFace.displayName)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Terminal")
    }
}
```

(Confirm `TerminalSettingsStore` is injected as an `@EnvironmentObject` at the app root — it's constructed in `App/AppStores.swift:34`. If it isn't already `.environmentObject(...)`-injected, add that at the root alongside the other stores.)

- [ ] **Step 3: Write `TerminalFontPickerView.swift`**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import UniformTypeIdentifiers
import SemicolynKit

/// Font-face picker: system + bundled Nerd Fonts, plus user-imported faces.
/// Each row previews sample letters and a couple of icons in that face.
struct TerminalFontPickerView: View {
    @EnvironmentObject private var store: TerminalSettingsStore
    @State private var importing = false
    @State private var importedFaces: [TerminalFont] = []

    private static let sample = "AaBb 0O ==> !=  \u{e0b0} \u{f07b} \u{f09b}"

    private var systemFace: TerminalFont { TerminalFont(kind: .system, displayName: "System") }

    var body: some View {
        List {
            Section("Bundled") {
                row(systemFace)
                ForEach(FontCatalog.bundled, id: \.postScriptName) { bf in
                    row(bf.face)
                }
            }
            Section("Imported") {
                ForEach(importedFaces, id: \.self) { row($0) }
                    .onDelete(perform: deleteImported)
                Button {
                    InputClickFeedback.play()
                    importing = true
                } label: {
                    Label("Import Font…", systemImage: "square.and.arrow.down")
                }
            }
        }
        .navigationTitle("Typeface")
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [UTType(filenameExtension: "ttf")!,
                                            UTType(filenameExtension: "otf")!],
                      allowsMultipleSelection: false) { result in
            handleImport(result)
        }
    }

    @ViewBuilder private func row(_ face: TerminalFont) -> some View {
        Button {
            InputClickFeedback.play()
            store.settings.fontFace = face
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(face.displayName)
                    Spacer()
                    if face == store.settings.fontFace {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
                Text(Self.sample)
                    .font(previewFont(for: face))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func previewFont(for face: TerminalFont) -> Font {
        let ui = TerminalFontProvider.shared.font(for: face, size: 15)
        return Font(ui)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let src = urls.first else { return }
        // Copy into Application Support so it survives relaunch, then register.
        guard let dest = copyIntoAppSupport(src) else { return }
        if let ps = TerminalFontProvider.shared.registerImported(fileURL: dest) {
            let face = TerminalFont(kind: .imported(ps),
                                    displayName: dest.deletingPathExtension().lastPathComponent)
            importedFaces.append(face)
            store.settings.fontFace = face
        }
    }

    private func copyIntoAppSupport(_ src: URL) -> URL? {
        let needsStop = src.startAccessingSecurityScopedResource()
        defer { if needsStop { src.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        guard let dir = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
            .appendingPathComponent("Fonts", isDirectory: true) else { return nil }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(src.lastPathComponent)
        try? fm.removeItem(at: dest)
        do { try fm.copyItem(at: src, to: dest); return dest } catch { return nil }
    }

    private func deleteImported(_ offsets: IndexSet) {
        for i in offsets {
            let face = importedFaces[i]
            if store.settings.fontFace == face { store.settings.fontFace = FontCatalog.default.face }
        }
        importedFaces.remove(atOffsets: offsets)
    }
}
```

Note: re-registering imported fonts at launch (so `.imported` faces resolve after relaunch) — the launch hook (Task 5, Step 4) should also enumerate `AppSupport/Fonts/*` and call `registerImported`. Add that enumeration to `registerBundledFonts()` or a sibling `registerImportedFonts()` called at the same launch site. Persisting the imported-faces *list* across launches (so the Imported section repopulates) is a known limitation for this cut — see Deferred; the resolve-with-fallback keeps a persisted `.imported` face safe (reverts to default) until re-import.

- [ ] **Step 4: Compile gate (macOS CI, Task 8).** No local Swift toolchain; syntax-check by eye.

- [ ] **Step 5: Commit**

```bash
git add App/SettingsView.swift App/TerminalSettingsView.swift App/TerminalFontPickerView.swift App/AppStores.swift
git commit -m "feat(app): Terminal settings screen with font picker + import"
```

---

### Task 8: CI green + device verification

**Files:** none (verification task).

- [ ] **Step 1: Push branch, open PR, wait for macOS CI**

```bash
git push -u github feat/nerd-font-support
gh pr create --title "feat: Nerd Font support in the terminal" --body "Implements docs/superpowers/specs/2026-07-08-nerd-font-support-design.md"
```
Expected: `linux-swift`, `linux-rust`, `lint`, **`macos`** all green. `macos` is the only Apple-code signal. (`linux-rust` flake → rerun.)

- [ ] **Step 2: Cut a TestFlight build; device-verify**

On green, dispatch "Release to TestFlight" off the merged main. On device confirm:
  - Terminal renders FiraCode by default; **icons render** (run e.g. `eza --icons`, a Starship/powerlevel prompt, or `echo -e ' '`).
  - **Ligatures**: type `=>`, `!=`, `->`, `>=` — confirm they ligate (spec predicts YES; record actual).
  - Picker switches faces live; system face shows no icons; import a `.ttf` and confirm it renders and persists across relaunch (or reverts to default if the imported-list limitation bites — expected per Deferred).

- [ ] **Step 3: Record ligature outcome in the spec** (update the "Ligatures caveat" section with the observed on-device result), then commit that doc change.

---

## Deferred / known limitations (YAGNI for this cut)

- Persisting the *list* of imported faces across launches (the picker's Imported section repopulating). The persisted selected `.imported` face is safe via resolve-with-fallback; a fuller cut stores the imported-face list in the settings store.
- Per-host font overrides; weight/style selection; symbols-only cascade (chosen against).

## Self-Review

- **Spec coverage:** model+field (T1) ✓, registry+resolve-fallback (T2) ✓, persistence-correction (T3) ✓, provider/registration/resolver/import (T4) ✓, bundle+project.yml+launch (T5) ✓, 4 call-sites (T6) ✓, picker+minimal settings screen+import UI (T7) ✓, ligature investigation recorded (spec + T8 step 3) ✓, REUSE/licensing (T5 step 2) ✓, default=FiraCode (T2) ✓, full-patched-only (no cascade anywhere) ✓.
- **Placeholder scan:** no TBD/"handle errors" — every code step shows code; the only manual step (font download + PS-name reconcile, T5) is explicit with commands.
- **Type consistency:** `TerminalFont(kind:displayName:)`, `FontCatalog.bundled/.default/.resolvePostScriptName(_:registeredImported:)`, `TerminalFontProvider.shared.font(for:size:)/registerBundledFonts()/registerImported(fileURL:)/registeredImportedNames`, `TerminalSettingsStore.settings/resetToDefaults()` — used consistently across T1→T7.
