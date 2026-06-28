# Screen capture protection

**Date:** 2026-06-17
**Status:** Locked
**Resolves:** punch-list item #7 in `docs/final-review-punchlist.md`.

## Goal

Define Semicolyn's posture toward iOS's three screen-capture surfaces: app-switcher snapshots, screen recording / mirroring, and screenshots. The goal is *more privacy-aware than the average SSH client, not paranoid* — terminal recording / mirroring is a legitimate, common use case (screencasts, demos, pair programming), so we don't blank by default.

## What iOS lets us do

- **Screenshots** (volume + power): iOS provides `UIApplication.userDidTakeScreenshotNotification` for *detection* only. **No API to block.** A "block screenshots" feature would be theater.
- **Screen recording / mirroring** (Control Center recording, ReplayKit, AirPlay, USB-C display): `UIScreen.main.isCaptured` is observable. Apps can swap their UI for a blank or redacted view while capture is active.
- **App-switcher snapshot**: iOS captures a thumbnail of the foreground view when the app backgrounds. Apps can override by swapping the view at background time.

## What Semicolyn ships

### App-switcher privacy overlay — always on

When the app backgrounds (`scenePhase` changes away from `.active`), Semicolyn swaps the on-screen content for a privacy overlay before iOS captures the switcher thumbnail. The overlay is a centered Semicolyn bell-bronze mark on a `surface.bg` background, no terminal content visible.

- No user setting; this is automatic.
- Restores the real UI when the app returns to foreground.
- The cost is essentially zero (one extra view, swapped on background-event).
- Differentiates Semicolyn from Blink and Prompt 3, which leak terminal content into the switcher.

### Screen-recording / mirroring blank — toggle, default OFF

App preferences → Security gains:

```
☐  Hide content while screen is being captured
   When on, terminal panes blank during screen recording or mirroring.
   Off by default — terminal demos and screencasts work normally.
```

When the toggle is on and `UIScreen.main.isCaptured` is true:

- Terminal pane contents render blank (just `terminal.bg` color).
- A small caption in the center of each pane reads: *"Hidden by Semicolyn while screen is being captured."*
- Keybar, predictor strip, Esc pill, banners, and all other chrome stay visible — only the *pane content* blanks.
- The user can still scroll, type, run commands; just nothing of value is on screen for the capture.
- When `isCaptured` returns to false, panes restore to normal rendering instantly.

**Default off** because:
- Most terminal screen recordings are legitimate (screencasts, tutorials, presentations).
- The user who *needs* the protection (about to SSH into prod with a coworker's screen-share running, etc.) knows their threat model and can enable it.
- Defaulting on would surprise users whose terminal goes black during a meeting demo for reasons they don't immediately understand.

### Screenshot detection — skipped

We don't show a toast on screenshot. iOS lets us detect but not block, and a toast that says "you can't actually prevent screenshots, here's how to enable a partial protection" is performative noise. The user knows they took a screenshot.

A v1.5+ candidate if a meaningful use case surfaces (e.g., logging screenshot events for compliance), but v1 is silent.

## Positioning

Semicolyn says, in About & Help → Privacy:

> Semicolyn swaps your terminal content for the Semicolyn logo whenever the app is in the iOS app switcher. If you also want your terminal hidden during screen recording or mirroring, turn on *Hide content while screen is being captured* in Security. Semicolyn cannot prevent screenshots — no iOS app can — and we don't show a notification when one is taken.

Honest about capabilities, honest about limits.

## Out of scope (v1)

- **Screenshot block / "screenshot prevention" hack** via secure-text-field overlays. Fragile, deprecated by Apple periodically, defeats user expectations. Not shipped.
- **Per-pane sensitive flag.** A pane marked "sensitive" that blanks on capture while others stay visible. Adds surface for marginal value; defer.
- **Audio capture protection.** Semicolyn doesn't produce audio (no terminal bell sound, per the terminal-feedback spec). Nothing to protect.
- **Notification preview suppression** when the screen is captured. iOS handles notifications; out of Semicolyn's surface.

## Cross-spec consequences

- [[2026-06-16-settings-sub-screens-design]] — App preferences → Security gains the *Hide content while screen is being captured* toggle.
- [[2026-06-17-design-tokens-design]] — privacy overlay uses `Color.theme.surface.bg` and `accent.primary` (the bell-bronze mark). No new tokens needed.
- [[2026-06-16-pro-paid-scope-design]] — no change. Per-pane sensitive flag would be a candidate v1.5+ feature; explicitly not a Pro perk (Pro is cosmetic, not security).

## Related

- [[2026-06-16-settings-sub-screens-design]]
- [[2026-06-17-design-tokens-design]]
