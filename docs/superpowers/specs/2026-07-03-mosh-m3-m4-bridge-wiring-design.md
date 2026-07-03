<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Mosh Transport M3/M4 — Bridge + Wiring + Resilience (design)

> Follow-up to the M1/M2 mosh-transport work. Prereqs **shipped**: `Mosh.xcframework`
> builds/links/exports `mosh_main` (M1, merged `18ba374`, macOS CI green); the pure
> Kit units `parseMoshConnect` / `moshServerCommand` / `moshLaunchDecision` and the
> Rust `mosh-server` bootstrap interop test are green (M2, merged `7e8cb95`).
>
> Parent spec: [`2026-07-02-mosh-transport-design.md`](2026-07-02-mosh-transport-design.md)
> (§ "Internal phasing": M3 = bridge + wiring, M4 = resilience + polish).

## Context & goal

Turn the built-but-uncalled `Mosh.xcframework` into a working transport: after SSH
auth, bootstrap `mosh-server` over the existing russh channel, parse its `MOSH CONNECT
<port> <key>` handoff (Kit, done), and hand off to a **`MoshSession` Obj-C++ bridge**
that drives the vendored `mosh_main` event loop and speaks **bytes + size events** to
SwiftTerm — the exact contract the SSH shell and tmux control mode already satisfy, so
the terminal view is agnostic to which transport feeds it.

**Goal:** a Mosh-enabled host connects over Mosh (predictive local echo, UDP session,
survives network drops); every pre-handoff failure falls back to a normal SSH session
so the user always gets a shell. **A TestFlight build ships at the end of M3.**

## How `mosh_main` actually works (from the vendored source)

Read directly from `extern/mosh/src/frontend/{moshiosbridge.cc,iosclient.cc,iosclient.h}`
(our pinned fork). This is authoritative — it is the code we link.

```c
// moshiosbridge.h — the exported entry point (M1 gate confirmed this symbol)
int mosh_main(FILE *f_in, FILE *f_out, struct winsize *window_size,
              void (*state_callback)(const void *, const void *, size_t),
              void *state_callback_context,
              const char *ip, const char *port, const char *key,
              const char *predict_mode,
              const char *encoded_state_buffer, size_t encoded_state_size,
              const char *predict_overwrite);
```

- **`mosh_main` blocks** for the whole session. `moshiosbridge.cc` builds an `iOSClient`
  and calls `client.main(encoded_state)`, which runs a `select()` loop until the session
  ends, then returns `!success` (0 = clean).
- **Input:** `iOSClient` uses `in_fd = fileno(f_in)` and `read(in_fd, …)` — a raw fd read,
  **no stdio buffering on the input path**. The loop `select()`s on `network->fds()` (UDP)
  **plus** `in_fd`.
- **Output:** `out_fd = f_out` (a `FILE*`); frame diffs are written with `fwrite(…, out_fd)`.
  Because a pipe is not a TTY, stdio **block-buffers** this by default → **must
  `setvbuf(f_out, NULL, _IONBF, 0)`** so frames flush immediately.
- **Resize:** the loop reacts to **`SIGWINCH`** (`sel.signal(SIGWINCH)` → `process_resize()`),
  which re-reads the shared `struct winsize *window_size`. The winsize ioctl is commented
  out in the fork — resize is driven **only** by the signal + the shared struct.
- **Suspend/serialize:** `Ctrl-^ Ctrl-Z` (or `SIGINFO`) serializes session state, fires
  `state_callback`, and `pthread_exit()`s. Not used by us in M3/M4 (no session hand-off
  across process death yet) — `encoded_state` is passed empty; `state_callback` is a no-op
  sink we still supply (non-null required).
- **Quit:** `Ctrl-^ .` (`0x1e 0x2e`) starts a clean network shutdown.

