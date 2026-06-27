// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Stable identifier for a user-created custom slot. See `MacroID` for the
/// String-wrapper rationale.
public struct CustomSlotID: Hashable, Sendable, Codable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}

/// The four gestures a custom slot can bind. Horizontal swipes are reserved for
/// panning the scroll region, so they're deliberately absent in v1
/// (keybar-customization spec "Bindable gestures"). Display order (for label
/// fallback) is tap → swipe-up → swipe-down → long-press.
public enum CustomSlotGesture: String, CaseIterable, Sendable, Codable {
    case tap, swipeUp, swipeDown, longPress
}

/// One gesture's binding: a macro reference plus an optional per-gesture label
/// override (shown on the slot for that gesture). An absent binding (nil field
/// on the slot) means the gesture is unbound. (spec "Binding payload".)
public struct GestureBinding: Equatable, Sendable, Codable {
    public var macro: MacroID
    public var overrideLabel: String?
    public init(macro: MacroID, overrideLabel: String? = nil) {
        self.macro = macro
        self.overrideLabel = overrideLabel
    }
}

/// A user-created slot: a bundle of up to four gesture bindings plus an optional
/// primary label/glyph override. A slot with no bindings is meaningless and not
/// allowed — the editor gates Save on `hasAnyBinding`. (spec "Custom slot
/// binding model".)
public struct CustomSlot: Equatable, Sendable, Codable, Identifiable {
    public let id: CustomSlotID
    /// Primary label/glyph override. When nil/empty, the display label falls back
    /// to a bound macro's name (see `displayLabel`).
    public var label: String?
    public var tap: GestureBinding?
    public var swipeUp: GestureBinding?
    public var swipeDown: GestureBinding?
    public var longPress: GestureBinding?

    public init(id: CustomSlotID, label: String? = nil,
                tap: GestureBinding? = nil, swipeUp: GestureBinding? = nil,
                swipeDown: GestureBinding? = nil, longPress: GestureBinding? = nil) {
        self.id = id
        self.label = label
        self.tap = tap
        self.swipeUp = swipeUp
        self.swipeDown = swipeDown
        self.longPress = longPress
    }

    /// The binding for `gesture`, if any.
    public func binding(for gesture: CustomSlotGesture) -> GestureBinding? {
        switch gesture {
        case .tap:       return tap
        case .swipeUp:   return swipeUp
        case .swipeDown: return swipeDown
        case .longPress: return longPress
        }
    }

    /// True when at least one gesture is bound.
    public var hasAnyBinding: Bool {
        CustomSlotGesture.allCases.contains { binding(for: $0) != nil }
    }

    /// A slot is valid (Save-able) only when it has at least one binding.
    public var isValid: Bool { hasAnyBinding }

    /// The label shown on the slot, resolved per spec: an explicit non-empty
    /// `label` wins; otherwise the effective label of the first bound gesture in
    /// display order (tap first), where a binding's `overrideLabel` is preferred
    /// over the bound macro's name. Returns nil when nothing resolves.
    public func displayLabel(macroName: (MacroID) -> String?) -> String? {
        if let label, !label.isEmpty { return label }
        for gesture in CustomSlotGesture.allCases {
            guard let binding = binding(for: gesture) else { continue }
            if let override = binding.overrideLabel, !override.isEmpty { return override }
            if let name = macroName(binding.macro) { return name }
        }
        return nil
    }
}
