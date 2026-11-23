// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
//
// A test-only semicolyn_mosh_main linked into SemicolynBridgeTests INSTEAD of the
// real (network) implementation. It proves our plumbing: it echoes every byte read
// from f_in back to f_out (so onOutput reflects writeInput:), and returns cleanly (0)
// when it sees the quit sequence 0x1e 0x2e. No network, deterministic.
//
// Error mode: key "FAIL" models a session whose client threw. Like the real bridge
// it writes the reason into error_buf and returns non-zero, and it writes nothing to
// stderr.
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>

#include "semicolyn_mosh_bridge.h"

extern "C" int semicolyn_mosh_main(FILE *f_in, FILE *f_out, struct winsize *window_size,
                                   void (*state_callback)(const void *, const void *, size_t),
                                   void *state_callback_context, const char *ip,
                                   const char *port, const char *key, const char *predict_mode,
                                   const char *encoded_state_buffer, size_t encoded_state_size,
                                   const char *predict_overwrite, char *error_buf,
                                   size_t error_buf_size) {
    (void)window_size;
    (void)ip;
    (void)port;
    (void)predict_mode;
    (void)predict_overwrite;
    if (error_buf && error_buf_size > 0) error_buf[0] = '\0';
    if (key && strcmp(key, "FAIL") == 0) {
        snprintf(error_buf, error_buf_size, "Network exception: fake failure");
        return 1;
    }
    // On resume, announce the restored state so a test can observe replay.
    if (encoded_state_size > 0 && encoded_state_buffer) {
        fputc('R', f_out); fputc(':', f_out);
        fwrite(encoded_state_buffer, 1, encoded_state_size, f_out);
        fputc('\n', f_out);
    }
    int prevWasCtrlHat = 0;
    int c;
    while ((c = fgetc(f_in)) != EOF) {
        if (prevWasCtrlHat && c == 0x2e) { return 0; }        // quit → clean exit
        if (prevWasCtrlHat && c == 0x1a) {                     // suspend → serialize + EXIT
            // Model the REAL vendored iosclient SUSPEND exactly: fire state_callback,
            // then pthread_exit() SYNCHRONOUSLY on this (the mosh/T1) thread  - NOT a
            // plain `return`. A `return 0` would let runMoshLoop run its own post-
            // mosh_main teardown (fclose + fireEnd), which is the OPPOSITE of what mosh
            // does: mosh's pthread_exit KILLS T1 mid-mosh_main, so that teardown never
            // runs and -stop must deliver the reader's EOF itself. Testing the real
            // teardown contract (no reader/-stop deadlock, blob still captured) REQUIRES
            // this pthread_exit. The fake runs on the same thread MoshSession created,
            // so pthread_exit here mimics the vendored client faithfully.
            static const char kBlob[] = "STATE";
            state_callback(state_callback_context, kBlob, 5);
            static int ret = 0;
            pthread_exit(&ret);
        }
        prevWasCtrlHat = (c == 0x1e);
        fputc(c, f_out);  // echo (fout is unbuffered in the bridge)
    }
    return 0;
}
