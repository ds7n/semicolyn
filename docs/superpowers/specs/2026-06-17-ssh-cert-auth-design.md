# SSH certificate authentication (client-side)

**Date:** 2026-06-17
**Status:** Locked
**Resolves:** sub-item (a) of punch-list item #4 in `docs/final-review-punchlist.md`. The `forwardAgent` sub-item is resolved by removal — see "Cross-spec consequences."

## Goal

Support SSH client certificate authentication in v1. A user whose private key is signed by an SSH CA (Smallstep, HashiCorp Vault SSH CA, Teleport, Step CA, etc.) can present `<cert> + <private key>` instead of just `<private key>` during the SSH handshake. Servers configured to trust the CA accept the connection without per-user public-key distribution.

Skipping this in v1 cedes the corporate / managed-SSH user segment to Termius. Neotilde's positioning as a security-first, professional SSH client warrants including it.

## Scope

- Client-side cert presentation only. Neotilde does **not** issue, generate, or sign certificates; that's the user's CA's job.
- Cert + private-key pairing at the **identity** level. A single identity in `Settings → Identities & Keys` can have an associated cert.
- Cert metadata visible: principals, validity window, key ID, source CA fingerprint, critical options.
- Expiry handling: warning when near expiry, hard-fail when expired.

## Schema

Additive change to the identity schema in [[2026-06-15-host-config-model-design]]:

```yaml
identities:
  - id: <uuid>
    label: "Personal ed25519"
    flavor: iCloudKeychain | secureEnclave
    keyRef: <opaque-keychain-handle>
    authPolicy: never | afterUnlock | anyUse
    cert:                          # NEW, optional
      blob: <base64-encoded-cert>  # The full cert string (ssh-{algo}-cert-v01@openssh.com format)
      cachedMetadata:              # parsed at write time; refreshed on import
        keyId: "user@example.com"
        principals: ["alice", "ops-team"]
        validAfter: 2026-06-01T00:00:00Z
        validBefore: 2027-06-01T00:00:00Z
        caFingerprint: "SHA256:..."
        criticalOptions: { ... }
        extensions: { ... }
```

`cert.blob` is the source of truth; `cachedMetadata` is for fast display and is regenerated on import (and can be regenerated on demand). Storage shape: the cert lives alongside the key reference in iCloud Keychain (for `iCloudKeychain` flavor) or attached to the SE-bound identity record (for `secureEnclave` flavor). The cert itself is *not* secret — it can be in plaintext storage if a stack prefers — but co-locating with the identity keeps the lookup simple.

**Per-key-type:** a single identity record carries one cert. If a user has separate certs for separate key algorithms, they're separate identities (which they would be anyway because the underlying private key differs).

## Import flow

Add a step to the existing identity create/import half-sheet from [[2026-06-15-identities-keys-management-design]].

The half-sheet's three tabs (**Pick existing · Create new · Import existing**) gain a single addition: on **Import existing**, after the user pastes/imports the private key (or selects a Keychain entry), a new optional row appears below labeled **Certificate (optional)** with the same paste/file-pick affordances.

```
┌─────────────────────────────────────────┐
│  Import existing identity                │
├─────────────────────────────────────────┤
│  Private key                             │
│  ┌─────────────────────────────────────┐ │
│  │  (paste OpenSSH private key here)   │ │
│  └─────────────────────────────────────┘ │
│  [📎 File…]                              │
│                                          │
│  Certificate (optional)                  │
│  ┌─────────────────────────────────────┐ │
│  │  (paste ssh-keygen -L output or     │ │
│  │   the cert string here)             │ │
│  └─────────────────────────────────────┘ │
│  [📎 File…]                              │
│                                          │
│  ⓘ A certificate signed by your CA      │   ← only shown when cert field empty
│    binds this key to the CA's policy.    │
│    Most users will not have one.         │
│                                          │
│  Display name                            │
│  ┌─────────────────────────────────────┐ │
│  │  Work laptop                         │ │
│  └─────────────────────────────────────┘ │
│                                          │
│  ┌──────────────────┐  ┌──────────┐     │
│  │  Save            │  │  Cancel  │     │
│  └──────────────────┘  └──────────┘     │
└─────────────────────────────────────────┘
```