**Consequence:** `mosh_main` has exactly one integration shape — **give it a file-descriptor
pair it can `read()`/`fwrite()` and run it on its own thread.** This is what upstream
`mosh-client` does with a real controlling TTY; our fork's `#define STDIN_FILENO in_fd`
swap redirects that same loop onto caller-supplied fds.

### Loop mechanism — decision: `pipe()` pair + `setvbuf(_IONBF)` + background thread

Researched against upstream `mosh-client` (real TTY + `select`), our vendored Blink fork
(caller fds + `select`, above), and the general shape libmosh forces on any client. The
only real choice is what backs the fd pair:

| option | pros | cons |
|---|---|---|
| **A. `pipe()` pair + `fdopen` + bg thread (CHOSEN)** | minimal; exactly what the fork is written for; byte-oriented → matches SwiftTerm; no pty/entitlement quirks; input path is raw `write()`/`read()` (zero buffering) | two threads (mosh loop + output reader); `FILE*` output needs `setvbuf(_IONBF)` or frames lag; must drain the reader promptly |
| B. `openpty()` master/slave pair | mosh's `tcgetattr`/`ioctl`/native-SIGWINCH paths would "just work" | overkill on iOS (constrained pty alloc, device node); the fork **commented out all termios/ioctl** → zero benefit gained; more moving parts |

**Latency:** with `setvbuf(f_out, NULL, _IONBF, 0)` the output `FILE*` flushes each frame
immediately; input is a raw `write()` with no userspace buffer. Input *feel* is dominated
by **Mosh's own predictive echo** (local, sub-millisecond), not the pipe hop (kernel
`memcpy`s). Unbuffered `fwrite` means more, smaller `write()` syscalls per frame — negligible
at terminal data rates. Net: neither direction carries meaningful buffering latency.

## Architecture & tiers

All M3/M4 code is **App-tier, macOS-CI-verified** — it links `Mosh.xcframework` and
compiles only on macOS (invisible to Linux `swift test`). No new Linux-tested Kit units
(the M2 pure units already exist); the one piece of new decision logic is extracted to a
**pure, Linux-tested helper** (`moshBranchOutcome`) so it is not trapped behind the Apple gate.

```
ConnectionViewModel (@MainActor)  ── App, macOS-CI
  └─ after SSH auth, if mosh enabled for host:
       openExec("mosh-server new -s -c 256 -l LANG=… [-p lo:hi]")   [reuse russh open_exec]
         └─ capture stdout via a sink + timeout  (reuse probeTmuxVersion pattern)
       moshBranchOutcome(stdout, enabled)    ── App→Kit pure helper, LINUX-TESTED
         = wraps parseMoshConnect + moshLaunchDecision     [Kit units, exist]
         ├─ .mosh(port, key)  → MoshSession(ip, port, key, cols, rows, predictMode)
         │                        ├─ onOutput(bytes) → terminalView.feed   (bytes+size seam)
         │                        └─ sendTerminalInput(bytes) → session.writeInput
         └─ .fallback(reason) → banner(reason) + existing openRawShell / attachTmux path

MoshSession (Obj-C++, App/Mosh/MoshSession.{h,mm})  ── App, macOS-CI
  ├─ pipe() pair (app→mosh), pipe() pair (mosh→app), heap struct winsize
  ├─ thread A: mosh_main(fin, fout, &winsize, stateCb, self, ip, port, key, predict, "", 0, predictOverwrite)
  ├─ thread B: read(outRead) loop → onOutput (marshalled to main actor)
  └─ writeInput = raw write(inWrite); resize = update winsize + wake loop; stop = quit seq + join
```

