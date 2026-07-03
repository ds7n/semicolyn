// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
#import "MoshSession.h"
#if __has_include(<Mosh/moshiosbridge.h>)
#import <Mosh/moshiosbridge.h>
#else
#import "moshiosbridge.h"
#endif
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

// Mosh's clean-quit sequence is Ctrl-^ then '.'  (0x1e 0x2e).
static const unsigned char kMoshQuitSequence[2] = {0x1e, 0x2e};

// The bridge passes empty session state and a no-op state callback for M3/M4
// (session restoration across process death is out of scope).
static void mosh_state_noop(const void *ctx, const void *buf, size_t len) {
    (void)ctx;
    (void)buf;
    (void)len;
}

// Private methods invoked from the C pthread trampolines below, which are defined
// before the @implementation — declare them here so the trampolines compile.
@interface MoshSession ()
- (void *)runMoshLoop;
- (void *)runReaderLoop;
- (void)fireEnd:(NSString *_Nullable)reason;
@end

@implementation MoshSession {
    NSString *_ip, *_port, *_key, *_predict;
    struct winsize _winsize;  // shared with the mosh thread; updated on resize
    int _inPipe[2];           // app writes _inPipe[1]; mosh reads fileno(f_in) from _inPipe[0]
    int _outPipe[2];          // mosh writes f_out (_outPipe[1]); reader reads _outPipe[0]
    pthread_t _moshThread;
    pthread_t _readerThread;
    BOOL _started;
    BOOL _threadLive;  // mosh thread was actually created (guards pthread_kill/join)
    BOOL _stopped;
}

- (instancetype)initWithIP:(NSString *)ip port:(NSString *)port key:(NSString *)key
                      cols:(int)cols rows:(int)rows predictMode:(NSString *)predictMode {
    if ((self = [super init])) {
        _ip = [ip copy];
        _port = [port copy];
        _key = [key copy];
        _predict = [predictMode copy];
        _winsize = (struct winsize){.ws_row = (unsigned short)rows,
                                    .ws_col = (unsigned short)cols,
                                    .ws_xpixel = 0,
                                    .ws_ypixel = 0};
        _inPipe[0] = _inPipe[1] = _outPipe[0] = _outPipe[1] = -1;
    }
    return self;
}

// Trampolines: pthread entry points hop back into the ObjC object. Each thread is
// handed a RETAINED (+1) reference via CFBridgingRetain at pthread_create, and releases
// it (CFBridgingRelease) when it exits. This keeps the MoshSession alive for the whole
// lifetime of its threads — otherwise ARC can dealloc it (when the owner drops its ref)
// while a thread is still touching its ivars → use-after-free crash.
static void *mosh_thread_main(void *ctx) {
    MoshSession *self = (__bridge MoshSession *)ctx;
    void *r = [self runMoshLoop];
    CFBridgingRelease(ctx);   // balance the CFBridgingRetain in -start
    return r;
}
static void *reader_thread_main(void *ctx) {
    MoshSession *self = (__bridge MoshSession *)ctx;
    void *r = [self runReaderLoop];
    CFBridgingRelease(ctx);
    return r;
}

- (void)start {
    if (_started) return;
    _started = YES;
    // Writing to a pipe whose read end has closed raises SIGPIPE, which would kill the
    // process. We handle short writes by return value instead, so ignore SIGPIPE.
    signal(SIGPIPE, SIG_IGN);
    if (pipe(_inPipe) != 0 || pipe(_outPipe) != 0) {
        [self fireEnd:@"Mosh connection failed — using SSH"];
        return;
    }
    // CFBridgingRetain gives each thread its own +1; the trampoline releases it on exit.
    // If pthread_create fails the trampoline never runs, so reclaim that +1 here.
    CFTypeRef readerCtx = CFBridgingRetain(self);
    if (pthread_create(&_readerThread, NULL, reader_thread_main, (void *)readerCtx) != 0) {
        CFBridgingRelease(readerCtx);
    }
    CFTypeRef moshCtx = CFBridgingRetain(self);
    if (pthread_create(&_moshThread, NULL, mosh_thread_main, (void *)moshCtx) == 0) {
        _threadLive = YES;
    } else {
        CFBridgingRelease(moshCtx);
    }
}