- Pasting a cert auto-parses; if it doesn't match the imported key, a red validation row appears: *"This certificate does not match the imported key."* Save is disabled until either fixed or the cert is cleared.
- The "Pick existing" tab does not gain a cert field — the existing Keychain identity already has its cert (or doesn't); editing it is a future concern.
- The "Create new" tab does not gain a cert field — Neotilde-generated keys are not certified by a CA. (User can sign the generated public key with their CA out-of-band and re-import via "Import existing.")

## Identity-management surface

The identity detail screen from [[2026-06-15-identities-keys-management-design]] gains a new section between **Public key + fingerprint** and **Used by N hosts**:

```
─── Certificate ─────────────────────────
Key ID:       user@example.com
Principals:   alice, ops-team
Valid:        2026-06-01 → 2027-06-01   (340 days remaining)
CA:           SHA256:abc…xyz
Critical opts: source-address=10.0.0.0/8
Extensions:   permit-pty, permit-port-forwarding

[ Re-import certificate ]   [ Remove certificate ]
─────────────────────────────────────────
```

- Section is **collapsed by default**; user taps the disclosure to expand. (Most identities won't have a cert; an always-expanded empty section would be noise.)
- When the identity has no cert, the section header reads "Certificate" with a dim caption *"None — uses public-key authentication only"* and no action buttons.
- **Re-import certificate** opens the same paste/file-pick UI as the import flow, scoped to this identity.
- **Remove certificate** opens a confirm action sheet ("Remove certificate from `<identity>`? The private key remains."). Removes only the cert; key is untouched.

### Identity list chip

The alphabetical list at `Settings → Identities & Keys` gains a small `cert` chip next to the existing `iCloud` / `SE` flavor chip for any identity that has a cert. Tiny, monospace, bell-bronze.

### Expiry warning chip

When `validBefore` is within **14 days** of the current date, the identity row in the list and the identity detail header show an amber **`expires 8d`** chip. When the cert is already expired, the chip turns red and reads **`expired`**.

The warning chip appears alongside the `cert` chip:

```
[Personal ed25519]   iCloud  cert  expires 8d
[Work laptop]        iCloud  cert  expired
```

The chip is informational, not blocking — at this stage the user can still review the identity. The hard block is on the auth path, below.

## Auth flow

When an identity is used to authenticate to a host:

- **Cert present + not expired:** Neotilde passes `<cert> + <private-key>` to the SSH stack. The stack negotiates a cert-based key exchange (algorithm name `ssh-ed25519-cert-v01@openssh.com`, etc.).
- **Cert present + expired:** Neotilde refuses to use the identity for this connection. The connect attempt fails with a clear error: *"Certificate expired on `<identity>` ({date}). Re-import or remove the certificate to use the underlying key instead."* No silent fallback to the bare key — falling back would surprise the user (their CA-signed identity suddenly auths as a different user).
- **No cert:** existing behavior. Bare public-key auth.

**Algorithm allowlist intersection.** The host's negotiated `HostKeyAlgorithms` and the cert's signing algorithm must both be permitted by [[2026-06-17-ssh-algorithms-design]]'s tier rules. v1's Tier 1 already includes `ssh-ed25519-cert-v01@openssh.com`; RSA cert variants (`rsa-sha2-512-cert-v01`, `rsa-sha2-256-cert-v01`) need to be added — see Cross-spec consequences.

**CA trust:** Neotilde does not validate the CA against any client-side trust store. The server is the only party that decides if a cert is valid (it has the CA's trusted public key in `TrustedUserCAKeys`). Client-side cert validation would duplicate the server's job without benefit. Neotilde only checks that:

1. The cert's signature is well-formed (parser sanity)
2. The cert's `validAfter` ≤ now ≤ `validBefore` (expiry)
3. The cert's underlying public key matches the imported private key (pair sanity)

## Out of scope (v1)

- **Cert rotation wizard.** Stays deferred to v1.5+ alongside the existing identity rotation wizard. Without `ssh-copy-id`-style auto-install of new CA-signed certs, a rotation wizard is a checklist with a hand-wave.
- **Auto-renewal from a CA.** Some CAs (Step CA, Vault SSH) support API-based cert renewal. Real value but real surface (CA-protocol picker, API token storage, refresh scheduling). v1.5+ if demand.
- **Cert generation from Neotilde.** Neotilde does not sign. Users get certs from their CA out-of-band.
- **Per-host cert override.** A host can't be configured to "use cert X with identity Y." The cert is bound to the identity. Power users who need multiple cert-bearing identities create multiple identity records.
- **Cert-format conversion.** v1 accepts OpenSSH cert format only. PEM/DER conversion is out.
- **CA-signed host certificate validation surface.** Neotilde-side trust of CA-signed host certs (different from client certs) is governed by the host-key trust UX in [[2026-06-17-host-key-trust-design]] — `ssh-ed25519-cert-v01@openssh.com` host keys go through the same fingerprint-trust flow. Trusting the underlying CA's public key as a wildcard for host certs is a separate v1.5+ feature.

## Cross-spec consequences

- [[2026-06-15-host-config-model-design]] — identity schema gains optional `cert.{blob, cachedMetadata}`. Additive; existing records without `cert` are unchanged. **Also: `forwardAgent` is removed entirely from the schema's Tier 2 options.** Agent forwarding is not supported; users wanting bastion-style multi-hop use `proxyJump` (already in Tier 1). A note in the host-config spec documents the removal and recommends `ProxyJump`.
- [[2026-06-15-identities-keys-management-design]] — identity detail screen gains the Certificate section (collapsed by default), expiry chip in the list and detail header, `cert` flavor chip in the list. Out-of-scope list updated to remove "key rotation flows" duplicate.
- [[2026-06-15-host-crud-design]] — no change. Identity selection in the auth section is by identity-id; cert is implicit.
- [[2026-06-17-ssh-algorithms-design]] — Tier 1 expands to include the cert variants of currently-allowed signature algorithms:
  - `ssh-ed25519-cert-v01@openssh.com` *(already listed)*
  - `rsa-sha2-512-cert-v01@openssh.com` *(add)*
  - `rsa-sha2-256-cert-v01@openssh.com` *(add)*
  - `ecdsa-sha2-nistp256-cert-v01@openssh.com` *(add)*
  - `ecdsa-sha2-nistp384-cert-v01@openssh.com` *(add)*
  - `ecdsa-sha2-nistp521-cert-v01@openssh.com` *(add)*
  Tier 3 expands to include `ssh-rsa-cert-v01@openssh.com` *(SHA-1 cert; behind the Tier 3 toggle)*.

## Related

- [[2026-06-15-identities-keys-management-design]]
- [[2026-06-15-host-config-model-design]]
- [[2026-06-17-ssh-algorithms-design]]
- [[2026-06-17-host-key-trust-design]]
