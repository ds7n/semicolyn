// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
#import <XCTest/XCTest.h>
#import "ETSession.h"

// Test-only hook into fake_et_client.mm: lets a test control the reason string
// the fake reports via on_end (see that file for the NULL-reset contract).
extern "C" void fake_et_set_end_reason(const char *r);

@interface ETSessionTests : XCTestCase
@end

@implementation ETSessionTests

- (ETSession *)makeSession {
    return [[ETSession alloc] initWithHost:@"h" port:2022 id:@"0123456789abcdef"
                                   passkey:@"0123456789abcdef0123456789abcdef"
                                       env:@{@"TERM": @"xterm-256color"}
                                      cols:80 rows:24 width:0 height:0 keepaliveSecs:0];
}

// Bytes sent via -send: echo back through onOutput (proves the queue-hop + copy).
- (void)testSendEchoesThroughOnOutput {
    ETSession *s = [self makeSession];
    XCTestExpectation *got = [self expectationWithDescription:@"output"];
    __block NSData *received = nil;
    s.onOutput = ^(NSData *bytes) { received = bytes; [got fulfill]; };
    [s start];
    [s send:[@"hi" dataUsingEncoding:NSUTF8StringEncoding]];
    [self waitForExpectations:@[got] timeout:2.0];
    XCTAssertEqualObjects(received, [@"hi" dataUsingEncoding:NSUTF8StringEncoding]);
    [s close];
}

// onFirstFrame fires exactly once even across multiple output bytes.
- (void)testFirstFrameFiresExactlyOnce {
    ETSession *s = [self makeSession];
    XCTestExpectation *second = [self expectationWithDescription:@"second output"];
    __block int firstFrameCount = 0;
    __block int outputCount = 0;
    s.onFirstFrame = ^{ firstFrameCount++; };
    s.onOutput = ^(NSData *bytes) { if (++outputCount == 2) [second fulfill]; };
    [s start];
    [s send:[@"a" dataUsingEncoding:NSUTF8StringEncoding]];
    [s send:[@"b" dataUsingEncoding:NSUTF8StringEncoding]];
    [self waitForExpectations:@[second] timeout:2.0];
    XCTAssertEqual(firstFrameCount, 1);
    [s close];
}

// -close is idempotent and no onOutput fires after it.
- (void)testCloseIdempotentAndNoOutputAfter {
    ETSession *s = [self makeSession];
    XCTestExpectation *ended = [self expectationWithDescription:@"end"];
    __block int outputAfterClose = 0;
    __block BOOL closed = NO;
    s.onOutput = ^(NSData *bytes) { if (closed) outputAfterClose++; };
    s.onEnd = ^(NSString *reason) { [ended fulfill]; };
    [s start];
    closed = YES;
    [s close];
    [s close];   // second close must be a no-op (not crash)
    [s send:[@"late" dataUsingEncoding:NSUTF8StringEncoding]];  // must be dropped
    [self waitForExpectations:@[ended] timeout:2.0];
    // Give any erroneously-queued output a chance to (not) arrive.
    XCTestExpectation *settle = [self expectationWithDescription:@"settle"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [settle fulfill]; });
    [self waitForExpectations:@[settle] timeout:2.0];
    XCTAssertEqual(outputAfterClose, 0);
}

// onEnd delivers the reason RAW/verbatim: the wrapper does not sanitize it (that
// is the Swift consumer's job via sanitizeEndReason, unit-tested separately).
// Locks the design contract: a hostile injection payload (ANSI escape + markup)
// must arrive at onEnd byte-for-byte unchanged, not stripped/escaped here.
- (void)testEndReasonArrivesRawUnsanitized {
    const char *injection = "\x1B[31m<b>denied</b>\x1B[0m";
    fake_et_set_end_reason(injection);
    ETSession *s = [self makeSession];
    XCTestExpectation *ended = [self expectationWithDescription:@"end"];
    __block NSString *receivedReason = nil;
    s.onEnd = ^(NSString *reason) { receivedReason = reason; [ended fulfill]; };
    [s start];
    [s close];
    [self waitForExpectations:@[ended] timeout:2.0];
    NSString *expected = [NSString stringWithUTF8String:injection];
    XCTAssertEqualObjects(receivedReason, expected);
    fake_et_set_end_reason(NULL);   // reset so later tests get the default reason
}

// Regression for the callback UAF: the fake's et_close fires on_end (via
// dispatch_sync on its work queue) while the Swift-side owner has already
// dropped its only strong reference to the ETSession. Before the fix, the
// bridge context held no retain on the Swift object, so on_end after release
// messaged freed memory. With the fix (CFBridgingRetain holds a +1 until
// close tears the ctx down), the session stays alive through the callback,
// so this must complete without crashing and still deliver onEnd.
- (void)testOnEndAfterOwnerReleaseDoesNotCrash {
    XCTestExpectation *ended = [self expectationWithDescription:@"end"];
    @autoreleasepool {
        ETSession *s = [self makeSession];
        s.onEnd = ^(NSString *reason) { [ended fulfill]; };
        [s start];
        // fake's et_close fires on_end synchronously on its work queue; the
        // retained bridge ctx keeps the session alive through that callback
        // even though we drop our own strong ref on the next line.
        [s close];
        s = nil;
    }
    [self waitForExpectations:@[ended] timeout:2.0];
    // Reaching here without a crash, with the expectation fulfilled, is the
    // assertion: the callback ran against live memory, not a freed object.
    XCTAssertTrue(YES);
}

@end
