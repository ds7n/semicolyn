<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Unified Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merge the app's four disconnected settings surfaces into one unified `SettingsView`, reachable from the host-list gear and long-press-Esc, with context-aware dimming of session-only sections.

**Architecture:** A pure `SemicolynKit` gate (`SettingsGate.isEnabled(section:in:)`, Linux-tested) decides which sections are interactive per context. `SettingsView` gains a `context` + `keybarSettings` and renders all 7 sections, dimming the disabled ones. The two host-list Defaults/Settings icons collapse to one gear; the long-press-Esc `KeybarSettingsSheet` is replaced by the same `SettingsView`.

**Tech Stack:** Swift 6 (Kit, strict concurrency, XCTest on Linux), SwiftUI (App), Docker dev image for `swift test`.

**Spec:** `docs/superpowers/specs/2026-07-08-unified-settings-design.md`

## Global Constraints

- **Two-tier rule:** `Sources/SemicolynKit/` = pure logic, Linux-tested, NO `import UIKit`/`SwiftUI`, `Sendable`. `App/` = Apple-only, macOS-CI + device gated, invisible to `swift test`.
- SPDX header (both lines) on every new source file: `// SPDX-FileCopyrightText: 2026 True Positive LLC` / `// SPDX-License-Identifier: GPL-3.0-only`.
- Tests real: assert exact observable values (no tautologies); EP over input classes.
- Enablement rule (locked): `Keybar` + `Launcher` are enabled ONLY in-session; every other section always enabled.
- Both entry points open the unified `SettingsView` at its ROOT (no deep-link).
- Merge the two host-list icons into one (`gearshape`); remove ALL 3 Defaults host-list shortcuts (toolbar icon, list row, empty-state button); Defaults lives inside Settings.
- Reuse every existing leaf screen unchanged.
- Conventional commits; branch `feat/unified-settings` (spec already committed, off main); squash-merge.
- Kit test cmd: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter <name>` (run from repo root; may require sandbox-disabled for the Docker socket).

## File structure

- `Sources/SemicolynKit/Settings/SettingsSection.swift` — NEW. `SettingsContext`, `SettingsSection`, `SettingsGate`. One responsibility: the enablement rule + its vocabulary.
- `Tests/SemicolynKitTests/SettingsGateTests.swift` — NEW. The 14-case table.
- `App/SettingsView.swift` — MODIFY. Add `context` + `keybarSettings`; render all 7 rows with dimming.
- `App/HostListView.swift` — MODIFY. Remove all 3 Defaults shortcuts + `showingDefaults`; gear opens `SettingsView(context: .preConnect, …)`.
- `App/Keybar/KeybarView.swift` — MODIFY. `showingSettings` sheet → `SettingsView(context: .inSession, …)`.
- `App/Keybar/KeybarEditorView.swift` — MODIFY. Delete `KeybarSettingsSheet`.

---

### Task 1: Kit — `SettingsGate` enablement rule (Linux-tested)

**Files:**
- Create: `Sources/SemicolynKit/Settings/SettingsSection.swift`
- Test: `Tests/SemicolynKitTests/SettingsGateTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public enum SettingsContext: Equatable, Sendable { case preConnect, inSession }`
  - `public enum SettingsSection: String, CaseIterable, Sendable { case appearance, terminal, keybar, launcher, defaults, privacy, diagnostics }`
  - `public enum SettingsGate { public static func isEnabled(_ section: SettingsSection, in context: SettingsContext) -> Bool }`

- [ ] **Step 1: Write the failing test (the full 14-case table)**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class SettingsGateTests: XCTestCase {
    // In-session: every section enabled.
    func testAllSectionsEnabledInSession() {
        for s in SettingsSection.allCases {
            XCTAssertTrue(SettingsGate.isEnabled(s, in: .inSession),
                          "\(s) should be enabled in-session")
        }
    }
    // Pre-connect: keybar + launcher disabled; the other five enabled.
    func testKeybarDisabledPreConnect() {
        XCTAssertFalse(SettingsGate.isEnabled(.keybar, in: .preConnect))
    }
    func testLauncherDisabledPreConnect() {
        XCTAssertFalse(SettingsGate.isEnabled(.launcher, in: .preConnect))
    }
    func testAppearanceEnabledPreConnect() {
        XCTAssertTrue(SettingsGate.isEnabled(.appearance, in: .preConnect))
    }
    func testTerminalEnabledPreConnect() {
        XCTAssertTrue(SettingsGate.isEnabled(.terminal, in: .preConnect))
    }
    func testDefaultsEnabledPreConnect() {
        XCTAssertTrue(SettingsGate.isEnabled(.defaults, in: .preConnect))
    }
    func testPrivacyEnabledPreConnect() {
        XCTAssertTrue(SettingsGate.isEnabled(.privacy, in: .preConnect))
    }
    func testDiagnosticsEnabledPreConnect() {
        XCTAssertTrue(SettingsGate.isEnabled(.diagnostics, in: .preConnect))
    }
    // Section vocabulary is stable (guards accidental add/remove).
    func testSectionCount() {
        XCTAssertEqual(SettingsSection.allCases.count, 7)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter SettingsGateTests`
