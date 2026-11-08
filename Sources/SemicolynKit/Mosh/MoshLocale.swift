// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The locale every client used before privacy audit P-L3, kept as the last fallback.
public let moshFallbackLocale = "en_US.UTF-8"

/// The locales to offer mosh-server as `LANG`, in the order to try them (privacy audit
/// P-L3): the user's own locale as `ll_RR.UTF-8`, then `C.UTF-8`, then `en_US.UTF-8`.
///
/// mosh-server only applies the client's `-l` variables when its own login locale is not
/// UTF-8, and then exits with "needs a UTF-8 native locale" if the one offered isn't
/// installed. So the caller tries each candidate in turn while
/// `moshNeedsLocaleRetry` says the last attempt failed for that reason.
///
/// The user locale is only offered when both parts are well formed (a 2 or 3 letter
/// language and a 2 letter region); anything else (a numeric region such as `419`, a
/// missing region, stray characters) is skipped rather than guessed at. The value is
/// later joined into a shell command, so this strict form is also what keeps it a
/// single safe word.
public func moshLocaleCandidates(languageCode: String?, regionCode: String?) -> [String] {
    var candidates: [String] = []
    if let language = languageCode?.lowercased(), let region = regionCode?.uppercased(),
       isASCIILetters(language, count: 2...3), isASCIILetters(region, count: 2...2) {
        candidates.append("\(language)_\(region).UTF-8")
    }
    for fallback in ["C.UTF-8", moshFallbackLocale] where !candidates.contains(fallback) {
        candidates.append(fallback)
    }
    return candidates
}

/// True when mosh-server's bootstrap output says it refused the offered locale, so the
/// next candidate from `moshLocaleCandidates` should be tried.
public func moshNeedsLocaleRetry(_ output: String) -> Bool {
    output.contains("needs a UTF-8 native locale")
}

/// True when `value` is only ASCII letters and its length is in `count`.
private func isASCIILetters(_ value: String, count: ClosedRange<Int>) -> Bool {
    count.contains(value.count) && value.unicodeScalars.allSatisfy {
        ("a"..."z").contains($0) || ("A"..."Z").contains($0)
    }
}
