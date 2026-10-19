// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The label an unset ("inherit") picker shows: "Default (X)", where X is the value
/// actually used. One wording on both the host editor and Connection Defaults;
/// never a raw token like "false" or "accept-new".
public func defaultChoiceLabel(_ effective: String) -> String {
    "Default (\(effective))"
}

/// The placeholder an unset text field shows: "Default: X".
public func defaultPlaceholder(_ effective: String) -> String {
    "Default: \(effective)"
}

/// What an unset field falls back to, as the editors display it.
///
/// - `InheritedFallbacks(defaults:)`: for the HOST editor, the Connection Defaults
///   value when set, else the built-in.
/// - `InheritedFallbacks.builtIn`: for the Connection Defaults editor itself (its
///   unset fields fall back to the built-ins).
///
/// Mirrors the resolvers in `Resolution.swift` for a host that sets nothing.
public struct InheritedFallbacks: Equatable, Sendable {
    /// The user; nil when neither Defaults nor a built-in provides one.
    public let user: String?
    public let port: Int
    public let transport: Transport
    public let keepAliveInterval: Int
    public let keepAliveRetries: Int
    public let tmuxSessionName: String

    public init(defaults: Defaults) {
        let bare = Host(id: UUID(), label: "", hostName: "")
        user = resolveOptional(bare.user, defaults.user)
        port = resolvePort(host: bare, defaults: defaults)
        transport = resolveTransport(host: bare, defaults: defaults)
        keepAliveInterval = resolveServerAliveInterval(host: bare, defaults: defaults)
        keepAliveRetries = resolveServerAliveCountMax(host: bare, defaults: defaults)
        tmuxSessionName = resolveTmuxSessionName(host: bare, defaults: defaults)
    }

    /// The built-in fallbacks (an empty Defaults record).
    public static let builtIn = InheritedFallbacks(defaults: Defaults())

    /// Placeholder for the user field: "Default: <user>", or an example when no
    /// default user exists.
    public var userPlaceholder: String {
        user.map(defaultPlaceholder) ?? "e.g. ubuntu"
    }
}

/// The Mosh "Local echo" picker's selection. Unset already sends "adaptive"
/// (`ConnectionViewModel` defaults the predict mode to it), so "Adaptive (default)" stands for both unset and an
/// explicit `.adaptive`; mapping `.adaptive` to nil keeps a stored `.adaptive`
/// matching a row instead of showing a blank picker.
public func moshLocalEchoSelection(_ mode: MoshPredictionMode?) -> MoshPredictionMode? {
    mode == .adaptive ? nil : mode
}
