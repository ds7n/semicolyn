// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
#import "MoshSession.h"
#if __has_include(<Mosh/moshiosbridge.h>)
#import <Mosh/moshiosbridge.h>
#else
#import "moshiosbridge.h"
#endif
#include <errno.h>
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

// ─────────────────────────────────────────────────────────────────────────────
// OWNERSHIP + CONCURRENCY MODEL (holistic — read this before touching anything)
//
// Three threads touch a MoshSession:
//   (M)  the main thread/actor: -start, -writeInput:, -resizeCols:rows:, -stop,
//        and the onOutput/onEnd callbacks (always dispatched to main).
//   (T1) the mosh thread: runMoshLoop → blocking mosh_main.
//   (T2) the reader thread: runReaderLoop → read() on the output pipe.
//
// ONE mutex (`_lock`) guards ALL fd + BOOL state transitions. Every access to
// _inPipe/_outPipe/_started/_stopped/_moshThreadLive/_readerThreadLive/_endFired/
// _winsize/_moshThread/_readerThread happens under _lock. Blocking syscalls
// (mosh_main, read, write, pthread_join) are NEVER performed while holding the
// lock — the lock only brackets the snapshot-fd-and-record-intent step; every
// thread copies the fd/flag it needs into a local under the lock, drops the lock,
// then blocks on the local copy. So no two threads ever touch the fd table or the
// state ivars concurrently, and no thread blocks another by holding the lock.
//
// FD OWNERSHIP is SINGLE-OWNER, and every close is separated from any concurrent
// use by a pthread_join, which is what kills the fd-number-reuse race dead:
//   • The mosh-side fds (_inPipe[0] via f_in, _outPipe[1] via f_out) are closed
//     ONLY by runMoshLoop, via fclose, exactly once each, as the last thing it
//     does before returning. Nothing else ever closes them.
//   • The app-side fds are closed ONLY by -stop's teardown block:
//       – _inPipe[1] (input write end): closed under _lock in phase 1, atomically
//         with setting it to -1, so no writeInput can be mid-write on it (writeInput
//         snapshots the same fd under the same lock and, seeing _stopped, bails).
//         Closing it gives the mosh read side EOF → mosh_main returns.
//       – _outPipe[0] (output read end): closed by the teardown block AFTER the
//         reader thread is joined, so the reader's read() can never race the close
//         and hit a recycled fd number. In the normal path the mosh thread's
//         fclose(f_out) is what EOFs the reader (so it exits, then we join, then we
//         close); only in the degenerate "mosh thread never ran" path do we first
//         close the WRITE end (_outPipe[1]) to deliver EOF, then join, then close
//         the read end.
// Because the teardown block joins each thread BEFORE closing any fd that thread
// touches, no close() ever races a read()/write()/fclose() on a live-or-recycled
// number. Every fd number is live for its whole thread's life. (Single reader +
// join barrier = no self-pipe/refcount needed; see -stop for the upgrade note.)
//
// TEARDOWN SEQUENCE in -stop:
//   Phase 1 (caller thread, under _lock): if already stopping, return (idempotent).
//     Else set _stopped, snapshot both pthread_t + their "live" flags, send the
//     quit sequence and close _inPipe[1] (→ mosh EOF), clear onOutput/onEnd so no
//     callback fires after -stop returns. Drop the lock.
//   Phase 2 (async, off-main utility queue): join the mosh thread (it fclose()s
//     the mosh-side fds and fires onEnd on the way out). Then retire the reader:
//     in the normal path join it (it already EOF'd via the mosh fclose) THEN close
//     _outPipe[0]; in the degenerate no-mosh-thread path close _outPipe[1] first to
//     deliver EOF, join, then close _outPipe[0]. Join-before-close throughout.
//   The block retains self, so teardown safely outlives the app dropping its ref.
//
// CALLBACK-AFTER-STOP: -stop nils onOutput/onEnd under _lock before joining, and
// the loops re-read the (possibly-nil) block under _lock, so no dispatch is
// enqueued once teardown starts. fireEnd is gated by _endFired so onEnd fires at
// most once even if a natural exit races -stop. Any dispatch already in flight is
// harmless: the Swift blocks are [weak self].
// ─────────────────────────────────────────────────────────────────────────────

