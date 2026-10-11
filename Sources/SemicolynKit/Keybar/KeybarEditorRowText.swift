// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// The row title for a slot in Settings → Keybar. User-facing names: a
/// `.pinnedMacro` is a "Macro key" (tap runs one macro) and a `.custom` slot is a
/// "Gesture key" (tap / swipe up / swipe down / long-press each run a macro).
public func keybarEditorTitle(for slot: KeybarSlot, library: KeybarLibrary) -> String {
    switch slot {
    case .escPill:        return "Esc pill"
    case .pad:            return "Pad (arrows + pane)"
    case .modifier:       return "Modifier (Ctrl/Alt/Shift)"
    case .tab:            return "Tab"
    case .fn:             return "Fn (function keys)"
    case .symbol(let s):  return "Symbol “\(s)”"
    case .pinnedMacro(let id):
        guard let macro = library.macro(id) else { return "Macro key (missing macro)" }
        return "Macro key “\(macro.name)”"
    case .custom(let id):
        guard let key = library.customSlot(id) else { return "Gesture key (missing)" }
        guard let name = key.displayLabel(macroName: { library.macro($0)?.name }) else { return "Gesture key" }
        return "Gesture key “\(name)”"
    }
}

/// The secondary line under a Settings → Keybar row: what each gesture on the
/// key does, so the user needn't open every key's editor. Symbols and Tab show
/// their effective swipe secondaries (user override, else built-in default); a
/// macro key shows its tap macro; a gesture key lists every bound gesture in
/// display order. Nil for keys with nothing to show (Esc, Pad, Modifier, Fn) and
/// for a missing macro/gesture key (the title already says "missing").
public func keybarEditorDetail(for slot: KeybarSlot, settings: KeybarSettings) -> String? {
    let library = settings.library
    switch slot {
    case .symbol(let s):
        return _swipeDetail(resolveSecondaries(for: .symbol(s), overrides: settings.fixedKeySecondaries))
    case .tab:
        return _swipeDetail(resolveSecondaries(for: .tab, overrides: settings.fixedKeySecondaries))
    case .pinnedMacro(let id):
        return library.macro(id).map { "Tap: \($0.name)" }
    case .custom(let id):
        guard let key = library.customSlot(id) else { return nil }
        let parts = CustomSlotGesture.allCases.compactMap { gesture -> String? in
            guard let binding = key.binding(for: gesture) else { return nil }
            let name = library.macro(binding.macro)?.name ?? "missing"
            return _gesturePrefix(gesture) + name
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    case .escPill, .pad, .modifier, .fn:
        return nil
    }
}

private func _swipeDetail(_ secondaries: SwipeSecondaries) -> String {
    let glyphs = hintGlyphs(for: secondaries)
    return "↑ \(glyphs.up ?? "none")   ↓ \(glyphs.down ?? "none")"
}

private func _gesturePrefix(_ gesture: CustomSlotGesture) -> String {
    switch gesture {
    case .tap:       return "Tap: "
    case .swipeUp:   return "↑ "
    case .swipeDown: return "↓ "
    case .longPress: return "Hold: "
    }
}
