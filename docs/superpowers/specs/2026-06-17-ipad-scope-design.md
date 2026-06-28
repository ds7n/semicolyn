# iPad scope (v1)

**Status:** Locked
**Date:** 2026-06-17
**Resolves:** the iPad portion of the README's "Keyboard / input UX (remaining)" unresolved bullet.

## Decision

Semicolyn v1 ships as a **universal iPhone + iPad binary**. On iPad it runs the iPhone UX rendered in a single iPad window — layouts use size classes so nothing looks wrong at iPad size, but no iPad-specific affordances are added.

The framing is **iPad-compatible, not iPad-native, for v1.**

## What's in v1

- Universal binary; same UX on both devices.
- Single iPad window (no `UISceneSession` multi-window).
- All v1 mockups and built layouts must render reasonably at iPad sizes in both portrait and landscape. If a layout doesn't survive the size jump, it needs a size-class branch in the same spec — not a separate iPad design.
- Software keyboard works the same way it does on iPhone, including the floating mini keyboard and the split keyboard (the keybar sits above whichever mode is active).
- External keyboard support is in-scope for v1 regardless of device and is covered by [[2026-06-17-external-keyboard-design]].

## What's deferred to v1.5+

- **Multi-window via `UISceneSession`** — each connection in its own iPad window for Stage Manager and Split View. Real engineering surface, real power-user value, but not load-bearing for a defensible launch.
- **Landscape-specific layouts** — wider keybar (more slots visible without scrolling), side-by-side panes as a layout option, anything that treats landscape iPad as a different canvas rather than a wider phone.
- **Trackpad / pointer integration** — Magic Keyboard's trackpad shows iPad's circular pointer. The current cursor-placement spec (60pt halo, drag-to-place) is touch-oriented. A pointer user expects to point and click; reconciling that with the touch design needs its own pass.
- **Apple Pencil** — not considered for v1; no obvious terminal use case.

## Trigger to revisit

Quantitative: iPad's share of v1 active users plus qualitative feedback that iPad ergonomics block real work. Without that signal, v1.5 iPad-native work would precede demand.

## Constraint going forward

Every new v1 mockup must look reasonable at iPad size in single-window mode. If it doesn't, the layout needs a size-class branch before the spec lands. This applies retroactively to existing mockups during the implementation phase — any layout that breaks at iPad gets fixed when the implementing developer hits it, not deferred.

## Related

- [[2026-06-17-external-keyboard-design]] — the parallel hardware-keyboard story; the only iPad-power-user surface that v1 needs to cover regardless of iPad-native deferral.
- [[2026-06-15-keybar-customization-design]] — keybar layout. The reverse-bar (locked-right) option already partially serves iPad landscape left-thumb users; no extra iPad work here.
