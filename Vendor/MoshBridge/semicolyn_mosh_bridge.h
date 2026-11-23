// SPDX-FileCopyrightText: 2017-2026 Blink Shell contributors
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-or-later
//
// semicolyn's entry point into the vendored Mosh iOS client. Same contract as
// extern/mosh/src/frontend/moshiosbridge.h's mosh_main, except a failed session's
// error text is written to `error_buf` instead of being printed to stderr, so the
// caller never has to redirect the process's fd 2 to read it.
#ifndef SEMICOLYN_MOSH_BRIDGE_H
#define SEMICOLYN_MOSH_BRIDGE_H

#include <stddef.h>
#include <stdio.h>
#include <sys/ioctl.h>

#if __cplusplus
extern "C"
#endif
/// Runs a Mosh client session until it quits, fails, or suspends (suspend
/// pthread_exit()s the calling thread inside this call, as upstream does).
/// Returns 0 on a clean quit, non-zero on failure. On failure, `error_buf` (if
/// non-NULL and `error_buf_size` > 0) holds the NUL-terminated reason, for example
/// "Network exception: ..."; it is an empty string when there is none.
int semicolyn_mosh_main(
    FILE *f_in, FILE *f_out, struct winsize *window_size,
    void (*state_callback)(const void *, const void *, size_t),
    void *state_callback_context,
    const char *ip, const char *port, const char *key, const char *predict_mode,
    const char *encoded_state_buffer, size_t encoded_state_size, const char *predict_overwrite,
    char *error_buf, size_t error_buf_size
    );

#endif
