# tmux session / window / pane model (Phase 3b)

**Date:** 2026-06-20
**Status:** Locked
**Phase:** 3b — the structural state layer of the terminal phase. Consumes the
`ControlModeEvent`s produced by the Phase-3a parser
([[2026-06-20-tmux-control-mode-parser-design]]) into the window/pane tree the UI
renders. The command encoder and the session controller are separate later
slices; SwiftTerm content and SwiftUI rendering are macOS-gated.
**Related specs:** [[2026-06-20-tmux-control-mode-parser-design]],
[[2026-06-17-tmux-session-design]], [[2026-06-17-terminal-emulator-scope-design]].

## Goal

Maintain the in-memory *structure* of the single tmux session Neotilde is attached
to — its windows, each window's pane-geometry tree and active pane, the active
window, and session identity / ended-state — by applying parser events. This is
the model the native pane UI binds to. Keeping it a pure, Linux-testable value
type de-risks the rendering layer before any macOS UI work.

## Placement & representation

**Swift, in `Sources/NeotildeKit/Tmux/`.** A **value-type `struct TmuxSessionState`
with `mutating func apply(_ event: ControlModeEvent)`** — not an observable
class. The state logic must be Linux-testable (feed events → assert state); a
pure value type is trivially testable with no dependency on the `Observation`
framework being present in the Linux toolchain. The macOS SwiftUI layer later
wraps this struct in a thin `@Observable` holder; the model itself stays pure and
platform-agnostic.

## Boundary

- **Owns:** the structure of the attached session — windows (id, name, layout
  tree, active pane), window order, active window, session id / name /
  ended-state.
- **Does NOT own:** terminal *content*. `%output` bytes and scrollback belong to
  SwiftTerm, wired by the controller. The model ignores content and protocol
  events; it reacts only to structural ones.
- **One session per connection** (per [[2026-06-17-tmux-session-design]]: Neotilde
  attaches to one `neotilde-<accountHash>`). The model represents that single
  attached session, not a multi-session manager.

The controller's loop is therefore: feed every event to `model.apply(_:)` for
structure, and separately route `.output(pane:data:)` to that pane's SwiftTerm.

## State shape

```swift
public struct TmuxSessionState: Equatable, Sendable {
    public private(set) var sessionID: SessionID?      // attached session ($n)
    public private(set) var sessionName: String?
    public private(set) var windows: [TmuxWindow]      // insertion order (windowAdd order)
    public private(set) var activeWindow: WindowID?
    public private(set) var ended: Bool                // %exit seen
    public private(set) var exitReason: String?

    public init()
    public func window(_ id: WindowID) -> TmuxWindow?  // lookup by id, nil if absent
}

public struct TmuxWindow: Equatable, Sendable {
    public let id: WindowID
    public var name: String
    public var layout: PaneLayout?         // full window layout (nil until first %layout-change)
    public var visibleLayout: PaneLayout?  // what to render (differs when a pane is zoomed)
    public var activePane: PaneID?
}
```

Render helper on the existing layout tree:

```swift
extension PaneLayout {
    /// Depth-first flatten to leaf panes with their geometry, for the renderer.
    public var panes: [(pane: PaneID, geometry: Geometry)]
}
```

"Is zoomed" is derivable (`layout != visibleLayout`); no separate flag is stored.
All `TmuxSessionState` fields are `private(set)` — state changes only through
`apply`.

## `apply(_:)` semantics

| Event | Effect |
|---|---|
| `windowAdd(w)` | append `TmuxWindow(id: w, name: "", layout: nil, visibleLayout: nil, activePane: nil)` if `w` is not already present (dedupe) |
| `windowClose(w)` | remove window `w`; if `w == activeWindow`, set `activeWindow = nil` |
| `windowRenamed(w, name)` | set window `w`'s `name`; unknown window → ignore |
| `windowPaneChanged(w, pane)` | set window `w`'s `activePane`; unknown window → ignore |
| `layoutChange(w, layout, visible, _)` | set window `w`'s `layout` + `visibleLayout`; unknown window → ignore |
| `sessionChanged(s, name)` | set `sessionID = s`, `sessionName = name` |
| `sessionWindowChanged(s, w)` | if `s == sessionID` or `sessionID == nil`, set `activeWindow = w`; else ignore |
| `exit(reason)` | set `ended = true`, `exitReason = reason` |
| `sessionsChanged`, `output`, `commandResult`, `unknown`, `malformed` | ignored (no structural change) |

**Philosophy:** lenient, mirroring the parser — events referencing an unknown
window are ignored, never a crash or a synthesized window. The model trusts the
controller to seed initial windows (via a `list-windows` command result the
controller decodes) before per-window events arrive; until then, events for
not-yet-known windows are simply dropped.

## Ordering

Windows are kept in **insertion order** — the order `windowAdd` events (or the
controller's initial seed) arrive. tmux's own window index is not carried on
control-mode notifications; index-faithful ordering, if desired, is a later
controller concern (re-sorting from a `list-windows` result). v1 renders in
insertion order.

## Testing (Linux `swift test`)

Tier: **Core** (non-trivial state logic; not a trust boundary — its input is the
already-validated parser event stream). EP + lifecycle + adversarial-ignore:

- Each event's exact effect on `TmuxSessionState` (assert the whole value).
- Full lifecycle: add → rename → layout → pane-active → close, asserting state
  after each.
- Dedupe: a second `windowAdd` for an existing id does not duplicate or reset it.
- Active tracking: `sessionChanged` then `sessionWindowChanged` sets the active
  window; a `sessionWindowChanged` for a *different* session id is ignored.
- `windowClose` of the active window clears `activeWindow`.
- Zoomed: `layoutChange` with `layout != visible` stores both; `layout ==
  visible` when not zoomed.
- `exit` sets `ended` + `exitReason`.
- Unknown-window events (`rename`/`paneChanged`/`layout` before `add`) are
  ignored — state unchanged.
- Content/protocol events (`.output`, `.commandResult`, `.unknown`,
  `.malformed`) cause no structural change.
- `PaneLayout.panes` flatten: single leaf, one split, nested split — exact
  `(PaneID, Geometry)` list in depth-first order.

## Out of scope (this slice)

- The **command encoder** (`new-window`/`split-window`/`resize-pane`/`send-keys`/
  `kill-session` string generation) — next slice.
- The **session controller** (the `-CC` handshake, decoding the initial
  `list-windows`/`list-panes` command results to seed the model, wiring `.output`
  to SwiftTerm, sending commands) — later slice.
- SwiftTerm content/scrollback and SwiftUI pane rendering — macOS-gated.
- Multi-session management, window index-faithful ordering — not v1.

## Cross-spec consequences

- [[2026-06-20-tmux-control-mode-parser-design]] — this model is the structural
  consumer of that parser's events; the two together form the read path of the
  tmux session engine.
- [[2026-06-17-tmux-session-design]] — the single attached session this model
  represents is the `neotilde-<accountHash>` session named there.
