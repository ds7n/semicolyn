// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Map a typed ET bootstrap failure to a readable, user-facing line for the
/// `.failed` state. The string-bearing error cases already carry SANITIZED text
/// (see parseETIDPASSKEY / ETSession.onEnd), so it is safe to render here.
public func etFailureMessage(_ error: ETBootstrapError) -> String {
    let prefix = "Eternal Terminal could not connect: "
    switch error {
    case .execFailed:
        return prefix + "could not start the bootstrap over SSH."
    case .noIDPASSKEY(let serverOutput):
        return prefix + "no response from etserver (is it installed?). Server said: \(serverOutput)"
    case .malformedIDPASSKEY:
        return prefix + "the server sent a malformed credential."
    case .invalidConfig(let e):
        return prefix + "invalid connection settings (\(e))."
    case .handshakeFailed(let reason):
        return prefix + reason
    }
}
