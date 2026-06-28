// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Which edge the locked region anchors to. A pure layout-mirror for left-thumb
/// or preference users — the keybar's gesture semantics are unchanged
/// (keybar-customization spec "Reverse-bar option").
public enum KeybarLayoutDirection: String, Codable, Sendable {
    case lockedLeft
    case lockedRight
}

/// The full, persistable keybar customization: the user's slot composition, the
/// reverse-bar direction, and (4d-2) the macro / custom-slot library the layout
/// references. Persisted as JSON by the App's settings store.
public struct KeybarSettings: Equatable, Sendable, Codable {
    public var layout: KeybarLayout
    public var direction: KeybarLayoutDirection
    public var library: KeybarLibrary
    /// 4e: hide the keybar entirely when a hardware keyboard is connected. The
    /// predictor strip is governed independently and is unaffected by this.
    public var hideKeybarWithHardwareKeyboard: Bool

    public init(layout: KeybarLayout, direction: KeybarLayoutDirection,
                library: KeybarLibrary = .empty,
                hideKeybarWithHardwareKeyboard: Bool = false) {
        self.layout = layout
        self.direction = direction
        self.library = library
        self.hideKeybarWithHardwareKeyboard = hideKeybarWithHardwareKeyboard
    }

    /// The v1 default: stock layout, locked-left, empty library, keybar shown.
    public static let `default` = KeybarSettings(layout: .default, direction: .lockedLeft)

    private enum CodingKeys: String, CodingKey {
        case layout, direction, library, hideKeybarWithHardwareKeyboard
    }

    /// Back-compatible decode: keys added after a user's blob was written default
    /// rather than failing the decode (which would reset the layout). `library`
    /// (4d-2) → empty; `hideKeybarWithHardwareKeyboard` (4e) → false (shown).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layout = try c.decode(KeybarLayout.self, forKey: .layout)
        direction = try c.decode(KeybarLayoutDirection.self, forKey: .direction)
        library = try c.decodeIfPresent(KeybarLibrary.self, forKey: .library) ?? .empty
        hideKeybarWithHardwareKeyboard =
            try c.decodeIfPresent(Bool.self, forKey: .hideKeybarWithHardwareKeyboard) ?? false
    }
}
