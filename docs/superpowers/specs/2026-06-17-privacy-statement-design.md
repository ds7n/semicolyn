# Privacy statement — content + placement

**Date:** 2026-06-17
**Status:** Locked
**Resolves:** punch-list item #12 in `docs/final-review-punchlist.md`. Required for App Store submission and load-bearing for Neotilde's "security-first, no telemetry" marketing posture.

## Placement

Reached from **About & Help → Privacy statement** per [[2026-06-16-settings-sub-screens-design]]. Full-screen push, scrollable plain-prose with section headings. No interactive elements except a single "Contact us" mail link at the bottom.

The same content (slightly reformatted as HTML for the App Store privacy page) appears at the App Store privacy section. The Neotilde website hosts a copy at `neotilde.app/privacy` (placeholder URL; actual TLD TBD).

The in-app page is the canonical source. App Store and website are mirrors.

## Visual treatment

- Background: `Color.theme.surface.bg`
- Section headings: bell-bronze, ~17pt semi-bold
- Body: `Color.theme.text.primary`, ~15pt regular, line-height 1.5
- No graphics, no icons, no info boxes. Plain text reads as serious; chrome reads as marketing.

## Content (v1 draft)

The text below is the v1 draft. Final pass before App Store submission may tighten language; the substance is locked.

---

### How Neotilde handles your data

Neotilde is an SSH client. The connections you make are between your device and the servers you choose; Neotilde is not an intermediary, does not see your traffic, and does not have a server-side component.

### What Neotilde collects

Nothing.

Neotilde ships no analytics, no telemetry, no crash reporting, no usage tracking, no advertising identifiers, no third-party SDKs that collect any of the above. We do not know which hosts you connect to, when, how long, or how often. We don't know which features you use. There is no Neotilde account.

### What Neotilde stores on your device and your iCloud

To do its job, Neotilde needs to remember a few things across launches and across your devices. All of it lives in places Apple controls — there is no Neotilde cloud service.

**SSH identities (private keys).** Stored in iCloud Keychain (synced end-to-end encrypted across your Apple devices) or the Secure Enclave (hardware-bound to a single device, your choice when creating the identity). Neotilde never reads the raw key bytes for any purpose other than the SSH handshake.

**Host configurations** (hostnames, usernames, port numbers, references to identities, port-forward rules, your custom labels and notes). Stored in CloudKit Private Database, encrypted with a key that lives in your iCloud Keychain — effectively end-to-end encrypted regardless of your Advanced Data Protection setting.

**Known host fingerprints** (the `known_hosts` equivalent). Stored in iCloud Keychain, synced.

**Macros / snippets and keybar customizations.** Stored in CloudKit Private Database with the same client-side encryption layer. iCloud sync is on by default with a per-item "don't sync" flag for sensitive content.

**Predictor sketches.** A statistical fingerprint (Count-Min Sketch + Bloom filter) of vocabulary you've typed at the shell. Not recoverable text. Stored locally and optionally synced to iCloud (default on, opt-out per device) using the same client-side encryption layer.

**Recent connections.** Local-only. Not synced. Lists the last hosts you connected to so the picker can offer reconnect.

**Live session state.** Local-only. Not synced. Includes per-connection tmux state IDs and mosh resume tokens for the lifetime of the session.

### What Neotilde does *not* store

- No audit log of your activity (deferred to a future Pro/enterprise edition; the data layer reserves a stub but writes nothing in v1).
- No record of what you typed at the prompt outside the predictor sketch above.
- No record of what scrolled across your terminal.
- No copies of files you transferred.

### iCloud sync

Per-category toggles live at **Settings → App preferences → iCloud sync**. You can opt any of the synced categories out at any time. Turning sync off does not delete previously-synced data from iCloud — to remove that, delete the data itself from inside Neotilde, or sign out of iCloud.

End-to-end encryption applies to all synced categories, including without Advanced Data Protection enabled. The encryption key for non-Keychain categories lives only in your iCloud Keychain.

### Third parties

None. Neotilde embeds no third-party SDKs that collect, transmit, or share user data. The only network requests Neotilde makes are SSH and mosh connections to the hosts you configure, plus iOS-level iCloud sync that Apple handles.

### Screen capture

iOS allows screenshots and screen recording of any app, and provides no way to prevent screenshots. Neotilde replaces its on-screen content with a privacy overlay whenever the app appears in the iOS app switcher, so terminal content does not leak into the multitasking thumbnail. An optional setting at **Settings → Security → Hide content while screen is being captured** blanks the terminal panes during AirPlay, mirroring, or screen recording — off by default, since terminal demos and screencasts are common, legitimate uses. Neotilde cannot prevent screenshots and does not show a notification when one is taken.

### Identities, certificates, and key destruction

iCloud Keychain identities survive uninstalling and reinstalling Neotilde — the iCloud-synced copy is restored when you sign in again. Secure Enclave identities are bound to this device and this install; uninstalling Neotilde permanently destroys them. This matches what iOS does to any app's Keychain data on uninstall.

### Children

Neotilde is rated 17+ in the App Store because it can connect to arbitrary remote servers whose content we cannot moderate.

### Changes to this statement

Material changes to data handling will ship in an app update along with a one-time in-app notice at next launch. The in-app page in your current version is always the authoritative source for what *that version* does.

### Contact

[hello@neotilde.app](mailto:hello@neotilde.app)

---

## Out of scope (v1)

- **Localized translations.** v1 is English-only; the privacy statement is too. Translations come with the rest of the localization work, which is deferred.
- **Per-region variants** (e.g., GDPR-specific phrasing, CCPA notice). v1 ships one statement that the maintainer believes covers the substantive obligations of the major regimes — the simplicity ("we don't collect anything") makes regime-specific carve-outs largely unnecessary. Revisit when shipping in a market that requires specific text.
- **Cookie policy.** Neotilde has no website state to disclose; the app doesn't use cookies. Not relevant in v1.

## Maintenance triggers

Update the in-app statement and re-submit to the App Store privacy section when:

- A new data category is collected, stored, or synced (this should be rare).
- A third-party SDK that handles user data is added (this should be never).
- A new sync surface ships (e.g., CloudKit container changes).
- A new data destruction or export feature ships.

## Cross-spec consequences

- [[2026-06-16-settings-sub-screens-design]] — About & Help → Privacy statement is the entry point; this spec is the content.
- [[2026-06-16-icloud-sync-scope-design]] — the iCloud-sync paragraph here must stay aligned with what the sync spec actually does.
- [[2026-06-13-predictor-design]] — the predictor-sketch paragraph here must stay aligned with the predictor's sync and structural-loss properties.
- [[2026-06-15-identities-keys-management-design]] — the uninstall paragraph here mirrors the §"App uninstall behavior" subsection there.
- [[2026-06-17-screen-capture-protection-design]] — the screen-capture paragraph here mirrors that spec's posture.

## Related

- [[2026-06-16-settings-sub-screens-design]]
- [[2026-06-16-icloud-sync-scope-design]]
- [[2026-06-13-predictor-design]]
- [[2026-06-15-identities-keys-management-design]]
- [[2026-06-17-screen-capture-protection-design]]
