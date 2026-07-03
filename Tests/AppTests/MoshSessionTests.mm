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

// onFirstFrame fires exactly once — on the first output byte — and NOT again on
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
    // processed input past the first byte — so a second onFirstFrame would already
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

@end
