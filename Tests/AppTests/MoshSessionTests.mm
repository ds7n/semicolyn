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
    __block BOOL fulfilled = NO;
    // onOutput can fire in multiple chunks; fulfill EXACTLY once (double-fulfill asserts).
    s.onOutput = ^(NSData *d) {
        [acc appendData:d];
        if (acc.length >= 1 && !fulfilled) { fulfilled = YES; [got fulfill]; }
    };
    [s start];
    unsigned char byte = 'X';
    [s writeInput:[NSData dataWithBytes:&byte length:1]];
    [self waitForExpectations:@[ got ] timeout:2.0];
    XCTAssertEqual(((const unsigned char *)acc.bytes)[0], 'X');
    [s stop];
}

// Multi-byte input echoes verbatim and in order.
- (void)testMultiByteEchoesVerbatim {
    MoshSession *s = [[MoshSession alloc] initWithIP:@"127.0.0.1" port:@"60000" key:@"K"
                                                cols:80 rows:24 predictMode:@"none"];
    XCTestExpectation *got = [self expectationWithDescription:@"onOutput"];
    __block NSMutableData *acc = [NSMutableData data];
    __block BOOL fulfilled = NO;
    // "hello" may arrive as several chunks; fulfill EXACTLY once (double-fulfill asserts).
    s.onOutput = ^(NSData *d) {
        [acc appendData:d];
        if (acc.length >= 5 && !fulfilled) { fulfilled = YES; [got fulfill]; }
    };
    [s start];
    [s writeInput:[@"hello" dataUsingEncoding:NSUTF8StringEncoding]];
    [self waitForExpectations:@[ got ] timeout:2.0];
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
    [self waitForExpectations:@[ ended ] timeout:2.0];
    XCTAssertTrue(cleanReason, @"clean quit should report a nil reason");
    [s stop];
}

// onFirstFrame fires exactly once  - on the first output byte  - and NOT again on
// later bytes. Proves the handshake-completed signal the VM uses to divide
// pre-frame SSH fallback from mid-session crash. Asserts the exact fire count (1),
// not merely "it fired".
- (void)testFirstFrameFiresExactlyOnceThenNever {
    MoshSession *s = [[MoshSession alloc] initWithIP:@"127.0.0.1" port:@"60000" key:@"K"
                                                cols:80 rows:24 predictMode:@"none"];
    XCTestExpectation *firstFrame = [self expectationWithDescription:@"onFirstFrame"];
    XCTestExpectation *sawFiveBytes = [self expectationWithDescription:@"5 bytes echoed"];
    __block int firstFrameCount = 0;
    __block NSUInteger echoed = 0;
    __block BOOL frameFulfilled = NO;
    __block BOOL byteFulfilled = NO;
    s.onFirstFrame = ^{
        firstFrameCount += 1;
        if (!frameFulfilled) { frameFulfilled = YES; [firstFrame fulfill]; }
    };
    // Accumulate echoed bytes; once all 5 have round-tripped, the reader has
    // processed input past the first byte  - so a second onFirstFrame would already
    // have fired if the gate were broken.
    s.onOutput = ^(NSData *d) {
        echoed += d.length;
        if (echoed >= 5 && !byteFulfilled) { byteFulfilled = YES; [sawFiveBytes fulfill]; }
    };
    [s start];
    [s writeInput:[@"hello" dataUsingEncoding:NSUTF8StringEncoding]];
    [self waitForExpectations:@[ firstFrame, sawFiveBytes ] timeout:2.0];
    XCTAssertEqual(firstFrameCount, 1, @"onFirstFrame must fire exactly once across all output bytes");
    [s stop];
}

// stop() is idempotent and safe to call without a prior clean end. The real
// assertion is crash-freedom of the double-close path (the fd bookkeeping that
// nils the pipe fds after the first stop is what makes the second stop a no-op).
- (void)testStopIsIdempotent {
    MoshSession *s = [[MoshSession alloc] initWithIP:@"127.0.0.1" port:@"60000" key:@"K"
                                                cols:80 rows:24 predictMode:@"none"];
    [s start];
    [s stop];
    [s stop];  // must not crash / double-close
    XCTAssertTrue(YES);
}

