// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// A streaming terminal escape-sequence stripper for raw output bytes.
///
/// Unlike ``stripANSI(_:)`` (a whole-`String` helper) this keeps state across
/// calls, so a sequence split over two network chunks is still removed, and it
/// buffers nothing: bytes of a sequence are consumed as they arrive and every
/// other byte is emitted unchanged. It is deliberately forgiving so a hostile or
/// truncated stream cannot swallow output indefinitely:
///
/// - CSI (`ESC [`, parameter and intermediate bytes, final byte `0x40...0x7e`):
///   a byte below `0x20` (other than ESC) aborts the sequence and is emitted.
/// - OSC (`ESC ]`) and string sequences (`ESC P`, `ESC X`, `ESC ^`, `ESC _`) end at
///   BEL, `ESC \`, or LF (the LF is emitted).
/// - Any other ESC: the ESC, intermediate bytes `0x20...0x2f`, one final byte.
/// - A new ESC inside an unfinished sequence (string sequences included, unless
///   it forms `ESC \`) starts a fresh one.
public struct ANSIByteFilter: Sendable, Equatable {
    private enum State: Sendable, Equatable {
        case ground
        case escape          // saw ESC
        case escapeIntermediate
        case csi
        case string          // inside OSC / DCS / SOS / PM / APC
        case stringEscape    // ESC seen inside a string (maybe `ESC \`)
    }

    private var state: State = .ground

    public init() {}

    /// Returns `bytes` with escape sequences removed, advancing the carried state.
    public mutating func filter(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        for b in bytes { step(b, into: &out) }
        return out
    }

    private mutating func step(_ b: UInt8, into out: inout [UInt8]) {
        if state == .stringEscape {
            // `ESC \` ends the string; any other byte re-dispatches as if it
            // followed a bare ESC (so `ESC [` starts a CSI inside an open string).
            if b == UInt8(ascii: "\\") { state = .ground; return }
            state = .escape
        }
        switch state {
        case .ground:
            if b == 0x1b { state = .escape } else { out.append(b) }
        case .escape:
            switch b {
            case 0x1b: break                                   // restart, stay
            case UInt8(ascii: "["): state = .csi
            case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "X"),
                 UInt8(ascii: "^"), UInt8(ascii: "_"): state = .string
            case 0x20...0x2f: state = .escapeIntermediate
            case 0x00...0x1f: state = .ground; out.append(b)   // control aborts
            default: state = .ground                           // the one final byte
            }
        case .escapeIntermediate:
            switch b {
            case 0x1b: state = .escape
            case 0x20...0x2f: break
            case 0x00...0x1f: state = .ground; out.append(b)
            default: state = .ground
            }
        case .csi:
            switch b {
            case 0x1b: state = .escape
            case 0x20...0x3f: break                            // parameter / intermediate
            case 0x40...0x7e: state = .ground                  // final
            default: state = .ground; out.append(b)            // control or non-ASCII aborts
            }
        case .string:
            switch b {
            case 0x07: state = .ground
            case 0x1b: state = .stringEscape
            case 0x0a: state = .ground; out.append(b)
            default: break
            }
        case .stringEscape:
            break   // handled before the switch
        }
    }
}
