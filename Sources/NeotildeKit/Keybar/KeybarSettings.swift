// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Which edge the locked region anchors to. A pure layout-mirror for left-thumb
/// or preference users — the keybar's gesture semantics are unchanged
/// (keybar-customization spec "Reverse-bar option").
public enum KeybarLayoutDirection: String, Codable, Sendable {
    case lockedLeft
    case lockedRight
}

/// The full, persistable keybar customization: the user's slot composition plus
/// the reverse-bar direction. Persisted as JSON by the App's settings store.
public struct KeybarSettings: Equatable, Sendable, Codable {
    public var layout: KeybarLayout
    public var direction: KeybarLayoutDirection

    public init(layout: KeybarLayout, direction: KeybarLayoutDirection) {
        self.layout = layout
        self.direction = direction
    }

    /// The v1 default: stock layout, locked-left.
    public static let `default` = KeybarSettings(layout: .default, direction: .lockedLeft)
}
