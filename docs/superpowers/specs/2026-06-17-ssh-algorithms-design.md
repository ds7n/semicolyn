# SSH algorithm allowlist

**Date:** 2026-06-17
**Status:** Locked
**Resolves:** punch-list item #3 in `docs/final-review-punchlist.md`.

## Goal

Lock the v1 SSH algorithm policy: which key-exchange, host-key, cipher, and MAC algorithms Semicolyn will offer, how the user can broaden the set for legacy hosts, and what the maintenance cadence is.

## Model — four tiers

Algorithms fall into exactly one tier. Tier membership governs whether the algorithm is offered, whether the user must opt in, and whether each connection produces a warning.

| Tier | Negotiated? | User opt-in? | Per-connect warning? |
|---|---|---|---|
| 1 — Accepted | Always | No | No |
| 2 — Legacy but allowed | When the per-host toggle is on | Yes (one-time, at toggle) | No |
| 3 — Legacy & risky | When the per-host toggle is on | Yes (one-time, at toggle) | Yes (every connect) |
| 4 — Never allowed | Never | N/A | N/A |
| Unclassified | Never | N/A | N/A |

**Closed set.** The negotiation list passed to the SSH stack contains *only* the algorithms on a permitted tier for the current host. Algorithms not on any tier are not offered, regardless of what the SSH library would otherwise propose. New algorithms wait for an app update.

## Tier 1 — Accepted

The default modern set. Always offered. No user surface.

**Key exchange:**

- `sntrup761x25519-sha512@openssh.com` *(hybrid PQ + ECDH, OpenSSH 9.0+)*
- `mlkem768x25519-sha256` *(hybrid NIST ML-KEM + ECDH, OpenSSH 9.9+)*
- `curve25519-sha256`
- `curve25519-sha256@libssh.org`
- `ecdh-sha2-nistp256`
- `ecdh-sha2-nistp384`
- `ecdh-sha2-nistp521`
- `diffie-hellman-group16-sha512`
- `diffie-hellman-group18-sha512`

**Host key:**

- `ssh-ed25519`
- `ssh-ed25519-cert-v01@openssh.com`
- `rsa-sha2-512`
- `rsa-sha2-256`
- `ecdsa-sha2-nistp256`
- `ecdsa-sha2-nistp384`
- `ecdsa-sha2-nistp521`

**Cipher:**

- `chacha20-poly1305@openssh.com`
- `aes256-gcm@openssh.com`
- `aes128-gcm@openssh.com`
- `aes256-ctr`
- `aes192-ctr`
- `aes128-ctr`

**MAC** *(used only with non-AEAD ciphers)*:

- `hmac-sha2-256-etm@openssh.com`
- `hmac-sha2-512-etm@openssh.com`
- `umac-128-etm@openssh.com`
- `hmac-sha2-256`
- `hmac-sha2-512`

## Tier 2 — Legacy but allowed

Deprecated but not catastrophically broken. Per-host toggle `semicolyn.allowLegacyAlgorithms` (default `false`). When toggle is on, these are added to the negotiation list for that host. No per-connect warning.

- KEX: `diffie-hellman-group14-sha256`, `diffie-hellman-group-exchange-sha256`
- Cipher: `aes256-cbc`, `aes192-cbc`, `aes128-cbc`

CBC has known padding-oracle attack history but stays workable when paired with modern MACs over a fresh handshake. Group14-SHA256 is below current strength recommendations but still defensible for legacy hosts.

## Tier 3 — Legacy & risky

Cryptographically aged enough to warrant ongoing pressure to upgrade. Per-host toggle `semicolyn.allowDeprecatedAlgorithms` (default `false`). When toggle is on, these are added to the negotiation list. **Every connection that negotiates a Tier 3 algorithm shows a warning** (UX below).

- KEX: `diffie-hellman-group14-sha1`, `diffie-hellman-group-exchange-sha1`
- Host key: `ssh-rsa` *(SHA-1 signature)*
- MAC: `hmac-sha1`, `hmac-sha1-96`

SHA-1 is theoretically broken for collision resistance; SSH host-key signing uses SHA-1 on the public key + transcript, which makes practical attack difficult but not impossible against a determined adversary. The warning makes the user feel the cost so the upgrade pressure stays present.

## Tier 4 — Never allowed

Cryptographically dead. No toggle, no surface, no override path in v1.

- Cipher: `arcfour`, `arcfour128`, `arcfour256`, `3des-cbc`, `blowfish-cbc`, `cast128-cbc`
- MAC: `hmac-md5`, `hmac-md5-96`
- Host key: `ssh-dss` *(DSA-1024)*
- KEX: `diffie-hellman-group1-sha1` *(768-bit)*

A user who genuinely needs to connect to a host that offers nothing else cannot do so from Semicolyn. This is the floor.

## User-facing toggles

Two checkboxes in host CRUD under "Semicolyn behavior":

```
[ ]  Allow legacy algorithms
     SHA-256 DH-14, DH-GEX-SHA256, CBC ciphers. Older but workable.
     Only enable for hosts you cannot update.

[ ]  Allow deprecated algorithms
     SHA-1 signatures, weak DH groups, SHA-1 MACs. Warns on every
     connect. Only enable for hosts you cannot update.
```

Both default off. Per-host. Surfaces in [[2026-06-15-host-crud-design]]'s "Semicolyn behavior" section between the existing `semicolyn.tmux.attemptControlMode` and the existing `semicolyn.osc52.allow` toggles.

## Tier 3 warning UX

**First connection with Tier 3 enabled** *(after the user flips the toggle)*: modal at connect time.

