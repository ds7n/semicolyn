<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Mosh Transport M3/M4 — Bridge + Wiring + Resilience Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the built-but-uncalled `Mosh.xcframework` into a working transport — a `MoshSession` Obj-C++ bridge that drives the vendored `mosh_main` loop over a pipe pair, wired into `ConnectionViewModel` after SSH auth, with SSH fallback on every pre-handoff failure and Mosh-owned resilience thereafter.

**Architecture:** After SSH auth, `open_exec` bootstraps `mosh-server`; its `MOSH CONNECT <port> <key>` stdout is parsed (Kit, exists) and mapped to a launch decision (Kit, exists). On `.mosh`, a `MoshSession` (`App/Mosh/MoshSession.{h,mm}`) allocates two `pipe()` pairs + a heap `winsize`, runs `mosh_main` on a background thread reading `fileno(f_in)` / writing an **unbuffered** `f_out`, and a reader thread pumps output bytes → `SwiftTerm.feed`. The bridge speaks only bytes + size events, the same seam the SSH/tmux paths already use. Resize is delivered via `pthread_kill(SIGWINCH)` + a shared `winsize` (R1), with a vendored control-pipe patch as the documented fallback (R2).

**Tech Stack:** Obj-C++ (`.mm`) over `Mosh.xcframework` (`mosh_main`), Swift 6 SemicolynKit (pure decision helper, Linux-tested), SwiftUI/SwiftTerm app tier, russh `open_exec` (existing), XCTest (Linux + macOS-gated), XcodeGen `project.yml`.

## Global Constraints

- **Tiers:** SemicolynKit = pure, Linux-tested, Swift 6 strict-concurrency, `Sendable`, **no `import UIKit`/`SwiftUI`/`Foundation`-UI**. `MoshSession` + all `mosh_main`-touching code = **App-tier, macOS-CI-verified only** — it does NOT compile on Linux and is invisible to `swift test`.
- **SPDX header on every first-party file:** `SPDX-FileCopyrightText: 2026 True Positive LLC` + `SPDX-License-Identifier: GPL-3.0-only`. **Never** add a first-party header to or relicense any file under `extern/mosh/` (vendored, keeps upstream headers).
- **iOS:** deployment target 17.0; Xcode 26 / iOS 26 SDK. `MoshSession` is app-target code; guard any `#if os(...)` so the Linux `swift test` job is untouched.
- **Tests are real** (`docs/superpowers/specs/2026-06-18-testing-standards-design.md`): equivalence-partitioning + boundary values; assert the **specific** observable value; a negative test asserts the **specific** failure. No `assert(true)`, no "result is ok" without checking which, no test that still passes when the production call is deleted.
- **`mosh_main` signature (verbatim from `extern/mosh/src/frontend/moshiosbridge.h`):**
  ```c
  int mosh_main(FILE *f_in, FILE *f_out, struct winsize *window_size,
                void (*state_callback)(const void *, const void *, size_t),
                void *state_callback_context,
                const char *ip, const char *port, const char *key,
                const char *predict_mode,
                const char *encoded_state_buffer, size_t encoded_state_size,
                const char *predict_overwrite);
  ```
  Returns `0` on clean exit (`!success`). Reads user input from `fileno(f_in)` via raw `read()`; writes frames to `f_out` via `fwrite` (**block-buffered on a pipe → must `setvbuf(f_out, NULL, _IONBF, 0)`**). Reacts to `SIGWINCH` + re-reads the shared `window_size`. `encoded_state` empty + a non-null no-op `state_callback` for M3/M4.
- **Commits:** Conventional Commits; feature branch `feat/mosh-m3-m4` (or the already-created `docs/mosh-m3-m4-plan` extended); squash-merge to `main`.
- **Build/test commands:** Kit tests via `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`. macOS/app/bridge tests + the `MoshSession` compile are validated ONLY by the **macOS CI job** (push the branch → open/refresh a PR, since CI triggers on `pull_request`).
- **Spec:** [`docs/superpowers/specs/2026-07-03-mosh-m3-m4-bridge-wiring-design.md`](../specs/2026-07-03-mosh-m3-m4-bridge-wiring-design.md).

## File Structure

| file | responsibility | tier / where verified |
|---|---|---|
| `Sources/SemicolynKit/Mosh/MoshBranchOutcome.swift` | pure helper composing `parseMoshConnect` + `moshLaunchDecision` → `.mosh(port,key)` / `.fallback(bannerText)` | Kit, **Linux XCTest** |
| `Tests/SemicolynKitTests/MoshBranchOutcomeTests.swift` | EP/BVA tests for the helper | Kit, Linux XCTest |
| `App/Mosh/MoshSession.h` | Obj-C interface (bytes + size seam) | App, macOS CI |
| `App/Mosh/MoshSession.mm` | Obj-C++ impl: pipes, `setvbuf`, mosh thread + reader thread, resize, teardown | App, macOS CI |
| `App/Mosh/Semicolyn-Bridging-Header.h` (or module import) | expose `MoshSession` to Swift; expose `Mosh` framework header to the `.mm` | App, macOS CI |
| `Tests/AppTests/MoshSessionTests.mm` + `fake_mosh_main.mm` | loopback stub + bridge plumbing tests | App, **macOS CI only** |
| `App/ConnectionViewModel.swift` (modify) | Mosh branch: bootstrap exec → capture → decide → create session → attach | App, macOS CI |
| `project.yml` (modify) | app-target `.mm` compile, bridging header, macOS-gated test target for `MoshSessionTests` | App, macOS CI |

**Note on the macOS test target:** if `project.yml` has no test target today, Task 3 adds a minimal macOS-hosted unit-test target that links `Mosh` + the app sources under test. If wiring a full test target proves heavy on CI, the fallback (documented in Task 3) is an in-app `#if DEBUG` self-check invoked from a CI build step — but attempt the real test target first.

---

## Task 1: `MoshBranchOutcome` pure helper (Linux-tested)

