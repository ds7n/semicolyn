#!/bin/sh
# SPDX-FileCopyrightText: 2026 True Positive LLC
# SPDX-License-Identifier: GPL-3.0-only
set -e
ssh-keygen -A
mkdir -p /home/tester/.ssh
# Generate a throwaway test keypair into the shared volume on first boot.
if [ ! -f /testkeys/id_ed25519 ]; then
  ssh-keygen -t ed25519 -N '' -C 'semicolyn-test' -f /testkeys/id_ed25519
fi
# World-readable so the (non-root) dev container can read the private key.
# This is a disposable CI fixture key, never a real credential.
chmod 644 /testkeys/id_ed25519 /testkeys/id_ed25519.pub
cp /testkeys/id_ed25519.pub /home/tester/.ssh/authorized_keys
chown -R tester:tester /home/tester/.ssh
chmod 700 /home/tester/.ssh
chmod 600 /home/tester/.ssh/authorized_keys
# --- Client-certificate auth fixture (Phase 1c-cert) ---
# A disposable CA that signs the test user key. Never a real credential.
if [ ! -f /testkeys/ca ]; then
  ssh-keygen -t ed25519 -N '' -C 'semicolyn-test-ca' -f /testkeys/ca
fi
chmod 644 /testkeys/ca.pub
# Sign id_ed25519 into three certs for principal 'tester': valid-now, expired,
# and not-yet-valid. ssh-keygen names the output "<input-basename>-cert.pub",
# so sign copies to get distinct filenames. Re-signed every boot (validity
# windows stay fresh; the fixed-date ones stay expired/future).
cp /testkeys/id_ed25519.pub /testkeys/valid.pub
cp /testkeys/id_ed25519.pub /testkeys/expired.pub
cp /testkeys/id_ed25519.pub /testkeys/notyet.pub
# Must be 600 for ssh-keygen -s to accept it (even on reboot when a prior boot
# left it 644). Set immediately before signing, then relax after so the
# non-root dev container can read it on the mounted volume.
chmod 600 /testkeys/ca
ssh-keygen -s /testkeys/ca -I semicolyn-valid   -n tester -V -5m:+52w   /testkeys/valid.pub
ssh-keygen -s /testkeys/ca -I semicolyn-expired -n tester -V 20000101000000:20000102000000 /testkeys/expired.pub
ssh-keygen -s /testkeys/ca -I semicolyn-notyet  -n tester -V +52w:+104w /testkeys/notyet.pub
chmod 644 /testkeys/ca
chmod 644 /testkeys/valid-cert.pub /testkeys/expired-cert.pub /testkeys/notyet-cert.pub
# Trust the CA for user authentication (idempotent across reboots).
grep -q '^TrustedUserCAKeys' /etc/ssh/sshd_config \
  || echo 'TrustedUserCAKeys /testkeys/ca.pub' >> /etc/ssh/sshd_config
exec "$@"
