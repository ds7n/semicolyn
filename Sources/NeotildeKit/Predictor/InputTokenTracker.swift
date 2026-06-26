// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// A token committed (completed) on the input line, with the token before it —
/// the unit the predictor learns (`record(token, after: previous)`).
public struct CommittedToken: Equatable, Sendable {
    public let token: String
    public let previous: String?
    public init(token: String, previous: String?) { self.token = token; self.previous = previous }
}

/// Reconstructs the current partial token + the previous token from the raw bytes
/// the user sends to the remote. A terminal has no text field, so the predictor's
/// prefix is derived here by watching the outgoing stream. Pure and best-effort:
/// control sequences (arrows, Ctrl-*) reset the line context rather than tracking
/// cursor motion, and remote-side tab completion (whose result arrives as output)
/// is not reflected — both are acceptable v1 limitations.
public struct InputTokenTracker: Equatable, Sendable {
    /// The token currently being typed (since the last delimiter).
    public private(set) var current: String = ""
    /// The token immediately before `current` on this line (for bigram lookup).
    public private(set) var previous: String?

    public init() {}

    /// Fold one chunk of outgoing bytes. Returns the tokens committed by this chunk
    /// (newest last), in order, for the caller to learn.
    public mutating func observe(_ bytes: [UInt8]) -> [CommittedToken] {
        var committed: [CommittedToken] = []
        for b in bytes {
            switch b {
            case 0x21...0x7e:               // printable, non-space → extend the token
                current.unicodeScalars.append(UnicodeScalar(b))
            case 0x20:                      // space → commit, keep the line
                if !current.isEmpty {
                    committed.append(CommittedToken(token: current, previous: previous))
                    previous = current
                    current = ""
                }
            case 0x0d, 0x0a:                // enter → commit, then new line
                if !current.isEmpty {
                    committed.append(CommittedToken(token: current, previous: previous))
                }
                current = ""
                previous = nil
            case 0x7f, 0x08:                // backspace → pop one char
                if !current.isEmpty { current.removeLast() }
            case 0x09:                      // tab → remote completion: drop the partial
                current = ""
            default:                        // ESC / control → reset line context
                current = ""
                previous = nil
            }
        }
        return committed
    }

    /// Clear all context (e.g. a context/host switch).
    public mutating func reset() { current = ""; previous = nil }
}

/// The chips to show for `current` given the engine's ranked `suggestions`: the
/// engine already prefix-matches, applies the confidence floor, and caps at top-K;
/// the strip only drops the exact token already typed (and any empties).
public func predictorChips(current: String, suggestions: [String]) -> [String] {
    suggestions.filter { $0 != current && !$0.isEmpty }
}
