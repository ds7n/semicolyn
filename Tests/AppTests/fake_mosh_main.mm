// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
//
// A test-only override of mosh_main linked into SemicolynBridgeTests INSTEAD of
// the real (network) implementation. It proves our plumbing: it echoes every byte
// read from f_in back to f_out (so onOutput reflects writeInput:), and returns
// cleanly (0) when it sees the quit sequence 0x1e 0x2e. No network, deterministic.
#include <stdio.h>
#include <sys/ioctl.h>

extern "C" int mosh_main(FILE *f_in, FILE *f_out, struct winsize *window_size,
                         void (*state_callback)(const void *, const void *, size_t),
                         void *state_callback_context, const char *ip, const char *port,
                         const char *key, const char *predict_mode,
                         const char *encoded_state_buffer, size_t encoded_state_size,
                         const char *predict_overwrite) {
    (void)window_size;
    (void)ip;
    (void)port;
    (void)key;
    (void)predict_mode;
    (void)predict_overwrite;
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
        if (prevWasCtrlHat && c == 0x1a) {                     // suspend → serialize + exit
            static const char kBlob[] = "STATE";
            state_callback(state_callback_context, kBlob, 5);
            return 0;
        }
        prevWasCtrlHat = (c == 0x1e);
        fputc(c, f_out);  // echo (fout is unbuffered in the bridge)
    }
    return 0;
}
