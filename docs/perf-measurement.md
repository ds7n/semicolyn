<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Measuring keystroke latency

The `send` os_signpost interval (`PerfSignposts.input`, subsystem
`dev.truepositive.semicolyn`, category `input`) brackets the sacred keystroke →
transport-write path. Because the predictor now runs AFTER the write (Plan B),
this interval's duration should be independent of predictor cost.

**Capture (on device or Simulator):**
1. Xcode → Product → Profile (⌘I) → **os_signpost** (or **Time Profiler**) template.
2. Type a burst / paste into an active session.
3. Filter Instruments to subsystem `dev.truepositive.semicolyn`, category `input`.
4. Read the `send` interval durations. Regression = the distribution creeps up,
   especially correlating with predictor/keybar activity — which would mean
   something re-coupled work onto the send path.

This is the number that makes "snappy" objective instead of a fear.
