// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// The full, persistable keybar customization: the user's three-region slot
/// composition and (4d-2) the macro / custom-slot library it references.
/// Persisted as JSON by the App's settings store.
public struct KeybarSettings: Equatable, Sendable, Codable {
    public var layout: KeybarLayout
    public var library: KeybarLibrary
    /// 4e: hide the keybar entirely when a hardware keyboard is connected. The
    /// predictor strip is governed independently and is unaffected by this.
    public var hideKeybarWithHardwareKeyboard: Bool
    /// User overrides for fixed-key swipe secondaries (symbol/tab/fkey). Empty = all defaults.
    public var fixedKeySecondaries: [FixedKeyID: SwipeSecondaries] = [:]

    public init(layout: KeybarLayout = .default,
                library: KeybarLibrary = .empty,
                hideKeybarWithHardwareKeyboard: Bool = false,
                fixedKeySecondaries: [FixedKeyID: SwipeSecondaries] = [:]) {
        self.layout = layout
        self.library = library
        self.hideKeybarWithHardwareKeyboard = hideKeybarWithHardwareKeyboard
        self.fixedKeySecondaries = fixedKeySecondaries
    }

    /// The default: stock layout, empty library, keybar shown.
    public static let `default` = KeybarSettings()

    private enum CodingKeys: String, CodingKey {
        case layout, library, hideKeybarWithHardwareKeyboard, fixedKeySecondaries
    }

    /// Decode-only keys of the v1 schema: the retired whole-bar mirror toggle.
    private enum LegacyKeys: String, CodingKey { case layout, direction }
    private enum LegacyLayoutKeys: String, CodingKey { case locked, scroll }

    /// Back-compatible decode: keys added after a user's blob was written default
    /// rather than failing the decode (which would reset the layout). A v1 layout
    /// saved with `direction == "lockedRight"` migrates mirrored so the bar looks
    /// the same; any other or unknown direction migrates non-mirrored. Encoding
    /// always writes v2 without `direction`, so the migration runs once.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layout = try c.decode(KeybarLayout.self, forKey: .layout)
        library = try c.decodeIfPresent(KeybarLibrary.self, forKey: .library) ?? .empty
        hideKeybarWithHardwareKeyboard =
            try c.decodeIfPresent(Bool.self, forKey: .hideKeybarWithHardwareKeyboard) ?? false
        fixedKeySecondaries =
            try c.decodeIfPresent([FixedKeyID: SwipeSecondaries].self, forKey: .fixedKeySecondaries) ?? [:]

        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        guard (try? legacy.decodeIfPresent(String.self, forKey: .direction)) == "lockedRight" else { return }
        let v1 = try legacy.nestedContainer(keyedBy: LegacyLayoutKeys.self, forKey: .layout)
        guard v1.contains(.locked) else { return }
        layout = KeybarLayout.fromV1(locked: try v1.decode([KeybarSlot].self, forKey: .locked),
                                     scroll: try v1.decode([KeybarSlot].self, forKey: .scroll),
                                     mirrored: true)
    }
}
