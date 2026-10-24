// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Whether the session's small "≡" corner button is shown. The in-session Settings
/// sheet (with its Session section) is normally reached from the keybar (long-press
/// Esc) or `⌘,`; the corner button is the way in ONLY when the keybar is not on
/// screen, so it never covers the terminal otherwise.
///
/// - Parameters:
///   - inShell: a live shell session is up (nothing to open otherwise).
///   - keybarAttached: the keybar's input accessory is in a window, i.e. the
///     keyboard (or the hardware-keyboard bar) is showing. False while the
///     software keyboard is down or failed to come up.
///   - hardwareKeyboardConnected: a hardware keyboard is attached.
///   - hideKeybarWithHardwareKeyboard: the user's "hide the keybar with a hardware
///     keyboard" setting; with a hardware keyboard attached the accessory stays in
///     the window but shows no keys (no Esc to long-press).
public func sessionMenuButtonVisible(inShell: Bool,
                                     keybarAttached: Bool,
                                     hardwareKeyboardConnected: Bool,
                                     hideKeybarWithHardwareKeyboard: Bool) -> Bool {
    guard inShell else { return false }
    if !keybarAttached { return true }
    return hardwareKeyboardConnected && hideKeybarWithHardwareKeyboard
}

/// The Session section's title line: "<host> · <transport>", naming the transport
/// actually carrying the session (a Mosh host that fell back to SSH reads "SSH").
public func sessionMenuTitle(hostLabel: String, transport: Transport) -> String {
    "\(hostLabel) · \(transport.displayName)"
}

/// The transport carrying the live session, from which transport handle is active.
/// ET wins over Mosh (they are never both live); neither means SSH.
public func activeSessionTransport(moshActive: Bool, etActive: Bool) -> Transport {
    if etActive { return .et }
    if moshActive { return .mosh }
    return .ssh
}