Expected: FAIL — `SettingsGate`/`SettingsSection`/`SettingsContext` undefined.

- [ ] **Step 3: Write the implementation**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Where the unified Settings screen is being shown from.
public enum SettingsContext: Equatable, Sendable {
    case preConnect   // host list, no active session
    case inSession    // long-press Esc, active session
}

/// The sections of the unified Settings screen.
public enum SettingsSection: String, CaseIterable, Sendable {
    case appearance, terminal, keybar, launcher, defaults, privacy, diagnostics
}

/// Decides which Settings sections are interactive in a given context. Keybar and
/// Launcher edit the LIVE session's input surface, so they are disabled pre-connect;
/// every other section applies in both contexts.
public enum SettingsGate {
    public static func isEnabled(_ section: SettingsSection, in context: SettingsContext) -> Bool {
        switch section {
        case .keybar, .launcher: return context == .inSession
        default:                 return true
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter SettingsGateTests`
Then full sweep: `… swift test`
Expected: PASS (9 test methods, all green); no regressions.

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Settings/SettingsSection.swift Tests/SemicolynKitTests/SettingsGateTests.swift
git commit -m "feat(kit): add SettingsGate — context-aware section enablement rule"
```

---

### Task 2: App — unified `SettingsView` (all 7 rows + dimming)

**Files:**
- Modify: `App/SettingsView.swift`

**Interfaces:**
- Consumes: `SettingsContext`, `SettingsSection`, `SettingsGate` (Task 1); existing `KeybarSettingsStore`; existing leaf views `ThemePickerView()`, `TerminalSettingsView()`, `KeybarEditorView(store:)`, `MacroLibraryView(store:)`, `DefaultsEditorView()`, `PrivacySettingsView()`, `DiagnosticsSettingsView()`.
- Produces: `SettingsView(context: SettingsContext, keybarSettings: KeybarSettingsStore)` — presented by Tasks 3 & 4.

> App-tier: macOS-CI + device gated. No local Swift build; self-review by eye.

- [ ] **Step 1: Rewrite `SettingsView.swift`**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// The single unified Settings screen. Reached from the host-list gear
/// (`.preConnect`) and long-press-Esc (`.inSession`). Sections that don't apply to
/// the current context (Keybar, Launcher pre-connect) render dimmed + disabled.
struct SettingsView: View {
    let context: SettingsContext
    @ObservedObject var keybarSettings: KeybarSettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                row(.appearance, "Appearance", "paintpalette") { ThemePickerView() }
                row(.terminal, "Terminal", "terminal") { TerminalSettingsView() }
                row(.keybar, "Keybar", "keyboard") { KeybarEditorView(store: keybarSettings) }
                row(.launcher, "Launcher", "command") { MacroLibraryView(store: keybarSettings) }
                row(.defaults, "Connection Defaults", "slider.horizontal.3") { DefaultsEditorView() }
                row(.privacy, "Privacy", "hand.raised") { PrivacySettingsView() }
                row(.diagnostics, "Diagnostics", "ladybug") { DiagnosticsSettingsView() }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { InputClickFeedback.play(); dismiss() }
                }
            }
        }
    }

    /// One Settings row. Disabled + dimmed when the gate says the section doesn't
    /// apply in the current context.
    @ViewBuilder
    private func row<Destination: View>(_ section: SettingsSection,
                                        _ title: String,
                                        _ symbol: String,
                                        @ViewBuilder destination: @escaping () -> Destination) -> some View {
        let enabled = SettingsGate.isEnabled(section, in: context)
        NavigationLink { destination() } label: {
            Label(title, systemImage: symbol)
                .opacity(enabled ? 1.0 : 0.4)   // dim when the section doesn't apply
        }
        .disabled(!enabled)
    }
}
```

- [ ] **Step 2: Self-review**

Confirm: `context` + `keybarSettings` are required (no defaults) so call-sites are explicit; every leaf initializer label matches (`KeybarEditorView(store:)`, `MacroLibraryView(store:)`, others no-arg); `SettingsGate`/`SettingsSection` come from `SemicolynKit` (imported); the `.disabled(!enabled)` on a `NavigationLink` prevents navigation and `.opacity(0.4)` dims the disabled label (matches the app's `.foregroundStyle(.secondary)` dim convention — opacity is simpler for a whole Label); `InputClickFeedback.play()` on Done matches the existing pattern. macOS CI is the compile gate.

- [ ] **Step 3: Commit**

```bash
git add App/SettingsView.swift
git commit -m "feat(app): unified SettingsView — all sections + context-aware dimming"
```

---

### Task 3: App — merge host-list icons; remove all Defaults shortcuts

**Files:**
- Modify: `App/HostListView.swift`

**Interfaces:**
- Consumes: `SettingsView(context: .preConnect, keybarSettings:)` (Task 2); `AppStores.shared.keybarSettings`.
- Produces: a single `gearshape` toolbar entry opening the unified Settings; no Defaults shortcuts remain on the host list.

- [ ] **Step 1: Remove the toolbar Defaults button**

In the `.navigationBarLeading` `ToolbarItemGroup`, DELETE the `slider.horizontal.3` "Defaults" `Button { … showingDefaults = true … }` (leaving only the `gearshape` "Settings" button). The group now holds one button.

- [ ] **Step 2: Remove the top-of-list Defaults row**

In `hostList`, DELETE the first `Button { … showingDefaults = true … } label: { Label("Defaults", systemImage: "slider.horizontal.3") … }` row (above the `ForEach(vm.hosts …)`).

- [ ] **Step 3: Remove the empty-state "Edit defaults" button**

In the empty-state view, DELETE the `Button { … showingDefaults = true … } label: { Text("Edit defaults") … }`.

- [ ] **Step 4: Remove the `showingDefaults` state + its sheet; point the gear at the unified Settings**

Delete `@State private var showingDefaults = false` and the `.sheet(isPresented: $showingDefaults) { DefaultsEditorView() }`. Change the `gearshape` sheet to:
```swift
            .sheet(isPresented: $showingSettings) {
                SettingsView(context: .preConnect,
                             keybarSettings: AppStores.shared.keybarSettings)
            }
