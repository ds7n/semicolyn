// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// A hardware-keyboard command action. Each maps to a `UIKeyCommand` in the App
/// tier and routes to a connection/UI action (external-keyboard spec
/// "Cmd-shortcut map"). `switchWindow` carries its 1–9 target.
public enum KeyboardCommand: Equatable, Hashable, Sendable {
    case newWindow
    case closeWindow
    case switchWindow(Int)
    case prevWindow
    case nextWindow
    case prevPane
    case nextPane
    case splitVertical
    case splitHorizontal
    case clearScreen
    case copy
    case paste
    case newConnection
    case reconnect
    case openLauncher
    case settings
    case tips
}

/// A hardware-keyboard chord: the bound character plus its modifier flags. Cmd is
/// modeled here (unlike the terminal `KeyModifiers`) because these are
/// command-key shortcuts, resolved by iOS against the literal character.
public struct KeyboardChord: Equatable, Hashable, Sendable {
    public var input: String
    public var command: Bool
    public var shift: Bool
    public var control: Bool
    public var option: Bool
    public init(input: String, command: Bool = false, shift: Bool = false,
                control: Bool = false, option: Bool = false) {
        self.input = input
        self.command = command
        self.shift = shift
        self.control = control
        self.option = option
    }
}

/// One catalog entry: the chord, the action it fires, and the title iOS shows in
/// the ⌘-hold discoverability HUD.
public struct KeyboardCommandSpec: Equatable, Sendable {
    public let chord: KeyboardChord
    public let command: KeyboardCommand
    public let title: String
    public init(chord: KeyboardChord, command: KeyboardCommand, title: String) {
        self.chord = chord
        self.command = command
        self.title = title
    }
}

/// The authoritative hardware-keyboard shortcut map. The App tier registers a
/// `UIKeyCommand` per entry; `command(for:)` resolves an incoming chord. Split
/// actions appear twice (the `⌘D`/`⌘|` and `⇧⌘D`/`⌘-` aliases). The `⌘1…⌘9`
/// window switches are expanded to nine entries so each binds individually.
public enum KeyboardCommandCatalog {
    public static let all: [KeyboardCommandSpec] = {
        var entries: [KeyboardCommandSpec] = [
            cmd("t", .newWindow, "New Window"),
            cmd("w", .closeWindow, "Close Window"),
            chord(KeyboardChord(input: "[", command: true, shift: true), .prevWindow, "Previous Window"),
            chord(KeyboardChord(input: "]", command: true, shift: true), .nextWindow, "Next Window"),
            cmd("[", .prevPane, "Previous Pane"),
            cmd("]", .nextPane, "Next Pane"),
            cmd("d", .splitVertical, "Split Vertically"),
            cmd("|", .splitVertical, "Split Vertically"),
            chord(KeyboardChord(input: "d", command: true, shift: true), .splitHorizontal, "Split Horizontally"),
            cmd("-", .splitHorizontal, "Split Horizontally"),
            cmd("k", .clearScreen, "Clear Screen"),
            cmd("c", .copy, "Copy"),
            cmd("v", .paste, "Paste"),
            chord(KeyboardChord(input: "n", command: true, shift: true), .newConnection, "New Connection"),
            chord(KeyboardChord(input: "r", command: true, shift: true), .reconnect, "Reconnect"),
            chord(KeyboardChord(input: "p", command: true, shift: true), .openLauncher, "Macro Launcher"),
            cmd(",", .settings, "Settings"),
            cmd("?", .tips, "Tips & Gestures"),
        ]
        for n in 1...9 {
            entries.append(cmd(String(n), .switchWindow(n), "Switch to Window \(n)"))
        }
        return entries
    }()

    /// Resolves an incoming chord to its action, or nil if unbound.
    public static func command(for chord: KeyboardChord) -> KeyboardCommand? {
        all.first { $0.chord == chord }?.command
    }

    private static func cmd(_ input: String, _ command: KeyboardCommand, _ title: String) -> KeyboardCommandSpec {
        KeyboardCommandSpec(chord: KeyboardChord(input: input, command: true), command: command, title: title)
    }

    private static func chord(_ chord: KeyboardChord, _ command: KeyboardCommand, _ title: String) -> KeyboardCommandSpec {
        KeyboardCommandSpec(chord: chord, command: command, title: title)
    }
}