// suspendForResume sends mosh's SUSPEND sequence (0x1e 0x1a); the vendored client
// (and our fake, faithfully) serializes state → state_callback → onEncodedState fires
// with the blob AND latestEncodedState returns it. Uses the real -suspendForResume
// entry point (which also drives teardown via -stop) rather than a raw writeInput, so
// the blob-capture contract is proven on the path the app actually takes.
- (void)testSuspendCapturesEncodedState {
    MoshSession *s = [[MoshSession alloc] initWithIP:@"127.0.0.1" port:@"60000" key:@"K"
                                                cols:80 rows:24 predictMode:@"none"];
    XCTestExpectation *captured = [self expectationWithDescription:@"onEncodedState"];
    __block NSData *blob = nil;
    s.onEncodedState = ^(NSData *d) { blob = [d copy]; [captured fulfill]; };
    [s start];
    [s suspendForResume];
    [self waitForExpectations:@[ captured ] timeout:2.0];
    // The fake emits a known blob "STATE" on suspend (see fake_mosh_main.mm).
    XCTAssertEqualObjects([[NSString alloc] initWithData:blob encoding:NSUTF8StringEncoding], @"STATE");
    XCTAssertEqualObjects([s latestEncodedState], blob, @"latestEncodedState returns the captured blob");
    [s stop];
}

// SUSPEND-TEARDOWN CONTRACT (regression for the two Criticals). mosh's SUSPEND makes
// the client pthread_exit SYNCHRONOUSLY inside mosh_main (see fake_mosh_main.mm),
// killing the mosh thread mid-call WITHOUT running runMoshLoop's own fclose (which
// would have EOF'd the reader). Before the fix, -stop's NORMAL reader branch joined
// the reader assuming that fclose already delivered EOF  - so pthread_join(reader)
// blocked FOREVER and the reader thread + fds leaked. This test proves the fix by
// DIRECTLY OBSERVING the reader thread's termination:
//   (1) the encoded-state blob is STILL captured through suspendForResume, AND
//   (2) -stop's async teardown block RUNS TO COMPLETION  - it fires onTeardownComplete
//       as its final action, which happens ONLY after pthread_join(reader) returns
//       (i.e. the reader thread actually terminated). We wait on that signal.
// WHY THIS IS REAL (fails against the pre-fix impl): pre-fix, -stop's NORMAL reader
// branch runs on the suspend path and pthread_join(reader) blocks forever (mosh's
// fclose that would EOF the reader never ran). The teardown block is therefore wedged
// in the join and NEVER reaches its final onTeardownComplete call  - so the
// `teardown` expectation is never fulfilled and this test TIMES OUT / FAILS. Post-fix
// the suspend path delivers the reader's EOF (closes _outPipe[1]) before joining, the
// join returns, and onTeardownComplete fires promptly → the expectation is met.
// Contrast the OLD version of this test, which fulfilled its expectation from a SECOND
// [s stop] that returns immediately via the idempotency guard WITHOUT reaching the
// reader join  - so it passed even against a deadlocked reader (a tautology). This
// version cannot: the ONLY thing that fulfills `teardown` is the teardown block
// running past the reader join.
- (void)testSuspendThenStopTearsDownWithoutDeadlock {
    MoshSession *s = [[MoshSession alloc] initWithIP:@"127.0.0.1" port:@"60000" key:@"K"
                                                cols:80 rows:24 predictMode:@"none"];
    XCTestExpectation *captured = [self expectationWithDescription:@"onEncodedState"];
    XCTestExpectation *teardown = [self expectationWithDescription:@"onTeardownComplete"];
    __block NSData *blob = nil;
    __block BOOL teardownFired = NO;
    s.onEncodedState = ^(NSData *d) { blob = [d copy]; [captured fulfill]; };
    // onTeardownComplete is the teardown block's FINAL action, reached ONLY after the
    // reader join returns. Fulfill exactly once (the block fires it once per -stop, but
    // suspendForResume's internal -stop is the one that reaches it here; guard anyway).
    s.onTeardownComplete = ^{
        if (!teardownFired) { teardownFired = YES; [teardown fulfill]; }
    };
    [s start];
    // suspendForResume writes the suspend bytes (→ pthread_exit on the mosh thread) and
    // internally drives teardown via -stop (the suspend-aware EOF-we-deliver reader
    // path). Pre-fix, that -stop's reader join deadlocks and onTeardownComplete never
    // fires → the `teardown` wait below times out.
    [s suspendForResume];

    // Wait for BOTH: the blob was captured AND the async teardown ran to completion
    // (reader joined, all fds closed). A generous timeout so a slow CI machine does not
    // flake, but a real deadlock (pre-fix) never fires teardown and this WILL time out.
    [self waitForExpectations:@[ captured, teardown ] timeout:3.0];
    XCTAssertEqualObjects([[NSString alloc] initWithData:blob encoding:NSUTF8StringEncoding], @"STATE",
                          @"suspend must still capture the state blob after the teardown-driving change");
    XCTAssertTrue(teardownFired,
                  @"teardown block must run to completion (reader joined) instead of deadlocking");

    // A further -stop after everything settled must also be a crash-free idempotent no-op.
    [s stop];
    XCTAssertTrue(YES, @"suspend → stop teardown completed without deadlock");
}

