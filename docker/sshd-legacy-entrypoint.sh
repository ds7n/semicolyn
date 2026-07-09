#!/bin/sh
# SPDX-FileCopyrightText: 2026 True Positive LLC
# SPDX-License-Identifier: GPL-3.0-only
#
# Minimal entrypoint for the legacy Tier-3 fixture. It ONLY generates host
# keys and starts sshd — it deliberately does NOT run the shared-/testkeys
# key/cert-signing dance that the modern sshd entrypoint does. Both fixtures
# share one `testkeys` volume; when the legacy container also ran the full
# entrypoint, the two containers raced on `/testkeys/ca` (one chmod 644'd it
# while the other was mid `ssh-keygen -s`, which requires 600) — ssh-keygen
# then failed "bad permissions", `set -e` aborted, and the container exited
# 255. The legacy integration test only exercises algorithm negotiation
# (tier3_algorithms_are_detected_when_negotiated); it never authenticates with
# the shared keys/certs, so legacy needs none of that setup.
set -e
ssh-keygen -A
exec "$@"
