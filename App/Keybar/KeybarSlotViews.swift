// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import UIKit
import SemicolynKit

/// Shared slot chrome: themed background + label, uniform min size. When a slot has
/// swipe secondaries, they render as a small accent-tinted column to the RIGHT of the
/// label: swipe-up glyph on top, swipe-down below. A single-direction key fills only its
/// slot; the other is an invisible spacer so the main label stays vertically centered
/// (device issue #2: replaces the old edge-pinned overlay glyphs).
struct SlotChrome<Label: View>: View {
    let bg: Color
    var up: String? = nil
    var down: String? = nil
    @Environment(\.theme) private var theme
    /// Set by `keyTap` / `keyPressFeedback()` while the key is touched.
    @Environment(\.keyPressed) private var pressed
    @ViewBuilder var label: () -> Label

    private var hasHints: Bool { up != nil || down != nil }

    var body: some View {
        HStack(spacing: 3) {
            label()
            if hasHints {
                VStack(spacing: 0) {
                    hintText(up)
                    hintText(down)
                }
            }
        }
        .frame(minWidth: 24, minHeight: 31)   // 27→31 (2026-10-17): bar felt short once Fn stopped setting its height
        .padding(.horizontal, 4)               // narrower keys (2026-10-12): 48→32pt wide, default middle fits
        .background {
            ZStack {
                bg
                Color(theme.text.primary).opacity(pressed ? 0.12 : 0)   // pressed: tinted with the text colour so it shows on dark and light themes
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// One hint glyph, or an invisible spacer of the same metrics when the direction is
    /// unbound (keeps the main label centered and both single-swipe directions aligned).
    @ViewBuilder private func hintText(_ s: String?) -> some View {
        Text(s ?? " ")
            .font(.system(size: 8, design: .monospaced))
            .foregroundStyle(Color(theme.accent.primary))
            .opacity(s == nil ? 0 : 0.85)
    }
}

/// A plain symbol slot (tap = send the literal character).
struct SymbolSlotView: View {
    let symbol: String
    let vm: ConnectionViewModel
    let keybarSettings: KeybarSettingsStore
    @Environment(\.theme) private var theme
    var body: some View {
        let secondaries = resolveSecondaries(for: .symbol(symbol),
                                             overrides: keybarSettings.settings.fixedKeySecondaries)
        let g = hintGlyphs(for: secondaries)
        SlotChrome(bg: Color(theme.keybar.slotBg), up: g.up, down: g.down) {
            Text(symbol).font(.system(.body, design: .monospaced)).foregroundStyle(Color(theme.text.primary))
        }
        .fixedKeySwipes(secondaries) { v in vm.keybar.emitSecondary(v) }
        .keyTap { if let c = symbol.first { vm.keybar.tapSymbol(c) } }
    }
}

/// Tab slot.
struct TabSlotView: View {
    let vm: ConnectionViewModel
    let keybarSettings: KeybarSettingsStore
    @Environment(\.theme) private var theme
    var body: some View {
        let secondaries = resolveSecondaries(for: .tab,
                                             overrides: keybarSettings.settings.fixedKeySecondaries)
        let g = hintGlyphs(for: secondaries)
        SlotChrome(bg: Color(theme.keybar.slotBg), up: g.up, down: g.down) {
            Text("⇥").foregroundStyle(Color(theme.text.primary))
        }
        .fixedKeySwipes(secondaries) { v in vm.keybar.emitSecondary(v) }
        .keyTap { vm.keybar.tapTab() }
    }
}

// MARK: - Fixed-key swipe secondaries

extension View {
    /// The swipe-up / swipe-down gesture that emits a fixed key's secondaries, with the
    /// live flick bubble showing each secondary's hint glyph. The hint GLYPHS on the key
    /// are rendered by SlotChrome's column (fed hintGlyphs(for:)); this modifier is
    /// gesture + bubble only (device #2 removed the edge-pinned overlay glyphs).
    func fixedKeySwipes(_ secondaries: SwipeSecondaries,
                        emit: @escaping (SecondaryValue) -> Void) -> some View {
        let g = hintGlyphs(for: secondaries)
        return flickKey("fixed", up: g.up, down: g.down) { dir in
            switch dir {
            case .up:   if let up = secondaries.up { emit(up) }
            case .down: if let down = secondaries.down { emit(down) }
            }
        }
    }

    /// A key flick with the live preview: while the finger is past the flick
    /// threshold in a bound direction, the accessory root shows a bubble with that
    /// direction's label (`up`/`down`; nil = unbound, no bubble, no click, nothing
    /// sent), and the keyboard click plays each time the bubble appears or switches
    /// direction (not on release). On release `onSwipe` fires for a bound direction
    /// and the bubble lingers briefly, then fades.
    func flickKey(_ key: String, up: String?, down: String?,
                  onSwipe: @escaping (KeySwipeDirection) -> Void) -> some View {
        modifier(FlickKeyModifier(key: key, upLabel: up, downLabel: down, onSwipe: onSwipe))
    }

    /// A vertical swipe on a keybar key that never steals a sideways drag from the
    /// scrolling middle. Even a SIMULTANEOUS SwiftUI drag blocked the scroll view
    /// when the drag started on a key (device build 188), so on iOS 18+ the swipe is a
    /// UIKit pan that refuses to begin unless Kit `keySwipeShouldClaim` says the drag
    /// started vertically; a sideways start fails at once and the scroll view moves.
    /// `onPreview` gets Kit `keySwipePreview` (for the bound `hasUp`/`hasDown`) on every
    /// drag change, then nil once the drag ends or is cancelled (after `onSwipe`).
    func keySwipe(_ key: String, hasUp: Bool, hasDown: Bool,
                  onPreview: @escaping (KeySwipeDirection?) -> Void,
                  onSwipe: @escaping (KeySwipeDirection) -> Void) -> some View {
        modifier(KeySwipeModifier(key: key, hasUp: hasUp, hasDown: hasDown,
                                  onPreview: onPreview, onSwipe: onSwipe))
    }
}

/// Owns a flicked key's preview state: which direction is showing, the label the
/// bubble shows (kept briefly after release), and the publishing of that label to
/// `KeybarAccessoryRoot` through `KeyFlickPreferenceKey`.
private struct FlickKeyModifier: ViewModifier {
    let key: String
    let upLabel: String?
    let downLabel: String?
    let onSwipe: (KeySwipeDirection) -> Void

    /// How long the bubble stays after a release that sent a secondary, before fading.
    private static let linger: TimeInterval = 0.1

    /// The direction the live drag would send right now (nil = none).
    @State private var preview: KeySwipeDirection?
    /// The label the bubble shows; outlives `preview` by `linger` after a send.
    @State private var bubbleLabel: String?
    /// Set when a release sent a secondary, so the closing nil lingers instead of
    /// clearing at once (a return inside the threshold clears at once).
    @State private var sentOnRelease = false
    /// Bumped on every bubble change so a stale linger timer does nothing.
    @State private var bubbleGeneration = 0

    private func label(_ dir: KeySwipeDirection) -> String? {
        dir == .up ? upLabel : downLabel
    }

    func body(content: Content) -> some View {
        content
            .keySwipe(key, hasUp: upLabel != nil, hasDown: downLabel != nil,
                      onPreview: update, onSwipe: send)
            .anchorPreference(key: KeyFlickPreferenceKey.self, value: .bounds) { anchor in
                bubbleLabel.map { KeyFlickPreview(label: $0, anchor: anchor) }
            }
    }

    private func update(_ next: KeySwipeDirection?) {
        if let next, let text = label(next) {
            if next != preview { InputClickFeedback.play() }   // appear or switch: one click
            bubbleGeneration += 1
            sentOnRelease = false
            preview = next
            bubbleLabel = text
            return
        }
        // Already clear: a repeated end/cancel nil must not cut a lingering bubble short.
        guard preview != nil else { return }
        preview = nil
        bubbleGeneration += 1
        guard sentOnRelease else {
            bubbleLabel = nil   // back inside the threshold (or cancelled): gone at once
            return
        }
        sentOnRelease = false
        let generation = bubbleGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.linger) {
            guard bubbleGeneration == generation else { return }   // a new flick took over
            withAnimation(.easeOut(duration: 0.15)) { bubbleLabel = nil }
        }
    }

    private func send(_ dir: KeySwipeDirection) {
        guard label(dir) != nil else { return }   // unbound direction: nothing sent
        sentOnRelease = true
        onSwipe(dir)
    }
}

/// Judge a finished drag with Kit `keySwipeDirection`, log it, and fire the swipe.
@MainActor private func finishKeySwipe(_ key: String, dx: Double, dy: Double,
                                       onSwipe: (KeySwipeDirection) -> Void) {
    let dir = keySwipeDirection(dx: dx, dy: dy)
    DebugLog.shared.log(.keybar,
        "keybar:swipe key=\(key) dx=\(Int(dx)) dy=\(Int(dy)) -> \(dir?.rawValue ?? "none") reason=\(dir == nil ? "notVertical" : "vertical")")
    if let dir { onSwipe(dir) }
}

private struct KeySwipeModifier: ViewModifier {
    let key: String
    let hasUp: Bool
    let hasDown: Bool
    let onPreview: (KeySwipeDirection?) -> Void
    let onSwipe: (KeySwipeDirection) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.gesture(KeySwipeRecognizer(key: key, hasUp: hasUp, hasDown: hasDown,
                                               onPreview: onPreview, onSwipe: onSwipe))
        } else {
            content.modifier(LegacyKeySwipeModifier(key: key, hasUp: hasUp, hasDown: hasDown,
                                                    onPreview: onPreview, onSwipe: onSwipe))
        }
    }
}