**Key seam:** `MoshSession` exposes only `writeInput:` / `resizeCols:rows:` / callbacks
of raw bytes — the same shape `TerminalShellOutput` already gives the SSH/tmux paths — so
`TerminalScreen`/SwiftTerm does not know whether SSH, tmux, or Mosh is feeding it. **Mosh's
prediction is internal**: its output bytes already carry predicted overlays, so the
SemicolynKit predictor engine is **not** attached on the Mosh path (no double-prediction,
no harvest of Mosh's overlay bytes).

## Components & boundaries

### ① `MoshSession` — Obj-C++ bridge (`App/Mosh/MoshSession.{h,mm}`)

The one new non-trivial unit. Swift-facing surface, deliberately tiny (bytes + size only):

```objc
@interface MoshSession : NSObject
- (instancetype)initWithIP:(NSString *)ip port:(NSString *)port key:(NSString *)key
                      cols:(int)cols rows:(int)rows predictMode:(NSString *)predictMode;
- (void)start;                                 // spawn mosh thread + reader thread
- (void)writeInput:(NSData *)bytes;            // keystrokes → input pipe (raw write())
- (void)resizeCols:(int)cols rows:(int)rows;   // update shared winsize + wake the loop
- (void)stop;                                  // quit seq → join (bounded), close pipes
@property (nonatomic, copy, nullable) void (^onOutput)(NSData *);            // → SwiftTerm.feed
@property (nonatomic, copy, nullable) void (^onEnd)(NSString * _Nullable);   // loop exited
@end
```

Internals & lifecycle:
- **`init`:** `pipe(inPipe)`, `pipe(outPipe)`, allocate a heap `struct winsize` from cols/rows;
  stash ip/port/key/predict as C strings.
- **`start`:** `FILE *fin = fdopen(inPipe[0], "r")`; `FILE *fout = fdopen(outPipe[1], "w")`;
  **`setvbuf(fout, NULL, _IONBF, 0)`**; spawn **thread A** running `mosh_main(...)` (empty
  `encoded_state`, a no-op `state_callback`); spawn **thread B** looping
  `read(outPipe[0], buf, N)` → `onOutput([NSData dataWithBytes])`, exiting on EOF/`0`.
  On thread A return, fire `onEnd(reason)` (reason derived from the return code / any
  captured stderr note).
- **`writeInput:`** raw `write(inPipe[1], data.bytes, data.length)` — no `FILE*`, no buffer.
- **`resizeCols:rows:`** write new dims into the shared `winsize`, then deliver the resize
  (see § Resize).
- **`stop`:** write the quit sequence `0x1e 0x2e` to `inPipe[1]` for a clean network
  shutdown; then a **bounded** join (≈500 ms). If mosh will not exit (dead UDP path),
  close all pipe fds (write ends first → reader EOF → reader exits → read ends) and detach
  the mosh thread. **Idempotent**; never blocks the main actor (join happens off-main).
- Callbacks marshalled to the main actor before touching SwiftTerm / VM state.

### ② `moshBranchOutcome` — pure decision helper (Kit or App-shared, **Linux-tested**)

Composes the two existing Kit units so the VM branch's decision is testable off the Apple gate:

```swift
enum MoshBranchOutcome: Equatable, Sendable {
    case mosh(port: Int, key: String)
    case fallback(reason: String)   // user-facing banner text
}
func moshBranchOutcome(stdout: String, enabled: Bool) -> MoshBranchOutcome
// = moshLaunchDecision(enabled:, bootstrap: parseMoshConnect(stdout)) mapped to banner text
```

Placed in `Sources/SemicolynKit/Mosh/` so it is Linux-XCTest-covered. The VM calls it with
the captured bootstrap stdout; a bootstrap *timeout* (no output) is passed as `""` →
`.noConnectLine` → the same "mosh-server not found" fallback.

### ③ `ConnectionViewModel` Mosh branch — App, macOS-CI

A third path alongside `attachTmux` / `openRawShell`:
1. Resolve `MoshConfig` for the host (existing `HostExtensions` resolution + Defaults
   inheritance, like `resolveTmuxAttemptControlMode`).
2. If `mosh.enabled`: `openExec(moshServerCommand(cfg).joined(" "))`, capture stdout via a
   sink + timeout (reuse the `probeTmuxVersion` 2 s race).
3. `moshBranchOutcome(stdout, enabled: true)`:
   - `.mosh(port, key)` → create `MoshSession`, wire `onOutput → terminalView.feed`, wire
     `sendTerminalInput → session.writeInput`, retain the session (new `moshSession` slot),
     `state = .shell`. Resize uses the existing debounced client-size path
     (`TmuxPaneContainer`) but calls `session.resizeCols:rows:`.
   - `.fallback(reason)` → set the pre-handoff banner + run the existing tmux/raw path
     **on the retained connection** (no reconnect).
4. The bootstrap SSH connection is **retained until the Mosh session is confirmed up**, so
   a fast handshake failure can still fall back to SSH on the same connection.

## Resize

The fork learns of resize via **`SIGWINCH`** + the shared `winsize*`. Delivery decision:

- **R1 — `pthread_kill(moshThread, SIGWINCH)` (try first, zero vendor changes):**
  `resizeCols:rows:` updates the shared `winsize`, then `pthread_kill(moshThread, SIGWINCH)`.
  The loop's `sel.signal(SIGWINCH)` branch fires → `process_resize()` reads the struct →
  pushes `Parser::Resize` to the server. **Verify on macOS CI** that a `pthread_kill`-delivered
  SIGWINCH lands on the mosh thread and wakes its `Select` self-pipe (mosh's `Select`
  installs the signal machinery on the thread that runs the loop).
- **R2 — vendored control-pipe patch (documented fallback if R1 fails on CI):** add a small
  first-party patch to the vendored `iosclient` so the loop `select()`s an extra control fd;
  a byte on it means "re-read winsize", bypassing signals. Allowed (we carry a vendor-patch
  surface via `docs/vendor/mosh.md`) but heavier — only if R1 is disproven.

Resize is **debounced** by the existing `TmuxPaneContainer` size logic; the Mosh path reuses
that debounce, substituting `session.resizeCols:rows:` for `tmux.setClientSize`.

## Error handling

Dividing line: **before the first frame** arrives, any failure → silent SSH fallback +
banner. **After the first frame**, trust Mosh to survive drops (degraded banner only); a true
loop exit reuses the crash banner. This reuses the tmux crash-vs-degrade UI states already
in the VM — **no new banner states**.

| failure | detection | behavior |
|---|---|---|
| `mosh-server` not installed | stdout has no `MOSH CONNECT` → `.noConnectLine` | banner *"mosh-server not found on host — using SSH"* → existing tmux/raw path |
| Malformed handoff line | `.malformed` | banner *"couldn't parse mosh-server output — using SSH"* → SSH path |
| Bootstrap exec timeout | sink+timeout fires with no line | treated as `.noConnectLine` → SSH fallback |
| UDP blocked / handshake never completes | `onEnd(reason)` fires while still "connecting" (no frame yet) | banner *"Mosh UDP unreachable (check firewall) — using SSH"* → fall back to SSH on the retained connection |
| Crypto/key mismatch | `mosh_main` returns nonzero fast → `onEnd` before first frame | *"Mosh connection failed — using SSH"* → SSH fallback |
| Network drop **mid-session** | Mosh's job (the whole point) | **no teardown** — reuse the existing degraded/"reconnecting" banner; Mosh reconverges |
| Session/server death | `onEnd(reason)` after a live session | reuse the existing **mid-session crash banner** (same state tmux uses) |

## Testing

`MoshSession` is Obj-C++ over `Mosh.xcframework` → **invisible to `swift test`, compiles
only on macOS CI**. Coverage is split accordingly; every assertion is on observable
output/state per the testing-standards spec (no tautologies).

| layer | where | what | tier |
|---|---|---|---|
| Kit pure units (`parseMoshConnect`, `moshServerCommand`, `moshLaunchDecision`) | Linux XCTest | **already green (M2)** — unchanged | — |
| `moshBranchOutcome` | Linux XCTest | EP/BVA: valid handoff → `.mosh(exact port,key)`; `.noConnectLine`/`.malformed`/disabled/empty-stdout → the **specific** `.fallback(reason)` string | Core |
| `MoshSession` bridge plumbing | **macOS CI only** (`MoshSessionTests`) | drive the bridge against a **fake `mosh_main` loopback stub** compiled into the test target: `writeInput:` bytes appear on the input pipe verbatim; output-pipe bytes reach `onOutput` verbatim; `setvbuf` unbuffered (write 1 byte → arrives immediately, not batched); `stop` joins and fires `onEnd`; resize updates the shared winsize | Core |
| Real UDP/SSP interop | macOS CI **stretch** | `brew install mosh` → bootstrap real `mosh-server` → drive `MoshSession` → assert a framebuffer byte arrives; lands as follow-up if flaky | Core (stretch) |
| Rust bootstrap interop | Linux Docker fixture | **already green (M2, Task 4)** — SSH→`mosh-server`→`MOSH CONNECT` against a real server | — |
| roaming, predictive-echo feel, resize, background/foreground | **device + Simulator manual pass** | not automatable — explicit checklist in the plan | Core |

**The loopback stub is the key move:** it verifies every byte of *our* plumbing (the part
we can get wrong) deterministically on CI, while real-network behavior is covered by the
manual pass + the stretch interop test. Anti-tautology: the stub test asserts **exact echoed
bytes** and the **specific `onEnd` reason**, never merely "onOutput fired" or "result is ok".

## Phasing (one plan; M3 independently shippable + TestFlight-able)

**M3 — Bridge + wiring (the shippable core):**
1. `MoshSession.{h,mm}` + the loopback fake-`mosh_main` stub + `MoshSessionTests` (macOS CI).
2. Wire Obj-C++ into the app target: bridging header / module map, the iOS-only compile
   surface in `project.yml` (mirror how `Mosh` links today; `MoshSession` is app-target code
   guarded so Linux is untouched).
3. `moshBranchOutcome` pure helper + Linux tests.
4. `ConnectionViewModel` Mosh branch: bootstrap exec → capture stdout → `moshBranchOutcome`
   → create `MoshSession` → attach terminal + input; retain the connection through handoff.
5. Pre-handoff error banners + SSH fallback.
6. **Gate:** macOS CI green **and** a manual Simulator connect to a real mosh host works.
   → **ship a TestFlight build here.**

**M4 — Resilience + polish (layered on the working bridge):**
7. Resize: R1 (`pthread_kill` SIGWINCH) verified on CI; R2 vendor patch only if R1 disproven.
8. Roaming / network-path change + background/foreground UDP pause-resume.
9. Mid-session drop → degraded banner; `onEnd` → crash banner (reuse existing states).
10. Device manual pass: roam Wi-Fi↔cellular, predictive-echo feel, rotation resize.
11. Stretch: macOS real-server interop test.

If M4's device-only work hits snags, **M3 has already shipped a working Mosh to TestFlight**
(the shipping goal), so hardening is not a ship blocker.

## Out of scope / risks

- **Session restoration across process death** (`encoded_state`/`state_callback` round-trip) —
  the fork supports it (Ctrl-^ Ctrl-Z serialize), but M3/M4 pass empty state + a no-op callback.
  Revisit if backgrounded-session resume is wanted.
- **Primary risk (M3):** the Obj-C++/module-map wiring and `mosh_main` thread lifecycle — all
  macOS-CI-only, so expect a few CI iterations (M1 took 14). The loopback stub bounds the
  guесswork by making the plumbing testable.
- **Secondary risk (M4):** `pthread_kill`-delivered SIGWINCH landing on the mosh thread
  (R1) and iOS UDP-in-background behavior — both device/CI-verified, R2 patch is the escape hatch.
- **Not double-predicting:** the SemicolynKit predictor stays off the Mosh path; Mosh owns
  local echo. Confirmed by the internal-prediction design of the fork.
