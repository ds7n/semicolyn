// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Streaming, never-throwing parser for the tmux `-CC` control-mode line
/// protocol. Feed it raw channel bytes; it buffers partial lines and returns the
/// typed events parsed from each complete line.
public final class ControlModeParser {
    /// Maximum bytes allowed in a single (newline-terminated) line before the
    /// accumulation is flushed as a `.malformed` event. 1 MiB.
    static let maxLineBytes = 1 << 20
    /// Maximum body lines allowed inside one open block before it is force-
    /// closed as a `.malformed` event.
    static let maxBlockLines = 100_000

    private var buffer: [UInt8] = []
    private var openBlock: OpenBlock?

    private struct OpenBlock {
        let number: Int
        var body: [String]
        var lineCount: Int = 0
    }

    private enum BlockKind { case end, error }

    public init() {}

    public func feed(_ bytes: [UInt8]) -> [ControlModeEvent] {
        buffer.append(contentsOf: bytes)
        var events: [ControlModeEvent] = []
        // Line-length cap: if the buffer grows beyond maxLineBytes without a
        // newline, a hostile server is streaming a pathologically long line.
        // Flush it as malformed to prevent unbounded memory growth.
        if buffer.count > Self.maxLineBytes && !buffer.contains(0x0A) {
            buffer.removeAll()
            openBlock = nil
            events.append(.malformed(raw: "<truncated>",
                                     reason: "line exceeded \(Self.maxLineBytes) bytes"))
            return events
        }
        while let nl = buffer.firstIndex(of: 0x0A) {
            var lineBytes = Array(buffer[buffer.startIndex..<nl])
            buffer.removeSubrange(buffer.startIndex...nl)
            if lineBytes.last == 0x0D { lineBytes.removeLast() }
            let line = String(decoding: lineBytes, as: UTF8.self)
            events.append(contentsOf: parseLine(line))
        }
        // The DCS terminator (`ESC \`) trails the final newline-terminated line
        // and never forms a complete line of its own — drop it so the stream
        // ends on an empty buffer rather than two inert bytes. Re-checked each
        // feed, so a terminator split across feeds (`ESC` then `\`) still clears.
        if buffer == Self.dcsTerminatorBytes {
            buffer.removeAll()
        }
        return events
    }

    // MARK: - Line handling

    private func parseLine(_ line: String) -> [ControlModeEvent] {
        if openBlock != nil {
            return handleInsideBlock(line)
        }
        // Outside a block (where the DCS envelope lives), strip tmux's control-
        // mode framing. An empty line — whether it was nothing but framing, or a
        // genuinely blank line — is a benign no-op, not protocol corruption, so
        // it yields no event (rather than a `.malformed`, which is reserved for
        // lines that look like a notification but don't parse).
        let line = stripControlModeFraming(line)
        if line.isEmpty { return [] }
        if line.hasPrefix("%begin ") {
            let parts = line.split(separator: " ")
            guard parts.count >= 3, let number = Int(parts[2]) else {
                return [.malformed(raw: line, reason: "bad %begin")]
            }
            openBlock = OpenBlock(number: number, body: [])
            return []
        }
        if let event = dispatch(line) { return [event] }
        return []
    }

    /// A line received while a command block is open. Only the matching
    /// terminator closes it; everything else is a verbatim body line.
    private func handleInsideBlock(_ line: String) -> [ControlModeEvent] {
        guard var block = openBlock else { return [] }
        if let (kind, number) = blockTerminator(line) {
            openBlock = nil
            guard number == block.number else {
                return [.malformed(raw: line, reason: "block number mismatch")]
            }
            let outcome: CommandOutcome = (kind == .end) ? .ok(block.body) : .error(block.body)
            return [.commandResult(number: number, outcome: outcome)]
        }
        // Block-body cap: a hostile server must not grow the body slice to OOM.
        block.lineCount += 1
        if block.lineCount > Self.maxBlockLines {
            openBlock = nil
            return [.malformed(raw: line, reason: "block body exceeded \(Self.maxBlockLines) lines")]
        }
        block.body.append(line)
        openBlock = block
        return []
    }

    /// tmux wraps the entire `-CC` control stream in a DCS envelope: it opens
    /// with `ESC P 1 0 0 0 p` (glued to the first `%begin`) and closes with
    /// `ESC \` (ST). Neotilde's channel is dedicated to control mode, so the
    /// envelope conveys nothing and must be removed before parsing. Stripping it
    /// is safe because a raw `ESC` never appears inside control content — tmux
    /// octal-escapes such bytes in `%output` — so these sequences only ever occur
    /// as the stream's outer framing.
    private static let dcsIntro = "\u{1b}P1000p"
    private static let dcsTerminator = "\u{1b}\\"
    private static let dcsTerminatorBytes: [UInt8] = Array("\u{1b}\\".utf8)