/// The pre-iOS 18 key swipe: a simultaneous drag. Its release is handled only in
/// `onEnded`; the `GestureState` reset is used just to catch a cancelled drag (where
/// `onEnded` never runs), and defers one run-loop turn so it cannot clear the preview
/// ahead of a normal release (which would skip the bubble's linger).
private struct LegacyKeySwipeModifier: ViewModifier {
    let key: String
    let hasUp: Bool
    let hasDown: Bool
    let onPreview: (KeySwipeDirection?) -> Void
    let onSwipe: (KeySwipeDirection) -> Void

    /// True while the drag is live; resets on end AND on cancel.
    @GestureState private var dragging = false
    /// Set by `onEnded`, cleared by the next change: tells the cancel path the release
    /// was already handled.
    @State private var endedNormally = false

    func body(content: Content) -> some View {
        content.simultaneousGesture(DragGesture(minimumDistance: 12)
            .updating($dragging) { _, state, _ in state = true }
            .onChanged { g in
                endedNormally = false
                onPreview(keySwipePreview(dx: Double(g.translation.width),
                                          dy: Double(g.translation.height),
                                          hasUp: hasUp, hasDown: hasDown))
            }
            .onEnded { g in
                endedNormally = true
                finishKeySwipe(key, dx: Double(g.translation.width), dy: Double(g.translation.height),
                               onSwipe: onSwipe)
                onPreview(nil)
            })
        .onChange(of: dragging) { _, live in
            guard !live else { return }
            DispatchQueue.main.async {
                if !endedNormally { onPreview(nil) }   // cancelled: no onEnded ran
            }
        }
    }
}

