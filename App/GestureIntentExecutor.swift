// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import SwiftTerm
import SemicolynKit

/// Performs `GestureIntent`s (spec 2026-10-04) with the app's existing pieces: plain-tmux
/// actions, SwiftTerm selection + scrollback, mouse / arrow / wheel byte encoders, the
/// Copy/Paste edit menu and the selection magnifier. Holds the current selection, because
/// SwiftTerm's selection service is internal (unreadable from the App).
@MainActor
final class GestureIntentExecutor: NSObject {
    struct Hooks {
        let plainTmux: () -> PlainTmuxController?
        let mode: () -> InteractionMode
        let altScrollDecision: () -> AltScrollDecision
        let sendBytes: ([UInt8]) -> Void
        /// Move the shell cursor to a VIEWPORT cell (existing arrow-key cursor placement).
        let placeCursor: (_ col: Int, _ viewportRow: Int) -> Void
        let restoreKeyboard: () -> Void
    }

    private weak var terminal: TerminalView?
    private let hooks: Hooks
    private var editMenu: UIEditMenuInteraction?
    /// The magnifier shown while dragging a selection handle; added to the terminal's
    /// superview on first show, removed in `detach()`.
    private lazy var loupe: SelectionLoupeView? = SelectionLoupeView()
    /// Inclusive selection, absolute rows; nil when none.
    private(set) var selection: GestureSelection?

    init(terminal: TerminalView, hooks: Hooks) {
        self.terminal = terminal
        self.hooks = hooks
        super.init()
        let menu = UIEditMenuInteraction(delegate: self)
        terminal.addInteraction(menu)
        editMenu = menu
    }

    func detach() {
        loupe?.removeFromSuperview()
        loupe = nil
        if let editMenu { terminal?.removeInteraction(editMenu) }
        editMenu = nil
    }

    func perform(_ intents: [GestureIntent]) {
        for intent in intents { perform(intent) }
    }

    private func perform(_ intent: GestureIntent) {
        guard let view = terminal else { return }
        switch intent {
        case .restoreKeyboard:
            hooks.restoreKeyboard()
        case let .tap(cell):
            tap(cell, in: view)
        case let .selectWord(cell, p):
            let term = view.getTerminal()
            let viewportRow = cell.row - term.getTopVisibleRow()
            let (start, end) = subWordBounds(col: cell.col, viewportRow: viewportRow, in: view)
            apply(start: GestureCell(col: start, row: cell.row), end: GestureCell(col: end, row: cell.row), in: view)
            presentMenu(at: p, in: view)
        case let .selectLine(row, p):
            let cols = max(view.getTerminal().cols, 1)
            apply(start: GestureCell(col: 0, row: row), end: GestureCell(col: cols - 1, row: row), in: view)
            presentMenu(at: p, in: view)
        case .clearSelection:
            view.selectNone()
            selection = nil
        case let .showMenu(p):
            presentMenu(at: p, in: view)
        case let .setSelection(start, end, p):
            apply(start: start, end: end, in: view)
            loupe?.show(around: contentPoint(p, in: view), in: view)
        case let .endSelectionDrag(p, showMenu):
            loupe?.hide()
            if showMenu { presentMenu(at: p, in: view) }
        case let .switchWindow(delta):
            hooks.plainTmux()?.onSwitchWindow(delta: delta)
        case let .scroll(lines, cell):
            scroll(lines, at: cell, in: view)
        case .zoom:
            hooks.plainTmux()?.onLongPressZoom()
        }
    }

    // MARK: tap

    /// Plain tmux: click / pane cycle. Raw `localScroll`: place the cursor. Raw app with the
    /// mouse on: SGR click. Coordinates are clamped to the CURRENT grid (the engine clamped
    /// against the touch-down snapshot, which output may have moved since).
    private func tap(_ cell: GestureCell, in view: TerminalView) {
        let term = view.getTerminal()
        let col = min(max(0, cell.col), max(term.cols - 1, 0))
        let viewportRow = min(max(0, cell.row - term.getTopVisibleRow()), max(term.rows - 1, 0))
        if let tmux = hooks.plainTmux() {
            tmux.onTapPane(col: col + 1, row: viewportRow + 1, mouseModeOn: term.mouseMode != .off)
            return
        }
        if hooks.mode() == .localScroll {
            hooks.placeCursor(col, viewportRow)
        } else if term.mouseMode != .off {
            hooks.sendBytes(sgrMouseClick(col: col + 1, row: viewportRow + 1))
        }
    }

