// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Extract the printable-ASCII scalars the predictor cares about — space (0x20)
/// through tilde (0x7e) — from a raw input byte chunk. An empty result means the
/// chunk carries no predictor-relevant input (no echo anchor or settle is needed).
/// Mirrors the filter previously inlined in `ConnectionViewModel.observePredictorInput`.
public func predictorScalars(_ bytes: [UInt8]) -> [Unicode.Scalar] {
    bytes.compactMap { b in
        ((0x21...0x7e).contains(b) || b == 0x20) ? Unicode.Scalar(UInt32(b)) : nil
    }
}
