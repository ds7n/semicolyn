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
    if (pthread_create(&_moshThread, NULL, mosh_thread_main, (__bridge void *)self) == 0) {
        _threadLive = YES;
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
    // mosh_main returned: closing the output write end makes the reader see EOF.
    // rc == 0 means a clean exit.
    fclose(fout);  // closes _outPipe[1]
    [self fireEnd:(rc == 0 ? nil : @"Mosh connection failed — using SSH")];
    return NULL;
}

- (void *)runReaderLoop {
    const size_t bufSize = 16384;
    unsigned char *buf = (unsigned char *)malloc(bufSize);
    for (;;) {
        ssize_t n = read(_outPipe[0], buf, bufSize);
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
    // Ask Mosh to shut the network down cleanly.
    if (_inPipe[1] >= 0) { write(_inPipe[1], kMoshQuitSequence, sizeof(kMoshQuitSequence)); }
    // Join off the main thread with a bounded wait; then hard-close fds so the
    // reader unblocks even if Mosh never exits (dead UDP path).
    BOOL threadLive = _threadLive;
    pthread_t moshT = _moshThread, readerT = _readerThread;
    int inW = _inPipe[1], outW = _outPipe[1], inR = _inPipe[0], outR = _outPipe[0];
    _inPipe[0] = _inPipe[1] = _outPipe[0] = _outPipe[1] = -1;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        // Give the clean shutdown ~500ms; then force the pipes closed.
        usleep(500 * 1000);
        if (inW >= 0) close(inW);   // input write end → mosh read side sees EOF
        if (outW >= 0) close(outW); // mosh write end (may already be closed by runMoshLoop)
        if (threadLive) pthread_join(moshT, NULL);
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