    /// Remove a leading DCS intro and/or trailing ST from an out-of-block line.
    private func stripControlModeFraming(_ line: String) -> String {
        var s = Substring(line)
        if s.hasPrefix(Self.dcsIntro) { s = s.dropFirst(Self.dcsIntro.count) }
        if s.hasSuffix(Self.dcsTerminator) { s = s.dropLast(Self.dcsTerminator.count) }
        return String(s)
    }

    /// Recognise a `%end`/`%error` terminator line and pull its block number.
    private func blockTerminator(_ line: String) -> (BlockKind, Int)? {
        let parts = line.split(separator: " ")
        guard let verb = parts.first else { return nil }
        let kind: BlockKind
        if verb == "%end" { kind = .end }
        else if verb == "%error" { kind = .error }
        else { return nil }
        guard parts.count >= 3, let number = Int(parts[2]) else { return nil }
        return (kind, number)
    }

    /// Dispatch a complete line to its handler.
    private func dispatch(_ line: String) -> ControlModeEvent? {
        guard line.first == "%" else {
            return .malformed(raw: line, reason: "line does not start with %")
        }
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        let verb = parts[0]
        switch verb {
        case "%window-add":
            return single(line, parts) { WindowID(token: $0).map(ControlModeEvent.windowAdd) }
        case "%window-close", "%unlinked-window-close":
            return single(line, parts) { WindowID(token: $0).map(ControlModeEvent.windowClose) }
        case "%window-pane-changed":
            guard parts.count >= 3, let w = WindowID(token: parts[1]),
                  let p = PaneID(token: parts[2]) else {
                return .malformed(raw: line, reason: "bad %window-pane-changed")
            }
            return .windowPaneChanged(w, active: p)
        case "%window-renamed":
            guard parts.count >= 2, let w = WindowID(token: parts[1]) else {
                return .malformed(raw: line, reason: "bad %window-renamed")
            }
            return .windowRenamed(w, name: rest(line, after: parts[0], parts[1]))
        case "%session-changed":
            guard parts.count >= 2, let s = SessionID(token: parts[1]) else {
                return .malformed(raw: line, reason: "bad %session-changed")
            }
            return .sessionChanged(s, name: rest(line, after: parts[0], parts[1]))
        case "%session-window-changed":
            guard parts.count >= 3, let s = SessionID(token: parts[1]),
                  let w = WindowID(token: parts[2]) else {
                return .malformed(raw: line, reason: "bad %session-window-changed")
            }
            return .sessionWindowChanged(s, active: w)
        case "%output":
            // %output %<pane> <data> — data is the remainder and may contain spaces.
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, let pane = PaneID(token: fields[1]) else {
                return .malformed(raw: line, reason: "bad %output header")
            }
            guard let data = unescapeTmuxOutput(fields[2]) else {
                return .malformed(raw: line, reason: "bad %output escape")
            }
            return .output(pane: pane, data: data)
        case "%layout-change":
            // %layout-change @<win> <layout> <visible-layout> <flags>
            let f = line.split(separator: " ", omittingEmptySubsequences: false)
            guard f.count >= 5, let win = WindowID(token: f[1]),
                  let layout = PaneLayout.parse(f[2]),
                  let visible = PaneLayout.parse(f[3]) else {
                return .malformed(raw: line, reason: "bad %layout-change")
            }
            return .layoutChange(win, layout: layout, visible: visible, flags: String(f[4]))
        case "%end", "%error":
            return .malformed(raw: line, reason: "\(verb) with no open block")
        case "%sessions-changed":
            return .sessionsChanged
        case "%exit":
            let reason = line == "%exit" ? nil : String(line.dropFirst("%exit ".count))
            return .exit(reason: reason)
        default:
            return .unknown(verb: String(verb.dropFirst()), raw: line)
        }
    }

    // MARK: - Helpers

    /// A one-argument notification: `verb <token>`. Calls `make` with the token;
    /// a nil result (bad/missing token) becomes `.malformed`.
    private func single(_ line: String, _ parts: [Substring],
                        _ make: (Substring) -> ControlModeEvent?) -> ControlModeEvent {
        guard parts.count >= 2, let event = make(parts[1]) else {
            return .malformed(raw: line, reason: "bad \(parts[0])")
        }
        return event
    }

    /// Everything after `verb token ` — the free-form remainder (may be empty,
    /// may contain spaces). Used for window/session names.
    private func rest(_ line: String, after verb: Substring, _ token: Substring) -> String {
        let prefix = "\(verb) \(token) "
        guard line.count >= prefix.count else { return "" }
        return String(line.dropFirst(prefix.count))
    }
}