/// The iOS 18+ key swipe: a pan whose delegate lets it begin only for a vertical
/// start, and recognizes alongside the scroll view and the key's tap.
@available(iOS 18.0, *)
private struct KeySwipeRecognizer: UIGestureRecognizerRepresentable {
    let key: String
    let hasUp: Bool
    let hasDown: Bool
    let onPreview: (KeySwipeDirection?) -> Void
    let onSwipe: (KeySwipeDirection) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator(key: key) }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        let t = pan.translation(in: pan.view)
        switch pan.state {
        case .began, .changed:
            onPreview(keySwipePreview(dx: Double(t.x), dy: Double(t.y), hasUp: hasUp, hasDown: hasDown))
        case .ended:
            finishKeySwipe(key, dx: Double(t.x), dy: Double(t.y), onSwipe: onSwipe)
            onPreview(nil)
        default:   // cancelled / failed: nothing sent, clear the preview
            onPreview(nil)
        }
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let key: String
        init(key: String) { self.key = key }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer else { return true }
            var move = pan.translation(in: pan.view)
            if move == .zero { move = pan.velocity(in: pan.view) }  // no travel yet: use direction of motion
            let claim = keySwipeShouldClaim(dx: Double(move.x), dy: Double(move.y))
            DebugLog.shared.log(.keybar,
                "keybar:swipeStart key=\(key) dx=\(Int(move.x)) dy=\(Int(move.y)) -> \(claim ? "claim" : "scroll")")
            return claim
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

