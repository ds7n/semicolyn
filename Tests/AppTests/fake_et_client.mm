// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
//
// A test-only override of the et_* C ABI linked into SemicolynBridgeTests INSTEAD
// of ETerminal.xcframework. It proves ETSession's plumbing without a network: a
// fake handle spins a background thread that (a) reports CONNECTED, (b) echoes
// every byte from et_send back through on_bytes, (c) on et_close reports and stops.
// Deterministic, no sockets, no libsodium.
#import <eternaltermlib.h>
#import <Foundation/Foundation.h>
#include <vector>

struct et_client {
    void *ctx;
    void (*on_bytes)(void *, const uint8_t *, size_t);
    void (*on_state)(void *, et_state);
    void (*on_end)(void *, const char *);
    dispatch_queue_t work;   // serial: emulates the transport thread
    bool closed;
};

// Test-controlled override for the reason et_close reports via on_end. Lets a
// test exercise a raw, potentially hostile reason string (e.g. an injection
// payload) without teaching the fake a whole config surface. NULL-safe: a
// NULL/unset value falls back to the fixed "closed by client" string below.
// Reset to NULL when a test is done so later tests aren't affected.
static const char *g_fake_et_end_reason = NULL;

extern "C" void fake_et_set_end_reason(const char *r) {
    g_fake_et_end_reason = r;
}

extern "C" et_client *et_connect(const et_config *cfg, const et_callbacks *cbs, void *ctx) {
    if (!cfg || !cfg->host || !cfg->id || !cfg->passkey) return NULL;   // sync arg failure
    et_client *c = new et_client();
    c->ctx = ctx; c->on_bytes = cbs->on_bytes; c->on_state = cbs->on_state;
    c->on_end = cbs->on_end;
    c->work = dispatch_queue_create("fake.et.transport", DISPATCH_QUEUE_SERIAL);
    c->closed = false;
    dispatch_async(c->work, ^{ if (c->on_state) c->on_state(c->ctx, ET_STATE_CONNECTED); });
    return c;
}

extern "C" int et_send(et_client *c, const uint8_t *buf, size_t len) {
    if (!c || c->closed) return ET_ERR_CLOSED;
    std::vector<uint8_t> bytes(buf, buf + len);
    dispatch_async(c->work, ^{
        if (!c->closed && c->on_bytes) c->on_bytes(c->ctx, bytes.data(), bytes.size());
    });
    return (int)len;
}

extern "C" int et_set_window_size(et_client *c, uint16_t cols, uint16_t rows,
                                  uint16_t w, uint16_t h) {
    (void)cols; (void)rows; (void)w; (void)h;
    if (!c || c->closed) return ET_ERR_CLOSED;
    return 0;
}

extern "C" void et_close(et_client *c) {
    if (!c || c->closed) return;
    c->closed = true;
    const char *reason = g_fake_et_end_reason ? g_fake_et_end_reason : "closed by client";
    dispatch_sync(c->work, ^{ if (c->on_end) c->on_end(c->ctx, reason); });
    delete c;
}
