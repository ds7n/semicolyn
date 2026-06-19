#!/bin/sh
# SPDX-FileCopyrightText: 2026 True Positive LLC
# SPDX-License-Identifier: GPL-3.0-only
set -e
ssh-keygen -A
mkdir -p /home/tester/.ssh
# Generate a throwaway test keypair into the shared volume on first boot.
if [ ! -f /testkeys/id_ed25519 ]; then
  ssh-keygen -t ed25519 -N '' -C 'glymr-test' -f /testkeys/id_ed25519
fi
# World-readable so the (non-root) dev container can read the private key.
# This is a disposable CI fixture key, never a real credential.
chmod 644 /testkeys/id_ed25519 /testkeys/id_ed25519.pub
cp /testkeys/id_ed25519.pub /home/tester/.ssh/authorized_keys
chown -R tester:tester /home/tester/.ssh
chmod 700 /home/tester/.ssh
chmod 600 /home/tester/.ssh/authorized_keys
exec "$@"