// MARK: - Pressed key state

private struct KeyPressedKey: EnvironmentKey {
    static var defaultValue: Bool { false }
}

extension EnvironmentValues {
    /// True while a finger is down on the enclosing keybar key (and has not moved off
    /// into a scroll or flick); `SlotChrome` brightens its background for it.
    var keyPressed: Bool {
        get { self[KeyPressedKey.self] }
        set { self[KeyPressedKey.self] = newValue }
    }
}

extension View {
    /// Shows the pressed look on a keybar key while it is touched, from touch-down
    /// with no delay, for a key whose tap is handled elsewhere (a key with its own
    /// long-press action). Apply it OUTSIDE the key's own gestures so it can only ever
    /// run alongside the tap, never ahead of it.
    func keyPressFeedback() -> some View {
        modifier(KeyPressModifier(onTap: nil))
    }

    /// The key's tap: the pressed look from touch-down, then the keyboard click and
    /// `action` when the finger lifts, however long it was held, as long as it stayed
    /// put (Kit `keyPressIsTap`; a scroll or flick sends nothing). A key with no
    /// long-press action of its own uses this, so a long press acts as a tap. Apply it
    /// as the key's LAST modifier, outside its flick gesture, like `keyPressFeedback`.
    func keyTap(perform action: @escaping () -> Void) -> some View {
        modifier(KeyPressModifier(onTap: action))
            .accessibilityAction { InputClickFeedback.play(); action() }
    }
}

private struct KeyPressModifier: ViewModifier {
    /// Sent on release when the touch stayed inside the slop; nil = pressed look only.
    let onTap: (() -> Void)?
    /// iOS 18+: set by the UIKit press recognizer.
    @State private var pressed = false
    /// Before iOS 18: the simultaneous drag; resets on end and on cancel.
    @GestureState private var pressing = false
    /// Before iOS 18: the touch has left the slop at some point (no tap on release).
    /// Reset at touch-down, since a drag the scroll view takes over never ends.
    @State private var leftSlop = false

    func body(content: Content) -> some View {
        let tracked = content.environment(\.keyPressed, pressed || pressing)
        if #available(iOS 18.0, *) {
            tracked.gesture(KeyPressRecognizer(onPress: { pressed = $0 }, onRelease: fire))
        } else {
            tracked.simultaneousGesture(DragGesture(minimumDistance: 0)
                .updating($pressing) { g, state, _ in
                    state = keyPressIsTap(dx: g.translation.width, dy: g.translation.height)
                }
                .onChanged { g in
                    if g.translation == .zero { leftSlop = false }
                    if !keyPressIsTap(dx: g.translation.width, dy: g.translation.height) { leftSlop = true }
                }
                .onEnded { g in
                    let tap = !leftSlop && keyPressIsTap(dx: g.translation.width, dy: g.translation.height)
                    leftSlop = false
                    if tap { fire() }
                })
        }
    }

    private func fire() {
        guard let onTap else { return }
        InputClickFeedback.play()
        onTap()
    }
}