@implementation MoshSession {
    NSString *_ip, *_port, *_key, *_predict;
    struct winsize _winsize;  // guarded by _lock (written on resize, read by mosh thread)
    int _inPipe[2];           // app writes _inPipe[1]; mosh reads fileno(f_in) from _inPipe[0]
    int _outPipe[2];          // mosh writes f_out (_outPipe[1]); reader reads _outPipe[0]
    pthread_t _moshThread;
    pthread_t _readerThread;
    BOOL _started;
    BOOL _moshThreadLive;    // mosh thread was created (guards pthread_kill/join)
    BOOL _readerThreadLive;  // reader thread was created (guards pthread_join)
    BOOL _stopped;           // teardown requested — set once, under _lock
    BOOL _endFired;          // onEnd dispatched already (fire at most once), under _lock
    BOOL _firstFrameFired;   // onFirstFrame dispatched already (fire at most once), under _lock
    pthread_mutex_t _lock;
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
        pthread_mutex_init(&_lock, NULL);
    }
    return self;
}

- (void)dealloc {
    // By the time ARC deallocs, both trampolines have released their +1 and
    // therefore have exited (the +1 is the last ref they hold). So no thread is
    // running and it is safe to destroy the mutex and close any stray fds. In the
    // normal flow -stop already closed everything (fds are -1); this is a belt-and
    // -suspenders sweep for the "never started" / "started but stop never called"
    // paths so we don't leak fds.
    if (_inPipe[0] >= 0) close(_inPipe[0]);
    if (_inPipe[1] >= 0) close(_inPipe[1]);
    if (_outPipe[0] >= 0) close(_outPipe[0]);
    if (_outPipe[1] >= 0) close(_outPipe[1]);
    pthread_mutex_destroy(&_lock);
}

// Trampolines: pthread entry points hop back into the ObjC object. Each thread is
// handed a RETAINED (+1) reference via CFBridgingRetain at pthread_create, and
// releases it (CFBridgingRelease) when it exits — as the LAST thing it does, after
// runMoshLoop/runReaderLoop have fully returned and touch no more ivars. This keeps
// the MoshSession alive for the whole lifetime of its threads. The release can
// trigger dealloc, but only once BOTH threads have released and both have exited,
// and dealloc never runs while the lock is held (the loops always drop _lock before
// returning), so there is no dealloc-under-lock hazard.
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
    pthread_mutex_lock(&_lock);
    if (_started) { pthread_mutex_unlock(&_lock); return; }
    _started = YES;

    // Writing to a pipe whose read end has closed raises SIGPIPE, which would kill
    // the process. We handle short writes by return value, so ignore SIGPIPE. This
    // is process-global and idempotent; setting it once per start is harmless.
    signal(SIGPIPE, SIG_IGN);

    if (pipe(_inPipe) != 0 || pipe(_outPipe) != 0) {
        // Leave any partially-opened pipe for dealloc to sweep; report failure.
        pthread_mutex_unlock(&_lock);
        [self fireEnd:@"Mosh connection failed — using SSH"];
        return;
    }

    // CFBridgingRetain gives each thread its own +1; the trampoline releases it on
    // exit. If pthread_create fails the trampoline never runs, so reclaim that +1.
    CFTypeRef readerCtx = CFBridgingRetain(self);
    if (pthread_create(&_readerThread, NULL, reader_thread_main, (void *)readerCtx) == 0) {
        _readerThreadLive = YES;
    } else {
        CFBridgingRelease(readerCtx);
    }
    CFTypeRef moshCtx = CFBridgingRetain(self);
    if (pthread_create(&_moshThread, NULL, mosh_thread_main, (void *)moshCtx) == 0) {
        _moshThreadLive = YES;
    } else {
        CFBridgingRelease(moshCtx);
    }
    pthread_mutex_unlock(&_lock);
}

