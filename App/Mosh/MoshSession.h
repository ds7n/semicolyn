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

/// Update the session's terminal size and wake the loop so it re-reads the size.
- (void)resizeCols:(int)cols rows:(int)rows;

/// Request a clean shutdown (quit sequence), then join the thread with a bounded
/// timeout off the main thread. Idempotent.
- (void)stop;

/// Output bytes from Mosh (main queue). Wire to `terminalView.feed(byteArray:)`.
@property (nonatomic, copy, nullable) void (^onOutput)(NSData *bytes);

/// Fires exactly once (main queue) when the FIRST output byte arrives from Mosh —
/// i.e. the UDP handshake completed and frames are flowing. The VM uses this to
/// divide "pre-handoff" failures (fall back to SSH on the retained connection)
/// from "mid-session" loop exits (crash banner). Fires before that first
/// `onOutput`. Never fires if the loop dies before any byte (→ pre-frame `onEnd`).
@property (nonatomic, copy, nullable) void (^onFirstFrame)(void);

/// Fires once when the mosh loop exits (main queue). `reason` nil = clean exit.
@property (nonatomic, copy, nullable) void (^onEnd)(NSString *_Nullable reason);

@end

NS_ASSUME_NONNULL_END