/// The iOS 18+ press tracker: a zero-duration long press that begins at touch-down,
/// recognizes alongside everything (the swipe pan, the scroll view's pan), and never
/// cancels or delays the view's touches. It ends when the finger lifts, so it also
/// reports the release of a touch that never left the slop, however long it was held.
/// A SwiftUI drag is not used here because on iOS 18 it blocked the middle region's
/// scrolling (device build 188).
@available(iOS 18.0, *)
private struct KeyPressRecognizer: UIGestureRecognizerRepresentable {
    let onPress: (Bool) -> Void
    /// The finger lifted while still pressed (it never left the slop).
    let onRelease: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let press = UILongPressGestureRecognizer()
        press.minimumPressDuration = 0
        press.allowableMovement = .greatestFiniteMagnitude   // movement is judged below
        press.cancelsTouchesInView = false
        press.delaysTouchesEnded = false
        press.delegate = context.coordinator
        return press
    }

    func handleUIGestureRecognizerAction(_ press: UILongPressGestureRecognizer, context: Context) {
        let c = context.coordinator
        let at = press.location(in: press.view)
        let now: Bool
        switch press.state {
        case .began:
            c.start = at
            now = true
        case .changed:
            now = c.isPressed && keyPressIsTap(dx: at.x - c.start.x, dy: at.y - c.start.y)
        case .ended:
            if c.isPressed && keyPressIsTap(dx: at.x - c.start.x, dy: at.y - c.start.y) { onRelease() }
            now = false
        default:   // cancelled / failed
            now = false
        }
        guard now != c.isPressed else { return }
        c.isPressed = now
        onPress(now)
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var start: CGPoint = .zero
        var isPressed = false

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

/// Modifier slot: tap=arm Ctrl (one-shot), swipe-up=Alt, swipe-down=Shift.
/// A single tap recognizer, no double-tap sibling, so the arm fires the instant
/// the finger lifts (a `count:2` sibling forced SwiftUI to wait out the
/// double-tap window first, which felt laggy).
struct ModifierSlotView: View {
    let ctrl: CtrlState
    let vm: ConnectionViewModel
    @Environment(\.theme) private var theme
    private var bg: Color {
        switch ctrl {
        case .armed: return Color(theme.keybar.slotBgArmed)
        case .off:   return Color(theme.keybar.slotBg)
        }
    }
    var body: some View {
        SlotChrome(bg: bg) {
            Text("⌃").foregroundStyle(Color(theme.text.primary))
        }
        .flickKey("modifier", up: "Alt", down: "Shift") { dir in
            switch dir {
            case .up:   vm.keybar.armAlt()
            case .down: vm.keybar.armShift()
            }
        }
        .keyTap { vm.keybar.tapCtrl() }
    }
}

/// Esc pill: tap=Esc; long-press opens the
/// Settings tree (4d wires the Settings→Keybar leaf; the full unified picker,
/// windows/hosts/recent, is a later slice). The dim `≡` glyph hints at the
/// extra gestures (keybar-customization spec "Esc pill → Visual").
struct EscPillView: View {
    let vm: ConnectionViewModel
    /// Invoked on long-press to surface the Settings tree.
    var onOpenSettings: () -> Void = {}
    @Environment(\.theme) private var theme
    var body: some View {
        SlotChrome(bg: Color(theme.keybar.slotBg)) {
            ZStack(alignment: .topTrailing) {
                Text("Esc").font(.caption).foregroundStyle(Color(theme.text.primary))
                Text("≡").font(.system(size: 8))
                    .foregroundStyle(Color(theme.text.secondary))
                    .offset(x: 4, y: -3)
            }
        }
        .onInputClickTap { vm.keybar.tapEscape() }
        .onLongPressGesture { onOpenSettings() }
    }
}

/// A macro pinned directly to the bar (a `.pinnedMacro` slot): tap fires the
/// recorded body via the input router. (keybar-customization spec "Macro library
/// → pinning".)
struct PinnedMacroSlotView: View {
    let macro: Macro
    let vm: ConnectionViewModel
    @Environment(\.theme) private var theme
    var body: some View {
        SlotChrome(bg: Color(theme.keybar.slotBg)) {
            Text(macro.name).font(.caption).lineLimit(1)
                .foregroundStyle(Color(theme.text.primary))
        }
        .keyTap {
            DebugLog.shared.log(.keybar, "keybar:macroResolved events=\(macro.body.count)")
            vm.keybar.fireMacro(macro.body)
        }
    }
}

/// A user-created custom slot (a `.custom` slot): up to four gesture bindings,
/// each firing a macro from the library. The primary label resolves per spec; dim
/// edge glyphs hint at bound swipe-up/down, and a corner `≡` hints at long-press
/// (keybar-customization spec "Slot display content").
struct CustomSlotView: View {
    let slot: CustomSlot
    let library: KeybarLibrary
    let vm: ConnectionViewModel
    @Environment(\.theme) private var theme

    private var label: String {
        slot.displayLabel(macroName: { library.macro($0)?.name }) ?? "·"
    }

    /// Fires the macro bound to `gesture`, if any (orphaned refs are no-ops).
    private func fire(_ gesture: CustomSlotGesture) {
        guard let binding = slot.binding(for: gesture),
              let body = library.macro(binding.macro)?.body else { return }
        DebugLog.shared.log(.keybar, "keybar:macroResolved events=\(body.count)")
        vm.keybar.fireMacro(body)
    }

    var body: some View {
        // A bound long press keeps its own action; otherwise a long press is a tap.
        if slot.longPress != nil {
            key
                .onInputClickTap { fire(.tap) }
                .onLongPressGesture { fire(.longPress) }
                .flickKey("gestureKey", up: flickLabel(.swipeUp), down: flickLabel(.swipeDown), onSwipe: swipe)
                .keyPressFeedback()
        } else {
            key
                .flickKey("gestureKey", up: flickLabel(.swipeUp), down: flickLabel(.swipeDown), onSwipe: swipe)
                .keyTap { fire(.tap) }
        }
    }

    private func swipe(_ dir: KeySwipeDirection) {
        fire(dir == .up ? .swipeUp : .swipeDown)
    }

    private var key: some View {
        SlotChrome(bg: Color(theme.keybar.slotBg)) {
            Text(label).font(.system(.body, design: .monospaced)).lineLimit(1)
                .foregroundStyle(Color(theme.text.primary))
        }
        .overlay(alignment: .top) {
            if slot.swipeUp != nil { hintGlyph("˄") }
        }
        .overlay(alignment: .bottom) {
            if slot.swipeDown != nil { hintGlyph("˅") }
        }
        .overlay(alignment: .topTrailing) {
            if slot.longPress != nil { hintGlyph("≡").offset(x: -2, y: 2) }
        }
    }

    /// The flick bubble's label for a swipe gesture: the binding's override label, else
    /// its macro's name; nil when unbound or orphaned (no bubble, no click).
    private func flickLabel(_ gesture: CustomSlotGesture) -> String? {
        guard let binding = slot.binding(for: gesture) else { return nil }
        if let override = binding.overrideLabel, !override.isEmpty { return override }
        return library.macro(binding.macro)?.name
    }

    private func hintGlyph(_ s: String) -> some View {
        Text(s).font(.system(size: 7)).foregroundStyle(Color(theme.text.secondary))
    }
}

/// A dim placeholder for a slot whose library entry is missing (orphaned id),
/// defensive only; the store prunes references on delete.
struct MissingSlotView: View {
    @Environment(\.theme) private var theme
    var body: some View {
        SlotChrome(bg: Color(theme.keybar.slotBg)) {
            Text("?").foregroundStyle(Color(theme.text.secondary))
        }
    }
}

/// Pad: SWIPE = arrow key in the swiped (dominant-axis) direction, and HOLDING the swipe
/// auto-repeats it iOS-style (distance picks direction, held-time drives the rate; see
/// SemicolynKit `ArrowRepeat`). No tap action: the pad is purely a directional control
/// (device 2026-07-20: tap used to zoom the active pane, so a press meant to send an arrow
/// zoomed a pane instead). Zoom lives on the long-press-pane gesture elsewhere.
struct PadView: View {
    let vm: ConnectionViewModel
    @Environment(\.theme) private var theme

    @State private var heldSince: Date?                 // set on the first crossing; nil = not held
    @State private var lastTranslation: CGSize = .zero  // latest dx/dy, updated every onChanged
    @State private var repeatTimer: Timer?
    @State private var showWindowMenu = false
    /// Second step of "Close Pane": closing stops whatever runs in the pane (D-10).
    @State private var confirmingClosePane = false

    var body: some View {
        SlotChrome(bg: Color(theme.keybar.slotBg)) {
            Image(systemName: "dpad").foregroundStyle(Color(theme.text.primary))
        }
        .gesture(
            DragGesture(minimumDistance: 16)
                .onChanged { g in
                    lastTranslation = g.translation           // always track the latest thumb pos
                    guard heldSince == nil else { return }     // already holding; timer drives it
                    fireArrow()                                // first fire on crossing 16pt
                    heldSince = Date()
                    DebugLog.shared.log(.keybar,
                        "keybar:dpad swipe dx=\(Int(g.translation.width)) dy=\(Int(g.translation.height)) -> arrow=\(dominantArrow(dx: g.translation.width, dy: g.translation.height))")
                    DebugLog.shared.log(.keybar, "keybar:dpad repeat start")
                    scheduleNextRepeat()
                }
                .onEnded { _ in stopRepeat() }
        )
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4)
                .onEnded { _ in
                    guard vm.plainTmux != nil else { return }
                    DebugLog.shared.log(.keybar, "keybar:dpad longPress -> window menu")
                    showWindowMenu = true
                }
        )
        .confirmationDialog("Pane", isPresented: $showWindowMenu, titleVisibility: .visible) {
            Button("Split Right") { vm.windowAction(.splitHorizontal) }
            Button("Split Down") { vm.windowAction(.splitVertical) }
            Button("New Window") { vm.windowAction(.newWindow) }
            // tmux zoom is a toggle and the app does not track the zoom state, so the
            // label names both directions.
            Button("Zoom / Unzoom Pane") { vm.windowAction(.zoom) }
            Button("Close Pane", role: .destructive) { confirmingClosePane = true }
            Button("Cancel", role: .cancel) { }
        }
        .confirmationDialog("Close this pane?", isPresented: $confirmingClosePane,
                            titleVisibility: .visible) {
            Button("Close Pane", role: .destructive) { vm.windowAction(.closePane) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Anything running in it will stop.")
        }
    }

    /// Fire the arrow for the current thumb direction, with the keyboard click on every
    /// arrow (first and each repeat), like a held iOS delete key.
    private func fireArrow() {
        InputClickFeedback.play()
        vm.keybar.arrow(dominantArrow(dx: lastTranslation.width, dy: lastTranslation.height))
    }

    /// Re-arm the repeat timer: ask the Kit decider for the interval at the current held-time.
    /// While still in the initial-delay window it returns nil; poll again at the remaining delay.
    private func scheduleNextRepeat() {
        guard let since = heldSince else { return }
        let held = Date().timeIntervalSince(since)
        let delay: TimeInterval
        let shouldFire: Bool
        if let interval = ArrowRepeat.interval(heldFor: held) {
            delay = interval
            shouldFire = true
        } else {
            delay = max(0.01, ArrowRepeat.initialDelay - held)   // wait out the remaining delay
            shouldFire = false
        }
        repeatTimer?.invalidate()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard self.heldSince != nil else { return }      // released between arm and fire
                if shouldFire { self.fireArrow() }
                self.scheduleNextRepeat()
            }
        }
    }

    /// Stop repeating and reset held state (on release).
    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        heldSince = nil
    }
}