    // MARK: scroll

    /// Positive `lines` = finger moved down = older content. Raw shell on its normal screen
    /// scrolls SwiftTerm's scrollback; everything else sends wheel / arrow / page-key bytes.
    private func scroll(_ lines: Int, at cell: GestureCell, in view: TerminalView) {
        guard lines != 0 else { return }
        if hooks.plainTmux() == nil, hooks.mode() == .localScroll {
            if lines > 0 { view.scrollUp(lines: lines) } else { view.scrollDown(lines: -lines) }
            return
        }
        let term = view.getTerminal()
        let col = min(max(1, cell.col + 1), max(term.cols, 1))
        let row = min(max(1, cell.row - term.getTopVisibleRow() + 1), max(term.rows, 1))
        let keys = hooks.altScrollDecision().keys
        for run in arrowEvents(cols: 0, rows: -lines) {   // finger down -> up runs (older)
            let bytes: [UInt8]
            switch keys {
            case .wheel: bytes = encodeWheelRun(run, col: col, row: row)
            case .pageKeys: bytes = encodePageKeyRun(run)
            case .arrows: bytes = encodeArrowRun(run, applicationCursorKeys: term.applicationCursor)
            }
            if !bytes.isEmpty { hooks.sendBytes(bytes) }
        }
    }

    // MARK: selection

    /// Inclusive cells; SwiftTerm's `setSelectionRange` end column is EXCLUSIVE, hence +1.
    private func apply(start: GestureCell, end: GestureCell, in view: TerminalView) {
        view.setSelectionRange(start: Position(col: start.col, row: start.row),
                               end: Position(col: end.col + 1, row: end.row))
        selection = GestureSelection(start: start, end: end)
    }

    /// Sub-word bounds on a VIEWPORT row (getCharData adds yDisp itself).
    private func subWordBounds(col: Int, viewportRow: Int, in view: TerminalView) -> (Int, Int) {
        let term = view.getTerminal()
        let cols = max(term.cols, 1)
        func classOf(_ c: Int) -> CharClass {
            guard c >= 0, c < cols, let cd = term.getCharData(col: c, row: viewportRow) else { return .space }
            let ch = cd.getCharacter()
            if ch == " " || ch == "\t" || ch == "\0" { return .space }
            if SemicolynKit.selectionPunctuation.contains(ch) { return .punct }
            return .word
        }
        let r = SemicolynKit.subWordBounds(cols: cols, col: col, classOf: classOf)
        return (r.start, r.end)
    }

    // MARK: menu

    /// Viewport point -> the terminal's CONTENT space (it is a `UIScrollView`), the space
    /// `UIEditMenuConfiguration.sourcePoint` and `SelectionLoupeView.show` expect.
    private func contentPoint(_ p: GesturePoint, in view: TerminalView) -> CGPoint {
        CGPoint(x: CGFloat(p.x) + view.contentOffset.x, y: CGFloat(p.y) + view.contentOffset.y)
    }

    private func presentMenu(at p: GesturePoint, in view: TerminalView) {
        let config = UIEditMenuConfiguration(identifier: nil, sourcePoint: contentPoint(p, in: view))
        editMenu?.presentEditMenu(with: config)
    }
}

// MARK: UIEditMenuInteractionDelegate

extension GestureIntentExecutor: @preconcurrency UIEditMenuInteractionDelegate {
    func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                             menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let view = terminal else { return UIMenu(children: suggestedActions) }
        var items: [UIMenuElement] = []
        if view.hasActiveSelection {
            items.append(UIAction(title: "Copy") { [weak view] _ in view?.copy(nil) })
        }
        if UIPasteboard.general.hasStrings {
            items.append(UIAction(title: "Paste") { [weak self] _ in
                guard let self, let text = UIPasteboard.general.string, !text.isEmpty else { return }
                // Always bracket: apps without bracketed paste ignore the ESC[200~/ESC[201~ markers.
                self.hooks.sendBytes(SemicolynKit.bracketedPasteBytes(text, bracketed: true))
            })
        }
        return UIMenu(children: items.isEmpty ? suggestedActions : items)
    }
}
