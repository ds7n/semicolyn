// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Pane context the predictor may weight prose-vs-CLI on. Every field is optional;
/// `nil` means "signal unavailable, do not weight on it." `PredictionContext()`
/// (all-nil) reproduces the pre-context ranking exactly. Adding a future signal is a
/// new optional field, source-compatible with all existing callers.
public struct PredictionContext: Sendable, Equatable {
    /// Foreground process in the active pane (e.g. "zsh", "claude", "vim").
    public var foregroundProcess: String?
    /// Whether the active pane is on the alternate screen (vim/less/htop).
    public var isAlternateScreen: Bool?
    /// The full current input line (not just the token prefix).
    public var line: String?
    /// Cursor position within `line` (character offset).
    public var cursorIndex: Int?

    public init(foregroundProcess: String? = nil, isAlternateScreen: Bool? = nil,
                line: String? = nil, cursorIndex: Int? = nil) {
        self.foregroundProcess = foregroundProcess
        self.isAlternateScreen = isAlternateScreen
        self.line = line
        self.cursorIndex = cursorIndex
    }

    /// True when no signal is available at all (new pane / pre-poll). NOTE: `proseBias`
    /// no longer uses this to gate the blind prior (it keys on `foregroundProcess` and
    /// `isAlternateScreen` alone, since `line`/`cursorIndex` are almost always present
    /// as a side effect of typing and would otherwise make the blind prior unreachable
    /// in production). Retained as public API / for other potential callers.
    public var allSignalsNil: Bool {
        foregroundProcess == nil && isAlternateScreen == nil
            && line == nil && cursorIndex == nil
    }
}