Extracts the VM branch's decision so it is covered off the Apple gate. Composes the two existing Kit units.

**Files:**
- Create: `Sources/SemicolynKit/Mosh/MoshBranchOutcome.swift`
- Test: `Tests/SemicolynKitTests/MoshBranchOutcomeTests.swift`

**Interfaces:**
- Consumes (exist): `parseMoshConnect(_ output: String) -> MoshConnect`, `moshLaunchDecision(enabled: Bool, bootstrap: MoshConnect) -> MoshLaunchDecision` (`.mosh(port:key:)` / `.fallbackSSH(reason:)`).
- Produces:
  - `enum MoshBranchOutcome: Equatable, Sendable { case mosh(port: Int, key: String); case fallback(reason: String) }`
  - `func moshBranchOutcome(stdout: String, enabled: Bool) -> MoshBranchOutcome`

**Banner text mapping (user-facing; asserted exactly in tests):**
- disabled → `"Mosh not enabled for this host — using SSH"`
- no `MOSH CONNECT` line (incl. empty stdout / bootstrap timeout) → `"mosh-server not found on host — using SSH"`
- malformed line → `"couldn't parse mosh-server output — using SSH"`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/SemicolynKitTests/MoshBranchOutcomeTests.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class MoshBranchOutcomeTests: XCTestCase {
    // Valid: enabled + clean handoff → mosh with exact port/key.
    func testEnabledValidHandoffIsMosh() {
        let out = "MOSH CONNECT 60001 x5HdELy8n2XkX9pO4dO2Zw"
        XCTAssertEqual(moshBranchOutcome(stdout: out, enabled: true),
                       .mosh(port: 60001, key: "x5HdELy8n2XkX9pO4dO2Zw"))
    }

    // Valid: handoff amid banner chatter still parses.
    func testHandoffAmidChatterIsMosh() {
        let out = "Last login: Tue\nMOSH CONNECT 60002 KEYKEYKEYKEY\nbye"
        XCTAssertEqual(moshBranchOutcome(stdout: out, enabled: true),
                       .mosh(port: 60002, key: "KEYKEYKEYKEY"))
    }

    // Invalid: disabled → fallback with the disabled reason even if a line parsed.
    func testDisabledIsFallbackDisabledReason() {
        let out = "MOSH CONNECT 60001 KEYKEYKEYKEY"
        XCTAssertEqual(moshBranchOutcome(stdout: out, enabled: false),
                       .fallback(reason: "Mosh not enabled for this host — using SSH"))
    }

    // Invalid: no MOSH CONNECT line → mosh-server-not-found fallback.
    func testNoConnectLineIsNotFoundFallback() {
        XCTAssertEqual(moshBranchOutcome(stdout: "mosh-server: command not found", enabled: true),
                       .fallback(reason: "mosh-server not found on host — using SSH"))
    }

    // Boundary: empty stdout (bootstrap timeout is passed as "") → not-found fallback.
    func testEmptyStdoutIsNotFoundFallback() {
        XCTAssertEqual(moshBranchOutcome(stdout: "", enabled: true),
                       .fallback(reason: "mosh-server not found on host — using SSH"))
    }

    // Invalid: malformed line (non-numeric port) → parse-failure fallback.
    func testMalformedLineIsParseFallback() {
        XCTAssertEqual(moshBranchOutcome(stdout: "MOSH CONNECT abc KEY", enabled: true),
                       .fallback(reason: "couldn't parse mosh-server output — using SSH"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter MoshBranchOutcomeTests`
Expected: FAIL — `moshBranchOutcome` / `MoshBranchOutcome` undefined.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/SemicolynKit/Mosh/MoshBranchOutcome.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// The `ConnectionViewModel` Mosh-branch decision: hand off to a Mosh session,
/// or fall back to SSH with a user-facing banner string. Extracted here (pure,
/// Linux-tested) so the decision is covered off the Apple-only bridge gate.
public enum MoshBranchOutcome: Equatable, Sendable {
    case mosh(port: Int, key: String)
    /// `reason` is the exact banner text shown before the SSH fallback runs.
    case fallback(reason: String)
}

/// Maps captured `mosh-server` bootstrap stdout + the resolved `mosh.enabled`
/// flag to a branch outcome. An empty `stdout` (used to represent a bootstrap
/// timeout with no output) parses as `.noConnectLine` → the not-found fallback.
public func moshBranchOutcome(stdout: String, enabled: Bool) -> MoshBranchOutcome {
    switch moshLaunchDecision(enabled: enabled, bootstrap: parseMoshConnect(stdout)) {
    case let .mosh(port, key):
        return .mosh(port: port, key: key)
    case .fallbackSSH:
        // Re-derive a user-facing banner from the underlying cause. Recompute the
        // parse to distinguish the failure classes (cheap; keeps this a pure map).
        if !enabled {
            return .fallback(reason: "Mosh not enabled for this host — using SSH")
        }
        switch parseMoshConnect(stdout) {
        case .failed(.noConnectLine):
            return .fallback(reason: "mosh-server not found on host — using SSH")
        case .failed(.malformed):
            return .fallback(reason: "couldn't parse mosh-server output — using SSH")
        case .success:
            // Unreachable: enabled + success would have returned .mosh above.
            return .fallback(reason: "mosh-server not found on host — using SSH")
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter MoshBranchOutcomeTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Mosh/MoshBranchOutcome.swift Tests/SemicolynKitTests/MoshBranchOutcomeTests.swift
git commit -m "feat(mosh): pure Mosh-branch outcome helper (Linux-tested)"
```

---

## Task 2: `MoshSession` Obj-C++ bridge — interface + pipe/thread core

The bridge that drives `mosh_main`. This task delivers the class + its plumbing (pipes, `setvbuf`, threads, input write). Resize and the CI test target come in Tasks 3–4; resilience in M4 tasks.

**Files:**
- Create: `App/Mosh/MoshSession.h`
- Create: `App/Mosh/MoshSession.mm`

**Interfaces:**
- Consumes (exists): `mosh_main` (Global Constraints signature), imported via the `Mosh` framework header (`#import <Mosh/moshiosbridge.h>` — the header path packaged into `Mosh.xcframework`; confirm the module/umbrella name at build time and adjust the `#import` if the framework exposes it as `moshiosbridge.h` directly).
- Produces (Swift-visible):
  - `-initWithIP:port:key:cols:rows:predictMode:`
  - `-start`, `-writeInput:` (`NSData*`), `-resizeCols:rows:` (stub here, real in Task 5), `-stop`
  - `@property (copy) void (^onOutput)(NSData *);`
  - `@property (copy) void (^onEnd)(NSString * _Nullable);`

- [ ] **Step 1: Write the interface**

```objc
// App/Mosh/MoshSession.h
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Drives one vendored `mosh_main` session over a pipe pair on a background
/// thread. Speaks only bytes + size events — the same contract SwiftTerm already
/// consumes from the SSH/tmux paths — so the terminal view is transport-agnostic.
///
/// Threading: `mosh_main` runs on a detached thread; a second reader thread pumps
/// output-pipe bytes into `onOutput`. Both callbacks are dispatched to the main
/// queue before they fire, so the Swift side may touch UIKit/SwiftTerm directly.
@interface MoshSession : NSObject

- (instancetype)initWithIP:(NSString *)ip
                      port:(NSString *)port
                       key:(NSString *)key
                      cols:(int)cols
                      rows:(int)rows
               predictMode:(NSString *)predictMode NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Allocate pipes + spawn the mosh thread and the output-reader thread.
- (void)start;

/// Enqueue keystroke bytes to Mosh via a raw `write()` (no stdio buffering).
- (void)writeInput:(NSData *)bytes;

/// Update the session's terminal size. Real delivery lands in a later task;
/// here it only records the new dimensions.
- (void)resizeCols:(int)cols rows:(int)rows;

/// Request a clean shutdown (quit sequence), then join the thread with a bounded
/// timeout off the main thread. Idempotent.
- (void)stop;

/// Output bytes from Mosh (main queue). Wire to `terminalView.feed(byteArray:)`.
@property (nonatomic, copy, nullable) void (^onOutput)(NSData *bytes);

/// Fires once when the mosh loop exits (main queue). `reason` nil = clean exit.
@property (nonatomic, copy, nullable) void (^onEnd)(NSString * _Nullable reason);

@end

NS_ASSUME_NONNULL_END
```

- [ ] **Step 2: Write the implementation (plumbing; resize is a no-op stub here)**

```objc
// App/Mosh/MoshSession.mm
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
#import "MoshSession.h"
#import <Mosh/moshiosbridge.h>   // if the framework exposes the bare header, use: #import "moshiosbridge.h"
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

// Mosh's clean-quit sequence is Ctrl-^ then '.'  (0x1e 0x2e).
static const unsigned char kMoshQuitSequence[2] = {0x1e, 0x2e};

// The bridge passes empty session state and a no-op state callback for M3/M4
// (session restoration across process death is out of scope).
static void mosh_state_noop(const void *ctx, const void *buf, size_t len) {
    (void)ctx; (void)buf; (void)len;
}

@implementation MoshSession {
    NSString *_ip, *_port, *_key, *_predict;
    struct winsize _winsize;   // shared with the mosh thread; updated on resize
    int _inPipe[2];            // app writes _inPipe[1]; mosh reads fileno(f_in) from _inPipe[0]
    int _outPipe[2];           // mosh writes f_out (_outPipe[1]); reader reads _outPipe[0]
    pthread_t _moshThread;
    pthread_t _readerThread;
    BOOL _started;
    BOOL _stopped;
}

- (instancetype)initWithIP:(NSString *)ip port:(NSString *)port key:(NSString *)key
                      cols:(int)cols rows:(int)rows predictMode:(NSString *)predictMode {
    if ((self = [super init])) {
        _ip = [ip copy]; _port = [port copy]; _key = [key copy]; _predict = [predictMode copy];
        _winsize = (struct winsize){ .ws_row = (unsigned short)rows, .ws_col = (unsigned short)cols,
                                     .ws_xpixel = 0, .ws_ypixel = 0 };
        _inPipe[0] = _inPipe[1] = _outPipe[0] = _outPipe[1] = -1;
    }
    return self;
}

// Trampolines: pthread entry points hop back into the ObjC object.
static void *mosh_thread_main(void *ctx) { return [(__bridge MoshSession *)ctx runMoshLoop]; }
static void *reader_thread_main(void *ctx) { return [(__bridge MoshSession *)ctx runReaderLoop]; }

- (void)start {
    if (_started) return;
    _started = YES;
    if (pipe(_inPipe) != 0 || pipe(_outPipe) != 0) {
        [self fireEnd:@"Mosh connection failed — using SSH"];
        return;
    }
    pthread_create(&_readerThread, NULL, reader_thread_main, (__bridge void *)self);
    pthread_create(&_moshThread, NULL, mosh_thread_main, (__bridge void *)self);
}

- (void *)runMoshLoop {
    FILE *fin = fdopen(_inPipe[0], "r");
    FILE *fout = fdopen(_outPipe[1], "w");
    if (!fin || !fout) { [self fireEnd:@"Mosh connection failed — using SSH"]; return NULL; }
    setvbuf(fout, NULL, _IONBF, 0);   // unbuffered: every frame flushes to the pipe immediately

    std::string emptyState;
    int rc = mosh_main(fin, fout, &_winsize,
                       mosh_state_noop, (__bridge void *)self,
                       _ip.UTF8String, _port.UTF8String, _key.UTF8String,
                       _predict.UTF8String,
                       emptyState.data(), 0, _predict.UTF8String);
    // mosh_main returned: signal the reader to stop by closing the output write end,
    // then report the end. rc == 0 means a clean exit.
    fclose(fout);            // closes _outPipe[1] → reader sees EOF
    [self fireEnd:(rc == 0 ? nil : @"Mosh connection failed — using SSH")];
    return NULL;
}

- (void *)runReaderLoop {
    const size_t bufSize = 16384;
    unsigned char *buf = (unsigned char *)malloc(bufSize);
    for (;;) {
        ssize_t n = read(_outPipe[0], buf, bufSize);
        if (n <= 0) break;   // EOF or error → mosh loop ended / pipe closed
        NSData *data = [NSData dataWithBytes:buf length:(NSUInteger)n];
        void (^cb)(NSData *) = self.onOutput;
        if (cb) dispatch_async(dispatch_get_main_queue(), ^{ cb(data); });
    }
    free(buf);
    return NULL;
}

- (void)writeInput:(NSData *)bytes {
    if (!_started || _stopped || _inPipe[1] < 0 || bytes.length == 0) return;
    const unsigned char *p = (const unsigned char *)bytes.bytes;
    size_t remaining = bytes.length;
    while (remaining > 0) {
        ssize_t w = write(_inPipe[1], p, remaining);
        if (w <= 0) break;
        p += w; remaining -= (size_t)w;
    }
}

- (void)resizeCols:(int)cols rows:(int)rows {
    // Record only; real delivery lands in the resize task.
    _winsize.ws_col = (unsigned short)cols;
    _winsize.ws_row = (unsigned short)rows;
}

- (void)stop {
    if (_stopped) return;
    _stopped = YES;
    // Ask Mosh to shut the network down cleanly.
    if (_inPipe[1] >= 0) { write(_inPipe[1], kMoshQuitSequence, sizeof(kMoshQuitSequence)); }
    // Join off the main thread with a bounded wait; then hard-close fds so the
    // reader unblocks even if Mosh never exits (dead UDP path).
    pthread_t moshT = _moshThread, readerT = _readerThread;
    int inW = _inPipe[1], outW = _outPipe[1], inR = _inPipe[0], outR = _outPipe[0];
    _inPipe[0] = _inPipe[1] = _outPipe[0] = _outPipe[1] = -1;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        // Give the clean shutdown ~500ms; then force the pipes closed.
        usleep(500 * 1000);
        if (inW >= 0) close(inW);     // reader for input side / mosh read side
        if (outW >= 0) close(outW);   // mosh write side (may already be closed by runMoshLoop)
        pthread_join(moshT, NULL);
        pthread_join(readerT, NULL);
        if (inR >= 0) close(inR);
        if (outR >= 0) close(outR);
    });
}

- (void)fireEnd:(NSString *)reason {
    void (^cb)(NSString *) = self.onEnd;
    if (cb) dispatch_async(dispatch_get_main_queue(), ^{ cb(reason); });
}

@end
```

- [ ] **Step 3: Add the files to the app target + bridging header (see Task 3 for `project.yml`)**

This task only *creates* the source. It does not build on Linux. Verification is deferred to Task 3's CI wiring (the first macOS build that compiles the `.mm`). Do NOT attempt `swift build` locally for these files.

- [ ] **Step 4: Commit**

```bash
git add App/Mosh/MoshSession.h App/Mosh/MoshSession.mm
git commit -m "feat(mosh): MoshSession Obj-C++ bridge — pipes, unbuffered fout, mosh+reader threads"
```

---

## Task 3: Wire the bridge into the app target + macOS CI test target + loopback plumbing tests

Makes the `.mm` compile in the app, exposes `MoshSession` to Swift, and adds a **macOS-only** test that drives the bridge against a fake `mosh_main` loopback so the plumbing is verified on CI without a network.

**Files:**
- Modify: `project.yml` (app target: ensure `App/Mosh` sources compile; set `SWIFT_OBJC_BRIDGING_HEADER`; link the `Mosh` framework header search path if needed. Add a macOS-hosted unit-test target `SemicolynBridgeTests` that compiles `MoshSessionTests.mm` + `fake_mosh_main.mm` and links the app's `MoshSession.mm`.)
- Create: `App/Mosh/Semicolyn-Bridging-Header.h`
- Create: `Tests/AppTests/fake_mosh_main.mm`
- Create: `Tests/AppTests/MoshSessionTests.mm`
- Modify: `.github/workflows/ci.yml` (macos job: add a step that builds + runs `SemicolynBridgeTests` after `xcodegen generate`)

**Interfaces:**
- Consumes: `MoshSession` (Task 2).
- Produces: a linkable **`mosh_main` override** (`fake_mosh_main.mm`) used ONLY in the test target — it echoes input-pipe bytes to the output pipe and honors the quit sequence, so tests exercise our pipe/thread/`setvbuf` logic deterministically.

- [ ] **Step 1: Bridging header**

```objc
// App/Mosh/Semicolyn-Bridging-Header.h
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
#import "MoshSession.h"
```

- [ ] **Step 2: `project.yml` — expose the bridge + add the macOS test target**

Add to the `Semicolyn` app target `settings.base` (alongside the existing keys):

```yaml
        SWIFT_OBJC_BRIDGING_HEADER: App/Mosh/Semicolyn-Bridging-Header.h
        CLANG_CXX_LANGUAGE_STANDARD: gnu++17
```

Add a new test target (top-level `targets:` map). Mirror the app target's platform/deps; host it on the app so it links `Mosh` + the app sources:

```yaml
  SemicolynBridgeTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - Tests/AppTests
      - path: App/Mosh/MoshSession.mm      # compile the real bridge into the test bundle
    dependencies:
      - target: Semicolyn
      - package: SemicolynPackage
        product: SemicolynSSHCoreFFI       # brings in the Mosh binaryTarget's headers
    settings:
      base:
        SWIFT_OBJC_BRIDGING_HEADER: App/Mosh/Semicolyn-Bridging-Header.h
        CLANG_CXX_LANGUAGE_STANDARD: gnu++17
        CODE_SIGNING_ALLOWED: NO
```

> If hosting a `bundle.unit-test` on the app proves fiddly under `xcodebuild -sdk iphonesimulator` in CI, the documented fallback is a small command-line style check compiled into a macOS-native test bundle that links only `MoshSession.mm` + `fake_mosh_main.mm` (no app host). Attempt the app-hosted target first; only fall back if the CI job fails to build the host app for tests.

- [ ] **Step 3: Loopback fake `mosh_main`**

```objc
// Tests/AppTests/fake_mosh_main.mm
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
//
// A test-only override of mosh_main linked into SemicolynBridgeTests INSTEAD of
// the real (network) implementation. It proves our plumbing: it echoes every byte
// read from f_in back to f_out (so onOutput reflects writeInput:), and returns
// cleanly (0) when it sees the quit sequence 0x1e 0x2e. No network, deterministic.
#include <stdio.h>
#include <sys/ioctl.h>

extern "C" int mosh_main(FILE *f_in, FILE *f_out, struct winsize *window_size,
                         void (*state_callback)(const void *, const void *, size_t),
                         void *state_callback_context,
                         const char *ip, const char *port, const char *key,
                         const char *predict_mode,
                         const char *encoded_state_buffer, size_t encoded_state_size,
                         const char *predict_overwrite) {
    (void)window_size; (void)state_callback; (void)state_callback_context;
    (void)ip; (void)port; (void)key; (void)predict_mode;
    (void)encoded_state_buffer; (void)encoded_state_size; (void)predict_overwrite;
    int prevWasCtrlHat = 0;
    int c;
    while ((c = fgetc(f_in)) != EOF) {
        if (prevWasCtrlHat && c == 0x2e) { return 0; }   // quit sequence → clean exit
        prevWasCtrlHat = (c == 0x1e);
        fputc(c, f_out);                                 // echo (fout is unbuffered in the bridge)
    }
    return 0;
}
```

- [ ] **Step 4: Write the failing plumbing tests**

```objc
// Tests/AppTests/MoshSessionTests.mm
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
#import <XCTest/XCTest.h>
#import "MoshSession.h"

@interface MoshSessionTests : XCTestCase
@end

@implementation MoshSessionTests

// A single written byte arrives on onOutput immediately (proves setvbuf(_IONBF):
// no 4KB stdio batching). Asserts the EXACT byte, not merely "something arrived".
- (void)testSingleByteEchoesImmediately {
    MoshSession *s = [[MoshSession alloc] initWithIP:@"127.0.0.1" port:@"60000" key:@"K"
                                                cols:80 rows:24 predictMode:@"none"];
    XCTestExpectation *got = [self expectationWithDescription:@"onOutput"];
    __block NSMutableData *acc = [NSMutableData data];
    s.onOutput = ^(NSData *d) { [acc appendData:d]; if (acc.length >= 1) [got fulfill]; };
    [s start];
    unsigned char byte = 'X';
    [s writeInput:[NSData dataWithBytes:&byte length:1]];
    [self waitForExpectations:@[got] timeout:2.0];
    XCTAssertEqual(((const unsigned char *)acc.bytes)[0], 'X');
    [s stop];
}

// Multi-byte input echoes verbatim and in order.
- (void)testMultiByteEchoesVerbatim {
    MoshSession *s = [[MoshSession alloc] initWithIP:@"127.0.0.1" port:@"60000" key:@"K"
                                                cols:80 rows:24 predictMode:@"none"];
    XCTestExpectation *got = [self expectationWithDescription:@"onOutput"];
    __block NSMutableData *acc = [NSMutableData data];
    s.onOutput = ^(NSData *d) { [acc appendData:d]; if (acc.length >= 5) [got fulfill]; };
    [s start];
    [s writeInput:[@"hello" dataUsingEncoding:NSUTF8StringEncoding]];
    [self waitForExpectations:@[got] timeout:2.0];
    XCTAssertEqualObjects([[NSString alloc] initWithData:acc encoding:NSUTF8StringEncoding], @"hello");
    [s stop];
}

// The quit sequence makes the loop exit cleanly → onEnd fires with a nil reason.
- (void)testQuitSequenceEndsCleanly {
    MoshSession *s = [[MoshSession alloc] initWithIP:@"127.0.0.1" port:@"60000" key:@"K"
                                                cols:80 rows:24 predictMode:@"none"];
    XCTestExpectation *ended = [self expectationWithDescription:@"onEnd"];
    __block BOOL cleanReason = NO;
    s.onEnd = ^(NSString *reason) { cleanReason = (reason == nil); [ended fulfill]; };
    [s start];
    unsigned char quit[2] = {0x1e, 0x2e};
    [s writeInput:[NSData dataWithBytes:quit length:2]];
    [self waitForExpectations:@[ended] timeout:2.0];
    XCTAssertTrue(cleanReason, @"clean quit should report a nil reason");
    [s stop];
}

// stop() is idempotent and safe to call without a prior clean end.
- (void)testStopIsIdempotent {
    MoshSession *s = [[MoshSession alloc] initWithIP:@"127.0.0.1" port:@"60000" key:@"K"
                                                cols:80 rows:24 predictMode:@"none"];
    [s start];
    [s stop];
    [s stop];   // must not crash / double-close
    XCTAssertTrue(YES);   // reaching here without a crash IS the assertion for idempotency
}

@end
```

> Note on `testStopIsIdempotent`: the real assertion is "the second `stop` does not crash or double-close fds"; the trailing `XCTAssertTrue(YES)` marks that the process survived both calls. This is the one acceptable "survived" assertion because the behavior under test *is* crash-freedom of a double-free path — the fd bookkeeping (`_inPipe[...] = -1` after the first stop) is what makes it pass, and removing that bookkeeping makes it crash.

- [ ] **Step 5: Push the branch → macOS CI builds + runs the tests**

```bash
git add App/Mosh/Semicolyn-Bridging-Header.h Tests/AppTests/fake_mosh_main.mm \
        Tests/AppTests/MoshSessionTests.mm project.yml .github/workflows/ci.yml
git commit -m "build(mosh): compile MoshSession in app + macOS CI plumbing tests (fake mosh_main loopback)"
git push github HEAD   # refresh/open the PR; CI runs on pull_request
```

Expected: the macos job compiles the `.mm`, builds `SemicolynBridgeTests`, and the 4 plumbing tests pass. Iterate on CI (module-map / bridging-header / test-host wrinkles are expected — bound them with the loopback stub, not guesswork). This is the M3 bridge-compile gate.

---

## Task 4: `ConnectionViewModel` Mosh branch (bootstrap → decide → attach)

Wires the working bridge into the connect flow, after SSH auth, before the tmux/raw branch. Adds pre-handoff SSH fallback with banners.

**Files:**
- Modify: `App/ConnectionViewModel.swift` (add a `moshSession` slot, a `captureMoshBootstrap` helper, and a Mosh branch in both `connect(savedHost:…)` and `connect(host:…)` after auth; extend `teardown()`).

**Interfaces:**
- Consumes: `moshBranchOutcome(stdout:enabled:)` (Task 1); `MoshSession` (Task 2); `moshServerCommand(_:)` (exists), `conn.openExec(command:term:cols:rows:output:)`, `TerminalShellOutput`, `output.onBytes`, `terminalView.feed(byteArray:)`.
- Produces: session wiring + a new `@Published var moshFallback: String?` banner slot; a resolved-config helper `resolveMoshConfig(host:defaults:)`.

> **Confirmed against current code (do NOT invent APIs):**
> - `resolveMoshEnabled(host:defaults:) -> Bool` **already exists** (`Sources/SemicolynKit/Model/Resolution.swift:95`): `resolveOptional(host.mosh, defaults.mosh)?.enabled ?? false`. **Reuse it** for the enabled gate.
> - For the full effective config, **use `resolveOptional(host.mosh, defaults.mosh) -> MoshConfig?`** (also in `Resolution.swift`). **Do NOT use `host.mosh.value`** — `Resolution.swift` documents that `.value` collapses `.inherit` and `.explicit(nil)` and MUST NOT be used for resolution (a cleared host field would wrongly inherit the Defaults value). `host`/`defaults` both carry `mosh: Inherited<MoshConfig>` (Host.swift:74, :132). So Task 4 does NOT add a resolver — it calls the existing `resolveOptional`/`resolveMoshEnabled`.
> - `DegradeReason` (in `Tmux/TmuxLaunch.swift`) is a **fixed enum** (`.optedOut`/`.tmuxNotFound`/`.tooOld`) with **no free-text case** and is tmux-specific. Do NOT overload it for Mosh. The pre-handoff Mosh banner uses a **new `moshFallback: String?`** published slot rendered by `SessionView` (mirror the existing `degraded`/`crashBanner` banner rendering).

- [ ] **Step 1: Add the `moshSession` slot + teardown**

In `ConnectionViewModel`, add near the `tmux`/`session` properties:

```swift
    /// Non-nil while a Mosh session is driving the terminal (mutually exclusive
    /// with `tmux`). Retained so teardown can shut the UDP loop down.
    private var moshSession: MoshSession?
    /// Set when we bootstrapped Mosh but fell back to SSH before handoff. Consumed
    /// by `SessionView` to show a one-line banner (parallels `degraded`/`crashBanner`).
    @Published var moshFallback: String?
```

No new resolver is needed — reuse the existing `Resolution.swift` helpers. The effective
config is `resolveOptional(host.mosh, defaults.mosh)` (a `MoshConfig?`, honoring `Inherited`
three-state); the enabled gate is `resolveMoshEnabled(host:defaults:)`. **Never** use
`host.mosh.value` for resolution (it collapses `.inherit`/`.explicit(nil)`).

In `teardown()`, add (before `session = nil`):

```swift
        moshSession?.stop()
        moshSession = nil
        moshFallback = nil
```

- [ ] **Step 2: Add the bootstrap-capture helper**

Mirror `probeTmuxVersion`'s capture-via-sink-with-2s-race pattern:

```swift
    /// Run the `mosh-server` bootstrap over a one-shot exec and return its stdout
    /// (empty string if nothing came back or the channel failed). Resolves when the
    /// exec channel closes or a 2s guard fires — same race as `probeTmuxVersion`.
    private func captureMoshBootstrap(conn: Connection, command: String) async -> String {
        let sink = TerminalShellOutput()
        var captured: [UInt8] = []
        sink.onBytes = { captured.append(contentsOf: $0) }
        let done = AsyncStream<Void> { cont in
            sink.onExit = { _ in cont.yield(); cont.finish() }
        }
        let sess = try? await conn.openExec(command: command, term: "xterm-256color",
                                            cols: 80, rows: 24, output: sink)
        guard sess != nil else { return "" }
        defer { if let sess { Task { try? await sess.close() } } }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for await _ in done { break } }
            group.addTask { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            await group.next(); group.cancelAll()
        }
        return String(decoding: captured, as: UTF8.self)
    }
```

- [ ] **Step 3: Add the Mosh attach path**

```swift
    /// Attach a Mosh session on the authenticated connection: bootstrap mosh-server,
    /// decide, and either create a MoshSession or fall back to the SSH/tmux path with
    /// a banner. Returns true if a Mosh session was attached; false if it fell back
    /// (the caller then runs the existing tmux/raw branch).
    private func attachMoshIfPossible(conn: Connection, host: Host, defaults: Defaults) async -> Bool {
        guard resolveMoshEnabled(host: host, defaults: defaults) else { return false }
        // Effective config for the argv (port range, server path, prediction mode).
        let cfg = resolveOptional(host.mosh, defaults.mosh) ?? MoshConfig(enabled: true)
        let command = moshServerCommand(cfg).joined(separator: " ")
        let stdout = await captureMoshBootstrap(conn: conn, command: command)
        switch moshBranchOutcome(stdout: stdout, enabled: true) {
        case let .mosh(port, key):
            let predict = cfg.predictionMode?.rawValue ?? "adaptive"
            let sess = MoshSession(ip: host.hostName, port: String(port), key: key,
                                   cols: 80, rows: 24, predictMode: predict)
            sess.onOutput = { [weak self] data in
                self?.output.onBytes?([UInt8](data))
            }
            sess.onEnd = { [weak self] reason in
                // Post-handoff loop exit → reuse the mid-session crash banner.
                guard let self else { return }
                if let reason { self.degraded = nil; self.state = .failed(reason) }
                else { self.crashBanner = .tmuxEnded }
            }
            sess.start()
            self.moshSession = sess
            connection = conn
            state = .shell
            return true
        case let .fallback(reason):
            moshFallback = reason   // pre-handoff banner; the caller then runs the SSH/tmux path
            return false
        }
    }
```

> `resolveMoshConfig` and `moshFallback` are both defined in Step 1 of this task (not pre-existing) — see the "Confirmed against current code" note under Interfaces. The `MoshSession` `cols:80 rows:24` seed matches the SSH/tmux initial size; the first debounced `setMoshClientSize` (Step 5) corrects it to the real terminal size.

- [ ] **Step 4: Call the branch after auth in both connect methods**

In `connect(savedHost:password:)` and `connect(host:port:user:password:)`, immediately after the `switch outcome { case .success: break … }` block and before the tmux probe, insert:

```swift
                // Mosh takes precedence over tmux when enabled + bootstrappable.
                if await attachMoshIfPossible(conn: conn, host: /*savedHost or hostRecord*/, defaults: defaults2) {
                    return
                }
```

(Use `savedHost` in the saved-host method and `hostRecord` in the ad-hoc method — matching the local variable already in scope there.)

- [ ] **Step 5: Wire keystrokes + resize to the session**

In `sendTerminalInput(_:)`, route to Mosh when a session is active (Mosh is exclusive with tmux):

```swift
    func sendTerminalInput(_ bytes: [UInt8]) {
        observePredictorInput(bytes)
        if let moshSession {
            moshSession.writeInput(Data(bytes))
        } else if let tmux {
            tmux.sendInput(bytes)
        } else {
            rawWriter?.enqueue(bytes)
        }
    }
```

> Note: Mosh owns prediction internally. Leave `observePredictorInput` in place for token tracking, but `startPredictor` already gates on incognito — a follow-up may skip the SemicolynKit predictor entirely on the Mosh path; not required for M3.

Resize: the existing `setTmuxClientSize(cols:rows:)` is the size entry point; add a sibling that targets Mosh, called from the same debounced site in `TmuxPaneContainer`/`TerminalScreen` size logic:

```swift
    func setMoshClientSize(cols: Int, rows: Int) { moshSession?.resizeCols(Int32(cols), rows: Int32(rows)) }
```

(Real per-frame delivery of that resize to the running loop is Task 5 — this only records it.)

- [ ] **Step 6: Push → macOS CI compiles the wired VM**

```bash
git add App/ConnectionViewModel.swift Sources/SemicolynKit/Model/HostExtensions.swift
git commit -m "feat(mosh): ConnectionViewModel Mosh branch — bootstrap, decide, attach, SSH fallback"
git push github HEAD
```

Expected: macos job compiles the app with the Mosh branch. **M3 code-complete gate.** Then do the **manual Simulator pass** (Task 6) before the TestFlight build.

---

## Task 5: Resize delivery — `pthread_kill(SIGWINCH)` (R1)

Make a recorded resize actually reach the running `mosh_main` loop.

**Files:**
- Modify: `App/Mosh/MoshSession.mm` (install a SIGWINCH handler context + deliver the signal to the mosh thread on resize)

**Interfaces:**
- Consumes: the `_moshThread` + shared `_winsize` from Task 2.
- Produces: `-resizeCols:rows:` now wakes the loop so it re-reads `_winsize`.

- [ ] **Step 1: Deliver SIGWINCH to the mosh thread on resize**

Replace the `resizeCols:rows:` stub body:

```objc
- (void)resizeCols:(int)cols rows:(int)rows {
    _winsize.ws_col = (unsigned short)cols;
    _winsize.ws_row = (unsigned short)rows;
    if (_started && !_stopped) {
        // The vendored loop handles SIGWINCH by re-reading the shared winsize and
        // pushing a Parser::Resize. Mosh's Select installs the signal machinery on
        // the thread running the loop, so target that thread specifically.
        pthread_kill(_moshThread, SIGWINCH);
    }
}
```

- [ ] **Step 2: Ensure SIGWINCH is not ignored/blocked for the process**

At the top of `runMoshLoop` (before `mosh_main`), make sure the signal isn't SIG_IGN inherited from the app and isn't blocked on this thread:

```objc
    // Mosh's Select installs its own SIGWINCH handler; ensure the disposition/mask
    // let it be delivered to this thread.
    sigset_t unblock; sigemptyset(&unblock); sigaddset(&unblock, SIGWINCH);
    pthread_sigmask(SIG_UNBLOCK, &unblock, NULL);
```

(Add `#include <signal.h>` to the includes.)

- [ ] **Step 3: Push → macOS CI + verify on the Simulator manual pass**

```bash
git add App/Mosh/MoshSession.mm
git commit -m "feat(mosh): deliver terminal resize via pthread_kill(SIGWINCH) + shared winsize (R1)"
git push github HEAD
```

Expected: compiles. **Behavioral verification is the device/Simulator pass:** rotate / resize and confirm the remote reflows.

> **If R1 fails behavioral verification** (SIGWINCH not landing on the mosh thread / loop not reflowing): switch to **R2** — a first-party patch to `extern/mosh/src/frontend/iosclient.cc` adding an extra control fd to the loop's `select()` set (a byte on it = "re-read winsize"), documented in `docs/vendor/mosh.md` as a carried patch. Do NOT relicense the file; keep upstream headers; note the patch + rationale in the vendor doc. This is the escape hatch, not the default.

---

## Task 6: M3 manual verification pass + TestFlight

No new code — the M3 ship gate.

- [ ] **Step 1: macOS CI is green** on the branch (bridge compiles, plumbing tests pass, VM compiles).
- [ ] **Step 2: Simulator connect to a real Mosh host** — a host with `mosh` installed (e.g. a local VM or `brew install mosh` box). Confirm: connects over Mosh, prompt renders, keystrokes echo (predictive), a command's output renders, resize reflows.
- [ ] **Step 3: SSH-fallback paths** — connect to a host WITHOUT mosh-server: confirm the "mosh-server not found — using SSH" banner + a working SSH/tmux shell. Disable mosh for the host: confirm it goes straight to SSH.
- [ ] **Step 4: Ship a TestFlight build** via the existing `release-testflight` lane (see `testflight-lane-live` memory: API key = Admin, France excluded). This satisfies the M3 shipping goal.

---

## Task 7 (M4): Roaming, background/foreground, mid-session resilience

**Files:**
- Modify: `App/Mosh/MoshSession.mm` (background/foreground UDP pause-resume hooks), `App/ConnectionViewModel.swift` (mid-session banner reuse), possibly `App/SessionView.swift` (scenePhase hook).

**Interfaces:**
- Consumes: `MoshSession.onEnd`, existing `scenePhase` handling (grep `scenePhase` in the app — `flushPredictor` already hooks it), existing degraded/crash banner states.

- [ ] **Step 1: Mid-session drop → degraded banner (no teardown)**

Mosh survives drops by design; ensure a *transient* network change does NOT tear down. The bridge only fires `onEnd` when the loop truly exits. Confirm in the VM that `onEnd(nil)`/`onEnd(reason)` map to crash/degraded banners (already wired in Task 4 Step 3) and that no other code path calls `moshSession?.stop()` on a background/foreground transition.

- [ ] **Step 2: Background/foreground**

iOS suspends the app in the background; UDP pauses naturally. On foreground, Mosh re-sends from the new source addr (its roaming). Verify no explicit action is needed beyond not tearing down; if the socket is killed by the OS, `onEnd` fires → crash banner (acceptable v1). Document the observed behavior from the device pass.

- [ ] **Step 3: Device manual pass**

Roam Wi-Fi↔cellular mid-session (predictive echo stays responsive, session reconverges); rotate for resize; background 30s then foreground. Record results in the plan's progress ledger.

- [ ] **Step 4: Commit any hooks added**

```bash
git add App/Mosh/MoshSession.mm App/ConnectionViewModel.swift App/SessionView.swift
git commit -m "feat(mosh): M4 resilience — mid-session drop/degraded banner, background/foreground behavior"
git push github HEAD
```

---

## Task 8 (M4, stretch): macOS real-server interop test

**Files:**
- Modify: `.github/workflows/ci.yml` (macos job: `brew install mosh`), Create: `Tests/AppTests/MoshInteropTests.mm`

- [ ] **Step 1:** `brew install mosh` in the macos job (idempotent).
- [ ] **Step 2:** A test that starts a real `mosh-server new` locally (parse its `MOSH CONNECT`), drives a real `MoshSession` (NOT the fake) against `127.0.0.1` + that port/key, and asserts a framebuffer byte (e.g. an ESC `0x1b`) arrives on `onOutput` within a timeout.
- [ ] **Step 3:** If flaky on the runner, mark it `XCTSkip` behind an env flag and land it as documentation of the interop path (per the spec's "may land as follow-up if flaky").

```bash
git add .github/workflows/ci.yml Tests/AppTests/MoshInteropTests.mm
git commit -m "test(mosh): macOS real mosh-server UDP/SSP interop (stretch)"
git push github HEAD
```

---

## Self-review notes

- **Spec coverage:** loop mechanism (pipes + `setvbuf`) → Task 2; `MoshSession` surface → Tasks 2/3/5; `moshBranchOutcome` → Task 1; VM branch + bootstrap capture → Task 4; pre-handoff SSH fallback + banners → Task 4; resize R1/R2 → Task 5; teardown → Task 2 (`stop`) + Task 4 (VM `teardown`); error-handling table → Task 4 (`onEnd`/fallback) + Task 7; testing (Linux helper, macOS loopback, stretch interop, manual pass) → Tasks 1/3/6/7/8; phasing M3 ship gate → Task 6; no-double-prediction → Task 4 Step 5 note.
- **Placeholder scan:** verified against current code — `resolveMoshConfig` and the `moshFallback` banner slot are **new** (defined in Task 4 Step 1), because no mosh resolver exists and `DegradeReason` is a fixed tmux-only enum with no free-text case (do NOT overload it). The remaining "confirm at execution" items (`Inherited` accessor / whether `Defaults` has a `mosh` field; the `#import <Mosh/moshiosbridge.h>` header form) are real integration lookups with the exact grep + fallback action stated, not substitutable placeholders.
- **Type consistency:** `MoshBranchOutcome.mosh(port:key:)` / `.fallback(reason:)` defined in Task 1 and consumed unchanged in Task 4; `MoshSession` init + `onOutput`/`onEnd`/`writeInput:`/`resizeCols:rows:`/`stop` defined in Task 2 and consumed identically in Tasks 3–5; the loopback `mosh_main` signature matches the Global Constraints signature verbatim; quit sequence `0x1e 0x2e` consistent between bridge (`kMoshQuitSequence`), fake, and tests.
- **Known soft spots (macOS-CI-only, expect iteration like M1's 14 rounds):** (a) the app-hosted `bundle.unit-test` target building under `-sdk iphonesimulator` — Task 3 gives the no-host fallback; (b) `pthread_kill(SIGWINCH)` landing on the mosh thread — Task 5 gives the R2 vendor-patch fallback. Both are behavioral, not derivable on Linux.
