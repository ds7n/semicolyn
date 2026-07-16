// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Renders a self-contained decision line in the project's standard format:
/// `event a=1 b=2 → x=9 reason=R`. Returns the string only; the App-tier caller passes it
/// to `DebugLog.shared.log(.<category>, …)` so category gating stays autoclosure-cheap. The
/// uniform format lets a device trace be read decision-by-decision without correlation.
public func decisionLine(_ event: String,
                         inputs: [(String, String)],
                         outputs: [(String, String)],
                         reason: String? = nil) -> String {
    func join(_ pairs: [(String, String)]) -> String {
        pairs.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
    }
    var line = event
    let ins = join(inputs)
    if !ins.isEmpty { line += " \(ins)" }
    line += " → \(join(outputs))"
    if let reason { line += " reason=\(reason)" }
    return line
}
