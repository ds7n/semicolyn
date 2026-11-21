<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: MIT
-->

# Vendored SwiftTerm

Upstream: https://github.com/migueldeicaza/SwiftTerm, tag `v1.99.3` (2026-11-06), MIT
licensed (see `LICENSE`). Only the library, its build-info generator and plugin, and the
`swifterm-terminfo` source the generator reads are copied.

Vendored rather than consumed as a package so the app can carry the patches below.
Patches are offered under the upstream MIT licence.

## Local changes

1. `Package.swift`: trimmed to the library and the build-info plugin.
2. `Plugins/SwiftTermBuildInfoPlugin/plugin.swift`: pins the build identity. This copy
   has no `.git`, so the generator would otherwise describe the host repository.
3. `Sources/SwiftTerm/iOS/`: held-Backspace repeat. The soft keyboard repeats Backspace
   only while the text-input document has text before the caret, and that document held
   only locally typed text, so a held Backspace stopped after one delete once the remote
   side had inserted text (shell Tab completion). The document now always starts with a
   two-space placeholder that edits never remove; a Backspace at the placeholder sends
   DEL and leaves the document unchanged, so the key keeps repeating. Same approach as
   xterm.dart's `deleteDetection`.
4. `Sources/SwiftTerm/Apple/PowerlineRenderer.swift`: `thinFlamePath` wraps
   `dropFirst()` in `Array(...)`; Xcode 26.3's type checker rejects the upstream
   expression.

## Updating

Copy the same paths from the new upstream tag, re-apply the local changes (search for
`semicolyn` in this directory), and update the tag here and in the plugin defaults.