- (void *)runMoshLoop {
    // Mosh's Select installs its own SIGWINCH handler; make sure this thread does
    // not have SIGWINCH blocked so a pthread_kill(SIGWINCH) on resize is delivered.
    sigset_t unblock;
    sigemptyset(&unblock);
    sigaddset(&unblock, SIGWINCH);
    pthread_sigmask(SIG_UNBLOCK, &unblock, NULL);

    // Snapshot the mosh-side fds under the lock. These fds stay OPEN for the whole
    // life of this thread; -stop never closes them until after it joins us.
    pthread_mutex_lock(&_lock);
    int inFd = _inPipe[0];
    int outFd = _outPipe[1];
    pthread_mutex_unlock(&_lock);

    FILE *fin = fdopen(inFd, "r");
    FILE *fout = fdopen(outFd, "w");
    if (!fin || !fout) {
        // Partial/total fdopen failure. Close whichever succeeded via fclose (which
        // owns that fd) and, for a slot whose fdopen FAILED, close the raw fd here.
        // Then clear the mosh-side slots so dealloc's sweep never double-closes.
        pthread_mutex_lock(&_lock);
        _inPipe[0] = -1;
        _outPipe[1] = -1;
        pthread_mutex_unlock(&_lock);
        if (fin) { fclose(fin); } else if (inFd >= 0) { close(inFd); }
        if (fout) { fclose(fout); } else if (outFd >= 0) { close(outFd); }
        [self fireEnd:@"Mosh connection failed — using SSH"];
        return NULL;
    }
    setvbuf(fout, NULL, _IONBF, 0);  // unbuffered: every frame flushes to the pipe immediately

    // Snapshot the config strings + winsize pointer. _winsize is shared with resize;
    // mosh reads it on SIGWINCH. It is a plain POD struct written under _lock by
    // resize and read here by mosh's handler — the tearing risk on two u16 fields is
    // benign (a resize is idempotent and re-sent), and passing &_winsize matches the
    // vendored contract. We take &_winsize directly as the vendored API requires.
    // DIAGNOSTIC: capture what mosh writes to stderr during the run. The vendored
    // bridge (moshiosbridge.cc) prints the caught Network/Crypto/std exception —
    // the REAL reason a session failed — to stderr, which otherwise vanishes into
    // the device console. Redirect fd 2 into a pipe around the mosh_main call (this
    // thread only sees the failure path; the happy path prints nothing), then use
    // the captured text as the onEnd reason so a device trace names the cause.
    // Scoped: the original fd 2 is restored immediately after the call.
    int errPipe[2] = { -1, -1 };
    int savedStderr = -1;
    if (pipe(errPipe) == 0) {
        // Non-blocking read end so draining a quiet/failed run never hangs.
        fcntl(errPipe[0], F_SETFL, O_NONBLOCK);
        savedStderr = dup(STDERR_FILENO);
        dup2(errPipe[1], STDERR_FILENO);
        close(errPipe[1]);
    }

    char emptyState = 0;
    int rc = mosh_main(fin, fout, &_winsize, mosh_state_noop, (__bridge void *)self,
                       _ip.UTF8String, _port.UTF8String, _key.UTF8String, _predict.UTF8String,
                       &emptyState, 0, _predict.UTF8String);

    // Restore the real stderr, then drain whatever mosh printed into a bounded buffer.
    NSString *capturedErr = nil;
    if (savedStderr >= 0) {
        fflush(stderr);
        dup2(savedStderr, STDERR_FILENO);
        close(savedStderr);
        char buf[512];
        ssize_t n = read(errPipe[0], buf, sizeof(buf) - 1);
        if (n > 0) {
            buf[n] = '\0';
            // Trim trailing CR/LF so the reason is a single clean line.
            while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r')) { buf[--n] = '\0'; }
            if (n > 0) { capturedErr = [NSString stringWithUTF8String:buf]; }
        }
    }
    if (errPipe[0] >= 0) { close(errPipe[0]); }

    // The mosh thread is the SOLE owner of the mosh-side fds: fclose each exactly
    // once (fclose closes the underlying _inPipe[0]/_outPipe[1] fd). -stop never
    // touches these fds and, crucially, -stop always pthread_join()s THIS thread
    // BEFORE it does anything that could observe a recycled number — so these
    // fclose()s have fully completed (and these fd numbers are dead) by the time any
    // -stop close runs. That join is the barrier that removes the fd-reuse race.
    // Mark the mosh-side slots consumed under the lock so nothing else references
    // them (writeInput/resize/-stop/dealloc all check for -1 under the same lock).
    fflush(fout);
    pthread_mutex_lock(&_lock);
    _inPipe[0] = -1;
    _outPipe[1] = -1;
    pthread_mutex_unlock(&_lock);
    fclose(fin);
    fclose(fout);   // closing the output write end makes the reader see EOF

    // On failure, surface the captured mosh error (the real cause) if we got one;
    // otherwise the generic fallback string. On success (rc == 0), reason stays nil.
    NSString *endReason = nil;
    if (rc != 0) {
        endReason = capturedErr.length > 0
            ? [NSString stringWithFormat:@"Mosh failed: %@ — using SSH", capturedErr]
            : @"Mosh connection failed — using SSH";
    }
    [self fireEnd:endReason];
    return NULL;
}

