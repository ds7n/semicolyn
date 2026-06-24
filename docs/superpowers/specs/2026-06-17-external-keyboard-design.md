# External keyboard support (v1)

**Status:** Locked
**Date:** 2026-06-17
**Resolves:** the external-keyboard portion of the README's "Keyboard / input UX (remaining)" unresolved bullet.

## Scope & trigger

This spec covers Neotilde's behavior when a hardware keyboard is connected — Bluetooth or USB-C on iPhone, Magic Keyboard / Smart Keyboard Folio on iPad. iOS suppresses the software keyboard automatically in this state; Neotilde adapts the keybar and accepts raw key events from the hardware.

In-scope for v1 regardless of device class. Decided alongside [[2026-06-17-ipad-scope-design]].

## Keybar behavior

When a hardware keyboard is connected, the keybar **stays visible** as a **compact floating bar** docked above the home indicator. Slot subset:

- Esc pill
- Pad
- Modifier slot
- Tab

The rationale is reach, not capability — users have full passthrough from the hardware keyboard, but the compact bar keeps a one-handed Esc / Ctrl / arrow option for the hand not on the keyboard. The predictor strip remains above the compact bar.

A setting at Settings → App preferences → Keybar lets the user hide the keybar entirely when a hardware keyboard is connected. Default: shown. **The predictor strip is governed independently** — hiding the keybar does not hide the predictor; the predictor strip floats on its own if the keybar is hidden.

## Key passthrough

Letters, numbers, symbols, arrows, Tab, and Esc go to the terminal as raw bytes via the same terminal codec the software-keyboard path uses.

**Ctrl, Option, and Shift become real held modifiers.** The user holds Ctrl and taps `C` to send `^C` — no sticky-for-one-keystroke dance. This is the headline ergonomic win of hardware-keyboard support and the main reason power users want it.

The sticky-modifier behavior in the keybar is unchanged for users who continue tapping the keybar slots with a hand off the keyboard.

## Esc handling

Most Magic Keyboards lack a physical Esc key. v1 ships **no in-app Esc rebind.** Users are expected to use iOS's system-wide remap:

> Settings → General → Keyboard → Hardware Keyboard → Modifier Keys → Caps Lock → Escape

This is the convention every iOS terminal client documents and the path users already know. Neotilde documents it in **Tips & Gestures** and in **About & Help → Keyboard tips**.

In-app Esc rebind deferred to v1.5.

## Caps-as-Ctrl

Same story. iOS supports Caps Lock → Control system-wide in the same Modifier Keys screen. Documented, not reimplemented.

## Cmd-shortcut map

iOS auto-renders the discoverability HUD when the user holds Cmd. Every shortcut below is registered via `UIKeyCommand` so it appears in the HUD with its action label.

| Shortcut | Action |
|---|---|
| ⌘T | New window (tmux window in active connection) — fires directly, no confirm sheet (the Esc-pill swipe-down path keeps its confirm; the chord is deliberate enough on its own) |
| ⌘W | Close current window (confirm if last in connection) |
| ⌘1 … ⌘9 | Switch to window N |
| ⇧⌘[ / ⇧⌘] | Prev / next window |
| ⌘[ / ⌘] | Prev / next pane |
| ⌘D **or** ⌘\| | Split pane vertical (side-by-side) |
| ⇧⌘D **or** ⌘- | Split pane horizontal (top/bottom) |
| ⌘F | Find in scrollback |
| ⌘K | Clear screen |
| ⌘C / ⌘V | Copy / paste (hardware-keyboard path; the touch long-press path is unchanged) |
| ⇧⌘N | New connection (open host picker) |
| ⇧⌘R | Reconnect current connection |
| ⇧⌘P | Open macro launcher |
| ⌘, | Settings |
| ⌘? | Tips & Gestures |

15 actions, 17 shortcuts counting the two split aliases.

**Mnemonic for the split aliases.** Vertical split puts a vertical divider between two side-by-side panes — `|` looks like that divider. Horizontal split puts a horizontal divider between top and bottom panes — `-` looks like that divider. Both aliases fire the same action as their `⌘D` form.

**Layout note.** `⌘|` is `⇧⌘\` on US layouts. iOS's `UIKeyCommand` binds to the literal `|` character and resolves the modifier transparently, so it works the way the user sees it. Non-Latin layouts where `|` isn't on `\` still work since iOS resolves by character, not by physical key.

**Relationship to the "picker is the only top-level handle" rule.** The Esc-pill picker remains the only *on-screen* affordance for Settings, host picker, and macro launcher. Hardware Cmd-shortcuts (`⌘,`, `⇧⌘N`, `⇧⌘P`, `⌘?`) are invisible to a touch user and don't violate that rule — they're the off-screen power-user equivalent of the same routes.

**Convention alignment.** The map matches Blink, iTerm2, and Apple Terminal where they converge (⌘T for new window/tab, ⌘W to close, ⌘F to find, ⌘K to clear, ⌘, for settings, ⌘D for vertical split). ⇧⌘P for the launcher follows the VS Code / Sublime command-palette convention. ⇧⌘N for new connection avoids the Prompt 3 ⇧⌘F-vs-⌘F collision.

## Predictor

Unchanged. The predictor observes input bytes, not key sources. Suggestions appear above the compact keybar exactly as they do above the full keybar.

## Globe key (🌐)

Reserved by iOS. Not intercepted.

## Conflict handling

When a user-bound macro on the keybar collides with a system Cmd-shortcut, **the system shortcut wins.** Macros are touch-surface bindings; Cmd-shortcuts route through `UIKeyCommand` at a higher layer. v1 does not warn the user about the collision — the macro just doesn't fire from the hardware keyboard. Documented in Tips & Gestures.

## Open questions / deferred

- **In-app Esc rebind** — deferred to v1.5. Adds a Settings → App preferences row for "Hardware keyboard Esc key" with options (none / Cmd-. / grave / custom). Depends on a real complaint from a user whose layout makes the iOS system path inconvenient.
- **Custom Cmd-shortcut remapping** — deferred to v1.5+. Not a v1 blocker; the default map covers the conventional set.
- **Font-size shortcuts (⌘+ / ⌘−)** — deferred. Neotilde has no font-size feature specced anywhere yet; adding the shortcut implies adding the feature. Revisit when font-size lands.
- **Scrollback navigation shortcuts (⌘Home / ⌘End)** — deferred. Useful but Magic Keyboard requires Fn+arrow for Home/End and many users won't discover it. Revisit when scrollback ergonomics get their own pass.
- **Magic Keyboard function row (F1–F12)** — out of scope for v1. The keybar's Fn slot covers F-key entry per [[2026-06-14-function-keys-design]]; hardware F-keys can pass through later if demand emerges.

## Related

- [[2026-06-17-ipad-scope-design]] — the parallel iPad scope decision; this spec is the iPad-power-user surface that lives in v1 regardless of iPad-native deferral.
- [[2026-06-14-function-keys-design]] — F-key entry via the keybar's Fn slot; the v1 path for function keys.
- [[2026-06-13-predictor-design]] — predictor strip; unchanged on the hardware-keyboard path.
- [[2026-06-15-keybar-customization-design]] — keybar layout; the compact slot subset here is a strict prefix of the locked-left default.
