// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import os

/// First performance instrumentation (Plan B §B3). `input` brackets the sacred
/// keystroke→transport-write path so its latency is independent of predictor cost
/// and can be watched in Instruments. Zero cost when not being traced.
enum PerfSignposts {
    static let input = OSSignposter(subsystem: "dev.truepositive.semicolyn", category: "input")
}