- (void *)runReaderLoop {
    // Snapshot the read fd ONCE under the lock. This fd stays open until AFTER the
    // reader thread is joined by -stop, so `fd` is valid for the whole loop and can
    // never be closed-and-recycled underneath us.
    pthread_mutex_lock(&_lock);
    int fd = _outPipe[0];
    pthread_mutex_unlock(&_lock);

    const size_t bufSize = 16384;
    unsigned char *buf = (unsigned char *)malloc(bufSize);
    if (!buf) return NULL;
    for (;;) {
        ssize_t n = read(fd, buf, bufSize);
        if (n < 0 && errno == EINTR) continue;  // interrupted by a signal; retry
        if (n <= 0) break;                       // EOF or hard error → loop ends
        NSData *data = [NSData dataWithBytes:buf length:(NSUInteger)n];
        // Re-read the callbacks under the lock; -stop clears them before join so no
        // dispatch is enqueued for a session the app already tore down. The blocks
        // themselves are [weak self] on the Swift side, so even an in-flight dispatch
        // is safe if the object is gone. On the FIRST byte, also fire onFirstFrame
        // (once) — enqueued BEFORE this byte's onOutput, so the "frames are flowing"
        // signal reaches the main actor before the byte it announces.
        pthread_mutex_lock(&_lock);
        void (^firstFrame)(void) = nil;
        if (!_firstFrameFired) {
            _firstFrameFired = YES;
            firstFrame = self.onFirstFrame;
        }
        void (^cb)(NSData *) = self.onOutput;
        pthread_mutex_unlock(&_lock);
        if (firstFrame) dispatch_async(dispatch_get_main_queue(), ^{ firstFrame(); });
        if (cb) dispatch_async(dispatch_get_main_queue(), ^{ cb(data); });
    }
    free(buf);
    return NULL;
}

- (void)writeInput:(NSData *)bytes {
    if (bytes.length == 0) return;
    // Snapshot the write fd under the lock so it can't be closed/recycled between
    // the guard and the write(). If -stop has run, _stopped is YES → no-op.
    pthread_mutex_lock(&_lock);
    int fd = (_started && !_stopped) ? _inPipe[1] : -1;
    pthread_mutex_unlock(&_lock);
    if (fd < 0) return;

    const unsigned char *p = (const unsigned char *)bytes.bytes;
    size_t remaining = bytes.length;
    while (remaining > 0) {
        ssize_t w = write(fd, p, remaining);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) break;  // pipe closed (EPIPE, SIGPIPE ignored) or error
        p += (size_t)w;
        remaining -= (size_t)w;
    }
}

- (void)resizeCols:(int)cols rows:(int)rows {
    pthread_mutex_lock(&_lock);
    _winsize.ws_col = (unsigned short)cols;
    _winsize.ws_row = (unsigned short)rows;
    // pthread_kill only if the mosh thread was actually created AND we have not
    // begun teardown (which joins it — signalling a joined pthread_t is UB).
    BOOL deliver = _moshThreadLive && !_stopped;
    pthread_t target = _moshThread;
    pthread_mutex_unlock(&_lock);
    if (deliver) {
        // The vendored loop handles SIGWINCH by re-reading the shared winsize and
        // pushing a Parser::Resize. Mosh's Select installs the signal machinery on
        // the thread running the loop, so target that thread specifically.
        pthread_kill(target, SIGWINCH);
    }
}

