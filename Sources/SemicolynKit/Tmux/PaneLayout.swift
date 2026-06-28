// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public struct Geometry: Equatable, Sendable {
    public let w, h, x, y: UInt16
    public init(w: UInt16, h: UInt16, x: UInt16, y: UInt16) {
        self.w = w; self.h = h; self.x = x; self.y = y
    }
}

public indirect enum PaneLayout: Equatable, Sendable {
    case leaf(PaneID, Geometry)
    case columns([PaneLayout], Geometry)   // {…} panes left→right
    case rows([PaneLayout], Geometry)      // […] panes top→bottom
}

extension PaneLayout {
    /// Depth-first flatten to leaf panes with their geometry, for the renderer.
    public var panes: [(pane: PaneID, geometry: Geometry)] {
        switch self {
        case let .leaf(id, geo):
            return [(id, geo)]
        case let .columns(children, _), let .rows(children, _):
            return children.flatMap { $0.panes }
        }
    }
}

extension PaneLayout {
    /// Parse a tmux layout string (`checksum,WxH,X,Y{…}`). The leading 4-hex
    /// checksum is parsed and ignored. Returns nil on any grammar violation.
    /// Accepts any string type (`String`, `Substring`, literal).
    public static func parse(_ input: some StringProtocol) -> PaneLayout? {
        let s = Substring(input)
        guard let comma = s.firstIndex(of: ",") else { return nil }
        var scanner = Scanner(s[s.index(after: comma)...])
        guard let node = scanner.node(), scanner.isAtEnd else { return nil }
        return node
    }

    /// Recursive-descent scanner over the layout body (checksum already stripped).
    private struct Scanner {
        private let chars: [Character]
        private var i = 0
        init(_ s: Substring) { chars = Array(s) }

        var isAtEnd: Bool { i == chars.count }
        private func peek() -> Character? { i < chars.count ? chars[i] : nil }
        private mutating func expect(_ c: Character) -> Bool {
            if peek() == c { i += 1; return true }
            return false
        }
        /// Read a run of ASCII decimal digits (`0`–`9`) as UInt32 (nil if none).
        /// ASCII-strict so a non-ASCII Unicode numeric ends the run rather than
        /// being mistaken for a digit.
        private mutating func number() -> UInt32? {
            var digits = ""
            while let c = peek(), c.isASCII, c.isNumber { digits.append(c); i += 1 }
            return UInt32(digits)
        }
        /// A geometry dimension: a number that fits in UInt16.
        private mutating func dim() -> UInt16? {
            guard let n = number(), let v = UInt16(exactly: n) else { return nil }
            return v
        }

        /// node := WxH,X,Y ( ,paneid | {list} | [list] )
        mutating func node() -> PaneLayout? {
            guard let w = dim(), expect("x"), let h = dim(),
                  expect(","), let x = dim(),
                  expect(","), let y = dim() else { return nil }
            let geo = Geometry(w: w, h: h, x: x, y: y)
            switch peek() {
            case "{": return list(open: "{", close: "}").map { .columns($0, geo) }
            case "[": return list(open: "[", close: "]").map { .rows($0, geo) }
            case ",":
                i += 1
                guard let pane = number() else { return nil }
                return .leaf(PaneID(raw: pane), geo)
            default:
                return nil
            }
        }

        /// list := open node (,node)* close
        private mutating func list(open: Character, close: Character) -> [PaneLayout]? {
            guard expect(open), let first = node() else { return nil }
            var nodes = [first]
            while expect(",") {
                guard let next = node() else { return nil }
                nodes.append(next)
            }
            guard expect(close) else { return nil }
            return nodes
        }
    }
}
