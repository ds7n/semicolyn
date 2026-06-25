// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import NeotildeKit

/// App-lifetime holder for terminal preferences. Plan C exposes defaults only;
/// a future Settings screen mutates `settings` and views react.
@MainActor final class TerminalSettingsStore: ObservableObject {
    @Published var settings: TerminalSettings = TerminalSettings()
}