- (void)stop {
    // Phase 1 (any thread, typically main): flip to stopping exactly once, snapshot
    // everything teardown needs, clear callbacks so none fire after we return, and
    // send the quit sequence + close the INPUT WRITE end so mosh_main hits EOF.
    pthread_mutex_lock(&_lock);
    if (_stopped) { pthread_mutex_unlock(&_lock); return; }
    _stopped = YES;

    BOOL moshLive = _moshThreadLive;
    BOOL readerLive = _readerThreadLive;
    pthread_t moshT = _moshThread;
    pthread_t readerT = _readerThread;
    int inWrite = _inPipe[1];    // app write end → close to give mosh EOF
    _inPipe[1] = -1;             // publish -1 NOW: writeInput will see it and bail
    // Silence callbacks under the lock: nothing fires onOutput/onFirstFrame/onEnd
    // after -stop.
    self.onOutput = nil;
    self.onFirstFrame = nil;
    self.onEnd = nil;
    pthread_mutex_unlock(&_lock);

    // Best-effort clean quit, then EOF — done OUTSIDE the lock because write() to a
    // full pipe can block, and we must never block while holding _lock. inWrite is
    // now exclusively ours: _inPipe[1] is -1 under the lock, so no writeInput can
    // touch this fd number, and this is the only close() of it (single-owner).
    if (inWrite >= 0) {
        (void)write(inWrite, kMoshQuitSequence, sizeof(kMoshQuitSequence));
        close(inWrite);  // mosh read side → EOF → mosh_main returns
    }

    // Phases 2-4 run off the main thread: pthread_join blocks, and -stop is called
    // from the main actor. Capture only scalars/pthread_t (POD) + a retained self so
    // the object outlives the async teardown even if the app drops its ref now.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        // Retain self across the async teardown (block captures self strongly).
        // Join the mosh thread first. After this returns, runMoshLoop has fully
        // finished — including its fclose(_outPipe[1]) — so the reader is at (or is
        // about to hit) EOF, and the mosh-side fds (_inPipe[0]/_outPipe[1]) are
        // already closed by that fclose (their numbers are dead) UNLESS the mosh
        // thread never ran (the degenerate branch below handles that).
        if (moshLive) pthread_join(moshT, NULL);

        // Now retire the reader and close the app read end. The ORDER matters and
        // differs by case — the reader thread reads _outPipe[0] with no lock between
        // iterations, so closing that fd while the reader is mid-loop would free its
        // number for another thread to recycle (e.g. attachSSHShell opening a russh
        // socket during the pre-frame fallback), and the reader's next read() would
        // then target a foreign fd. `pthread_join` is the barrier that proves the
        // reader is done with the fd; the close must sit on the safe side of it.
        //
        // Single reader + a real join barrier is why this needs no self-pipe/refcount
        // machinery. If a SECOND consumer of _outPipe[0] is ever added, switch the
        // reader to a select() over a self-pipe wakeup instead of relying on join.
        if (moshLive) {
            // Normal path: the mosh thread's fclose(_outPipe[1]) already EOF'd the
            // reader, so it exits on its own. Join FIRST (honoring runReaderLoop's
            // "fd valid until after join" invariant), THEN close the read end — no
            // window in which a live reader can hit a recycled fd number.
            if (readerLive) pthread_join(readerT, NULL);
            pthread_mutex_lock(&_lock);
            int appRead = _outPipe[0];
            _outPipe[0] = -1;
            pthread_mutex_unlock(&_lock);
            if (appRead >= 0) close(appRead);
        } else {
            // Degenerate path: the mosh thread never ran, so nothing fclose'd the
            // write end and the reader (if it started) is blocked in read() with no
            // EOF coming. Deliver EOF by closing the WRITE end first (closing the read
            // end does NOT reliably wake a blocked reader on Darwin), THEN join, THEN
            // close the read end. No concurrent russh fd traffic exists on this path
            // (the connection never handed off), so there is no recycle hazard here.
            pthread_mutex_lock(&_lock);
            int outWrite = _outPipe[1];
            _outPipe[1] = -1;
            pthread_mutex_unlock(&_lock);
            if (outWrite >= 0) close(outWrite);  // → reader read() returns 0 (EOF)

            if (readerLive) pthread_join(readerT, NULL);

            pthread_mutex_lock(&_lock);
            int appRead = _outPipe[0];
            _outPipe[0] = -1;
            pthread_mutex_unlock(&_lock);
            if (appRead >= 0) close(appRead);
        }
        // All threads joined; all fds closed exactly once. Teardown complete.
        (void)self;  // keep self alive to end of block
    });
}

- (void)fireEnd:(NSString *)reason {
    // Fire onEnd at most once, and never after -stop cleared it. Snapshot under lock.
    pthread_mutex_lock(&_lock);
    if (_endFired) { pthread_mutex_unlock(&_lock); return; }
    _endFired = YES;
    void (^cb)(NSString *) = self.onEnd;
    pthread_mutex_unlock(&_lock);
    if (cb) dispatch_async(dispatch_get_main_queue(), ^{ cb(reason); });
}

@end
