// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Blocks kitty graphics commands that make the terminal read a local file or shared
/// memory (security audit L1).
///
/// SwiftTerm honors `t=f` (file), `t=t` (temp file, deleted after reading) and `t=s`
/// (shared memory). On the phone those paths point into the app's own sandbox, and the
/// different error replies for a missing file and an unreadable one let a server probe
/// what exists there. Images sent inline (`t=d`, the default and the only mode that
/// works over SSH anyway) are untouched.
///
/// The filter rewrites the transmission value to `x` in place, so SwiftTerm answers
/// every such command with the same "unsupported transmission" error. The byte count
/// never changes. It is stateful because a command can arrive split across reads; it
/// tracks just enough of SwiftTerm's parser (ground, escape, CSI, strings, and the C1
/// controls SwiftTerm honors outside ground) to know when bytes are a kitty control
/// block. One filter per terminal.
public struct KittyTransmissionFilter: Sendable {
    private enum State: Sendable {
        case ground, escape, csi, string
        case apcStart            // just entered an APC; the next byte names it
        case kittyKeyStart       // at the start of a `key=value` in a kitty control block
        case kittyKeyT           // read key `t`, waiting for `=`
        case kittyValueT         // the next byte is the transmission value
        case kittyOther          // inside some other key or value
        case apcBody             // kitty payload or a non-kitty APC
    }

    private var state: State = .ground

    public init() {}

    /// Rewrites blocked transmission values in `bytes`, carrying parse state to the next call.
    public mutating func filter(_ bytes: inout [UInt8]) {
        for i in bytes.indices {
            if let rewritten = step(bytes[i]) { bytes[i] = rewritten }
        }
    }

    /// Advances one byte; returns a replacement byte when this one must change.
    private mutating func step(_ b: UInt8) -> UInt8? {
        if state == .ground {
            if b == 0x1B { state = .escape }
            return nil
        }
        // SwiftTerm's "anywhere" rules, active in every state but ground.
        switch b {
        case 0x1B: state = .escape; return nil
        case 0x18, 0x1A, 0x9C: state = .ground; return nil
        case 0x9F: state = .apcStart; return nil
        case 0x9B: state = .csi; return nil
        case 0x90, 0x9D, 0x98, 0x9E: state = .string; return nil
        case 0x80...0x9A: state = .ground; return nil
        default: break
        }
        switch state {
        case .ground:
            return nil
        case .escape:
            switch b {
            case UInt8(ascii: "_"): state = .apcStart
            case UInt8(ascii: "["): state = .csi
            case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"): state = .string
            case 0x20...0x2F: break                  // intermediates keep the escape open
            default: state = .ground
            }
        case .csi:
            if (0x40...0x7E).contains(b) { state = .ground }
        case .string:
            if b == 0x07 { state = .ground }
        case .apcStart:
            state = (b == UInt8(ascii: "G")) ? .kittyKeyStart : .apcBody
        case .kittyKeyStart:
            state = (b == UInt8(ascii: "t")) ? .kittyKeyT : kittyAfter(b)
        case .kittyKeyT:
            state = (b == UInt8(ascii: "=")) ? .kittyValueT : kittyAfter(b)
        case .kittyValueT:
            state = kittyAfter(b)
            if b == UInt8(ascii: "f") || b == UInt8(ascii: "t") || b == UInt8(ascii: "s") {
                return UInt8(ascii: "x")
            }
        case .kittyOther:
            state = kittyAfter(b)
        case .apcBody:
            if b == 0x07 { state = .ground }
        }
        return nil
    }

    /// The state after an ordinary byte inside a kitty control block.
    private func kittyAfter(_ b: UInt8) -> State {
        switch b {
        case UInt8(ascii: ","): return .kittyKeyStart
        case UInt8(ascii: ";"): return .apcBody
        case 0x07: return .ground
        default: return .kittyOther
        }
    }
}

/// Memory cap for each terminal's kitty image cache (security audit L5). SwiftTerm's
/// default is 320 MB per terminal, enough for a server to push the app toward an iOS
/// memory kill; 64 MB still holds dozens of screen-sized images.
public let kittyImageCacheLimitBytes = 64 * 1024 * 1024
