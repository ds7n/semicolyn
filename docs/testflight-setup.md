# TestFlight from CI — no personal Mac required

Semicolyn can be built, signed, and shipped to your iPhone entirely on GitHub's macOS
runner via TestFlight. The `.github/workflows/release-testflight.yml` lane is **dormant**
until you complete the one-time setup below — it only runs when **manually triggered** *and*
the repo variable `TESTFLIGHT_ENABLED=true` is set.

Signing uses an **App Store Connect API key** with `-allowProvisioningUpdates`, so Xcode
creates the distribution certificate + provisioning profile in the cloud. Nothing is
generated on a local Mac.

## Prerequisites
- **Paid Apple Developer Program** membership (the True Positive LLC org enrollment). A free
  Apple ID **cannot** use TestFlight — this is the one hard gate.
- That's it. No Mac, no Xcode locally.

## One-time setup

1. **App record** — in [App Store Connect](https://appstoreconnect.apple.com) → **Apps** →
   **+** → New App: platform iOS, bundle ID **`com.truepositive.semicolyn`** (must match
   `project.yml`), name `Semicolyn`, your primary language + SKU.

2. **App Store Connect API key** — Users and Access → **Integrations** → App Store Connect API
   → **Generate API Key**. Give it the **App Manager** role. Then capture:
   - **Key ID** (e.g. `A1B2C3D4E5`)
   - **Issuer ID** (a UUID, shown at the top of the page)
   - **Download the `.p8` file** — *you can only download it once.*

3. **Team ID** — Membership page (developer.apple.com/account) → the 10-char Team ID.

4. **GitHub repo secrets** (Settings → Secrets and variables → Actions → **Secrets**):
   | Secret | Value |
   |---|---|
   | `ASC_API_KEY_ID` | the Key ID |
   | `ASC_API_ISSUER_ID` | the Issuer ID |
   | `ASC_API_KEY_P8` | the full contents of the `.p8` file (paste incl. the BEGIN/END lines) |
   | `APPLE_TEAM_ID` | the Team ID |

5. **GitHub repo variable** (same page → **Variables**): `TESTFLIGHT_ENABLED` = `true`.
   This is the switch that un-dorms the lane.

## Ship a build
- GitHub → **Actions** → **Release to TestFlight** → **Run workflow**.
- It archives the device build, signs it, exports the `.ipa` (kept as a run artifact), and
  uploads to TestFlight. Build number = the workflow run number (auto-increments).
- In App Store Connect → your app → **TestFlight**: the build processes (~5–15 min), then add
  yourself to **Internal Testing**.
- On the iPhone: install **TestFlight** from the App Store → accept the invite → install the
  build. Re-running the workflow pushes a new build to the same testers.

## First-run notes / likely snags
- **App icon required.** TestFlight rejects builds without a 1024×1024 app icon. If the first
  upload is held for "missing icon," add an `AppIcon` asset to the app target before re-running.
- **Export/upload tooling.** The lane exports the `.ipa` then uploads with `xcrun altool`. If a
  future Xcode drops `altool`, download the `Semicolyn-ipa` run artifact and drag it into
  **Transporter** (Mac App Store) or switch the export-options `destination` to `upload`.
- **Signing is the classic CI snag.** Expect a tweak or two on the very first run (capabilities,
  bundle-ID mismatch, profile role). After it's green once it stays green.
- **No project.yml change needed** — the Simulator CI stays unsigned (`CODE_SIGNING_ALLOWED:
  NO`); this lane overrides `CODE_SIGNING_ALLOWED=YES` + team on the `xcodebuild` command line.

## Why this beats a cabled Mac for *this* project
- Unblocks the owed device feel-passes (cursor-placement gesture + haptics, keybar 4a–4e,
  theme live-recolor, hardware keyboard, real Keychain) with no extra hardware.
- Trade-off: a few minutes of TestFlight processing per build (vs. seconds over a cable), and
  no live Xcode debugger — crash logs come via TestFlight / Xcode Organizer. Fine for
  exercising touch/feel; a Mac is only nicer for deep debugging.
