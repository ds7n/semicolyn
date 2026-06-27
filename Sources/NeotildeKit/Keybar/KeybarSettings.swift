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

    public init(layout: KeybarLayout, direction: KeybarLayoutDirection,
                library: KeybarLibrary = .empty) {
        self.layout = layout
        self.direction = direction
        self.library = library
    }

    /// The v1 default: stock layout, locked-left, empty library.
    public static let `default` = KeybarSettings(layout: .default, direction: .lockedLeft)

    private enum CodingKeys: String, CodingKey { case layout, direction, library }

    /// Back-compatible decode: a pre-4d-2 blob has no `library` key, so it defaults
    /// to `.empty` rather than failing the decode (which would reset the layout).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layout = try c.decode(KeybarLayout.self, forKey: .layout)
        direction = try c.decode(KeybarLayoutDirection.self, forKey: .direction)
        library = try c.decodeIfPresent(KeybarLibrary.self, forKey: .library) ?? .empty
    }
}
