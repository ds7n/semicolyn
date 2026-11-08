// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import UIKit
import SemicolynKit

/// Hides the screen in the app switcher (privacy audit P-H1). When the app stops being
/// active and "Hide screen in app switcher" is on, a window showing only the app's
/// background, its name and the current host's name goes up above everything else
/// (sheets, full-screen sessions, the keybar), so the switcher card and the background
/// snapshot never show terminal content. It comes down when the app is active again.
@MainActor
final class PrivacyCover {
    static let shared = PrivacyCover()

    /// Above the keyboard and its accessory window, which sit far above `.alert`.
    private static let windowLevel = UIWindow.Level(rawValue: 10_000_010)

    /// Labels of the sessions on screen, innermost last (a quick-connect session can
    /// open on top of another).
    private var hostLabels: [String] = []
    private var window: UIWindow?

    private init() {}

    /// A session showing `label` came on screen.
    func pushHost(_ label: String) {
        hostLabels.append(label)
    }

    /// The session showing `label` left the screen.
    func popHost(_ label: String) {
        if let index = hostLabels.lastIndex(of: label) { hostLabels.remove(at: index) }
    }

    /// Show or hide the cover for the scene's new activity.
    func update(_ activity: AppActivity) {
        let enabled = PrivacyPreferences(defaults: .standard).hideInAppSwitcher
        if privacyCoverVisible(activity, enabled: enabled) { show() } else { hide() }
    }

    private func show() {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first else { return }
        let stores = AppStores.shared
        let theme = displayedDescriptor(selectedID: stores.appearance.selectedThemeID,
                                        previewID: nil, isPro: stores.pro.isPro).theme
        let cover = UIWindow(windowScene: scene)
        cover.windowLevel = Self.windowLevel
        cover.rootViewController = UIHostingController(
            rootView: PrivacyCoverView(hostLabel: hostLabels.last, theme: theme))
        // Shown without becoming key, so the terminal keeps first responder and the
        // keyboard is still up when the cover comes down.
        cover.isHidden = false
        window = cover
    }

    private func hide() {
        window?.isHidden = true
        window = nil
    }
}

/// The cover's content: the theme background with the app name and, in a session, the
/// host's name.
private struct PrivacyCoverView: View {
    let hostLabel: String?
    let theme: Theme

    var body: some View {
        ZStack {
            Color(theme.surface.bg).ignoresSafeArea()
            VStack(spacing: 8) {
                Text("Semicolyn")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color(theme.text.primary))
                if let hostLabel {
                    Text(hostLabel)
                        .font(.body)
                        .foregroundStyle(Color(theme.text.secondary))
                }
            }
        }
    }
}

extension AppActivity {
    /// The activity for a SwiftUI scene phase (an unknown future phase counts as
    /// inactive, so the cover errs on the side of going up).
    init(_ phase: ScenePhase) {
        switch phase {
        case .active: self = .active
        case .background: self = .background
        default: self = .inactive
        }
    }
}