```

- [ ] **Step 5: Verify no `showingDefaults` references remain**

Run: `rg -n "showingDefaults|Edit defaults" App/HostListView.swift`
Expected: no matches.
Also: `rg -n "SettingsView\(" App/HostListView.swift` → shows the `.preConnect` call.

- [ ] **Step 6: Commit**

```bash
git add App/HostListView.swift
git commit -m "feat(app): merge host-list Defaults+Settings into one gear opening unified Settings"
```

---

### Task 4: App — long-press Esc opens the unified Settings; delete `KeybarSettingsSheet`

**Files:**
- Modify: `App/Keybar/KeybarView.swift`
- Modify: `App/Keybar/KeybarEditorView.swift`

**Interfaces:**
- Consumes: `SettingsView(context: .inSession, keybarSettings:)` (Task 2).
- Produces: the Esc menu is now the unified Settings; `KeybarSettingsSheet` no longer exists.

- [ ] **Step 1: Point the Esc sheet at the unified Settings**

In `App/Keybar/KeybarView.swift`, change:
```swift
        .sheet(isPresented: $showingSettings) {
            KeybarSettingsSheet(store: keybarSettings)
        }
```
to:
```swift
        .sheet(isPresented: $showingSettings) {
            SettingsView(context: .inSession, keybarSettings: keybarSettings)
        }