// A session constructed WITH a restore blob passes it into mosh_main; the fake
// echoes "R:<blob>" so we observe that the RESTORE branch ran with our bytes.
- (void)testEncodedStateIsReplayedIntoMoshMain {
    NSData *blob = [@"STATE" dataUsingEncoding:NSUTF8StringEncoding];
    MoshSession *s = [[MoshSession alloc] initWithIP:@"127.0.0.1" port:@"60000" key:@"K"
                                                cols:80 rows:24 predictMode:@"none"
                                          encodedState:blob];
    XCTestExpectation *got = [self expectationWithDescription:@"replay echo"];
    __block NSMutableData *acc = [NSMutableData data];
    __block BOOL done = NO;
    s.onOutput = ^(NSData *d) {
        [acc appendData:d];
        NSString *str = [[NSString alloc] initWithData:acc encoding:NSUTF8StringEncoding];
        if ([str containsString:@"R:STATE"] && !done) { done = YES; [got fulfill]; }
    };
    [s start];
    [self waitForExpectations:@[ got ] timeout:2.0];
    XCTAssertTrue(done, @"mosh_main received the encoded_state buffer on resume");
    [s stop];
}

// Empty/no restore blob => fresh session => the fake emits NO "R:" prefix.
- (void)testFreshSessionSendsNoEncodedState {
    MoshSession *s = [[MoshSession alloc] initWithIP:@"127.0.0.1" port:@"60000" key:@"K"
                                                cols:80 rows:24 predictMode:@"none"];
    XCTestExpectation *echoed = [self expectationWithDescription:@"echo"];
    __block NSMutableData *acc = [NSMutableData data];
    __block BOOL done = NO;
    s.onOutput = ^(NSData *d) {
        [acc appendData:d];
        if (acc.length >= 1 && !done) { done = YES; [echoed fulfill]; }
    };
    [s start];
    [s writeInput:[@"Z" dataUsingEncoding:NSUTF8StringEncoding]];
    [self waitForExpectations:@[ echoed ] timeout:2.0];
    NSString *str = [[NSString alloc] initWithData:acc encoding:NSUTF8StringEncoding];
    XCTAssertFalse([str hasPrefix:@"R:"], @"fresh session must not carry restore state");
    [s stop];
}

@end
