#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 True Positive LLC
# SPDX-License-Identifier: GPL-3.0-only
#
# View-only gate: fail if an App/**.swift file contains pure decision logic that
# belongs in Sources/SemicolynKit/. Heuristic + allowlisted; see
# docs/app-view-only-gate.md. Low-false-positive by design — flag only the
# clearest smells (free-function value-returning math on plain Int/Double).
set -euo pipefail

APP_DIR="${1:-App}"

# Smell: a private/free func returning a scalar computed from scalar args with a
# modulo/arithmetic body — the window-step class. Extended cautiously over time.
# Allowlist: SwiftUI/UIKit wiring never matches because it returns View/Void or
# touches self./view./@Published — excluded below.
scan() {
  local dir="$1"
  # -P: Perl regex; match a func returning a bare scalar (`-> Int|Double|Bool {`),
  # then subtract the wiring allowlist: methods that touch `self.`/`view.`, carry
  # an attribute (`@`), return/compose SwiftUI (`View`/`Binding`/`some `), or take
  # a UIKit / gesture / capitalized-type parameter (delegate & gesture handlers).
  # Verified 2026-07-06 against the real App tree: flags the window-step math class,
  # excludes `gestureRecognizerShouldBegin(_:UIGestureRecognizer)->Bool` & bindings.
  grep -rnP --include='*.swift' \
    'func\s+\w+\([^)]*\)\s*->\s*(Int|Double|Bool)\s*\{' "$dir" 2>/dev/null \
    | grep -vP '(self\.|view\.|@|View|Binding|some |UI[A-Z]\w+|Gesture|Recognizer|_ [a-z]\w*: [A-Z])' || true
}

selftest() {
  local tmp; tmp="$(mktemp -d)"
  cat >"$tmp/Clean.swift" <<'SW'
struct V { var body: some View { Text("hi") }
  func makeBinding() -> Binding<Int> { .constant(0) } }
SW
  cat >"$tmp/Dirty.swift" <<'SW'
func wrap(current: Int, count: Int) -> Int {
  return (current + 1) % count
}
SW
  local dirty_hits clean_hits
  dirty_hits="$(scan "$tmp/Dirty.swift" | wc -l | tr -d ' ')"
  clean_hits="$(scan "$tmp/Clean.swift" | wc -l | tr -d ' ')"
  rm -rf "$tmp"
  [ "$dirty_hits" -ge 1 ] || { echo "SELFTEST FAIL: dirty fixture not flagged"; exit 1; }
  [ "$clean_hits" -eq 0 ] || { echo "SELFTEST FAIL: clean fixture false-positived"; exit 1; }
  echo "selftest OK"
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit 0; fi

hits="$(scan "$APP_DIR")"
if [ -n "$hits" ]; then
  echo "View-only gate: pure logic found in App/ — move it to Sources/SemicolynKit/ and unit-test it:" >&2
  echo "$hits" >&2
  echo "(See docs/app-view-only-gate.md. If this is a false positive, refine the allowlist there.)" >&2
  exit 1
fi
echo "View-only gate: clean"