```
(`keybarSettings` is already an `@ObservedObject` on `KeybarView`.)

- [ ] **Step 2: Delete `KeybarSettingsSheet`**

In `App/Keybar/KeybarEditorView.swift`, delete the entire `struct KeybarSettingsSheet: View { … }` (its former job — presenting Keybar + Launcher — is now the unified `SettingsView`). Leave `KeybarEditorView` and everything else in the file intact.

- [ ] **Step 3: Verify no `KeybarSettingsSheet` references remain**

Run: `rg -n "KeybarSettingsSheet" App/`
Expected: no matches.

- [ ] **Step 4: Commit**

```bash
git add App/Keybar/KeybarView.swift App/Keybar/KeybarEditorView.swift
git commit -m "feat(app): long-press Esc opens the unified Settings; remove KeybarSettingsSheet"
```

---

### Task 5: CI green + device verification

**Files:** none (verification).

- [ ] **Step 1: Push, open PR, wait for CI**

```bash
git push -u github feat/unified-settings
gh pr create --title "feat: unified Settings screen (merge 4 surfaces, context-aware dimming)" \
  --body "Implements docs/superpowers/specs/2026-07-08-unified-settings-design.md"
```
Expected: `linux-swift`, `linux-rust`, `lint`, **`macos`** all green. The Kit tests run on `linux-swift`; the App changes compile on `macos`. (`linux-rust` flake → rerun.)

- [ ] **Step 2: Fix any macOS compile errors and re-push**

Likely suspects if red: a leaf initializer label mismatch; the `AnyShapeStyle` foreground expression; a missing `import SemicolynKit`. Fix, commit, re-push.

- [ ] **Step 3: Device/simulator verify**

  1. Host list: only ONE gear icon (no `slider.horizontal.3`); no "Defaults" row; empty state has no "Edit defaults" button.
  2. Tap gear → unified Settings; **Keybar + Launcher rows are dimmed and non-tappable**; Appearance/Terminal/Connection Defaults/Privacy/Diagnostics all open.
  3. Connection Defaults opens the same `DefaultsEditorView` as before.
  4. In a session, long-press Esc → the SAME unified Settings; now **Keybar + Launcher are enabled** and open their editors; other sections still work.
  5. No leaf screen regressed.

- [ ] **Step 4: Record the device outcome** in the spec, then commit that doc change.

---

## Self-Review

- **Spec coverage:** Kit gate + enums + tests (T1) ✓; unified `SettingsView` with 7 rows + dimming (T2) ✓; merge icons + remove all 3 Defaults shortcuts (T3) ✓; Esc → unified Settings + delete `KeybarSettingsSheet` (T4) ✓; both entry points open root, no deep-link (T2/T3/T4 all present `SettingsView` directly) ✓; Kit-tested rule (T1, 9 methods / 14 logical cases) ✓; CI + device incl. all spec device checks (T5) ✓; leaf screens reused unchanged (constraint honored — no leaf edits in any task) ✓.
- **Placeholder scan:** no TBD/"handle errors"; every code step shows code; verification steps use concrete `rg` commands with expected output.
- **Type consistency:** `SettingsContext`/`SettingsSection`/`SettingsGate.isEnabled(_:in:)` defined in T1 and used identically in T2; `SettingsView(context:keybarSettings:)` defined in T2 and called with the same labels in T3 (`.preConnect`) and T4 (`.inSession`); leaf initializers (`KeybarEditorView(store:)`, `MacroLibraryView(store:)`) match the verified current signatures.
