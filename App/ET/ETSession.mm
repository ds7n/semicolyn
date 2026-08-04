// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
#import "ETSession.h"
#if __has_include(<eternaltermlib.h>)
#import <eternaltermlib.h>
#else
#import "eternaltermlib.h"
#endif

@implementation ETSession {
    NSString *_host; uint16_t _port; NSString *_id; NSString *_passkey;
    NSDictionary<NSString *, NSString *> *_env;
    uint16_t _cols, _rows, _width, _height; int32_t _keepalive;

    dispatch_queue_t _api;      // serial: owns send/resize/close ordering
    et_client *_handle;         // touched only on _api
    BOOL _closed;               // touched only on _api
    BOOL _firstFrameSent;       // touched only on main (set before onOutput)
}

- (instancetype)initWithHost:(NSString *)host port:(uint16_t)port id:(NSString *)clientID
                     passkey:(NSString *)passkey env:(NSDictionary<NSString *,NSString *> *)env
                        cols:(uint16_t)cols rows:(uint16_t)rows width:(uint16_t)width
                      height:(uint16_t)height keepaliveSecs:(int32_t)keepaliveSecs {
    if ((self = [super init])) {
        _host = [host copy]; _port = port; _id = [clientID copy]; _passkey = [passkey copy];
        _env = [env copy]; _cols = cols; _rows = rows; _width = width; _height = height;
        _keepalive = keepaliveSecs;
        _api = dispatch_queue_create("dev.truepositive.semicolyn.et.api", DISPATCH_QUEUE_SERIAL);
        _handle = NULL; _closed = NO; _firstFrameSent = NO;
    }
    return self;
}

// ---- C trampolines: ctx is the ETSession* (unretained; the object outlives the
// handle because -close joins the transport thread before dealloc). ----

static void et_on_bytes(void *ctx, const uint8_t *buf, size_t len) {
    ETSession *self = (__bridge ETSession *)ctx;
    NSData *data = [NSData dataWithBytes:buf length:len];   // COPY inside the callback
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self->_firstFrameSent) {
            self->_firstFrameSent = YES;
            if (self.onFirstFrame) self.onFirstFrame();
        }
        if (self.onOutput) self.onOutput(data);
    });
}

static void et_on_state(void *ctx, et_state state) {
    ETSession *self = (__bridge ETSession *)ctx;
    NSInteger raw = (NSInteger)state;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.onState) self.onState(raw);
    });
}

static void et_on_end(void *ctx, const char *reason) {
    ETSession *self = (__bridge ETSession *)ctx;
    NSString *r = reason ? [NSString stringWithUTF8String:reason] : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.onEnd) self.onEnd(r);   // RAW; Swift sanitizes
    });
}

- (void)start {
    dispatch_async(_api, ^{
        if (self->_closed || self->_handle) return;

        // Flat env arrays (deep-copied by et_connect; freed on return).
        NSArray<NSString *> *keys = self->_env.allKeys;
        size_t n = keys.count;
        const char **ck = (const char **)malloc(sizeof(char *) * (n ?: 1));
        const char **cv = (const char **)malloc(sizeof(char *) * (n ?: 1));
        for (size_t i = 0; i < n; i++) {
            ck[i] = [keys[i] UTF8String];
            cv[i] = [self->_env[keys[i]] UTF8String];
        }

        et_config cfg = {0};
        cfg.host = [self->_host UTF8String];
        cfg.port = self->_port;
        cfg.id = [self->_id UTF8String];
        cfg.passkey = [self->_passkey UTF8String];
        cfg.env_keys = ck; cfg.env_vals = cv; cfg.env_count = n;
        cfg.cols = self->_cols; cfg.rows = self->_rows;
        cfg.width = self->_width; cfg.height = self->_height;
        cfg.keepalive_secs = self->_keepalive;

        et_callbacks cbs = { et_on_bytes, et_on_state, et_on_end };
        self->_handle = et_connect(&cfg, &cbs, (__bridge void *)self);
        free(ck); free(cv);

        if (self->_handle == NULL) {
            // Synchronous arg failure. Report as a teardown so the caller sees it.
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.onEnd) self.onEnd(@"et_connect failed");
            });
        }
    });
}

- (void)send:(NSData *)bytes {
    NSData *copy = [bytes copy];
    dispatch_async(_api, ^{
        if (self->_closed || self->_handle == NULL) return;
        et_send(self->_handle, (const uint8_t *)copy.bytes, copy.length);
    });
}

- (void)setWindowSizeCols:(uint16_t)cols rows:(uint16_t)rows
                    width:(uint16_t)width height:(uint16_t)height {
    dispatch_async(_api, ^{
        if (self->_closed || self->_handle == NULL) return;
        et_set_window_size(self->_handle, cols, rows, width, height);
    });
}

- (void)close {
    dispatch_async(_api, ^{
        if (self->_closed) return;
        self->_closed = YES;
        if (self->_handle) { et_close(self->_handle); self->_handle = NULL; }
    });
}

@end
