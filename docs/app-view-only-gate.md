<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# The View-only gate

`App/**.swift` is a humble View tier: SwiftUI/UIKit/SwiftTerm wiring + `@Published`
state only. Pure decision logic (arithmetic, parsing, validation, value-returning
state machines) belongs in `Sources/SemicolynKit/`, where it is unit-tested on Linux
in ~2 min instead of discovered on-device after a ~40-min CI/TestFlight round-trip.

`scripts/check-app-view-only.sh` (run in the CI `lint` job) flags the clearest smell:
a free/private function that returns a scalar computed by arithmetic and does not
touch `self.`/`view.`/a SwiftUI type. It is deliberately conservative (low false
positive), so it will miss subtler logic — the primary defence is code review; the
gate is the backstop that catches the obvious regressions.

**If flagged:** move the function to `Sources/SemicolynKit/`, give it a test
(EP + BVA, assert exact expected values), and have the View call it. See
`Sources/SemicolynKit/Tmux/WindowNavigation.swift` for the canonical example.

**False positive?** Tighten the allowlist in the `scan()` function's `grep -vP`
and record the excluded pattern here. Do not disable the gate wholesale.

**Escape hatch:** if the gate proves too noisy in practice, downgrade it from a
hard CI failure to an informational `lint`-job annotation (drop the `exit 1`) and
rely on the code-review checklist — this is the spec's documented fallback.