```
Outdated cryptography on this host

This host uses SHA-1 signatures and/or weak Diffie-Hellman
groups. The connection will succeed, but every future session
will show a warning until the host is upgraded.

Negotiated algorithms:
  HostKey: ssh-rsa
  KEX:     diffie-hellman-group14-sha1
  MAC:     hmac-sha1

[  Cancel  ]      [  Continue  ]
```

**Every subsequent connection** *(no modal)*: persistent **amber banner** at the top of the session for its entire lifetime.

- Banner text: "Outdated cryptography on `<host>`."
- Tap to expand → shows the list of Tier 3 algorithms negotiated, using the amber-template body from [[2026-06-16-banner-expanded-design]] with the algo list in place of the latency stats grid.
- The banner can be dismissed for the current session only; it returns on the next connect.
- The banner co-exists with health banners (degraded / broken) — the amber-cryptography banner shows alongside, never in place of, a health alert.

## Schema additions

In the `semicolyn.*` extension namespace (per [[2026-06-15-host-config-model-design]]):

```yaml
semicolyn:
  allowLegacyAlgorithms: false       # Tier 2
  allowDeprecatedAlgorithms: false   # Tier 3
```

Both fields are independent. A user can enable Tier 3 without Tier 2 if they want to — though that's a weird combo.

## Stack compatibility note

This spec assumes an SSH stack that exposes algorithm control (`libssh2` ≥ 1.10 with appropriate patches, or a Swift-native implementation like Citadel / SwiftNIO SSH). `Network.framework`'s SSH layer is opinionated and may not let consumers control all four algorithm categories independently — that's a stack-pick consequence to evaluate at implementation time, not a spec issue.

## Maintenance

The lists above are not write-once. Algorithm guidance evolves:

- New safe algorithms (post-quantum, NIST standardizations) enter Tier 1.
- Algorithms get demoted as practical attacks mature (Tier 1 → Tier 2 → Tier 3 → Tier 4 over years).

**Review triggers** *(committed to here; no separate maintenance doc)*:

1. **Every major OpenSSH release.** OpenSSH's default algorithm changes are a public signal — when they drop or add an algo from defaults, Semicolyn's lists should be re-evaluated.
2. **At every Semicolyn major release** *(roughly: when the version's `.0` increments)*, a pass through this spec against current Mozilla SSH guidelines and the NIST SP 800-52 / SP 800-57 family.
3. **When a practical attack is published** against any currently-listed algorithm. Demote or remove on the next patch release.

The reference sources:
- Mozilla SSH guidelines (`infosec.mozilla.org/guidelines/openssh`)
- OpenSSH release notes (`openssh.com/releasenotes.html`)
- NIST SP 800-52 (TLS) and SP 800-57 (key management) — the underlying primitive guidance that SSH algorithm choices reflect.

The expectation is that the maintainer notices these signals as part of normal SSH-ecosystem awareness, not that a calendar task forces the review. If the rhythm decays, the algorithm lists themselves are the canary — users will complain when they can't connect to a new safe-algo-only host.

## Stack availability (russh 0.61.2) — added 2026-06-17

The v1 SSH stack is **russh 0.61.2**. Three algorithms listed above are not yet
implemented by russh and are **omitted from v1's offered set** (opportunistic
omit, decided 2026-06-17). Each auto-enters its tier when russh gains support;
no spec change is needed at that point — only adding the constant to
`crates/semicolyn-ssh-core/src/algorithms.rs`.

| Omitted algorithm | Tier | russh tracking |
|---|---|---|
| `sntrup761x25519-sha512@openssh.com` | 1 (KEX) | russh #626 |
| `umac-128-etm@openssh.com` | 1 (MAC) | not yet implemented |
| `hmac-sha1-96` | 3 (MAC) | not yet implemented |

Post-quantum key exchange is **unaffected**: russh implements
`mlkem768x25519-sha256`, which remains Tier 1 and the PQC KEX for v1. The Tier-4
"never offered" algorithms (arcfour, blowfish, cast128, 3des, hmac-md5, ssh-dss,
dh-group1) are not implemented by russh either, so excluding them is automatic.

## Out of scope (v1)

- **Per-algorithm fine-grained control** (the Tier 3 host-config schema option) stays deferred to v1.5+. The two-toggle surface is the v1 control.
- **Algorithm preference ordering control** per host (e.g., "prefer rsa-sha2-512 over ed25519 for this host" for FIDO-key reasons). Out of v1.
- **CA-signed host certificates** beyond `ssh-ed25519-cert-v01@openssh.com`. Cert *auth* (client-side) is a separate question — see punch-list item #4.
- **GSSAPI key exchange.** Out of v1. Tier 4 by absence.

## Cross-spec consequences

- [[2026-06-15-host-config-model-design]] — schema gains `semicolyn.allowLegacyAlgorithms` and `semicolyn.allowDeprecatedAlgorithms`, both `bool`, default `false`, in the `semicolyn.*` namespace.
- [[2026-06-15-host-crud-design]] — "Semicolyn behavior" section gains the two toggles with the caveat copy above.
- [[2026-06-16-banner-expanded-design]] — the amber template gets a third use case beyond reconnecting / high-latency: outdated-cryptography. Body content varies (algo list instead of latency stats) but visual shape unchanged.
- [[2026-06-17-host-key-trust-design]] — the algorithm Semicolyn accepts as a host key is now grounded by this spec's HostKey lists.

## Related

- [[2026-06-15-host-config-model-design]]
- [[2026-06-15-host-crud-design]]
- [[2026-06-16-banner-expanded-design]]
- [[2026-06-17-host-key-trust-design]]
