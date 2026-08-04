// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Connection parameters for one ET session, mirroring the C ABI's `et_config`
/// (`extern/eternaltermlib/include/eternaltermlib.h`). A pure value type so the
/// bootstrap slice can build + validate it on any platform before the Obj-C++
/// `ETSession` marshals it into the flat C struct.
public struct ETConfig: Sendable, Equatable {
    public var host: String
    /// 0 is kept as 0; the C ABI maps 0 to ET's default port 2022.
    public var port: UInt16
    public var id: String
    public var passkey: String
    /// Must contain a non-empty TERM (validated).
    public var env: [String: String]
    public var cols: UInt16
    public var rows: UInt16
    /// Pixel size; 0 means unknown.
    public var width: UInt16
    public var height: UInt16
    /// 0 means ET's default keepalive (5s).
    public var keepaliveSecs: Int32

    public init(host: String, port: UInt16, id: String, passkey: String,
                env: [String: String], cols: UInt16, rows: UInt16,
                width: UInt16, height: UInt16, keepaliveSecs: Int32) {
        self.host = host; self.port = port; self.id = id; self.passkey = passkey
        self.env = env; self.cols = cols; self.rows = rows
        self.width = width; self.height = height; self.keepaliveSecs = keepaliveSecs
    }
}

/// Specific, typed validation failures raised at the config boundary.
public enum ETConfigError: Error, Equatable {
    case emptyHost, emptyID, emptyPasskey, missingTERM
}

/// Validate a config before it reaches the C ABI. Raises the SPECIFIC typed
/// error for invalid input (an API-boundary guard, not a null-return miss).
public func validateETConfig(_ cfg: ETConfig) throws -> ETConfig {
    if cfg.host.isEmpty { throw ETConfigError.emptyHost }
    if cfg.id.isEmpty { throw ETConfigError.emptyID }
    if cfg.passkey.isEmpty { throw ETConfigError.emptyPasskey }
    guard let term = cfg.env["TERM"], !term.isEmpty else { throw ETConfigError.missingTERM }
    return cfg
}

/// Flatten an env map into the two parallel arrays the C ABI wants
/// (`env_keys`/`env_vals`). Sorted by key so the output is deterministic
/// (stable tests, stable handshake payload); `keys[i]` pairs with `vals[i]`.
public func etEnvArrays(_ env: [String: String]) -> (keys: [String], vals: [String]) {
    let sorted = env.sorted { $0.key < $1.key }
    return (sorted.map(\.key), sorted.map(\.value))
}
