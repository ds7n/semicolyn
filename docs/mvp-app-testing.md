<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->
# Running the MVP app (connect & get a shell)

The MVP is the thinnest runnable Neotilde: a connect form (host / port / user /
password) → password auth → an interactive raw-PTY shell rendered in SwiftTerm.
It builds for the iOS Simulator in CI (the `macos` job); to actually use it you
need a Mac with Xcode.

## Build & run on a Mac

```bash
# 1. Build the Rust core into the UniFFI XCFramework (+ Swift bindings).
bash scripts/build-xcframework.sh

# 2. Generate the Xcode project from project.yml (install once: brew install xcodegen).
xcodegen generate

# 3. Open and run in the iOS Simulator (pick an iPhone simulator, ⌘R).
open Neotilde.xcodeproj
```

Or headless, matching CI:

```bash
xcodebuild -project Neotilde.xcodeproj -scheme Neotilde \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

## Try it against the repo's test SSH server

The Docker `sshd` fixture used by the Rust integration tests works as a target.
From the simulator you can also reach any host your Mac can reach.

1. Bring up the fixture (user `tester`, key-only by default — for a password
   smoke test point at any host that accepts passwords, or your own machine's
   `sshd`).
2. In the app: enter host, port (22), user, password → **Connect**.
3. Expect: the form swaps to a terminal; typing echoes, `ls` / the prompt
   render, and rotating the simulator reflows the grid.

## MVP limitations (intentional — next slices)

- **Password auth only**; publickey/cert deferred.
- **Host key is auto-trusted** (no prompt, no persistence). Real trust-on-first-use
  + `known_hosts` persistence wires the already-built `HostKeyStore`.
- **No saved hosts/credentials** — re-entered each launch. Wiring the built
  `HostStore` (Phase 2a) is the immediate follow-up.
- **Raw PTY**, no tmux control mode yet (the `open_exec` + `TmuxSessionController`
  stack is built and is the next terminal slice).
- App target builds in **Swift 5 language mode** (the UniFFI callback bridges +
  SwiftTerm aren't Swift-6 strict-concurrency clean yet).
- **On-device / TestFlight** needs the Apple Developer account + signing; the
  simulator build needs neither.
