<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Configurable tmux session name — design

**Date:** 2026-07-04
**Status:** Locked
**Related:** [[2026-06-15-host-config-model-design]] (config model + resolution),
[[2026-06-20-tmux-session-controller-design]] (the `-CC` launch path),
`2026-07-04` review-remediation #7 (leaf-independent resolution — reused here).

## Context & goal

Today the tmux control-mode session name is machine-generated:
`tmuxSessionName(seed:)` returns `semicolyn-<first 8 hex of SHA256(deviceSeed)>`
(`Sources/SemicolynKit/Tmux/TmuxLaunch.swift`). It is opaque, unrecognizable in a
server-side `tmux ls`, and not attachable from a normal terminal, so a user cannot
point the app at a tmux session they already use.

**Goal:** let the user choose the tmux session name — at the **Defaults** level (a
recognizable default for every host) and as a **per-host override** — so they can
attach to a named session of their choosing. The built-in default becomes the
literal `semicolyn` (replacing the hash).

This is a small additive feature that reuses the existing config-model resolution
machinery; it does not change the `-CC` launch mechanics.

## Decisions (locked)

- **Both levels.** A Defaults-level default session name **and** a per-host
  override. Same field at two levels, mirroring every other setting.
- **Built-in default: the literal `semicolyn`** (not the old `semicolyn-<hash>`).
- **`-A` (attach-or-create) is kept.** `tmux -CC new-session -A -s <name>` — attach
  if the named session exists, else create it. Unchanged.
- **Shared-session semantics are intended.** With a fixed default name, two
  connections to the same host (app↔app, or app↔a manually-started `semicolyn`
  session) attach to the *same* tmux session and mirror each other. This is the
  desired "pick up where I left off" behavior, not a bug to design around.

## Data model

Add one optional leaf to `TmuxConfig` (`Sources/SemicolynKit/Model/HostExtensions.swift`):

```swift
public struct TmuxConfig: Codable, Equatable, Sendable {
    public var attemptControlMode: Bool?
    public var sessionName: String?          // NEW — nil = inherit
}
```

Additive and `Codable`-back-compatible: existing records without `sessionName`
decode to `nil` (inherit). `SemicolynConfig` is unchanged (it already nests `tmux`).

## Resolution

New resolver in `Sources/SemicolynKit/Model/Resolution.swift`, using the
`resolveLeaf` helper introduced by review-remediation #7 (so a host that sets only
`sessionName` still inherits Defaults for the other tmux/semicolyn leaves, and vice
versa):

```swift
/// Resolve the tmux session name: host leaf → Defaults leaf → built-in "semicolyn".
/// Normalization happens inside the leaf accessor: an empty/whitespace-only leaf
/// is mapped to nil so `resolveLeaf` skips it and falls through to the next level.
public func resolveTmuxSessionName(host: Host, defaults: Defaults) -> String {
    resolveLeaf(host.semicolyn, defaults.semicolyn,
                { $0.tmux?.sessionName.flatMap(normalizedTmuxSessionName) },
                fallback: builtInTmuxSessionName)
}

public let builtInTmuxSessionName = "semicolyn"
```

`normalizedTmuxSessionName(_:)` trims whitespace and returns `nil` for an
empty/whitespace-only string. Because it is applied *inside* the leaf accessor
passed to `resolveLeaf`, a leaf set to `""` or `"   "` is seen as absent and
resolution falls through to the next level (ultimately `"semicolyn"`), consistent
with how every other inherited field treats "cleared to blank."

The built-in fallback `"semicolyn"` is always valid, so the launch path always
receives a valid, non-empty name.

## Validation

The name is now user-editable **and** interpolated into the
`-CC new-session -A -s <name>` command, so it must be validated. tmux forbids `.`
and `:` in session names; a command sink additionally must reject shell
metacharacters and whitespace.

Pure Kit helper (`Sources/SemicolynKit/Tmux/TmuxLaunch.swift` or a sibling),
Linux-tested:

```swift
/// A tmux session name is valid iff, after trimming, it is non-empty and every
/// character is an ASCII letter, digit, hyphen, or underscore. Rejects tmux's
/// forbidden `.`/`:`, whitespace, control chars, and any shell metacharacter —
/// so a resolved name is always safe to interpolate into the -CC command.
public func isValidTmuxSessionName(_ name: String) -> Bool
```

**Allowed charset:** ASCII letters, digits, `-`, `_`. Examples: `semicolyn`,
`work`, `my-session`, `dev_2` valid; `a.b`, `a:b`, `a b`, `a;rm`, ``, and
control-char strings rejected.

- **Editor:** an invalid name shows a red validation row (the existing host-form
  validation pattern) and blocks Save. A blank field is valid input (means
  "inherit / use default"), not a validation error.
- **Launch safety:** because Save is blocked on invalid input and the built-in
  fallback is valid, the resolved name reaching the command is always in the safe
  charset. The name still flows through the existing `TmuxCommand`/`-CC` encoder
  path unchanged.

## Editor UI

