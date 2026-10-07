// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Replayable touch log lines: the App logs every touch event in this form so a device log
/// of a misbehaving gesture can be pasted into a Linux test and replayed through the engine.
public extension TouchEvent {
    /// `touch <phase> <x> <y> <time> <count>`, e.g. `touch down 120.50 300.00 12.3457 1`.
    var replayLine: String {
        "touch \(phase.rawValue) \(String(format: "%.2f", point.x)) \(String(format: "%.2f", point.y)) "
            + "\(String(format: "%.4f", time)) \(touchCount)"
    }

    /// Parse a replay line; the `touch ` token may appear anywhere (a whole log line works).
    /// Returns nil for anything malformed.
    init?(replayLine line: String) {
        guard let range = line.range(of: "touch ") else { return nil }
        let fields = line[range.upperBound...].split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 5,
              let phase = TouchPhase(rawValue: String(fields[0])),
              let x = Double(fields[1]), let y = Double(fields[2]),
              let time = Double(fields[3]), let count = Int(fields[4]) else { return nil }
        self.init(phase: phase, point: GesturePoint(x: x, y: y), time: time, touchCount: count)
    }
}
