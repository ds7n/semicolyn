// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SemicolynKit

/// Maps how this binary was built to a `BuildChannel`. Decided at compile time on
/// purpose: App Review runs the submitted build in the same sandbox environment as
/// TestFlight, so a runtime check (receipt URL, `AppTransaction`) would show reviewers
/// the TestFlight-only Supporter preview. `SUPPORTER_PREVIEW` is set only by the
/// TestFlight workflow's `supporter_preview` input (default off).
enum BuildChannelDetector {
    static let current: BuildChannel = {
        #if DEBUG
        return .debug
        #elseif SUPPORTER_PREVIEW
        return .testFlight
        #else
        return .appStore
        #endif
    }()
}