Two text fields, following the existing `attemptControlMode` binding pattern in the
same sections (get/set through `SemicolynConfig` → `TmuxConfig`).

- **Host editor** (`App/HostEditorSections.swift`, `semicolynSection`, directly
  below the "Attempt tmux control mode" toggle): a "tmux session name" `TextField`,
  placeholder `inherit · semicolyn` (the resolved inherited value), **disabled when
  `attemptControlMode` is off** (no session to name). Writes
  `semicolyn.tmux.sessionName`; `.onChange` calls `revalidate()`; invalid input →
  red row + Save blocked.
- **Defaults editor** (`App/DefaultsEditorView.swift`): the same field with a
  "Clear override" swipe action (matching the other Defaults rows), placeholder
  `inherit · semicolyn`.

Binding shape mirrors the existing nested-leaf writes: read
`vm.host.semicolyn.value?.tmux?.sessionName`, write by mutating a copied
`SemicolynConfig`/`TmuxConfig` and assigning `vm.host.semicolyn = .explicit(cfg)`.

## Launch wiring

The single consumption point changes. `ConnectionViewModel.attachTmux`
(`App/ConnectionViewModel.swift`) currently builds the name from the device seed:

```swift
let seed = (try? AppStores.shared.deviceSeed()) ?? "semicolyn-local"
let runtime = TmuxRuntime(sessionName: tmuxSessionName(seed: seed))
```

becomes:

```swift
let name = resolveTmuxSessionName(host: host, defaults: defaults)
let runtime = TmuxRuntime(sessionName: name)
```

(`attachTmux` gains access to the resolved `host`/`defaults` already in scope on
the connect path.) `TmuxRuntime(sessionName:)` and its
`-CC new-session -A -s <name>` command are **unchanged** — they receive the
resolved name. `-A` is kept.

`tmuxSessionName(seed:)` and its `deviceSeed`-hashing are **retired from the
session-name path**. `deviceSeed` remains for any other current use; only its use
in naming the tmux session is removed. (If `tmuxSessionName(seed:)` has no other
caller after this, it is deleted; otherwise left for its remaining callers.)

## Error handling

- Invalid saved name: impossible — blocked at Save by `isValidTmuxSessionName`.
- Empty/blank name: normalized to unset → resolves to the next level → `semicolyn`.
- The launch path therefore always receives a valid, non-empty name; no new failure
  mode is introduced. This change does **not** alter the tmux crash/degrade
  detection (`classifyTmuxClosure`) or the `tmuxLaunchDecision` probe.

## Testing

| Unit | Where | Cases |
|---|---|---|
| `resolveTmuxSessionName` | Kit / Linux | host wins; host-inherit→Defaults; both-unset→builtin `"semicolyn"`; host sets *only* `sessionName` still inherits Defaults for `attemptControlMode` (leaf independence); a `""`/whitespace leaf treated as unset → falls through | Core |
| `isValidTmuxSessionName` | Kit / Linux | EP + adversarial — valid: `semicolyn`, `work`, `my-session`, `dev_2`; rejected: `a.b`, `a:b`, `a b`, `a;rm` (shell metachar), `` (empty), a control-char string, a leading/trailing-space string | Critical (command-injection surface) |
| `normalizedTmuxSessionName` | Kit / Linux | trims; `"  x  "`→`"x"`; `""`/`"   "`→`nil` | Trivial |
| Editor binding + red-row-blocks-Save + disabled-when-control-mode-off | App / macOS CI | — | — |
| `-CC` command carries the resolved name | App / macOS CI | — | — |

Anti-tautology: `resolveTmuxSessionName` tests assert the **exact** resolved string
per partition; `isValidTmuxSessionName` negatives assert `false` for each specific
rejected input (not just "some invalid input fails").

## Out of scope (YAGNI)

- **Attach-only mode** ("fail if the session doesn't exist"). `-A` create-or-attach
  is the only mode.
- **Per-connection unique suffixes.** A fixed shared name is the intended behavior.
- **Migrating existing `semicolyn-<hash>` sessions** on servers. Old hash-named
  sessions simply become orphaned; the user can `tmux kill-session` them manually.
  Not worth a migration path.
- **CloudKit-account-bound session naming** (the original intent of the hash). If a
  future 2b-ii wants account-scoped names, it sets the Defaults `sessionName` from
  the account key — this design already supports that without further change.

## Cross-spec consequences

- [[2026-06-15-host-config-model-design]] — `TmuxConfig` gains optional
  `sessionName`. Additive; existing records unchanged.
- [[2026-06-20-tmux-session-controller-design]] — no change to the `-CC` mechanics;
  the session name is now resolved from config instead of the device-seed hash.

## Relationship to the connect-time crash banner (#2)

A device observation logged the mid-session crash banner appearing on a *fresh*
connect to a host where tmux works when used manually. This feature **may**
incidentally resolve it if the opaque `semicolyn-<hash>` start command was the
trigger, but #2 is tracked as a **separate investigation** (root-cause pending the
exact `tmux -CC new-session -A -s <name>` behavior on the affected server) and is
not a goal of this spec.
