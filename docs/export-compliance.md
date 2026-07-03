# Export compliance — encryption classification

**Summary:** semicolyn self-classifies as **mass-market encryption software, ECCN
5D992.c** (standard, published cryptographic algorithms used to secure the user's
own SSH/Mosh connections). It ships **no proprietary or non-standard encryption**.
The app's Info.plist declares `ITSAppUsesNonExemptEncryption = NO`, and True Positive
LLC asserts the mass-market exemption for this usage.

This document records the basis for that classification so it can be reviewed or
revised (e.g. with counsel) rather than re-derived each release.

## What crypto the app actually uses

All cryptography is **standard, well-known, and published** — no custom primitives:

| Path | Backend | Algorithms |
|---|---|---|
| **Mosh transport** | Apple **CommonCrypto** (iOS SDK) | AES-128-OCB (SSP), plus the vendored Mosh protocol |
| **SSH transport** | **russh 0.61** → `aws-lc-rs` (+ RustCrypto: `aes`, `chacha20`, `curve25519-dalek`, `ed25519-dalek`) | AES-CTR/GCM, ChaCha20-Poly1305, curve25519 (X25519/Ed25519), ECDSA, RSA |
| Key storage | iOS Keychain / Secure Enclave | ed25519 / SE-backed keys |

The encryption exists to secure the **user's own remote-shell connections** — the
core, and mass-market, function of a terminal client.

## Why this is the mass-market case, not the fully-exempt case

Apple's export-compliance flow
(<https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption/>)
distinguishes:

- **"Encryption limited to that within the Apple operating system"** → fully exempt,
  no documentation. semicolyn does **not** qualify for this, because the **SSH path's
  crypto is provided by russh (aws-lc-rs / RustCrypto), not by Apple's OS crypto.**
  (The Mosh path *does* use Apple CommonCrypto, but the SSH path does not, so the
  app as a whole is not "Apple-OS-crypto only".)
- **"Industry-standard algorithm, not provided within the Apple OS"** → this is the
  bucket semicolyn falls in: standard algorithms, publicly available, but bundled
  rather than OS-provided. This is the **mass-market (5D992.c)** classification.

Because the algorithms are all standard/published (not proprietary), no CCATS is
required. Since the March 2021 BIS rule change, mass-market software using **standard**
algorithms **no longer requires a self-classification report** to BIS/NSA (that duty
now attaches only to non-standard cryptography). We use only standard algorithms, so
no annual self-classification report is required.

## France / ANSSI

France requires a separate **ANSSI declaration** for non-exempt encryption before an
app is *listed* in the French App Store. Interim posture (see the `testflight-lane-live`
memory): **exclude France in App Store Connect → Pricing and Availability** to unblock
testing; complete the ANSSI declaration before any public French listing. Territory
exclusion lives in Availability, not TestFlight (internal testing ignores territory).

## Why `ITSAppUsesNonExemptEncryption = NO` (not YES)

Apple accepts `NO` for apps whose encryption qualifies for an exemption **including the
mass-market exemption**. Answering `YES` demands a matching `ITSEncryptionExport
ComplianceCode` in the Info.plist; without one, the TestFlight upload fails with a
`409 Invalid Export Compliance Code` (observed 2026-07-03, ASC validation). Since we
self-classify under the mass-market exemption, `NO` is the correct answer and avoids a
per-build compliance code. The comparison point: **Blink** (the reference iOS Mosh/SSH
client) ships **no** `ITSAppUsesNonExemptEncryption` key at all and answers the
export-compliance question manually per build in App Store Connect.

## If this needs revisiting

- If a future dependency adds **non-standard/proprietary** crypto → the mass-market
  exemption no longer applies; a self-classification report (and possibly CCATS) would
  be required.
- Before **listing publicly in France** → complete the ANSSI declaration and, if Apple
  issues an `ITSEncryptionExportComplianceCode`, switch to `YES` + that code.
- This classification is an assertion by True Positive LLC; confirm with export-control
  counsel before a public (non-TestFlight) release if in doubt.