- (void *)runMoshLoop {
    // Mosh's Select installs its own SIGWINCH handler; make sure this thread does
    // not have SIGWINCH blocked so a pthread_kill(SIGWINCH) on resize is delivered.
    sigset_t unblock;
    sigemptyset(&unblock);
    sigaddset(&unblock, SIGWINCH);
    pthread_sigmask(SIG_UNBLOCK, &unblock, NULL);

    FILE *fin = fdopen(_inPipe[0], "r");
    FILE *fout = fdopen(_outPipe[1], "w");
    if (!fin || !fout) {
        [self fireEnd:@"Mosh connection failed — using SSH"];
        return NULL;
    }
    setvbuf(fout, NULL, _IONBF, 0);  // unbuffered: every frame flushes to the pipe immediately

    char emptyState = 0;
    int rc = mosh_main(fin, fout, &_winsize, mosh_state_noop, (__bridge void *)self,
                       _ip.UTF8String, _port.UTF8String, _key.UTF8String, _predict.UTF8String,
                       &emptyState, 0, _predict.UTF8String);
    // runMoshLoop OWNS both mosh-side FILE*s: fclose each exactly once (which closes
    // the underlying _inPipe[0]/_outPipe[1] fds). `stop` never touches these fds — it
    // only closes the APP-side ends — so there is no double-close race. Mark the
    // mosh-side fds consumed so nothing else can reference them.
    _inPipe[0] = -1;
    _outPipe[1] = -1;
    fclose(fin);
    fclose(fout);   // closing the output write end makes the reader see EOF
    [self fireEnd:(rc == 0 ? nil : @"Mosh connection failed — using SSH")];
    return NULL;
}

- (void *)runReaderLoop {
    // Capture the read fd ONCE so the loop never re-reads the ivar (which `stop` nils
    // from another thread). `stop`/runMoshLoop closing the pipe makes this read() return
    // 0/-1 and the loop exits cleanly.
    int fd = _outPipe[0];
    const size_t bufSize = 16384;
    unsigned char *buf = (unsigned char *)malloc(bufSize);
    for (;;) {
        ssize_t n = read(fd, buf, bufSize);
        if (n <= 0) break;  // EOF or error → mosh loop ended / pipe closed
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
        p += w;
        remaining -= (size_t)w;
    }
}

- (void)resizeCols:(int)cols rows:(int)rows {
    _winsize.ws_col = (unsigned short)cols;
    _winsize.ws_row = (unsigned short)rows;
    if (_threadLive && !_stopped) {
        // The vendored loop handles SIGWINCH by re-reading the shared winsize and
        // pushing a Parser::Resize. Mosh's Select installs the signal machinery on
        // the thread running the loop, so target that thread specifically.
        pthread_kill(_moshThread, SIGWINCH);
    }
}

- (void)stop {
    if (_stopped) return;
    _stopped = YES;
    // Ask Mosh to shut the network down cleanly (best-effort; ignored if the loop
    // already exited and closed its read end).
    if (_inPipe[1] >= 0) { write(_inPipe[1], kMoshQuitSequence, sizeof(kMoshQuitSequence)); }

    // fd OWNERSHIP: runMoshLoop owns the mosh-side ends (_inPipe[0], _outPipe[1]) and
    // fcloses them itself. `stop` owns ONLY the app-side ends: close the app WRITE end
    // (_inPipe[1]) so the mosh read() sees EOF and the loop exits even without a quit
    // seq, and the app READ end (_outPipe[0]) so the reader thread's read() unblocks.
    // Never touch the mosh-side fds here → no double-close/use-after-free.
    BOOL threadLive = _threadLive;
    pthread_t moshT = _moshThread, readerT = _readerThread;
    int appWrite = _inPipe[1], appRead = _outPipe[0];
    _inPipe[1] = -1;
    _outPipe[0] = -1;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (appWrite >= 0) close(appWrite);   // mosh read side → EOF → loop exits
        if (threadLive) pthread_join(moshT, NULL);
        // Join the mosh loop first; only then close the app read end and join the
        // reader (the loop's fclose(fout) already closed the mosh write end, so the
        // reader is already at EOF or will be once we close our read end).
        if (appRead >= 0) close(appRead);
        pthread_join(readerT, NULL);
    });
}

- (void)fireEnd:(NSString *)reason {
    void (^cb)(NSString *) = self.onEnd;
    if (cb) dispatch_async(dispatch_get_main_queue(), ^{ cb(reason); });
}

@end
