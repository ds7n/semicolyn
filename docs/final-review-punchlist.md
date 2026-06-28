# Final review punch list

**Created:** 2026-06-17
**Source:** post-mockup-audit holistic design review (commit `99599bf` is the reviewed state)
**Purpose:** track the remaining design work surfaced by the final review so brainstorming finishes cleanly before code starts.

Status legend: `open` · `in-progress` · `resolved` · `deferred`. Resolution column links to the spec / commit that closed the item.

---

## Critical (must lock before code)

These are protocol-layer or first-trust UX questions whose answers partly determine the SSH stack pick. Reversing later is expensive.

| # | Item | Severity | Status | Resolution |
|---|---|---|---|---|
| 1 | **Terminal emulator scope.** Escape-sequence level (xterm-256? truecolor?), terminal **bell** (silent / haptic / sound / flash), **OSC 52** clipboard policy, **OSC 0/2** title handling, **mouse-mode** (`set mouse=a`) passthrough. Cursor-placement spec quietly assumes mouse mode exists; nothing states whether real mouse reporting is supported. | critical | resolved | (a, c, d, e) `2026-06-17-terminal-emulator-scope-design.md`; (b) `2026-06-17-terminal-feedback-design.md`. |
| 2 | **SSH host-key TOFU + mismatch UX.** Host-config schema flags a mismatch modal as "deferred to CRUD spec"; CRUD doesn't pick it up. First-trust prompt format on the very first connection isn't documented anywhere as a UI flow. | critical | resolved | `2026-06-17-host-key-trust-design.md` |
| 3 | **SSH algorithm allowlist.** No spec declares the v1 ciphers / MACs / KEX / HostKey allowlist. "Modern OpenSSH defaults" depends on the SSH stack (libssh2 vs SwiftSSH vs Network.framework). | critical | resolved | `2026-06-17-ssh-algorithms-design.md` |

## Should address before implementation

Not load-bearing for ship, but should be designed before code starts.

| # | Item | Severity | Status | Resolution |
|---|---|---|---|---|
| 4 | **SSH cert auth + `ssh-agent` semantics.** Cert auth (CA-signed) is unmentioned. `forwardAgent` flag is in the schema but Semicolyn has no agent — flag is decorative in v1. Either remove it from Tier 2 or document semantics (recommend: hard-disable in v1, "v1.5 in-app ephemeral agent" deferred). | medium | resolved | (a) cert auth shipped in v1 — `2026-06-17-ssh-cert-auth-design.md`. (b) `forwardAgent` removed entirely from schema; documented `ProxyJump` as the multi-hop path. |
| 5 | **Jump-host chained Face ID prompts.** Two hops with `anyUse` identities — does the user get prompts in series? One bundled prompt? Will surprise users; spell out the order. | medium | resolved | `2026-06-17-chain-auth-design.md` |
| 6 | **tmux session naming + multi-device policy.** Session-ID generation isn't defined. Two iCloud-paired iOS devices connecting to the same host — share session or fork two? Server-side state could diverge while picker shows one row. | medium | resolved | `2026-06-17-tmux-session-design.md` |
| 7 | **Screenshot / screen-record protection.** No mention anywhere. Security-first marketing vs leaving terminal contents screenshottable by other processes / ReplayKit. Recommend `UIScreen.isCaptured` observation + opt-in App-preferences toggle, or an explicit decision *not* to do this with rationale. | medium | resolved | `2026-06-17-screen-capture-protection-design.md` |
| 8 | **App-uninstall + Secure Enclave key destruction.** One-liner confirming SE-flavor keys are destroyed on uninstall (iOS 10.3+ default) and that's expected behavior, not a surprise. | low | resolved | `2026-06-15-identities-keys-management-design.md` §"App uninstall behavior" |
| 9 | **Mosh + Tailscale roaming interaction.** Mosh roaming assumed to "just work" on IP change; under Tailscale the UDP endpoint can change semantics. Likely fine but a sentence is warranted. | low | resolved | `2026-06-15-multi-connection-switching-design.md` §"Mosh + Tailscale interaction" |

## Added during walk-through

Items that surfaced while resolving the original list and were addressed alongside.

| # | Item | Severity | Status | Resolution |
|---|---|---|---|---|
| W1 | **Color theming plumbing.** Semantic-token layer for color references so v1 can ship Bell Bronze while staying ready for alternative palettes (Pro perk, accessibility, future light mode) without consumer-code churn. Surfaced from #1(b) bell-halo color discussion. | medium | resolved | `2026-06-17-design-tokens-design.md` |
| W2 | **Terminal UX additions** — font size (incl. pinch-zoom + ⌘+/⌘-/⌘0), URL tap-to-open (http/https/ssh), cursor style + blink + DECSCUSR, scrollback buffer policy (tmux mode is tmux's; raw-PTY default 5000, slider to 'unlimited'), explicit resize / rotation policy, port-forward runtime status in Esc-pill picker Live row. Surfaced as a bundle of basic-terminal-client gaps no spec had covered. | medium | resolved | `2026-06-17-terminal-ux-additions-design.md` |

## Nice-to-tighten

Take-or-leave polish.

| # | Item | Severity | Status | Resolution |
|---|---|---|---|---|
| 10 | README "multiple simultaneous live connections" pitch doesn't mention the soft cap of 8 from `multi-connection-switching`. Power-user reader would expect unbounded. | trivial | resolved | README.md inline parenthetical added. |
| 11 | `mosh-server` binary missing surfaces as generic "unreachable" — mosh users have a specific mental model for that failure and a tailored message would help. | trivial | resolved | `2026-06-15-multi-connection-switching-design.md` §"Mosh resume" — specific failure messages added. |
| 12 | **Privacy statement** content (drilled-down from About & Help) is load-bearing for Semicolyn's marketed posture but has no draft. Worth a content pass before code so App Store submission isn't blocked. | medium | resolved | `2026-06-17-privacy-statement-design.md` |
| 13 | README's Layout section lists every spec date individually; at 16 specs it's already long. Cosmetic. | trivial | resolved | README.md — replaced inline list with directory pointer. |
| 14 | **Encrypted-key passphrase lifetime** — covered for imports, worth a sentence confirming Semicolyn never retains or re-prompts; the iCloud Keychain copy is the canonical decrypted-equivalent under iOS data protection. | trivial | resolved | `2026-06-15-identities-keys-management-design.md` §"Create / Import sub-flow" passphrase row — expanded. |

---

## Out of scope for this punch list

These are the deliberately-deferred-to-v1.5+ items that came up in earlier sweeps and are **not** open brainstorm work:

- v2 custom inputView (letter-to-alt mapping)
- iPad-native surfaces (`UISceneSession` multi-window, landscape layouts, trackpad pointer)
- In-app hardware-Esc rebind
- Custom Cmd-shortcut remapping
- Font-size shortcuts (`⌘+` / `⌘−`)
- Scrollback navigation shortcuts (`⌘Home` / `⌘End`)
- Pane layout templates (`even-horizontal`, `even-vertical`, `main-horizontal`, `main-vertical`, `tiled`)
- Alternative color palettes (a Pro perk; needs a second palette designed)
- Alternative app icons (a Pro perk; needs concepts)
- Default app icon design
- Crash reporting policy (out-of-app failure surface)
- Local / push notifications policy beyond "notify on command done" (already deferred)
- App Store screenshots, listing copy, ASO
