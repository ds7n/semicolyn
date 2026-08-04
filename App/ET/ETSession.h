// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Drives one `eternaltermlib` ET session over the `et_*` C ABI. Speaks only
/// bytes + size + lifecycle events (the same contract SwiftTerm consumes from the
/// SSH/tmux/Mosh paths), so the terminal view stays transport-agnostic.
///
/// Threading: a private serial queue owns every `et_send`/`et_set_window_size`/
/// `et_close` so they never race (the C ABI's serialization requirement).
/// Library callbacks arrive on ET's transport thread; this class copies the byte
/// buffer in-callback and hops to the main queue before firing the closures
/// below, so the Swift side may touch UIKit/SwiftTerm directly.
@interface ETSession : NSObject

- (instancetype)initWithHost:(NSString *)host
                        port:(uint16_t)port
                          id:(NSString *)clientID
                     passkey:(NSString *)passkey
                         env:(NSDictionary<NSString *, NSString *> *)env
                        cols:(uint16_t)cols
                        rows:(uint16_t)rows
                       width:(uint16_t)width
                      height:(uint16_t)height
               keepaliveSecs:(int32_t)keepaliveSecs NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Build the et_config and call et_connect (spawns the transport thread).
- (void)start;

/// Enqueue input bytes to the ET stream (serialized).
- (void)send:(NSData *)bytes;

/// Update the terminal window size (serialized). Pixel width/height 0 if unknown.
- (void)setWindowSizeCols:(uint16_t)cols rows:(uint16_t)rows
                    width:(uint16_t)width height:(uint16_t)height;

/// Tear down: serialized et_close (joins the transport thread), idempotent. After
/// close no closure fires.
- (void)close;

/// Decrypted output bytes (main queue). Wire to `terminalView.feed(byteArray:)`.
@property (nonatomic, copy, nullable) void (^onOutput)(NSData *bytes);

/// Raw et_state code (main queue). Swift maps it via `mapETState`.
@property (nonatomic, copy, nullable) void (^onState)(NSInteger state);

/// Fires exactly once (main queue) on the FIRST output byte. The fallback slice
/// uses this to divide pre-frame failures from mid-session teardown.
@property (nonatomic, copy, nullable) void (^onFirstFrame)(void);

/// Fires once when the session ends (main queue). `reason` is RAW/untrusted; the
/// Swift caller must route it through sanitizeEndReason before logging/display.
@property (nonatomic, copy, nullable) void (^onEnd)(NSString *_Nullable reason);

@end

NS_ASSUME_NONNULL_END
